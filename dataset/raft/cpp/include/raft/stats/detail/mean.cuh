/*
 * Copyright (c) 2021-2024, NVIDIA CORPORATION.
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

#pragma once

#include <raft/linalg/eltwise.cuh>
#include <raft/linalg/reduce.cuh>
#include <raft/util/cuda_utils.cuh>

#include <cub/cub.cuh>

namespace raft {
namespace stats {
namespace detail {

template <bool rowMajor, typename Type, typename IdxType = int>
void mean(Type* mu, const Type* data, IdxType D, IdxType N, cudaStream_t stream)
{
  Type ratio = Type(1) / Type(N);
  raft::linalg::reduce<rowMajor, false>(mu,
                                        data,
                                        D,
                                        N,
                                        Type(0),
                                        stream,
                                        false,
                                        raft::identity_op(),
                                        raft::add_op(),
                                        raft::mul_const_op<Type>(ratio));
}

template <bool rowMajor, typename Type, typename IdxType = int>
[[deprecated]] void mean(
  Type* mu, const Type* data, IdxType D, IdxType N, bool sample, cudaStream_t stream)
{
  Type ratio = Type(1) / ((sample) ? Type(N - 1) : Type(N));
  raft::linalg::reduce<rowMajor, false>(mu,
                                        data,
                                        D,
                                        N,
                                        Type(0),
                                        stream,
                                        false,
                                        raft::identity_op(),
                                        raft::add_op(),
                                        raft::mul_const_op<Type>(ratio));
}

}  // namespace detail
}  // namespace stats
}  // namespace raft
