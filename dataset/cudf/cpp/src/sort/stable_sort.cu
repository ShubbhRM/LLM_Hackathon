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

#include "sort_impl.cuh"
#include "sort_radix.hpp"

#include <cudf/column/column.hpp>
#include <cudf/detail/gather.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/detail/sorting.hpp>
#include <cudf/sorting.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/utilities/default_stream.hpp>
#include <cudf/utilities/memory_resource.hpp>

#include <rmm/cuda_stream_view.hpp>

namespace cudf {
namespace detail {
std::unique_ptr<column> stable_sorted_order(table_view const& input,
                                            std::vector<order> const& column_order,
                                            std::vector<null_order> const& null_precedence,
                                            rmm::cuda_stream_view stream,
                                            rmm::device_async_resource_ref mr)
{
  return sorted_order<sort_method::STABLE>(input, column_order, null_precedence, stream, mr);
}

std::unique_ptr<table> stable_sort(table_view const& input,
                                   std::vector<order> const& column_order,
                                   std::vector<null_order> const& null_precedence,
                                   rmm::cuda_stream_view stream,
                                   rmm::device_async_resource_ref mr)
{
  // fast-path sort conditions: single, fixed-width column with no nulls
  if (input.num_columns() == 1 && is_radix_sortable(input.column(0))) {
    auto order  = (column_order.empty() ? order::ASCENDING : column_order.front());
    auto output = sort_radix(input.column(0), order == order::ASCENDING, stream, mr);
    std::vector<std::unique_ptr<column>> columns;
    columns.emplace_back(std::move(output));
    return std::make_unique<table>(std::move(columns));
  }
  return detail::stable_sort_by_key(input, input, column_order, null_precedence, stream, mr);
}

std::unique_ptr<table> stable_sort_by_key(table_view const& values,
                                          table_view const& keys,
                                          std::vector<order> const& column_order,
                                          std::vector<null_order> const& null_precedence,
                                          rmm::cuda_stream_view stream,
                                          rmm::device_async_resource_ref mr)
{
  CUDF_EXPECTS(values.num_rows() == keys.num_rows(),
               "Mismatch in number of rows for values and keys");

  auto sorted_order = detail::stable_sorted_order(
    keys, column_order, null_precedence, stream, cudf::get_current_device_resource_ref());

  return detail::gather(values,
                        sorted_order->view(),
                        out_of_bounds_policy::DONT_CHECK,
                        detail::negative_index_policy::NOT_ALLOWED,
                        stream,
                        mr);
}
}  // namespace detail

std::unique_ptr<column> stable_sorted_order(table_view const& input,
                                            std::vector<order> const& column_order,
                                            std::vector<null_order> const& null_precedence,
                                            rmm::cuda_stream_view stream,
                                            rmm::device_async_resource_ref mr)
{
  CUDF_FUNC_RANGE();
  return detail::stable_sorted_order(input, column_order, null_precedence, stream, mr);
}

std::unique_ptr<table> stable_sort(table_view const& input,
                                   std::vector<order> const& column_order,
                                   std::vector<null_order> const& null_precedence,
                                   rmm::cuda_stream_view stream,
                                   rmm::device_async_resource_ref mr)
{
  CUDF_FUNC_RANGE();
  return detail::stable_sort(input, column_order, null_precedence, stream, mr);
}

std::unique_ptr<table> stable_sort_by_key(table_view const& values,
                                          table_view const& keys,
                                          std::vector<order> const& column_order,
                                          std::vector<null_order> const& null_precedence,
                                          rmm::cuda_stream_view stream,
                                          rmm::device_async_resource_ref mr)
{
  CUDF_FUNC_RANGE();
  return detail::stable_sort_by_key(values, keys, column_order, null_precedence, stream, mr);
}

}  // namespace cudf
