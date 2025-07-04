/*
 * Copyright (c) 2019-2025, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cudf/column/column.hpp>
#include <cudf/column/column_device_view.cuh>
#include <cudf/column/column_factories.hpp>
#include <cudf/detail/copy.hpp>
#include <cudf/detail/iterator.cuh>
#include <cudf/detail/null_mask.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/dictionary/detail/search.hpp>
#include <cudf/dictionary/detail/update_keys.hpp>
#include <cudf/dictionary/dictionary_column_view.hpp>
#include <cudf/dictionary/dictionary_factories.hpp>
#include <cudf/replace.hpp>
#include <cudf/scalar/scalar.hpp>
#include <cudf/scalar/scalar_device_view.cuh>
#include <cudf/strings/detail/strings_column_factories.cuh>
#include <cudf/strings/detail/utilities.cuh>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/default_stream.hpp>
#include <cudf/utilities/error.hpp>
#include <cudf/utilities/memory_resource.hpp>
#include <cudf/utilities/type_checks.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/exec_policy.hpp>

#include <cuda/functional>
#include <thrust/for_each.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/transform_iterator.h>
#include <thrust/iterator/zip_iterator.h>
#include <thrust/transform.h>
#include <thrust/tuple.h>

namespace cudf {
namespace detail {
namespace {

template <typename OptionalScalarIterator, typename ReplaceScalarIterator>
struct clamp_strings_fn {
  using string_index_pair = cudf::strings::detail::string_index_pair;
  column_device_view const d_strings;
  OptionalScalarIterator lo_itr;
  ReplaceScalarIterator lo_replace_itr;
  OptionalScalarIterator hi_itr;
  ReplaceScalarIterator hi_replace_itr;

  __device__ string_index_pair operator()(size_type idx) const
  {
    if (d_strings.is_null(idx)) { return string_index_pair{nullptr, 0}; }

    auto const element      = d_strings.element<string_view>(idx);
    auto const d_lo         = (*lo_itr).value_or(element);
    auto const d_hi         = (*hi_itr).value_or(element);
    auto const d_lo_replace = *(*lo_replace_itr);
    auto const d_hi_replace = *(*hi_replace_itr);

    auto d_str = [d_lo, d_lo_replace, d_hi, d_hi_replace, element] {
      if (element < d_lo) { return d_lo_replace; }
      if (d_hi < element) { return d_hi_replace; }
      return element;
    }();

    // ensures an empty string is not converted to a null row
    return !d_str.empty() ? string_index_pair{d_str.data(), d_str.size_bytes()}
                          : string_index_pair{"", 0};
  }
};

template <typename OptionalScalarIterator, typename ReplaceScalarIterator>
std::unique_ptr<cudf::column> clamp_string_column(strings_column_view const& input,
                                                  OptionalScalarIterator lo_itr,
                                                  ReplaceScalarIterator lo_replace_itr,
                                                  OptionalScalarIterator hi_itr,
                                                  ReplaceScalarIterator hi_replace_itr,
                                                  rmm::cuda_stream_view stream,
                                                  rmm::device_async_resource_ref mr)
{
  auto input_device_column = column_device_view::create(input.parent(), stream);
  auto d_input             = *input_device_column;

  auto fn = clamp_strings_fn<OptionalScalarIterator, ReplaceScalarIterator>{
    d_input, lo_itr, lo_replace_itr, hi_itr, hi_replace_itr};
  rmm::device_uvector<cudf::strings::detail::string_index_pair> indices(input.size(), stream);
  thrust::transform(rmm::exec_policy_nosync(stream),
                    thrust::counting_iterator<size_type>(0),
                    thrust::counting_iterator<size_type>(input.size()),
                    indices.begin(),
                    fn);

  return cudf::strings::detail::make_strings_column(indices.begin(), indices.end(), stream, mr);
}

template <typename T, typename OptionalScalarIterator, typename ReplaceScalarIterator>
std::unique_ptr<cudf::column> clamper(column_view const& input,
                                      OptionalScalarIterator lo_itr,
                                      ReplaceScalarIterator lo_replace_itr,
                                      OptionalScalarIterator hi_itr,
                                      ReplaceScalarIterator hi_replace_itr,
                                      rmm::cuda_stream_view stream,
                                      rmm::device_async_resource_ref mr)
  requires(cudf::is_fixed_width<T>())
{
  auto output =
    detail::allocate_like(input, input.size(), mask_allocation_policy::NEVER, stream, mr);
  // mask will not change
  if (input.nullable()) {
    output->set_null_mask(cudf::detail::copy_bitmask(input, stream, mr), input.null_count());
  }

  auto output_device_view =
    cudf::mutable_column_device_view::create(output->mutable_view(), stream);
  auto input_device_view = cudf::column_device_view::create(input, stream);
  auto scalar_zip_itr =
    thrust::make_zip_iterator(thrust::make_tuple(lo_itr, lo_replace_itr, hi_itr, hi_replace_itr));

  auto trans =
    cuda::proclaim_return_type<T>([] __device__(auto element_optional, auto scalar_tuple) {
      if (element_optional.has_value()) {
        auto lo_optional = thrust::get<0>(scalar_tuple);
        auto hi_optional = thrust::get<2>(scalar_tuple);
        if (lo_optional.has_value() and (*element_optional < *lo_optional)) {
          return *(thrust::get<1>(scalar_tuple));
        } else if (hi_optional.has_value() and (*element_optional > *hi_optional)) {
          return *(thrust::get<3>(scalar_tuple));
        }
        return *element_optional;
      }
      return T{};  // null entry so value is ignored
    });

  auto input_pair_iterator =
    make_optional_iterator<T>(*input_device_view, nullate::DYNAMIC{input.has_nulls()});
  thrust::transform(rmm::exec_policy(stream),
                    input_pair_iterator,
                    input_pair_iterator + input.size(),
                    scalar_zip_itr,
                    output_device_view->begin<T>(),
                    trans);

  return output;
}

template <typename T, typename OptionalScalarIterator, typename ReplaceScalarIterator>
std::unique_ptr<cudf::column> clamper(column_view const& input,
                                      OptionalScalarIterator lo_itr,
                                      ReplaceScalarIterator lo_replace_itr,
                                      OptionalScalarIterator hi_itr,
                                      ReplaceScalarIterator hi_replace_itr,
                                      rmm::cuda_stream_view stream,
                                      rmm::device_async_resource_ref mr)
  requires(std::is_same_v<T, string_view>)
{
  return clamp_string_column(input, lo_itr, lo_replace_itr, hi_itr, hi_replace_itr, stream, mr);
}

}  // namespace

template <typename T, typename OptionalScalarIterator, typename ReplaceScalarIterator>
std::unique_ptr<column> clamp(column_view const& input,
                              OptionalScalarIterator lo_itr,
                              ReplaceScalarIterator lo_replace_itr,
                              OptionalScalarIterator hi_itr,
                              ReplaceScalarIterator hi_replace_itr,
                              rmm::cuda_stream_view stream,
                              rmm::device_async_resource_ref mr)
{
  return clamper<T>(input, lo_itr, lo_replace_itr, hi_itr, hi_replace_itr, stream, mr);
}

struct dispatch_clamp {
  template <typename T>
  std::unique_ptr<column> operator()(column_view const& input,
                                     scalar const& lo,
                                     scalar const& lo_replace,
                                     scalar const& hi,
                                     scalar const& hi_replace,
                                     rmm::cuda_stream_view stream,
                                     rmm::device_async_resource_ref mr)
  {
    CUDF_EXPECTS(cudf::have_same_types(input, lo),
                 "mismatching types of scalar and input",
                 cudf::data_type_error);

    auto lo_itr         = make_optional_iterator<T>(lo, nullate::YES{});
    auto hi_itr         = make_optional_iterator<T>(hi, nullate::YES{});
    auto lo_replace_itr = make_optional_iterator<T>(lo_replace, nullate::NO{});
    auto hi_replace_itr = make_optional_iterator<T>(hi_replace, nullate::NO{});

    return clamp<T>(input, lo_itr, lo_replace_itr, hi_itr, hi_replace_itr, stream, mr);
  }
};

template <>
std::unique_ptr<column> dispatch_clamp::operator()<cudf::list_view>(
  column_view const& input,
  scalar const& lo,
  scalar const& lo_replace,
  scalar const& hi,
  scalar const& hi_replace,
  rmm::cuda_stream_view stream,
  rmm::device_async_resource_ref mr)
{
  CUDF_FAIL("clamp for list_view not supported");
}

template <>
std::unique_ptr<column> dispatch_clamp::operator()<struct_view>(column_view const& input,
                                                                scalar const& lo,
                                                                scalar const& lo_replace,
                                                                scalar const& hi,
                                                                scalar const& hi_replace,
                                                                rmm::cuda_stream_view stream,
                                                                rmm::device_async_resource_ref mr)
{
  CUDF_FAIL("clamp for struct_view not supported");
}

template <>
std::unique_ptr<column> dispatch_clamp::operator()<cudf::dictionary32>(
  column_view const& input,
  scalar const& lo,
  scalar const& lo_replace,
  scalar const& hi,
  scalar const& hi_replace,
  rmm::cuda_stream_view stream,
  rmm::device_async_resource_ref mr)
{
  // add lo_replace and hi_replace to keys
  auto matched_column = [&] {
    auto matched_view              = dictionary_column_view(input);
    std::unique_ptr<column> result = nullptr;
    auto add_scalar_key            = [&](scalar const& key, scalar const& key_replace) {
      if (key.is_valid(stream)) {
        result = dictionary::detail::add_keys(
          matched_view, make_column_from_scalar(key_replace, 1, stream)->view(), stream, mr);
        matched_view = dictionary_column_view(result->view());
      }
    };
    add_scalar_key(lo, lo_replace);
    add_scalar_key(hi, hi_replace);
    return result;
  }();
  auto matched_view = dictionary_column_view(matched_column->view());
  auto default_mr   = cudf::get_current_device_resource_ref();

  // get the indexes for lo_replace and for hi_replace
  auto lo_replace_index =
    dictionary::detail::get_index(matched_view, lo_replace, stream, default_mr);
  auto hi_replace_index =
    dictionary::detail::get_index(matched_view, hi_replace, stream, default_mr);

  // get the closest indexes for lo and for hi
  auto lo_index = dictionary::detail::get_insert_index(matched_view, lo, stream, default_mr);
  auto hi_index = dictionary::detail::get_insert_index(matched_view, hi, stream, default_mr);

  // call clamp with the scalar indexes and the matched indices
  auto matched_indices = matched_view.get_indices_annotated();
  auto new_indices     = cudf::type_dispatcher<dispatch_storage_type>(matched_indices.type(),
                                                                  dispatch_clamp{},
                                                                  matched_indices,
                                                                  *lo_index,
                                                                  *lo_replace_index,
                                                                  *hi_index,
                                                                  *hi_replace_index,
                                                                  stream,
                                                                  mr);

  auto const indices_type = new_indices->type();
  auto const output_size  = new_indices->size();
  auto const null_count   = new_indices->null_count();
  auto contents           = new_indices->release();
  auto indices_column     = std::make_unique<column>(indices_type,
                                                 static_cast<size_type>(output_size),
                                                 std::move(*(contents.data.release())),
                                                 rmm::device_buffer{},
                                                 0);

  // take the keys from the matched column allocated using mr
  std::unique_ptr<column> keys_column(std::move(matched_column->release().children.back()));

  // create column with keys_column and indices_column
  return make_dictionary_column(std::move(keys_column),
                                std::move(indices_column),
                                std::move(*(contents.null_mask.release())),
                                null_count);
}

/**
 * @copydoc cudf::clamp(column_view const& input,
                                      scalar const& lo,
                                      scalar const& lo_replace,
                                      scalar const& hi,
                                      scalar const& hi_replace,
                                      rmm::device_async_resource_ref mr);
 *
 * @param[in] stream CUDA stream used for device memory operations and kernel launches.
 */
std::unique_ptr<column> clamp(column_view const& input,
                              scalar const& lo,
                              scalar const& lo_replace,
                              scalar const& hi,
                              scalar const& hi_replace,
                              rmm::cuda_stream_view stream,
                              rmm::device_async_resource_ref mr)
{
  CUDF_EXPECTS(
    cudf::have_same_types(lo, hi), "mismatching types of limit scalars", cudf::data_type_error);
  CUDF_EXPECTS(cudf::have_same_types(lo_replace, hi_replace),
               "mismatching types of replace scalars",
               cudf::data_type_error);
  CUDF_EXPECTS(cudf::have_same_types(lo, lo_replace),
               "mismatching types of limit and replace scalars",
               cudf::data_type_error);

  if ((not lo.is_valid(stream) and not hi.is_valid(stream)) or (input.is_empty())) {
    // There will be no change
    return std::make_unique<column>(input, stream, mr);
  }

  if (lo.is_valid(stream)) {
    CUDF_EXPECTS(lo_replace.is_valid(stream), "lo_replace can't be null if lo is not null");
  }
  if (hi.is_valid(stream)) {
    CUDF_EXPECTS(hi_replace.is_valid(stream), "hi_replace can't be null if hi is not null");
  }

  return cudf::type_dispatcher<dispatch_storage_type>(
    input.type(), dispatch_clamp{}, input, lo, lo_replace, hi, hi_replace, stream, mr);
}

}  // namespace detail

// clamp input at lo and hi with lo_replace and hi_replace
std::unique_ptr<column> clamp(column_view const& input,
                              scalar const& lo,
                              scalar const& lo_replace,
                              scalar const& hi,
                              scalar const& hi_replace,
                              rmm::cuda_stream_view stream,
                              rmm::device_async_resource_ref mr)
{
  CUDF_FUNC_RANGE();
  return detail::clamp(input, lo, lo_replace, hi, hi_replace, stream, mr);
}

// clamp input at lo and hi
std::unique_ptr<column> clamp(column_view const& input,
                              scalar const& lo,
                              scalar const& hi,
                              rmm::cuda_stream_view stream,
                              rmm::device_async_resource_ref mr)
{
  CUDF_FUNC_RANGE();
  return detail::clamp(input, lo, lo, hi, hi, stream, mr);
}
}  // namespace cudf
