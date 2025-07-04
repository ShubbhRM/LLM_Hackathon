/*
 * Copyright (c) 2020-2025, NVIDIA CORPORATION.
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

#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/detail/null_mask.hpp>
#include <cudf/detail/unary.hpp>
#include <cudf/dictionary/detail/encode.hpp>
#include <cudf/dictionary/dictionary_factories.hpp>
#include <cudf/utilities/memory_resource.hpp>
#include <cudf/utilities/type_dispatcher.hpp>

#include <rmm/cuda_stream_view.hpp>

namespace cudf {
namespace {
struct dispatch_create_indices {
  template <typename IndexType>
  std::unique_ptr<column> operator()(column_view const& indices,
                                     rmm::cuda_stream_view stream,
                                     rmm::device_async_resource_ref mr)
    requires(is_index_type<IndexType>())
  {
    CUDF_EXPECTS(cudf::is_signed<IndexType>(), "indices must be a signed type");
    column_view indices_view{
      indices.type(), indices.size(), indices.data<IndexType>(), nullptr, 0, indices.offset()};
    return std::make_unique<column>(indices_view, stream, mr);
  }
  template <typename IndexType>
  std::unique_ptr<column> operator()(column_view const&,
                                     rmm::cuda_stream_view,
                                     rmm::device_async_resource_ref)
    requires(!is_index_type<IndexType>())
  {
    CUDF_FAIL("indices must be an integer type.");
  }
};
}  // namespace

std::unique_ptr<column> make_dictionary_column(column_view const& keys_column,
                                               column_view const& indices_column,
                                               rmm::cuda_stream_view stream,
                                               rmm::device_async_resource_ref mr)
{
  CUDF_EXPECTS(!keys_column.has_nulls(), "keys column must not have nulls");
  if (keys_column.is_empty()) return make_empty_column(type_id::DICTIONARY32);

  auto keys_copy = std::make_unique<column>(keys_column, stream, mr);
  auto indices_copy =
    type_dispatcher(indices_column.type(), dispatch_create_indices{}, indices_column, stream, mr);
  rmm::device_buffer null_mask{0, stream, mr};
  auto null_count = indices_column.null_count();
  if (null_count) null_mask = detail::copy_bitmask(indices_column, stream, mr);

  std::vector<std::unique_ptr<column>> children;
  children.emplace_back(std::move(indices_copy));
  children.emplace_back(std::move(keys_copy));
  return std::make_unique<column>(data_type{type_id::DICTIONARY32},
                                  indices_column.size(),
                                  rmm::device_buffer{0, stream, mr},
                                  std::move(null_mask),
                                  null_count,
                                  std::move(children));
}

std::unique_ptr<column> make_dictionary_column(std::unique_ptr<column> keys_column,
                                               std::unique_ptr<column> indices_column,
                                               rmm::device_buffer&& null_mask,
                                               size_type null_count,
                                               rmm::cuda_stream_view stream,
                                               rmm::device_async_resource_ref mr)
{
  CUDF_EXPECTS(!keys_column->has_nulls(), "keys column must not have nulls");
  CUDF_EXPECTS(!indices_column->has_nulls(), "indices column must not have nulls");
  CUDF_EXPECTS(is_signed(indices_column->type()) && is_index_type(indices_column->type()),
               "indices must be type unsigned integer");

  auto count = indices_column->size();
  std::vector<std::unique_ptr<column>> children;
  children.emplace_back(std::move(indices_column));
  children.emplace_back(std::move(keys_column));
  return std::make_unique<column>(data_type{type_id::DICTIONARY32},
                                  count,
                                  rmm::device_buffer{0, stream, mr},
                                  std::move(null_mask),
                                  null_count,
                                  std::move(children));
}

namespace {

/**
 * @brief This functor maps signed type_ids to unsigned counterparts.
 */
struct make_unsigned_fn {
  template <typename T>
  constexpr cudf::type_id operator()()
    requires(is_index_type<T>())
  {
    return cudf::type_to_id<std::make_unsigned_t<T>>();
  }
  template <typename T>
  constexpr cudf::type_id operator()()
    requires(not is_index_type<T>())
  {
    return cudf::type_to_id<T>();
  }
};

}  // namespace

std::unique_ptr<column> make_dictionary_column(std::unique_ptr<column> keys,
                                               std::unique_ptr<column> indices,
                                               rmm::cuda_stream_view stream,
                                               rmm::device_async_resource_ref mr)
{
  CUDF_EXPECTS(!keys->has_nulls(), "keys column must not have nulls");

  // signed integer data can be used directly in the unsigned indices column
  auto const indices_type = cudf::type_dispatcher(indices->type(), make_unsigned_fn{});
  auto const indices_size = indices->size();        // these need to be saved
  auto const null_count   = indices->null_count();  // before calling release()
  auto contents           = indices->release();
  // compute the indices type using the size of the key set
  auto const new_type = dictionary::detail::get_indices_type_for_size(keys->size());

  // create the dictionary indices: convert to unsigned and remove nulls
  auto indices_column = [&] {
    // If the types match, then just commandeer the column's data buffer.
    if (new_type.id() == indices_type) {
      return std::make_unique<column>(new_type,
                                      indices_size,
                                      std::move(*(contents.data.release())),
                                      rmm::device_buffer{0, stream, mr},
                                      0);
    }
    // If the new type does not match, then convert the data.
    cudf::column_view cast_view{
      cudf::data_type{indices_type}, indices_size, contents.data->data(), nullptr, 0};
    return cudf::detail::cast(cast_view, new_type, stream, mr);
  }();

  return make_dictionary_column(std::move(keys),
                                std::move(indices_column),
                                std::move(*(contents.null_mask.release())),
                                null_count);
}

}  // namespace cudf
