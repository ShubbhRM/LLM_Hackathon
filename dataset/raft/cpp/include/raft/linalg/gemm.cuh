/*
 * Copyright (c) 2022-2024, NVIDIA CORPORATION.
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
#ifndef __GEMM_H
#define __GEMM_H

#pragma once

#ifndef RAFT_HIDE_DEPRECATION_WARNINGS
#pragma message(__FILE__                                                  \
                " is deprecated and will be removed in a future release." \
                " Use raft/linalg/gemm.hpp instead.")
#endif

#include "detail/gemm.hpp"
#include "gemm.hpp"  // Part of the API transferred to the non-deprecated file

#include <raft/core/device_mdarray.hpp>
#include <raft/core/device_mdspan.hpp>
#include <raft/core/host_mdarray.hpp>
#include <raft/core/host_mdspan.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <raft/core/resources.hpp>
#include <raft/util/input_validation.hpp>

namespace raft::linalg {

/**
 * @brief the wrapper of cublas gemm function
 *  It computes the following equation: C = alpha .* opA(A) * opB(B) + beta .* C
 *
 * @tparam A_t the element type of A
 * @tparam B_t the element type of B
 * @tparam C_t the element type of C
 * @tparam S_t the element type of alpha and beta
 * @tparam DevicePointerMode whether pointers alpha, beta point to device memory
 * @param [in] handle raft handle
 * @param [in] trans_a cublas transpose op for A
 * @param [in] trans_b cublas transpose op for B
 * @param [in] m number of rows of C
 * @param [in] n number of columns of C
 * @param [in] k number of rows of opB(B) / number of columns of opA(A)
 * @param [in] alpha host or device scalar
 * @param [in] A such a matrix that the shape of column-major opA(A) is [m, k]
 * @param [in] lda leading dimension of A
 * @param [in] B such a matrix that the shape of column-major opA(B) is [k, n]
 * @param [in] ldb leading dimension of B
 * @param [in] beta host or device scalar
 * @param [inout] C column-major matrix of size [m, n]
 * @param [in] ldc leading dimension of C
 * @param [in] stream
 */
template <typename A_t, typename B_t, typename C_t, typename S_t, bool DevicePointerMode = false>
void gemm(raft::resources const& handle,
          const bool trans_a,
          const bool trans_b,
          const int m,
          const int n,
          const int k,
          const S_t* alpha,
          const A_t* A,
          const int lda,
          const B_t* B,
          const int ldb,
          const S_t* beta,
          C_t* C,
          const int ldc,
          cudaStream_t stream)
{
  return detail::legacy_gemm(
    handle, trans_a, trans_b, m, n, k, alpha, A, lda, B, ldb, beta, C, ldc, stream);
}

/**
 * @brief the wrapper of cublas gemm function
 *  It computes the following equation: D = alpha . opA(A) * opB(B) + beta . C
 * @tparam A_t the element type of A
 * @tparam B_t the element type of B
 * @tparam C_t the element type of C
 * @tparam S_t the element type of alpha and beta
 * @param handle raft handle
 * @param a input matrix
 * @param n_rows_a number of rows of A
 * @param n_cols_a number of columns of A
 * @param b input matrix
 * @param c output matrix
 * @param n_rows_c number of rows of C
 * @param n_cols_c number of columns of C
 * @param trans_a cublas transpose op for A
 * @param trans_b cublas transpose op for B
 * @param alpha scalar
 * @param beta scalar
 * @param stream cuda stream
 */
template <typename A_t, typename B_t, typename C_t, typename S_t>
void gemm(raft::resources const& handle,
          const A_t* a,
          int n_rows_a,
          int n_cols_a,
          const B_t* b,
          C_t* c,
          int n_rows_c,
          int n_cols_c,
          cublasOperation_t trans_a,
          cublasOperation_t trans_b,
          S_t alpha,
          S_t beta,
          cudaStream_t stream)
{
  detail::legacy_gemm(
    handle, a, n_rows_a, n_cols_a, b, c, n_rows_c, n_cols_c, trans_a, trans_b, alpha, beta, stream);
}

/**
 * @brief the wrapper of cublas gemm function
 *  It computes the following equation: D = alpha . opA(A) * opB(B) + beta . C
 * @tparam A_t the element type of A
 * @tparam B_t the element type of B
 * @tparam C_t the element type of C
 * @param handle raft handle
 * @param a input matrix
 * @param n_rows_a number of rows of A
 * @param n_cols_a number of columns of A
 * @param b input matrix
 * @param c output matrix
 * @param n_rows_c number of rows of C
 * @param n_cols_c number of columns of C
 * @param trans_a cublas transpose op for A
 * @param trans_b cublas transpose op for B
 * @param stream cuda stream
 */
template <typename A_t, typename B_t, typename C_t>
void gemm(raft::resources const& handle,
          const A_t* a,
          int n_rows_a,
          int n_cols_a,
          const B_t* b,
          C_t* c,
          int n_rows_c,
          int n_cols_c,
          cublasOperation_t trans_a,
          cublasOperation_t trans_b,
          cudaStream_t stream)
{
  detail::legacy_gemm(
    handle, a, n_rows_a, n_cols_a, b, c, n_rows_c, n_cols_c, trans_a, trans_b, stream);
}

/**
 * @brief A wrapper for CUBLS GEMM function designed for handling all possible
 * combinations of operand layouts.
 * It computes the following equation: Z = alpha . X * Y + beta . Z
 * @tparam z_T the element type of z
 * @tparam x_T the element type of x
 * @tparam y_T the element type of y
 * @tparam s_T the element type of alpha and beta, equal to z_T by default
 * @param handle raft handle
 * @param z output matrix of size M rows x N columns
 * @param x input matrix of size M rows x K columns
 * @param y input matrix of size K rows x N columns
 * @param _M number of rows of X and Z
 * @param _N number of columns of Y and columns of Z
 * @param _K number of columns of X and rows of Y
 * @param isZColMajor Storage layout of Z. true = col major, false = row major
 * @param isXColMajor Storage layout of X. true = col major, false = row major
 * @param isYColMajor Storage layout of Y. true = col major, false = row major
 * @param stream cuda stream
 * @param alpha scalar
 * @param beta scalar
 */
template <typename z_T, typename x_T, typename y_T, typename s_T = z_T>
void gemm(raft::resources const& handle,
          z_T* z,
          x_T* x,
          y_T* y,
          int _M,
          int _N,
          int _K,
          bool isZColMajor,
          bool isXColMajor,
          bool isYColMajor,
          cudaStream_t stream,
          s_T alpha = s_T(1.0),
          s_T beta  = s_T(0.0))
{
  return detail::legacy_gemm<x_T, y_T, z_T, s_T, false>(
    handle, z, x, y, _M, _N, _K, isZColMajor, isXColMajor, isYColMajor, stream, &alpha, &beta);
}

}  // namespace raft::linalg

#endif
