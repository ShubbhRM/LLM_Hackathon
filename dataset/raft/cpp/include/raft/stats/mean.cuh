/*
 * Copyright (c) 2018-2024, NVIDIA CORPORATION.
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

#ifndef __MEAN_H
#define __MEAN_H

#pragma once

#include <raft/core/device_mdspan.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <raft/core/resources.hpp>
#include <raft/stats/detail/mean.cuh>

namespace raft {
namespace stats {

/**
 * @brief Compute mean of the input matrix
 *
 * Mean operation is assumed to be performed on a given column.
 *
 * @tparam rowMajor: whether the input data is row or col major
 * @tparam Type: the data type
 * @tparam IdxType Integer type used to for addressing
 * @param mu: the output mean vector
 * @param data: the input matrix
 * @param D: number of columns of data
 * @param N: number of rows of data
 * @param stream: cuda stream
 */
template <bool rowMajor, typename Type, typename IdxType = int>
void mean(Type* mu, const Type* data, IdxType D, IdxType N, cudaStream_t stream)
{
  detail::mean<rowMajor>(mu, data, D, N, stream);
}

/**
 * @brief Compute mean of the input matrix
 *
 * Mean operation is assumed to be performed on a given column.
 * Note: This call is deprecated, please use `mean` call without `sample` parameter.
 *
 * @tparam rowMajor: whether the input data is row or col major
 * @tparam Type: the data type
 * @tparam IdxType Integer type used to for addressing
 * @param mu: the output mean vector
 * @param data: the input matrix
 * @param D: number of columns of data
 * @param N: number of rows of data
 * @param sample: whether to evaluate sample mean or not. In other words,
 * whether
 *  to normalize the output using N-1 or N, for true or false, respectively
 * @param stream: cuda stream
 */
template <bool rowMajor, typename Type, typename IdxType = int>
[[deprecated("'sample' parameter deprecated")]] void mean(
  Type* mu, const Type* data, IdxType D, IdxType N, bool sample, cudaStream_t stream)
{
  detail::mean<rowMajor>(mu, data, D, N, sample, stream);
}

/**
 * @defgroup stats_mean Mean
 * @{
 */

/**
 * @brief Compute mean of the input matrix
 *
 * Mean operation is assumed to be performed on a given column.
 *
 * @tparam value_t the data type
 * @tparam idx_t index type
 * @tparam layout_t Layout type of the input matrix.
 * @param[in]  handle the raft handle
 * @param[in]  data: the input matrix
 * @param[out] mu: the output mean vector
 */
template <typename value_t, typename idx_t, typename layout_t>
void mean(raft::resources const& handle,
          raft::device_matrix_view<const value_t, idx_t, layout_t> data,
          raft::device_vector_view<value_t, idx_t> mu)
{
  static_assert(
    std::is_same_v<layout_t, raft::row_major> || std::is_same_v<layout_t, raft::col_major>,
    "Data layout not supported");
  RAFT_EXPECTS(data.extent(1) == mu.extent(0), "Size mismatch between data and mu");
  RAFT_EXPECTS(mu.is_exhaustive(), "mu must be contiguous");
  RAFT_EXPECTS(data.is_exhaustive(), "data must be contiguous");
  detail::mean<std::is_same_v<layout_t, raft::row_major>>(mu.data_handle(),
                                                          data.data_handle(),
                                                          data.extent(1),
                                                          data.extent(0),
                                                          resource::get_cuda_stream(handle));
}

/**
 * @brief Compute mean of the input matrix
 *
 * Mean operation is assumed to be performed on a given column.
 * Note: This call is deprecated, please use `mean` call without `sample` parameter.
 *
 * @tparam value_t the data type
 * @tparam idx_t index type
 * @tparam layout_t Layout type of the input matrix.
 * @param[in]  handle the raft handle
 * @param[in]  data: the input matrix
 * @param[out] mu: the output mean vector
 * @param[in]  sample: whether to evaluate sample mean or not. In other words, whether
 *   to normalize the output using N-1 or N, for true or false, respectively
 */
template <typename value_t, typename idx_t, typename layout_t>
[[deprecated("'sample' parameter deprecated")]] void mean(
  raft::resources const& handle,
  raft::device_matrix_view<const value_t, idx_t, layout_t> data,
  raft::device_vector_view<value_t, idx_t> mu,
  bool sample)
{
  static_assert(
    std::is_same_v<layout_t, raft::row_major> || std::is_same_v<layout_t, raft::col_major>,
    "Data layout not supported");
  RAFT_EXPECTS(data.extent(1) == mu.extent(0), "Size mismatch between data and mu");
  RAFT_EXPECTS(mu.is_exhaustive(), "mu must be contiguous");
  RAFT_EXPECTS(data.is_exhaustive(), "data must be contiguous");
  detail::mean<std::is_same_v<layout_t, raft::row_major>>(mu.data_handle(),
                                                          data.data_handle(),
                                                          data.extent(1),
                                                          data.extent(0),
                                                          sample,
                                                          resource::get_cuda_stream(handle));
}

/** @} */  // end group stats_mean

};  // namespace stats
};  // namespace raft

#endif
