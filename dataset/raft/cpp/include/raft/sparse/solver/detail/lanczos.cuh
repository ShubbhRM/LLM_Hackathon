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

#pragma once

// for cmath:
#define _USE_MATH_DEFINES

#include <raft/core/detail/macros.hpp>
#include <raft/core/device_csr_matrix.hpp>
#include <raft/core/device_mdspan.hpp>
#include <raft/core/host_mdarray.hpp>
#include <raft/core/host_mdspan.hpp>
#include <raft/core/logger.hpp>
#include <raft/core/mdspan_types.hpp>
#include <raft/core/resource/cublas_handle.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <raft/core/resources.hpp>
#include <raft/core/types.hpp>
#include <raft/linalg/add.cuh>
#include <raft/linalg/axpy.cuh>
#include <raft/linalg/binary_op.cuh>
#include <raft/linalg/detail/add.cuh>
#include <raft/linalg/detail/cublas_wrappers.hpp>
#include <raft/linalg/detail/gemv.hpp>
#include <raft/linalg/dot.cuh>
#include <raft/linalg/eig.cuh>
#include <raft/linalg/gemm.hpp>
#include <raft/linalg/gemv.cuh>
#include <raft/linalg/init.cuh>
#include <raft/linalg/map.cuh>
#include <raft/linalg/multiply.cuh>
#include <raft/linalg/norm.cuh>
#include <raft/linalg/norm_types.hpp>
#include <raft/linalg/normalize.cuh>
#include <raft/linalg/svd.cuh>
#include <raft/linalg/transpose.cuh>
#include <raft/linalg/unary_op.cuh>
#include <raft/matrix/diagonal.cuh>
#include <raft/matrix/gather.cuh>
#include <raft/matrix/matrix.cuh>
#include <raft/matrix/slice.cuh>
#include <raft/matrix/triangular.cuh>
#include <raft/random/rng.cuh>
#include <raft/sparse/detail/cusparse_wrappers.h>
#include <raft/sparse/linalg/detail/cusparse_utils.hpp>
#include <raft/sparse/solver/lanczos_types.hpp>
#include <raft/spectral/detail/lapack.hpp>
#include <raft/spectral/detail/warn_dbg.hpp>
#include <raft/spectral/matrix_wrappers.hpp>
#include <raft/util/cudart_utils.hpp>

#include <cuda.h>
#include <thrust/sort.h>

#include <cublasLt.h>
#include <curand.h>
#include <cusparse.h>
#include <sys/types.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>
#include <type_traits>
#include <utility>
#include <vector>

namespace raft::sparse::solver::detail {

// curandGeneratorNormalX
inline curandStatus_t curandGenerateNormalX(
  curandGenerator_t generator, float* outputPtr, size_t n, float mean, float stddev)
{
  return curandGenerateNormal(generator, outputPtr, n, mean, stddev);
}
inline curandStatus_t curandGenerateNormalX(
  curandGenerator_t generator, double* outputPtr, size_t n, double mean, double stddev)
{
  return curandGenerateNormalDouble(generator, outputPtr, n, mean, stddev);
}

// =========================================================
// Helper functions
// =========================================================

/**
 *  @brief  Perform Lanczos iteration
 *    Lanczos iteration is performed on a shifted matrix A+shift*I.
 *  @tparam index_type_t the type of data used for indexing.
 *  @tparam value_type_t the type of data used for weights, distances.
 *  @param handle the raft handle.
 *  @param A Matrix.
 *  @param iter Pointer to current Lanczos iteration. On exit, the
 *    variable is set equal to the final Lanczos iteration.
 *  @param maxIter Maximum Lanczos iteration. This function will
 *    perform a maximum of maxIter-*iter iterations.
 *  @param shift Matrix shift.
 *  @param tol Convergence tolerance. Lanczos iteration will
 *    terminate when the residual norm (i.e. entry in beta_host) is
 *    less than tol.
 *  @param reorthogonalize Whether to reorthogonalize Lanczos
 *    vectors.
 *  @param alpha_host (Output, host memory, maxIter entries)
 *    Diagonal entries of Lanczos system.
 *  @param beta_host (Output, host memory, maxIter entries)
 *    Off-diagonal entries of Lanczos system.
 *  @param lanczosVecs_dev (Input/output, device memory,
 *    n*(maxIter+1) entries) Lanczos vectors. Vectors are stored as
 *    columns of a column-major matrix with dimensions
 *    n x (maxIter+1).
 *  @param work_dev (Output, device memory, maxIter entries)
 *    Workspace. Not needed if full reorthogonalization is disabled.
 *  @return Zero if successful. Otherwise non-zero.
 */
template <typename index_type_t, typename value_type_t, typename nnz_type_t>
int performLanczosIteration(
  raft::resources const& handle,
  spectral::matrix::sparse_matrix_t<index_type_t, value_type_t, nnz_type_t> const* A,
  index_type_t* iter,
  index_type_t maxIter,
  value_type_t shift,
  value_type_t tol,
  bool reorthogonalize,
  value_type_t* __restrict__ alpha_host,
  value_type_t* __restrict__ beta_host,
  value_type_t* __restrict__ lanczosVecs_dev,
  value_type_t* __restrict__ work_dev)
{
  // -------------------------------------------------------
  // Variable declaration
  // -------------------------------------------------------

  // Useful variables
  constexpr value_type_t one    = 1;
  constexpr value_type_t negOne = -1;
  constexpr value_type_t zero   = 0;
  value_type_t alpha;

  auto cublas_h = resource::get_cublas_handle(handle);
  auto stream   = resource::get_cuda_stream(handle);

  RAFT_EXPECTS(A != nullptr, "Null matrix pointer.");

  nnz_type_t n = A->nrows_;

  // -------------------------------------------------------
  // Compute second Lanczos vector
  // -------------------------------------------------------
  if (*iter <= 0) {
    *iter = 1;

    // Apply matrix
    if (shift != 0)
      RAFT_CUDA_TRY(cudaMemcpyAsync(lanczosVecs_dev + n,
                                    lanczosVecs_dev,
                                    n * sizeof(value_type_t),
                                    cudaMemcpyDeviceToDevice,
                                    stream));
    A->mv(1, lanczosVecs_dev, shift, lanczosVecs_dev + n);

    // Orthogonalize Lanczos vector
    RAFT_CUBLAS_TRY(raft::linalg::detail::cublasdot(
      cublas_h, n, lanczosVecs_dev, 1, lanczosVecs_dev + IDX(0, 1, n), 1, alpha_host, stream));

    alpha = -alpha_host[0];
    RAFT_CUBLAS_TRY(raft::linalg::detail::cublasaxpy(
      cublas_h, n, &alpha, lanczosVecs_dev, 1, lanczosVecs_dev + IDX(0, 1, n), 1, stream));
    RAFT_CUBLAS_TRY(raft::linalg::detail::cublasnrm2(
      cublas_h, n, lanczosVecs_dev + IDX(0, 1, n), 1, beta_host, stream));

    // Check if Lanczos has converged
    if (beta_host[0] <= tol) return 0;

    // Normalize Lanczos vector
    alpha = 1 / beta_host[0];
    RAFT_CUBLAS_TRY(raft::linalg::detail::cublasscal(
      cublas_h, n, &alpha, lanczosVecs_dev + IDX(0, 1, n), 1, stream));
  }

  // -------------------------------------------------------
  // Compute remaining Lanczos vectors
  // -------------------------------------------------------

  while (*iter < maxIter) {
    ++(*iter);

    // Apply matrix
    if (shift != 0)
      RAFT_CUDA_TRY(cudaMemcpyAsync(lanczosVecs_dev + (*iter) * n,
                                    lanczosVecs_dev + (*iter - 1) * n,
                                    n * sizeof(value_type_t),
                                    cudaMemcpyDeviceToDevice,
                                    stream));
    A->mv(1, lanczosVecs_dev + IDX(0, *iter - 1, n), shift, lanczosVecs_dev + IDX(0, *iter, n));

    // Full reorthogonalization
    //   "Twice is enough" algorithm per Kahan and Parlett
    if (reorthogonalize) {
      RAFT_CUBLAS_TRY(raft::linalg::detail::cublasgemv(cublas_h,
                                                       CUBLAS_OP_T,
                                                       n,
                                                       *iter,
                                                       &one,
                                                       lanczosVecs_dev,
                                                       n,
                                                       lanczosVecs_dev + IDX(0, *iter, n),
                                                       1,
                                                       &zero,
                                                       work_dev,
                                                       1,
                                                       stream));

      RAFT_CUBLAS_TRY(raft::linalg::detail::cublasgemv(cublas_h,
                                                       CUBLAS_OP_N,
                                                       n,
                                                       *iter,
                                                       &negOne,
                                                       lanczosVecs_dev,
                                                       n,
                                                       work_dev,
                                                       1,
                                                       &one,
                                                       lanczosVecs_dev + IDX(0, *iter, n),
                                                       1,
                                                       stream));

      RAFT_CUDA_TRY(cudaMemcpyAsync(alpha_host + (*iter - 1),
                                    work_dev + (*iter - 1),
                                    sizeof(value_type_t),
                                    cudaMemcpyDeviceToHost,
                                    stream));

      RAFT_CUBLAS_TRY(raft::linalg::detail::cublasgemv(cublas_h,
                                                       CUBLAS_OP_T,
                                                       n,
                                                       *iter,
                                                       &one,
                                                       lanczosVecs_dev,
                                                       n,
                                                       lanczosVecs_dev + IDX(0, *iter, n),
                                                       1,
                                                       &zero,
                                                       work_dev,
                                                       1,
                                                       stream));

      RAFT_CUBLAS_TRY(raft::linalg::detail::cublasgemv(cublas_h,
                                                       CUBLAS_OP_N,
                                                       n,
                                                       *iter,
                                                       &negOne,
                                                       lanczosVecs_dev,
                                                       n,
                                                       work_dev,
                                                       1,
                                                       &one,
                                                       lanczosVecs_dev + IDX(0, *iter, n),
                                                       1,
                                                       stream));
    }

    // Orthogonalization with 3-term recurrence relation
    else {
      RAFT_CUBLAS_TRY(raft::linalg::detail::cublasdot(cublas_h,
                                                      n,
                                                      lanczosVecs_dev + IDX(0, *iter - 1, n),
                                                      1,
                                                      lanczosVecs_dev + IDX(0, *iter, n),
                                                      1,
                                                      alpha_host + (*iter - 1),
                                                      stream));

      auto alpha = -alpha_host[*iter - 1];
      RAFT_CUBLAS_TRY(raft::linalg::detail::cublasaxpy(cublas_h,
                                                       n,
                                                       &alpha,
                                                       lanczosVecs_dev + IDX(0, *iter - 1, n),
                                                       1,
                                                       lanczosVecs_dev + IDX(0, *iter, n),
                                                       1,
                                                       stream));

      alpha = -beta_host[*iter - 2];
      RAFT_CUBLAS_TRY(raft::linalg::detail::cublasaxpy(cublas_h,
                                                       n,
                                                       &alpha,
                                                       lanczosVecs_dev + IDX(0, *iter - 2, n),
                                                       1,
                                                       lanczosVecs_dev + IDX(0, *iter, n),
                                                       1,
                                                       stream));
    }

    // Compute residual
    RAFT_CUBLAS_TRY(raft::linalg::detail::cublasnrm2(
      cublas_h, n, lanczosVecs_dev + IDX(0, *iter, n), 1, beta_host + *iter - 1, stream));

    // Check if Lanczos has converged
    if (beta_host[*iter - 1] <= tol) break;

    // Normalize Lanczos vector
    alpha = 1 / beta_host[*iter - 1];
    RAFT_CUBLAS_TRY(raft::linalg::detail::cublasscal(
      cublas_h, n, &alpha, lanczosVecs_dev + IDX(0, *iter, n), 1, stream));
  }

  resource::sync_stream(handle, stream);

  return 0;
}

/**
 *  @brief  Find Householder transform for 3-dimensional system
 *    Given an input vector v=[x,y,z]', this function finds a
 *    Householder transform P such that P*v is a multiple of
 *    e_1=[1,0,0]'. The input vector v is overwritten with the
 *    Householder vector such that P=I-2*v*v'.
 *  @tparam index_type_t the type of data used for indexing.
 *  @tparam value_type_t the type of data used for weights, distances.
 *  @param v (Input/output, host memory, 3 entries) Input
 *    3-dimensional vector. On exit, the vector is set to the
 *    Householder vector.
 *  @param Pv (Output, host memory, 1 entry) First entry of P*v
 *    (here v is the input vector). Either equal to ||v||_2 or
 *    -||v||_2.
 *  @param P (Output, host memory, 9 entries) Householder transform
 *    matrix. Matrix dimensions are 3 x 3.
 */
template <typename index_type_t, typename value_type_t>
static void findHouseholder3(value_type_t* v, value_type_t* Pv, value_type_t* P)
{
  // Compute norm of vector
  *Pv = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);

  // Choose whether to reflect to e_1 or -e_1
  //   This choice avoids catastrophic cancellation
  if (v[0] >= 0) *Pv = -(*Pv);
  v[0] -= *Pv;

  // Normalize Householder vector
  value_type_t normHouseholder = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
  if (normHouseholder != 0) {
    v[0] /= normHouseholder;
    v[1] /= normHouseholder;
    v[2] /= normHouseholder;
  } else {
    v[0] = 0;
    v[1] = 0;
    v[2] = 0;
  }

  // Construct Householder matrix
  index_type_t i, j;
  for (j = 0; j < 3; ++j)
    for (i = 0; i < 3; ++i)
      P[IDX(i, j, 3)] = -2 * v[i] * v[j];
  for (i = 0; i < 3; ++i)
    P[IDX(i, i, 3)] += 1;
}

/**
 *  @brief  Apply 3-dimensional Householder transform to 4 x 4 matrix
 *    The Householder transform is pre-applied to the top three rows
 *  of the matrix and post-applied to the left three columns. The
 *  4 x 4 matrix is intended to contain the bulge that is produced
 *  in the Francis QR algorithm.
 *  @tparam index_type_t the type of data used for indexing.
 *  @tparam value_type_t the type of data used for weights, distances.
 *  @param v (Input, host memory, 3 entries) Householder vector.
 *  @param A (Input/output, host memory, 16 entries) 4 x 4 matrix.
 */
template <typename index_type_t, typename value_type_t>
static void applyHouseholder3(const value_type_t* v, value_type_t* A)
{
  // Loop indices
  index_type_t i, j;
  // Dot product between Householder vector and matrix row/column
  value_type_t vDotA;

  // Pre-apply Householder transform
  for (j = 0; j < 4; ++j) {
    vDotA = 0;
    for (i = 0; i < 3; ++i)
      vDotA += v[i] * A[IDX(i, j, 4)];
    for (i = 0; i < 3; ++i)
      A[IDX(i, j, 4)] -= 2 * v[i] * vDotA;
  }

  // Post-apply Householder transform
  for (i = 0; i < 4; ++i) {
    vDotA = 0;
    for (j = 0; j < 3; ++j)
      vDotA += A[IDX(i, j, 4)] * v[j];
    for (j = 0; j < 3; ++j)
      A[IDX(i, j, 4)] -= 2 * vDotA * v[j];
  }
}

/**
 *  @brief  Perform one step of Francis QR algorithm
 *    Equivalent to two steps of the classical QR algorithm on a
 *    tridiagonal matrix.
 *  @tparam index_type_t the type of data used for indexing.
 *  @tparam value_type_t the type of data used for weights, distances.
 *  @param n Matrix dimension.
 *  @param shift1 QR algorithm shift.
 *  @param shift2 QR algorithm shift.
 *  @param alpha (Input/output, host memory, n entries) Diagonal
 *    entries of tridiagonal matrix.
 *  @param beta (Input/output, host memory, n-1 entries)
 *    Off-diagonal entries of tridiagonal matrix.
 *  @param V (Input/output, host memory, n*n entries) Orthonormal
 *    transforms from previous steps of QR algorithm. Matrix
 *    dimensions are n x n. On exit, the orthonormal transform from
 *    this Francis QR step is post-applied to the matrix.
 *  @param work (Output, host memory, 3*n entries) Workspace.
 *  @return Zero if successful. Otherwise non-zero.
 */
template <typename index_type_t, typename value_type_t>
static int francisQRIteration(index_type_t n,
                              value_type_t shift1,
                              value_type_t shift2,
                              value_type_t* alpha,
                              value_type_t* beta,
                              value_type_t* V,
                              value_type_t* work)
{
  // -------------------------------------------------------
  // Variable declaration
  // -------------------------------------------------------

  // Temporary storage of 4x4 bulge and Householder vector
  value_type_t bulge[16];

  // Householder vector
  value_type_t householder[3];
  // Householder matrix
  value_type_t householderMatrix[3 * 3];

  // Shifts are roots of the polynomial p(x)=x^2+b*x+c
  value_type_t b = -shift1 - shift2;
  value_type_t c = shift1 * shift2;

  // Loop indices
  index_type_t i, j, pos;
  // Temporary variable
  value_type_t temp;

  // -------------------------------------------------------
  // Implementation
  // -------------------------------------------------------

  // Compute initial Householder transform
  householder[0] = alpha[0] * alpha[0] + beta[0] * beta[0] + b * alpha[0] + c;
  householder[1] = beta[0] * (alpha[0] + alpha[1] + b);
  householder[2] = beta[0] * beta[1];
  findHouseholder3<index_type_t, value_type_t>(householder, &temp, householderMatrix);

  // Apply initial Householder transform to create bulge
  memset(bulge, 0, 16 * sizeof(value_type_t));
  for (i = 0; i < 4; ++i)
    bulge[IDX(i, i, 4)] = alpha[i];
  for (i = 0; i < 3; ++i) {
    bulge[IDX(i + 1, i, 4)] = beta[i];
    bulge[IDX(i, i + 1, 4)] = beta[i];
  }
  applyHouseholder3<index_type_t, value_type_t>(householder, bulge);
  Lapack<value_type_t>::gemm(false, false, n, 3, 3, 1, V, n, householderMatrix, 3, 0, work, n);
  memcpy(V, work, 3 * n * sizeof(value_type_t));

  // Chase bulge to bottom-right of matrix with Householder transforms
  for (pos = 0; pos < n - 4; ++pos) {
    // Move to next position
    alpha[pos]     = bulge[IDX(0, 0, 4)];
    householder[0] = bulge[IDX(1, 0, 4)];
    householder[1] = bulge[IDX(2, 0, 4)];
    householder[2] = bulge[IDX(3, 0, 4)];
    for (j = 0; j < 3; ++j)
      for (i = 0; i < 3; ++i)
        bulge[IDX(i, j, 4)] = bulge[IDX(i + 1, j + 1, 4)];
    bulge[IDX(3, 0, 4)] = 0;
    bulge[IDX(3, 1, 4)] = 0;
    bulge[IDX(3, 2, 4)] = beta[pos + 3];
    bulge[IDX(0, 3, 4)] = 0;
    bulge[IDX(1, 3, 4)] = 0;
    bulge[IDX(2, 3, 4)] = beta[pos + 3];
    bulge[IDX(3, 3, 4)] = alpha[pos + 4];

    // Apply Householder transform
    findHouseholder3<index_type_t, value_type_t>(householder, beta + pos, householderMatrix);
    applyHouseholder3<index_type_t, value_type_t>(householder, bulge);
    Lapack<value_type_t>::gemm(
      false, false, n, 3, 3, 1, V + IDX(0, pos + 1, n), n, householderMatrix, 3, 0, work, n);
    memcpy(V + IDX(0, pos + 1, n), work, 3 * n * sizeof(value_type_t));
  }

  // Apply penultimate Householder transform
  //   Values in the last row and column are zero
  alpha[n - 4]   = bulge[IDX(0, 0, 4)];
  householder[0] = bulge[IDX(1, 0, 4)];
  householder[1] = bulge[IDX(2, 0, 4)];
  householder[2] = bulge[IDX(3, 0, 4)];
  for (j = 0; j < 3; ++j)
    for (i = 0; i < 3; ++i)
      bulge[IDX(i, j, 4)] = bulge[IDX(i + 1, j + 1, 4)];
  bulge[IDX(3, 0, 4)] = 0;
  bulge[IDX(3, 1, 4)] = 0;
  bulge[IDX(3, 2, 4)] = 0;
  bulge[IDX(0, 3, 4)] = 0;
  bulge[IDX(1, 3, 4)] = 0;
  bulge[IDX(2, 3, 4)] = 0;
  bulge[IDX(3, 3, 4)] = 0;
  findHouseholder3<index_type_t, value_type_t>(householder, beta + n - 4, householderMatrix);
  applyHouseholder3<index_type_t, value_type_t>(householder, bulge);
  Lapack<value_type_t>::gemm(
    false, false, n, 3, 3, 1, V + IDX(0, n - 3, n), n, householderMatrix, 3, 0, work, n);
  memcpy(V + IDX(0, n - 3, n), work, 3 * n * sizeof(value_type_t));

  // Apply final Householder transform
  //   Values in the last two rows and columns are zero
  alpha[n - 3]   = bulge[IDX(0, 0, 4)];
  householder[0] = bulge[IDX(1, 0, 4)];
  householder[1] = bulge[IDX(2, 0, 4)];
  householder[2] = 0;
  for (j = 0; j < 3; ++j)
    for (i = 0; i < 3; ++i)
      bulge[IDX(i, j, 4)] = bulge[IDX(i + 1, j + 1, 4)];
  findHouseholder3<index_type_t, value_type_t>(householder, beta + n - 3, householderMatrix);
  applyHouseholder3<index_type_t, value_type_t>(householder, bulge);
  Lapack<value_type_t>::gemm(
    false, false, n, 2, 2, 1, V + IDX(0, n - 2, n), n, householderMatrix, 3, 0, work, n);
  memcpy(V + IDX(0, n - 2, n), work, 2 * n * sizeof(value_type_t));

  // Bulge has been eliminated
  alpha[n - 2] = bulge[IDX(0, 0, 4)];
  alpha[n - 1] = bulge[IDX(1, 1, 4)];
  beta[n - 2]  = bulge[IDX(1, 0, 4)];

  return 0;
}

/**
 *  @brief  Perform implicit restart of Lanczos algorithm
 *    Shifts are Chebyshev nodes of unwanted region of matrix spectrum.
 *  @tparam index_type_t the type of data used for indexing.
 *  @tparam value_type_t the type of data used for weights, distances.
 *  @param handle the raft handle.
 *  @param n Matrix dimension.
 *  @param iter Current Lanczos iteration.
 *  @param iter_new Lanczos iteration after restart.
 *  @param shiftUpper Pointer (host memory) to upper bound for unwanted
 *    region. Value is ignored if less than *shiftLower. If a
 *    stronger upper bound has been found, the value is updated on
 *    exit.
 *  @param shiftLower Pointer (host memory) to lower bound for unwanted
 *    region. Value is ignored if greater than *shiftUpper. If a
 *    stronger lower bound has been found, the value is updated on
 *    exit.
 *  @param alpha_host (Input/output, host memory, iter entries)
 *    Diagonal entries of Lanczos system.
 *  @param beta_host (Input/output, host memory, iter entries)
 *    Off-diagonal entries of Lanczos system.
 *  @param V_host (Output, host memory, iter*iter entries)
 *    Orthonormal transform used to obtain restarted system. Matrix
 *    dimensions are iter x iter.
 *  @param work_host (Output, host memory, 4*iter entries)
 *    Workspace.
 *  @param lanczosVecs_dev (Input/output, device memory, n*(iter+1)
 *    entries) Lanczos vectors. Vectors are stored as columns of a
 *    column-major matrix with dimensions n x (iter+1).
 *  @param work_dev (Output, device memory, (n+iter)*iter entries)
 *    Workspace.
 *  @param smallest_eig specifies whether smallest (true) or largest
 *    (false) eigenvalues are to be calculated.
 *  @return error flag.
 */
template <typename index_type_t, typename value_type_t>
static int lanczosRestart(raft::resources const& handle,
                          index_type_t n,
                          index_type_t iter,
                          index_type_t iter_new,
                          value_type_t* shiftUpper,
                          value_type_t* shiftLower,
                          value_type_t* __restrict__ alpha_host,
                          value_type_t* __restrict__ beta_host,
                          value_type_t* __restrict__ V_host,
                          value_type_t* __restrict__ work_host,
                          value_type_t* __restrict__ lanczosVecs_dev,
                          value_type_t* __restrict__ work_dev,
                          bool smallest_eig)
{
  // -------------------------------------------------------
  // Variable declaration
  // -------------------------------------------------------

  // Useful constants
  constexpr value_type_t zero = 0;
  constexpr value_type_t one  = 1;

  auto cublas_h = resource::get_cublas_handle(handle);
  auto stream   = resource::get_cuda_stream(handle);

  // Loop index
  index_type_t i;

  // Number of implicit restart steps
  //   Assumed to be even since each call to Francis algorithm is
  //   equivalent to two calls of QR algorithm
  index_type_t restartSteps = iter - iter_new;

  // Ritz values from Lanczos method
  value_type_t* ritzVals_host = work_host + 3 * iter;
  // Shifts for implicit restart
  value_type_t* shifts_host;

  // Orthonormal matrix for similarity transform
  value_type_t* V_dev = work_dev + (size_t)n * (size_t)iter;

  // -------------------------------------------------------
  // Implementation
  // -------------------------------------------------------

  // Compute Ritz values
  memcpy(ritzVals_host, alpha_host, iter * sizeof(value_type_t));
  memcpy(work_host, beta_host, (iter - 1) * sizeof(value_type_t));
  Lapack<value_type_t>::sterf(iter, ritzVals_host, work_host);

  // Debug: Print largest eigenvalues
  // for (int i = iter-iter_new; i < iter; ++i)
  //  std::cout <<*(ritzVals_host+i)<< " ";
  // std::cout <<std::endl;

  // Initialize similarity transform with identity matrix
  memset(V_host, 0, (size_t)iter * (size_t)iter * (size_t)sizeof(value_type_t));
  for (i = 0; i < iter; ++i)
    V_host[IDX(i, i, iter)] = 1;

  // Determine interval to suppress eigenvalues
  if (smallest_eig) {
    if (*shiftLower > *shiftUpper) {
      *shiftUpper = ritzVals_host[iter - 1];
      *shiftLower = ritzVals_host[iter_new];
    } else {
      *shiftUpper = std::max(*shiftUpper, ritzVals_host[iter - 1]);
      *shiftLower = std::min(*shiftLower, ritzVals_host[iter_new]);
    }
  } else {
    if (*shiftLower > *shiftUpper) {
      *shiftUpper = ritzVals_host[iter - iter_new - 1];
      *shiftLower = ritzVals_host[0];
    } else {
      *shiftUpper = std::max(*shiftUpper, ritzVals_host[iter - iter_new - 1]);
      *shiftLower = std::min(*shiftLower, ritzVals_host[0]);
    }
  }

  // Calculate Chebyshev nodes as shifts
  shifts_host = ritzVals_host;
  for (i = 0; i < restartSteps; ++i) {
    shifts_host[i] = cos((i + 0.5) * static_cast<value_type_t>(M_PI) / restartSteps);
    shifts_host[i] *= 0.5 * ((*shiftUpper) - (*shiftLower));
    shifts_host[i] += 0.5 * ((*shiftUpper) + (*shiftLower));
  }

  // Apply Francis QR algorithm to implicitly restart Lanczos
  for (i = 0; i < restartSteps; i += 2)
    if (francisQRIteration(
          iter, shifts_host[i], shifts_host[i + 1], alpha_host, beta_host, V_host, work_host))
      WARNING("error in implicitly shifted QR algorithm");

  // Obtain new residual
  RAFT_CUDA_TRY(cudaMemcpyAsync(V_dev,
                                V_host,
                                (size_t)iter * (size_t)iter * (size_t)sizeof(value_type_t),
                                cudaMemcpyHostToDevice,
                                stream));

  beta_host[iter - 1] = beta_host[iter - 1] * V_host[IDX(iter - 1, iter_new - 1, iter)];
  RAFT_CUBLAS_TRY(raft::linalg::detail::cublasgemv(cublas_h,
                                                   CUBLAS_OP_N,
                                                   n,
                                                   iter,
                                                   beta_host + iter_new - 1,
                                                   lanczosVecs_dev,
                                                   n,
                                                   V_dev + IDX(0, iter_new, iter),
                                                   1,
                                                   beta_host + iter - 1,
                                                   lanczosVecs_dev + IDX(0, iter, n),
                                                   1,
                                                   stream));

  // Obtain new Lanczos vectors
  RAFT_CUBLAS_TRY(raft::linalg::detail::cublasgemm(cublas_h,
                                                   CUBLAS_OP_N,
                                                   CUBLAS_OP_N,
                                                   n,
                                                   iter_new,
                                                   iter,
                                                   &one,
                                                   lanczosVecs_dev,
                                                   n,
                                                   V_dev,
                                                   iter,
                                                   &zero,
                                                   work_dev,
                                                   n,
                                                   stream));

  RAFT_CUDA_TRY(cudaMemcpyAsync(lanczosVecs_dev,
                                work_dev,
                                (size_t)n * (size_t)iter_new * (size_t)sizeof(value_type_t),
                                cudaMemcpyDeviceToDevice,
                                stream));

  // Normalize residual to obtain new Lanczos vector
  RAFT_CUDA_TRY(cudaMemcpyAsync(lanczosVecs_dev + IDX(0, iter_new, n),
                                lanczosVecs_dev + IDX(0, iter, n),
                                n * sizeof(value_type_t),
                                cudaMemcpyDeviceToDevice,
                                stream));

  RAFT_CUBLAS_TRY(raft::linalg::detail::cublasnrm2(
    cublas_h, n, lanczosVecs_dev + IDX(0, iter_new, n), 1, beta_host + iter_new - 1, stream));

  auto h_beta = 1 / beta_host[iter_new - 1];
  RAFT_CUBLAS_TRY(raft::linalg::detail::cublasscal(
    cublas_h, n, &h_beta, lanczosVecs_dev + IDX(0, iter_new, n), 1, stream));

  return 0;
}

/**
 * @brief  Compute smallest eigenvectors of symmetric matrix
 *    Computes eigenvalues and eigenvectors that are least
 *    positive. If matrix is positive definite or positive
 *    semidefinite, the computed eigenvalues are smallest in
 *    magnitude.
 *    The largest eigenvalue is estimated by performing several
 *    Lanczos iterations. An implicitly restarted Lanczos method is
 *    then applied to A+s*I, where s is negative the largest
 *    eigenvalue.
 *  @tparam index_type_t the type of data used for indexing.
 *  @tparam value_type_t the type of data used for weights, distances.
 *  @param handle the raft handle.
 *  @param A Matrix.
 *  @param nEigVecs Number of eigenvectors to compute.
 *  @param maxIter Maximum number of Lanczos steps. Does not include
 *    Lanczos steps used to estimate largest eigenvalue.
 *  @param restartIter Maximum size of Lanczos system before
 *    performing an implicit restart. Should be at least 4.
 *  @param tol Convergence tolerance. Lanczos iteration will
 *    terminate when the residual norm is less than tol*theta, where
 *    theta is an estimate for the smallest unwanted eigenvalue
 *    (i.e. the (nEigVecs+1)th smallest eigenvalue).
 *  @param reorthogonalize Whether to reorthogonalize Lanczos
 *    vectors.
 *  @param effIter On exit, pointer to final size of Lanczos system.
 *  @param totalIter On exit, pointer to total number of Lanczos
 *    iterations performed. Does not include Lanczos steps used to
 *    estimate largest eigenvalue.
 *  @param shift On exit, pointer to matrix shift (estimate for
 *    largest eigenvalue).
 *  @param alpha_host (Output, host memory, restartIter entries)
 *    Diagonal entries of Lanczos system.
 *  @param beta_host (Output, host memory, restartIter entries)
 *    Off-diagonal entries of Lanczos system.
 *  @param lanczosVecs_dev (Output, device memory, n*(restartIter+1)
 *    entries) Lanczos vectors. Vectors are stored as columns of a
 *    column-major matrix with dimensions n x (restartIter+1).
 *  @param work_dev (Output, device memory,
 *    (n+restartIter)*restartIter entries) Workspace.
 *  @param eigVals_dev (Output, device memory, nEigVecs entries)
 *    Largest eigenvalues of matrix.
 *  @param eigVecs_dev (Output, device memory, n*nEigVecs entries)
 *    Eigenvectors corresponding to smallest eigenvalues of
 *    matrix. Vectors are stored as columns of a column-major matrix
 *    with dimensions n x nEigVecs.
 *  @param seed random seed.
 *  @return error flag.
 */
template <typename index_type_t, typename value_type_t, typename nnz_type_t>
int computeSmallestEigenvectors(
  raft::resources const& handle,
  spectral::matrix::sparse_matrix_t<index_type_t, value_type_t, nnz_type_t> const* A,
  index_type_t nEigVecs,
  index_type_t maxIter,
  index_type_t restartIter,
  value_type_t tol,
  bool reorthogonalize,
  index_type_t* effIter,
  index_type_t* totalIter,
  value_type_t* shift,
  value_type_t* __restrict__ alpha_host,
  value_type_t* __restrict__ beta_host,
  value_type_t* __restrict__ lanczosVecs_dev,
  value_type_t* __restrict__ work_dev,
  value_type_t* __restrict__ eigVals_dev,
  value_type_t* __restrict__ eigVecs_dev,
  unsigned long long seed)
{
  // Useful constants
  constexpr value_type_t one  = 1;
  constexpr value_type_t zero = 0;

  // Matrix dimension
  nnz_type_t n = A->nrows_;

  // Shift for implicit restart
  value_type_t shiftUpper;
  value_type_t shiftLower;

  // Lanczos iteration counters
  index_type_t maxIter_curr = restartIter;  // Maximum size of Lanczos system

  // Status flags
  int status;

  // Loop index
  index_type_t i;

  // Host memory
  value_type_t* Z_host;     // Eigenvectors in Lanczos basis
  value_type_t* work_host;  // Workspace

  // -------------------------------------------------------
  // Check that parameters are valid
  // -------------------------------------------------------
  RAFT_EXPECTS(nEigVecs > 0 && static_cast<nnz_type_t>(nEigVecs) <= n,
               "Invalid number of eigenvectors.");
  RAFT_EXPECTS(restartIter > 0, "Invalid restartIter.");
  RAFT_EXPECTS(tol > 0, "Invalid tolerance.");
  RAFT_EXPECTS(maxIter >= nEigVecs, "Invalid maxIter.");
  RAFT_EXPECTS(restartIter >= nEigVecs, "Invalid restartIter.");

  auto cublas_h = resource::get_cublas_handle(handle);
  auto stream   = resource::get_cuda_stream(handle);

  // -------------------------------------------------------
  // Variable initialization
  // -------------------------------------------------------

  // Total number of Lanczos iterations
  *totalIter = 0;

  // Allocate host memory
  std::vector<value_type_t> Z_host_v(restartIter * restartIter);
  std::vector<value_type_t> work_host_v(4 * restartIter);

  Z_host    = Z_host_v.data();
  work_host = work_host_v.data();

  // Initialize cuBLAS
  RAFT_CUBLAS_TRY(
    raft::linalg::detail::cublassetpointermode(cublas_h, CUBLAS_POINTER_MODE_HOST, stream));

  // -------------------------------------------------------
  // Compute largest eigenvalue to determine shift
  // -------------------------------------------------------

  // Random number generator
  curandGenerator_t randGen;
  // Initialize random number generator
  curandCreateGenerator(&randGen, CURAND_RNG_PSEUDO_PHILOX4_32_10);

  curandSetPseudoRandomGeneratorSeed(randGen, seed);

  // Initialize initial Lanczos vector
  curandGenerateNormalX(randGen, lanczosVecs_dev, n + n % 2, zero, one);
  value_type_t normQ1;
  RAFT_CUBLAS_TRY(
    raft::linalg::detail::cublasnrm2(cublas_h, n, lanczosVecs_dev, 1, &normQ1, stream));

  auto h_val = 1 / normQ1;
  RAFT_CUBLAS_TRY(
    raft::linalg::detail::cublasscal(cublas_h, n, &h_val, lanczosVecs_dev, 1, stream));

  // Obtain tridiagonal matrix with Lanczos
  *effIter = 0;
  *shift   = 0;
  status   = performLanczosIteration<index_type_t, value_type_t, nnz_type_t>(handle,
                                                                           A,
                                                                           effIter,
                                                                           maxIter_curr,
                                                                           *shift,
                                                                           0.0,
                                                                           reorthogonalize,
                                                                           alpha_host,
                                                                           beta_host,
                                                                           lanczosVecs_dev,
                                                                           work_dev);
  if (status) WARNING("error in Lanczos iteration");

  // Determine largest eigenvalue

  Lapack<value_type_t>::sterf(*effIter, alpha_host, beta_host);
  *shift = -alpha_host[*effIter - 1];

  // -------------------------------------------------------
  // Compute eigenvectors of shifted matrix
  // -------------------------------------------------------

  // Obtain tridiagonal matrix with Lanczos
  *effIter = 0;

  status = performLanczosIteration<index_type_t, value_type_t, nnz_type_t>(handle,
                                                                           A,
                                                                           effIter,
                                                                           maxIter_curr,
                                                                           *shift,
                                                                           0,
                                                                           reorthogonalize,
                                                                           alpha_host,
                                                                           beta_host,
                                                                           lanczosVecs_dev,
                                                                           work_dev);
  if (status) WARNING("error in Lanczos iteration");
  *totalIter += *effIter;

  // Apply Lanczos method until convergence
  shiftLower = 1;
  shiftUpper = -1;
  while (*totalIter < maxIter && beta_host[*effIter - 1] > tol * shiftLower) {
    // Determine number of restart steps
    // Number of steps must be even due to Francis algorithm
    index_type_t iter_new = nEigVecs + 1;
    if (restartIter - (maxIter - *totalIter) > nEigVecs + 1)
      iter_new = restartIter - (maxIter - *totalIter);
    if ((restartIter - iter_new) % 2) iter_new -= 1;
    if (iter_new == *effIter) break;

    // Implicit restart of Lanczos method
    status = lanczosRestart<index_type_t, value_type_t>(handle,
                                                        n,
                                                        *effIter,
                                                        iter_new,
                                                        &shiftUpper,
                                                        &shiftLower,
                                                        alpha_host,
                                                        beta_host,
                                                        Z_host,
                                                        work_host,
                                                        lanczosVecs_dev,
                                                        work_dev,
                                                        true);
    if (status) WARNING("error in Lanczos implicit restart");
    *effIter = iter_new;

    // Check for convergence
    if (beta_host[*effIter - 1] <= tol * fabs(shiftLower)) break;

    // Proceed with Lanczos method

    status = performLanczosIteration<index_type_t, value_type_t, nnz_type_t>(handle,
                                                                             A,
                                                                             effIter,
                                                                             maxIter_curr,
                                                                             *shift,
                                                                             tol * fabs(shiftLower),
                                                                             reorthogonalize,
                                                                             alpha_host,
                                                                             beta_host,
                                                                             lanczosVecs_dev,
                                                                             work_dev);
    if (status) WARNING("error in Lanczos iteration");
    *totalIter += *effIter - iter_new;
  }

  // Warning if Lanczos has failed to converge
  if (beta_host[*effIter - 1] > tol * fabs(shiftLower)) {
    WARNING("implicitly restarted Lanczos failed to converge");
  }

  // Solve tridiagonal system
  memcpy(work_host + 2 * (*effIter), alpha_host, (*effIter) * sizeof(value_type_t));
  memcpy(work_host + 3 * (*effIter), beta_host, (*effIter - 1) * sizeof(value_type_t));
  Lapack<value_type_t>::steqr('I',
                              *effIter,
                              work_host + 2 * (*effIter),
                              work_host + 3 * (*effIter),
                              Z_host,
                              *effIter,
                              work_host);

  // Obtain desired eigenvalues by applying shift
  for (i = 0; i < *effIter; ++i)
    work_host[i + 2 * (*effIter)] -= *shift;
  for (i = *effIter; i < nEigVecs; ++i)
    work_host[i + 2 * (*effIter)] = 0;

  // Copy results to device memory
  RAFT_CUDA_TRY(cudaMemcpyAsync(eigVals_dev,
                                work_host + 2 * (*effIter),
                                nEigVecs * sizeof(value_type_t),
                                cudaMemcpyHostToDevice,
                                stream));

  RAFT_CUDA_TRY(cudaMemcpyAsync(work_dev,
                                Z_host,
                                (*effIter) * nEigVecs * sizeof(value_type_t),
                                cudaMemcpyHostToDevice,
                                stream));
  RAFT_CHECK_CUDA(stream);

  // Convert eigenvectors from Lanczos basis to standard basis
  RAFT_CUBLAS_TRY(raft::linalg::detail::cublasgemm(cublas_h,
                                                   CUBLAS_OP_N,
                                                   CUBLAS_OP_N,
                                                   n,
                                                   nEigVecs,
                                                   *effIter,
                                                   &one,
                                                   lanczosVecs_dev,
                                                   n,
                                                   work_dev,
                                                   *effIter,
                                                   &zero,
                                                   eigVecs_dev,
                                                   n,
                                                   stream));

  // Clean up and exit
  curandDestroyGenerator(randGen);
  return 0;
}

template <typename index_type_t, typename value_type_t, typename nnz_type_t>
int computeSmallestEigenvectors(
  raft::resources const& handle,
  spectral::matrix::sparse_matrix_t<index_type_t, value_type_t, nnz_type_t> const& A,
  index_type_t nEigVecs,
  index_type_t maxIter,
  index_type_t restartIter,
  value_type_t tol,
  bool reorthogonalize,
  index_type_t& iter,
  value_type_t* __restrict__ eigVals_dev,
  value_type_t* __restrict__ eigVecs_dev,
  unsigned long long seed = 1234567)
{
  // Matrix dimension
  size_t n = A.nrows_;

  // Check that parameters are valid
  RAFT_EXPECTS(nEigVecs > 0 && (size_t)nEigVecs <= n, "Invalid number of eigenvectors.");
  RAFT_EXPECTS(restartIter > 0, "Invalid restartIter.");
  RAFT_EXPECTS(tol > 0, "Invalid tolerance.");
  RAFT_EXPECTS(maxIter >= nEigVecs, "Invalid maxIter.");
  RAFT_EXPECTS(restartIter >= nEigVecs, "Invalid restartIter.");

  // Allocate memory
  std::vector<value_type_t> alpha_host_v(restartIter);
  std::vector<value_type_t> beta_host_v(restartIter);

  value_type_t* alpha_host = alpha_host_v.data();
  value_type_t* beta_host  = beta_host_v.data();

  spectral::matrix::vector_t<value_type_t> lanczosVecs_dev(handle, n * (restartIter + 1));
  spectral::matrix::vector_t<value_type_t> work_dev(handle, (n + restartIter) * restartIter);

  // Perform Lanczos method
  index_type_t effIter;
  value_type_t shift;
  int status = computeSmallestEigenvectors(handle,
                                           &A,
                                           nEigVecs,
                                           maxIter,
                                           restartIter,
                                           tol,
                                           reorthogonalize,
                                           &effIter,
                                           &iter,
                                           &shift,
                                           alpha_host,
                                           beta_host,
                                           lanczosVecs_dev.raw(),
                                           work_dev.raw(),
                                           eigVals_dev,
                                           eigVecs_dev,
                                           seed);

  // Clean up and return
  return status;
}

/**
 *  @brief Compute largest eigenvectors of symmetric matrix
 *    Computes eigenvalues and eigenvectors that are least
 *    positive. If matrix is positive definite or positive
 *    semidefinite, the computed eigenvalues are largest in
 *    magnitude.
 *    The largest eigenvalue is estimated by performing several
 *    Lanczos iterations. An implicitly restarted Lanczos method is
 *    then applied.
 *  @tparam index_type_t the type of data used for indexing.
 *  @tparam value_type_t the type of data used for weights, distances.
 *  @param handle the raft handle.
 *  @param A Matrix.
 *  @param nEigVecs Number of eigenvectors to compute.
 *  @param maxIter Maximum number of Lanczos steps.
 *  @param restartIter Maximum size of Lanczos system before
 *    performing an implicit restart. Should be at least 4.
 *  @param tol Convergence tolerance. Lanczos iteration will
 *    terminate when the residual norm is less than tol*theta, where
 *    theta is an estimate for the largest unwanted eigenvalue
 *    (i.e. the (nEigVecs+1)th largest eigenvalue).
 *  @param reorthogonalize Whether to reorthogonalize Lanczos
 *    vectors.
 *  @param effIter On exit, pointer to final size of Lanczos system.
 *  @param totalIter On exit, pointer to total number of Lanczos
 *    iterations performed.
 *  @param alpha_host (Output, host memory, restartIter entries)
 *    Diagonal entries of Lanczos system.
 *  @param beta_host (Output, host memory, restartIter entries)
 *    Off-diagonal entries of Lanczos system.
 *  @param lanczosVecs_dev (Output, device memory, n*(restartIter+1)
 *    entries) Lanczos vectors. Vectors are stored as columns of a
 *    column-major matrix with dimensions n x (restartIter+1).
 *  @param work_dev (Output, device memory,
 *    (n+restartIter)*restartIter entries) Workspace.
 *  @param eigVals_dev (Output, device memory, nEigVecs entries)
 *    Largest eigenvalues of matrix.
 *  @param eigVecs_dev (Output, device memory, n*nEigVecs entries)
 *    Eigenvectors corresponding to largest eigenvalues of
 *    matrix. Vectors are stored as columns of a column-major matrix
 *    with dimensions n x nEigVecs.
 *  @param seed random seed.
 *  @return error flag.
 */
template <typename index_type_t, typename value_type_t, typename nnz_type_t>
int computeLargestEigenvectors(
  raft::resources const& handle,
  spectral::matrix::sparse_matrix_t<index_type_t, value_type_t, nnz_type_t> const* A,
  index_type_t nEigVecs,
  index_type_t maxIter,
  index_type_t restartIter,
  value_type_t tol,
  bool reorthogonalize,
  index_type_t* effIter,
  index_type_t* totalIter,
  value_type_t* __restrict__ alpha_host,
  value_type_t* __restrict__ beta_host,
  value_type_t* __restrict__ lanczosVecs_dev,
  value_type_t* __restrict__ work_dev,
  value_type_t* __restrict__ eigVals_dev,
  value_type_t* __restrict__ eigVecs_dev,
  unsigned long long seed)
{
  // Useful constants
  constexpr value_type_t one  = 1;
  constexpr value_type_t zero = 0;

  // Matrix dimension
  nnz_type_t n = A->nrows_;

  // Lanczos iteration counters
  index_type_t maxIter_curr = restartIter;  // Maximum size of Lanczos system

  // Status flags
  int status;

  // Loop index
  index_type_t i;

  // Host memory
  value_type_t* Z_host;     // Eigenvectors in Lanczos basis
  value_type_t* work_host;  // Workspace

  // -------------------------------------------------------
  // Check that LAPACK is enabled
  // -------------------------------------------------------
  // Lapack<value_type_t>::check_lapack_enabled();

  // -------------------------------------------------------
  // Check that parameters are valid
  // -------------------------------------------------------
  RAFT_EXPECTS(nEigVecs > 0 && static_cast<nnz_type_t>(nEigVecs) <= n,
               "Invalid number of eigenvectors.");
  RAFT_EXPECTS(restartIter > 0, "Invalid restartIter.");
  RAFT_EXPECTS(tol > 0, "Invalid tolerance.");
  RAFT_EXPECTS(maxIter >= nEigVecs, "Invalid maxIter.");
  RAFT_EXPECTS(restartIter >= nEigVecs, "Invalid restartIter.");

  auto cublas_h = resource::get_cublas_handle(handle);
  auto stream   = resource::get_cuda_stream(handle);

  // -------------------------------------------------------
  // Variable initialization
  // -------------------------------------------------------

  // Total number of Lanczos iterations
  *totalIter = 0;

  // Allocate host memory
  std::vector<value_type_t> Z_host_v(restartIter * restartIter);
  std::vector<value_type_t> work_host_v(4 * restartIter);

  Z_host    = Z_host_v.data();
  work_host = work_host_v.data();

  // Initialize cuBLAS
  RAFT_CUBLAS_TRY(
    raft::linalg::detail::cublassetpointermode(cublas_h, CUBLAS_POINTER_MODE_HOST, stream));

  // -------------------------------------------------------
  // Compute largest eigenvalue
  // -------------------------------------------------------

  // Random number generator
  curandGenerator_t randGen;
  // Initialize random number generator
  curandCreateGenerator(&randGen, CURAND_RNG_PSEUDO_PHILOX4_32_10);
  curandSetPseudoRandomGeneratorSeed(randGen, seed);
  // Initialize initial Lanczos vector
  curandGenerateNormalX(randGen, lanczosVecs_dev, n + n % 2, zero, one);
  value_type_t normQ1;
  RAFT_CUBLAS_TRY(
    raft::linalg::detail::cublasnrm2(cublas_h, n, lanczosVecs_dev, 1, &normQ1, stream));

  auto h_val = 1 / normQ1;
  RAFT_CUBLAS_TRY(
    raft::linalg::detail::cublasscal(cublas_h, n, &h_val, lanczosVecs_dev, 1, stream));

  // Obtain tridiagonal matrix with Lanczos
  *effIter               = 0;
  value_type_t shift_val = 0.0;
  value_type_t* shift    = &shift_val;

  status = performLanczosIteration<index_type_t, value_type_t, nnz_type_t>(handle,
                                                                           A,
                                                                           effIter,
                                                                           maxIter_curr,
                                                                           *shift,
                                                                           0,
                                                                           reorthogonalize,
                                                                           alpha_host,
                                                                           beta_host,
                                                                           lanczosVecs_dev,
                                                                           work_dev);
  if (status) WARNING("error in Lanczos iteration");
  *totalIter += *effIter;

  // Apply Lanczos method until convergence
  value_type_t shiftLower = 1;
  value_type_t shiftUpper = -1;
  while (*totalIter < maxIter && beta_host[*effIter - 1] > tol * shiftLower) {
    // Determine number of restart steps
    //   Number of steps must be even due to Francis algorithm
    index_type_t iter_new = nEigVecs + 1;
    if (restartIter - (maxIter - *totalIter) > nEigVecs + 1)
      iter_new = restartIter - (maxIter - *totalIter);
    if ((restartIter - iter_new) % 2) iter_new -= 1;
    if (iter_new == *effIter) break;

    // Implicit restart of Lanczos method
    status = lanczosRestart<index_type_t, value_type_t>(handle,
                                                        n,
                                                        *effIter,
                                                        iter_new,
                                                        &shiftUpper,
                                                        &shiftLower,
                                                        alpha_host,
                                                        beta_host,
                                                        Z_host,
                                                        work_host,
                                                        lanczosVecs_dev,
                                                        work_dev,
                                                        false);
    if (status) WARNING("error in Lanczos implicit restart");
    *effIter = iter_new;

    // Check for convergence
    if (beta_host[*effIter - 1] <= tol * fabs(shiftLower)) break;

    // Proceed with Lanczos method

    status = performLanczosIteration<index_type_t, value_type_t, nnz_type_t>(handle,
                                                                             A,
                                                                             effIter,
                                                                             maxIter_curr,
                                                                             *shift,
                                                                             tol * fabs(shiftLower),
                                                                             reorthogonalize,
                                                                             alpha_host,
                                                                             beta_host,
                                                                             lanczosVecs_dev,
                                                                             work_dev);
    if (status) WARNING("error in Lanczos iteration");
    *totalIter += *effIter - iter_new;
  }

  // Warning if Lanczos has failed to converge
  if (beta_host[*effIter - 1] > tol * fabs(shiftLower)) {
    WARNING("implicitly restarted Lanczos failed to converge");
  }
  for (int i = 0; i < restartIter; ++i) {
    for (int j = 0; j < restartIter; ++j)
      Z_host[i * restartIter + j] = 0;
  }
  // Solve tridiagonal system
  memcpy(work_host + 2 * (*effIter), alpha_host, (*effIter) * sizeof(value_type_t));
  memcpy(work_host + 3 * (*effIter), beta_host, (*effIter - 1) * sizeof(value_type_t));
  Lapack<value_type_t>::steqr('I',
                              *effIter,
                              work_host + 2 * (*effIter),
                              work_host + 3 * (*effIter),
                              Z_host,
                              *effIter,
                              work_host);

  // note: We need to pick the top nEigVecs eigenvalues
  // but effItter can be larger than nEigVecs
  // hence we add an offset for that case, because we want to access top nEigVecs eigenpairs in the
  // matrix of size effIter. remember the array is sorted, so it is not needed for smallest
  // eigenvalues case because the first ones are the smallest ones

  index_type_t top_eigenparis_idx_offset = *effIter - nEigVecs;

  // Debug : print nEigVecs largest eigenvalues
  // for (int i = top_eigenparis_idx_offset; i < *effIter; ++i)
  //  std::cout <<*(work_host+(2*(*effIter)+i))<< " ";
  // std::cout <<std::endl;

  // Debug : print nEigVecs largest eigenvectors
  // for (int i = top_eigenparis_idx_offset; i < *effIter; ++i)
  //{
  //  for (int j = 0; j < *effIter; ++j)
  //    std::cout <<Z_host[i*(*effIter)+j]<< " ";
  //  std::cout <<std::endl;
  //}

  // Obtain desired eigenvalues by applying shift
  for (i = 0; i < *effIter; ++i)
    work_host[i + 2 * (*effIter)] -= *shift;

  for (i = 0; i < top_eigenparis_idx_offset; ++i)
    work_host[i + 2 * (*effIter)] = 0;

  // Copy results to device memory
  // skip smallest eigenvalue if needed
  RAFT_CUDA_TRY(cudaMemcpyAsync(eigVals_dev,
                                work_host + 2 * (*effIter) + top_eigenparis_idx_offset,
                                nEigVecs * sizeof(value_type_t),
                                cudaMemcpyHostToDevice,
                                stream));

  // skip smallest eigenvector if needed
  RAFT_CUDA_TRY(cudaMemcpyAsync(work_dev,
                                Z_host + (top_eigenparis_idx_offset * (*effIter)),
                                (*effIter) * nEigVecs * sizeof(value_type_t),
                                cudaMemcpyHostToDevice,
                                stream));

  RAFT_CHECK_CUDA(stream);

  // Convert eigenvectors from Lanczos basis to standard basis
  RAFT_CUBLAS_TRY(raft::linalg::detail::cublasgemm(cublas_h,
                                                   CUBLAS_OP_N,
                                                   CUBLAS_OP_N,
                                                   n,
                                                   nEigVecs,
                                                   *effIter,
                                                   &one,
                                                   lanczosVecs_dev,
                                                   n,
                                                   work_dev,
                                                   *effIter,
                                                   &zero,
                                                   eigVecs_dev,
                                                   n,
                                                   stream));

  // Clean up and exit
  curandDestroyGenerator(randGen);
  return 0;
}

template <typename index_type_t, typename value_type_t, typename nnz_type_t>
int computeLargestEigenvectors(
  raft::resources const& handle,
  spectral::matrix::sparse_matrix_t<index_type_t, value_type_t, nnz_type_t> const& A,
  index_type_t nEigVecs,
  index_type_t maxIter,
  index_type_t restartIter,
  value_type_t tol,
  bool reorthogonalize,
  index_type_t& iter,
  value_type_t* __restrict__ eigVals_dev,
  value_type_t* __restrict__ eigVecs_dev,
  unsigned long long seed = 123456)
{
  // Matrix dimension
  size_t n = A.nrows_;

  // Check that parameters are valid
  RAFT_EXPECTS(nEigVecs > 0 && (size_t)nEigVecs <= n, "Invalid number of eigenvectors.");
  RAFT_EXPECTS(restartIter > 0, "Invalid restartIter.");
  RAFT_EXPECTS(tol > 0, "Invalid tolerance.");
  RAFT_EXPECTS(maxIter >= nEigVecs, "Invalid maxIter.");
  RAFT_EXPECTS(restartIter >= nEigVecs, "Invalid restartIter.");

  // Allocate memory
  std::vector<value_type_t> alpha_host_v(restartIter);
  std::vector<value_type_t> beta_host_v(restartIter);

  value_type_t* alpha_host = alpha_host_v.data();
  value_type_t* beta_host  = beta_host_v.data();

  spectral::matrix::vector_t<value_type_t> lanczosVecs_dev(handle, n * (restartIter + 1));
  spectral::matrix::vector_t<value_type_t> work_dev(handle, (n + restartIter) * restartIter);

  // Perform Lanczos method
  index_type_t effIter;
  int status = computeLargestEigenvectors(handle,
                                          &A,
                                          nEigVecs,
                                          maxIter,
                                          restartIter,
                                          tol,
                                          reorthogonalize,
                                          &effIter,
                                          &iter,
                                          alpha_host,
                                          beta_host,
                                          lanczosVecs_dev.raw(),
                                          work_dev.raw(),
                                          eigVals_dev,
                                          eigVecs_dev,
                                          seed);

  // Clean up and return
  return status;
}

template <typename T>
RAFT_KERNEL kernel_triangular_populate(T* M, const T* beta, int n)
{
  int row = blockIdx.x * blockDim.x + threadIdx.x;

  if (row < n) {
    // Upper diagonal: M[row + 1, row] in column-major
    if (row < n - 1) { M[(row + 1) * n + row] = beta[row]; }

    // Lower diagonal: M[row - 1, row] in column-major
    if (row > 0) { M[(row - 1) * n + row] = beta[row - 1]; }
  }
}

template <typename T>
RAFT_KERNEL kernel_triangular_beta_k(T* t, const T* beta_k, int k, int n)
{
  int tid = threadIdx.x + blockIdx.x * blockDim.x;

  if (tid < k) {
    // Update the k-th column: t[i, k] -> t[k * n + i] in column-major
    t[tid * n + k] = beta_k[tid];

    // Update the k-th row: t[k, j] -> t[j * n + k] in column-major
    t[k * n + tid] = beta_k[tid];
  }
}

template <typename T>
RAFT_KERNEL kernel_normalize(const T* u, const T* beta, int j, int n, T* v, T* V, int size)
{
  int i = blockIdx.x * blockDim.x + threadIdx.x;

  if (i < size) {
    if (beta[j] == 0) {
      v[i] = u[i] / 1;
    } else {
      v[i] = u[i] / beta[j];
    }
    V[i + (j + 1) * n] = v[i];
  }
}

template <typename T>
RAFT_KERNEL kernel_clamp_down(T* value, T threshold)
{
  *value = (fabs(*value) < threshold) ? 0 : *value;
}

template <typename T>
RAFT_KERNEL kernel_clamp_down_vector(T* vec, T threshold, int size)
{
  int idx = threadIdx.x + blockIdx.x * blockDim.x;
  if (idx < size) { vec[idx] = (fabs(vec[idx]) < threshold) ? 0 : vec[idx]; }
}

template <typename IndexTypeT, typename ValueTypeT>
void lanczos_solve_ritz(
  raft::resources const& handle,
  raft::device_matrix_view<ValueTypeT, uint32_t, raft::row_major> alpha,
  raft::device_matrix_view<ValueTypeT, uint32_t, raft::row_major> beta,
  std::optional<raft::device_vector_view<ValueTypeT, uint32_t>> beta_k,
  IndexTypeT k,
  LANCZOS_WHICH which,
  int ncv,
  raft::device_matrix_view<ValueTypeT, uint32_t, raft::col_major> eigenvectors,
  raft::device_vector_view<ValueTypeT> eigenvalues,
  raft::device_matrix_view<ValueTypeT, uint32_t, raft::col_major>& eigenvectors_k,
  raft::device_vector_view<ValueTypeT, uint32_t>& eigenvalues_k,
  raft::device_matrix_view<ValueTypeT, IndexTypeT, raft::col_major>& eigenvectors_k_slice,
  raft::device_vector_view<ValueTypeT> sm_eigenvalues,
  raft::device_matrix_view<ValueTypeT, uint32_t, raft::col_major> sm_eigenvectors)
{
  auto stream = resource::get_cuda_stream(handle);

  ValueTypeT zero = 0;
  auto triangular_matrix =
    raft::make_device_matrix<ValueTypeT, uint32_t, raft::col_major>(handle, ncv, ncv);
  raft::matrix::fill(handle, triangular_matrix.view(), zero);

  raft::device_vector_view<const ValueTypeT, uint32_t> alphaVec =
    raft::make_device_vector_view<const ValueTypeT, uint32_t>(alpha.data_handle(), ncv);
  raft::matrix::set_diagonal(handle, alphaVec, triangular_matrix.view());

  // raft::matrix::initializeDiagonalMatrix(
  //   alpha.data_handle(), triangular_matrix.data_handle(), ncv, ncv, stream);

  int blockSize = 256;
  int numBlocks = (ncv + blockSize - 1) / blockSize;
  kernel_triangular_populate<ValueTypeT>
    <<<blockSize, numBlocks, 0, stream>>>(triangular_matrix.data_handle(), beta.data_handle(), ncv);

  if (beta_k) {
    int threadsPerBlock = 256;
    int blocksPerGrid   = (k + threadsPerBlock - 1) / threadsPerBlock;
    kernel_triangular_beta_k<ValueTypeT><<<blocksPerGrid, threadsPerBlock, 0, stream>>>(
      triangular_matrix.data_handle(), beta_k.value().data_handle(), (int)k, ncv);
  }

  auto triangular_matrix_view =
    raft::make_device_matrix_view<const ValueTypeT, uint32_t, raft::col_major>(
      triangular_matrix.data_handle(), ncv, ncv);

  raft::linalg::eig_dc(handle, triangular_matrix_view, eigenvectors, eigenvalues);

  IndexTypeT nEigVecs = k;

  auto indices          = raft::make_device_vector<int>(handle, ncv);
  auto selected_indices = raft::make_device_vector<int>(handle, nEigVecs);

  if (which == LANCZOS_WHICH::SA) {
    eigenvectors_k = raft::make_device_matrix_view<ValueTypeT, uint32_t, raft::col_major>(
      eigenvectors.data_handle(), ncv, nEigVecs);
    eigenvalues_k =
      raft::make_device_vector_view<ValueTypeT, uint32_t>(eigenvalues.data_handle(), nEigVecs);
    eigenvectors_k_slice = raft::make_device_matrix_view<ValueTypeT, IndexTypeT, raft::col_major>(
      eigenvectors.data_handle(), ncv, nEigVecs);
  } else if (which == LANCZOS_WHICH::LA) {
    eigenvectors_k = raft::make_device_matrix_view<ValueTypeT, uint32_t, raft::col_major>(
      eigenvectors.data_handle() + (ncv - nEigVecs) * ncv, ncv, nEigVecs);
    eigenvalues_k = raft::make_device_vector_view<ValueTypeT, uint32_t>(
      eigenvalues.data_handle() + (ncv - nEigVecs), nEigVecs);
    eigenvectors_k_slice = raft::make_device_matrix_view<ValueTypeT, IndexTypeT, raft::col_major>(
      eigenvectors.data_handle() + (ncv - nEigVecs) * ncv, ncv, nEigVecs);
  } else if (which == LANCZOS_WHICH::SM || which == LANCZOS_WHICH::LM) {
    thrust::sequence(thrust::device, indices.data_handle(), indices.data_handle() + ncv, 0);

    // Sort indices by absolute eigenvalues (magnitude) using a custom comparator
    thrust::sort(thrust::device,
                 indices.data_handle(),
                 indices.data_handle() + ncv,
                 [eigenvalues = eigenvalues.data_handle()] __device__(int a, int b) {
                   return fabsf(eigenvalues[a]) < fabsf(eigenvalues[b]);
                 });

    if (which == LANCZOS_WHICH::SM) {
      // Take the first nEigVecs indices (smallest magnitude)
      raft::copy(selected_indices.data_handle(), indices.data_handle(), nEigVecs, stream);
    } else if (which == LANCZOS_WHICH::LM) {
      // Take the last nEigVecs indices (largest magnitude)
      raft::copy(
        selected_indices.data_handle(), indices.data_handle() + (ncv - nEigVecs), nEigVecs, stream);
    }

    // Re-sort these indices by algebraic value to maintain algebraic ordering
    thrust::sort(thrust::device,
                 selected_indices.data_handle(),
                 selected_indices.data_handle() + nEigVecs,
                 [eigenvalues = eigenvalues.data_handle()] __device__(int a, int b) {
                   return eigenvalues[a] < eigenvalues[b];
                 });
    raft::matrix::gather(
      handle,
      raft::make_device_matrix_view<const ValueTypeT, uint32_t, raft::row_major>(
        eigenvalues.data_handle(), ncv, 1),
      raft::make_device_vector_view<const int, uint32_t>(selected_indices.data_handle(), nEigVecs),
      raft::make_device_matrix_view<ValueTypeT, uint32_t, raft::row_major>(
        sm_eigenvalues.data_handle(), nEigVecs, 1));
    raft::matrix::gather(
      handle,
      raft::make_device_matrix_view<const ValueTypeT, uint32_t, raft::row_major>(
        eigenvectors.data_handle(), ncv, ncv),
      raft::make_device_vector_view<const int, uint32_t>(selected_indices.data_handle(), nEigVecs),
      raft::make_device_matrix_view<ValueTypeT, uint32_t, raft::row_major>(
        sm_eigenvectors.data_handle(), nEigVecs, ncv));

    eigenvectors_k = raft::make_device_matrix_view<ValueTypeT, uint32_t, raft::col_major>(
      sm_eigenvectors.data_handle(), ncv, nEigVecs);
    eigenvalues_k =
      raft::make_device_vector_view<ValueTypeT, uint32_t>(sm_eigenvalues.data_handle(), nEigVecs);
    eigenvectors_k_slice = raft::make_device_matrix_view<ValueTypeT, IndexTypeT, raft::col_major>(
      sm_eigenvectors.data_handle(), ncv, nEigVecs);
  }
}

template <typename IndexTypeT, typename ValueTypeT>
void lanczos_aux(raft::resources const& handle,
                 raft::device_csr_matrix_view<ValueTypeT, IndexTypeT, IndexTypeT, IndexTypeT> A,
                 raft::device_matrix_view<ValueTypeT, uint32_t, raft::row_major> V,
                 raft::device_matrix_view<ValueTypeT, uint32_t> u,
                 raft::device_matrix_view<ValueTypeT, uint32_t> alpha,
                 raft::device_matrix_view<ValueTypeT, uint32_t> beta,
                 int start_idx,
                 int end_idx,
                 int ncv,
                 raft::device_matrix_view<ValueTypeT, uint32_t> v,
                 raft::device_matrix_view<ValueTypeT, uint32_t> uu,
                 raft::device_matrix_view<ValueTypeT, uint32_t> vv)
{
  auto stream = resource::get_cuda_stream(handle);

  IndexTypeT n  = A.structure_view().get_n_rows();
  auto v_vector = raft::make_device_vector_view<const ValueTypeT>(v.data_handle(), n);
  auto u_vector = raft::make_device_vector_view<const ValueTypeT>(u.data_handle(), n);

  raft::copy(
    v.data_handle(), V.data_handle() + start_idx * V.stride(0), n, stream);  // V(start_idx, 0)

  auto cusparse_h                 = resource::get_cusparse_handle(handle);
  cusparseSpMatDescr_t cusparse_A = raft::sparse::linalg::detail::create_descriptor(A);

  cusparseDnVecDescr_t cusparse_v = raft::sparse::linalg::detail::create_descriptor(v_vector);
  cusparseDnVecDescr_t cusparse_u = raft::sparse::linalg::detail::create_descriptor(u_vector);

  ValueTypeT one  = 1;
  ValueTypeT zero = 0;
  size_t bufferSize;
  raft::sparse::detail::cusparsespmv_buffersize(cusparse_h,
                                                CUSPARSE_OPERATION_NON_TRANSPOSE,
                                                &one,
                                                cusparse_A,
                                                cusparse_v,
                                                &zero,
                                                cusparse_u,
                                                CUSPARSE_SPMV_ALG_DEFAULT,
                                                &bufferSize,
                                                stream);
  auto cusparse_spmv_buffer = raft::make_device_vector<ValueTypeT>(handle, bufferSize);

  for (int i = start_idx; i < end_idx; i++) {
    raft::sparse::detail::cusparsespmv(cusparse_h,
                                       CUSPARSE_OPERATION_NON_TRANSPOSE,
                                       &one,
                                       cusparse_A,
                                       cusparse_v,
                                       &zero,
                                       cusparse_u,
                                       CUSPARSE_SPMV_ALG_DEFAULT,
                                       cusparse_spmv_buffer.data_handle(),
                                       stream);

    auto alpha_i =
      raft::make_device_scalar_view(alpha.data_handle() + i * alpha.stride(1));  // alpha(0, i)
    raft::linalg::dot(handle, v_vector, u_vector, alpha_i);

    raft::matrix::fill(handle, vv, zero);

    auto cublas_h = resource::get_cublas_handle(handle);

    ValueTypeT alpha_i_host = 0;
    ValueTypeT b            = 0;
    ValueTypeT mone         = -1;

    raft::copy<ValueTypeT>(
      &b, beta.data_handle() + ((i - 1 + ncv) % ncv) * beta.stride(1), 1, stream);
    raft::copy<ValueTypeT>(
      &alpha_i_host, alpha.data_handle() + i * alpha.stride(1), 1, stream);  // alpha(0, i)

    raft::linalg::axpy(handle, n, &alpha_i_host, v.data_handle(), 1, vv.data_handle(), 1, stream);
    raft::linalg::axpy(handle,
                       n,
                       &b,
                       V.data_handle() + (((i - 1 + ncv) % ncv) * V.stride(0)),
                       1,
                       vv.data_handle(),
                       1,
                       stream);
    raft::linalg::axpy(handle, n, &mone, vv.data_handle(), 1, u.data_handle(), 1, stream);

    raft::linalg::gemv(handle,
                       CUBLAS_OP_T,
                       n,
                       i + 1,
                       &one,
                       V.data_handle(),
                       n,
                       u.data_handle(),
                       1,
                       &zero,
                       uu.data_handle(),
                       1,
                       stream);

    raft::linalg::gemv(handle,
                       CUBLAS_OP_N,
                       n,
                       i + 1,
                       &mone,
                       V.data_handle(),
                       n,
                       uu.data_handle(),
                       1,
                       &one,
                       u.data_handle(),
                       1,
                       stream);

    auto uu_i = raft::make_device_scalar_view(uu.data_handle() + uu.stride(1) * i);  // uu(0, i)
    raft::linalg::add(handle, make_const_mdspan(alpha_i), make_const_mdspan(uu_i), alpha_i);

    kernel_clamp_down<<<1, 1, 0, stream>>>(alpha_i.data_handle(), static_cast<ValueTypeT>(1e-9));

    auto output = raft::make_device_vector_view<ValueTypeT, uint32_t>(
      beta.data_handle() + beta.stride(1) * i, 1);
    auto input = raft::make_device_matrix_view<const ValueTypeT, uint32_t>(u.data_handle(), 1, n);
    raft::linalg::norm<raft::linalg::L2Norm, raft::Apply::ALONG_ROWS>(
      handle, input, output, raft::sqrt_op());

    int blockSize = 256;
    int numBlocks = (n + blockSize - 1) / blockSize;

    kernel_clamp_down_vector<<<numBlocks, blockSize, 0, stream>>>(
      u.data_handle(), static_cast<ValueTypeT>(1e-7), n);

    kernel_clamp_down<<<1, 1, 0, stream>>>(beta.data_handle() + beta.stride(1) * i,
                                           static_cast<ValueTypeT>(1e-6));

    if (i >= end_idx - 1) { break; }

    int threadsPerBlock = 256;
    int blocksPerGrid   = (n + threadsPerBlock - 1) / threadsPerBlock;

    kernel_normalize<ValueTypeT><<<blocksPerGrid, threadsPerBlock, 0, stream>>>(
      u.data_handle(), beta.data_handle(), i, n, v.data_handle(), V.data_handle(), n);
  }
}

template <typename IndexTypeT, typename ValueTypeT>
auto lanczos_smallest(
  raft::resources const& handle,
  raft::device_csr_matrix_view<ValueTypeT, IndexTypeT, IndexTypeT, IndexTypeT> A,
  int nEigVecs,
  int maxIter,
  int restartIter,
  ValueTypeT tol,
  LANCZOS_WHICH which,
  ValueTypeT* eigVals_dev,
  ValueTypeT* eigVecs_dev,
  ValueTypeT* v0,
  uint64_t seed) -> int
{
  int n       = A.structure_view().get_n_rows();
  int ncv     = restartIter;
  auto stream = resource::get_cuda_stream(handle);

  auto V = raft::make_device_matrix<ValueTypeT, uint32_t, raft::row_major>(handle, ncv, n);
  auto V_0_view =
    raft::make_device_matrix_view<ValueTypeT, uint32_t>(V.data_handle(), 1, n);  // First Row V[0]
  auto v0_view = raft::make_device_matrix_view<const ValueTypeT, uint32_t>(v0, 1, n);

  auto u        = raft::make_device_matrix<ValueTypeT, uint32_t, raft::row_major>(handle, 1, n);
  auto u_vector = raft::make_device_vector_view<ValueTypeT, uint32_t>(u.data_handle(), n);
  raft::copy(u.data_handle(), v0, n, stream);

  auto cublas_h = resource::get_cublas_handle(handle);
  auto v0nrm    = raft::make_device_vector<ValueTypeT, uint32_t>(handle, 1);
  raft::linalg::norm<raft::linalg::L2Norm, raft::Apply::ALONG_ROWS>(
    handle, v0_view, v0nrm.view(), raft::sqrt_op());

  auto v0_vector_const = raft::make_device_vector_view<const ValueTypeT, uint32_t>(v0, n);

  raft::linalg::unary_op(
    handle, v0_vector_const, V_0_view, [device_scalar = v0nrm.data_handle()] __device__(auto y) {
      return y / *device_scalar;
    });

  auto alpha      = raft::make_device_matrix<ValueTypeT, uint32_t, raft::row_major>(handle, 1, ncv);
  auto beta       = raft::make_device_matrix<ValueTypeT, uint32_t, raft::row_major>(handle, 1, ncv);
  ValueTypeT zero = 0;
  raft::matrix::fill(handle, alpha.view(), zero);
  raft::matrix::fill(handle, beta.view(), zero);

  auto v      = raft::make_device_matrix<ValueTypeT, uint32_t, raft::row_major>(handle, 1, n);
  auto aux_uu = raft::make_device_matrix<ValueTypeT, uint32_t, raft::row_major>(handle, 1, ncv);
  auto vv     = raft::make_device_matrix<ValueTypeT, uint32_t, raft::row_major>(handle, 1, n);

  lanczos_aux(handle,
              A,
              V.view(),
              u.view(),
              alpha.view(),
              beta.view(),
              0,
              ncv,
              ncv,
              v.view(),
              aux_uu.view(),
              vv.view());

  auto eigenvectors =
    raft::make_device_matrix<ValueTypeT, uint32_t, raft::col_major>(handle, ncv, ncv);
  auto eigenvalues = raft::make_device_vector<ValueTypeT, uint32_t>(handle, ncv);

  raft::device_matrix_view<ValueTypeT, uint32_t, raft::col_major> eigenvectors_k;
  raft::device_vector_view<ValueTypeT, uint32_t> eigenvalues_k;
  raft::device_matrix_view<ValueTypeT, IndexTypeT, raft::col_major> eigenvectors_k_slice;

  auto sm_eigenvalues = raft::make_device_vector<ValueTypeT>(handle, nEigVecs);
  auto sm_eigenvectors =
    raft::make_device_matrix<ValueTypeT, uint32_t, raft::col_major>(handle, ncv, nEigVecs);

  lanczos_solve_ritz<IndexTypeT, ValueTypeT>(handle,
                                             alpha.view(),
                                             beta.view(),
                                             std::nullopt,
                                             nEigVecs,
                                             which,
                                             ncv,
                                             eigenvectors.view(),
                                             eigenvalues.view(),
                                             eigenvectors_k,
                                             eigenvalues_k,
                                             eigenvectors_k_slice,
                                             sm_eigenvalues.view(),
                                             sm_eigenvectors.view());

  auto ritz_eigenvectors =
    raft::make_device_matrix_view<ValueTypeT, uint32_t, raft::col_major>(eigVecs_dev, n, nEigVecs);

  auto V_T =
    raft::make_device_matrix_view<ValueTypeT, uint32_t, raft::col_major>(V.data_handle(), n, ncv);
  raft::linalg::gemm<ValueTypeT, uint32_t, raft::col_major, raft::col_major, raft::col_major>(
    handle, V_T, eigenvectors_k, ritz_eigenvectors);

  auto s = raft::make_device_vector<ValueTypeT>(handle, nEigVecs);

  auto S_matrix = raft::make_device_matrix_view<ValueTypeT, IndexTypeT, raft::col_major>(
    s.data_handle(), 1, nEigVecs);

  raft::matrix::slice_coordinates<IndexTypeT> coords(ncv - 1, 0, ncv, nEigVecs);
  raft::matrix::slice(handle, make_const_mdspan(eigenvectors_k_slice), S_matrix, coords);

  auto beta_k = raft::make_device_vector<ValueTypeT>(handle, nEigVecs);
  raft::matrix::fill(handle, beta_k.view(), zero);
  auto beta_scalar = raft::make_device_scalar_view<const ValueTypeT>(beta.data_handle() +
                                                                     (ncv - 1) * beta.stride(1));

  raft::linalg::axpy(handle, beta_scalar, raft::make_const_mdspan(s.view()), beta_k.view());

  ValueTypeT res = 0;

  raft::device_vector<ValueTypeT, uint32_t> output =
    raft::make_device_vector<ValueTypeT, uint32_t>(handle, 1);
  raft::device_matrix_view<const ValueTypeT> input =
    raft::make_device_matrix_view<const ValueTypeT>(beta_k.data_handle(), 1, nEigVecs);
  raft::linalg::norm<raft::linalg::L2Norm, raft::Apply::ALONG_ROWS>(
    handle, input, output.view(), raft::sqrt_op());
  raft::copy(&res, output.data_handle(), 1, stream);
  resource::sync_stream(handle, stream);

  auto uu  = raft::make_device_matrix<ValueTypeT>(handle, 1, nEigVecs);
  int iter = ncv;
  while (res > tol && iter < maxIter) {
    auto beta_view = raft::make_device_matrix_view<ValueTypeT, uint32_t, raft::row_major>(
      beta.data_handle(), 1, nEigVecs);
    raft::matrix::fill(handle, beta_view, zero);

    raft::copy(alpha.data_handle(), eigenvalues_k.data_handle(), nEigVecs, stream);

    auto x_T =
      raft::make_device_matrix_view<ValueTypeT>(ritz_eigenvectors.data_handle(), nEigVecs, n);

    raft::copy(V.data_handle(), x_T.data_handle(), nEigVecs * n, stream);

    ValueTypeT one  = 1;
    ValueTypeT mone = -1;

    raft::linalg::gemv(handle,
                       CUBLAS_OP_T,
                       n,
                       nEigVecs,
                       &one,
                       V.data_handle(),
                       n,
                       u.data_handle(),
                       1,
                       &zero,
                       uu.data_handle(),
                       1,
                       stream);

    raft::linalg::gemv(handle,
                       CUBLAS_OP_N,
                       n,
                       nEigVecs,
                       &mone,
                       V.data_handle(),
                       n,
                       uu.data_handle(),
                       1,
                       &one,
                       u.data_handle(),
                       1,
                       stream);

    auto V_0_view =
      raft::make_device_matrix_view<ValueTypeT>(V.data_handle() + (nEigVecs * n), 1, n);
    auto V_0_view_vector =
      raft::make_device_vector_view<ValueTypeT, uint32_t>(V_0_view.data_handle(), n);
    auto unrm = raft::make_device_vector<ValueTypeT, uint32_t>(handle, 1);
    raft::linalg::norm<raft::linalg::L2Norm, raft::Apply::ALONG_ROWS>(
      handle, raft::make_const_mdspan(u.view()), unrm.view(), raft::sqrt_op());

    raft::linalg::unary_op(
      handle,
      raft::make_const_mdspan(u_vector),
      V_0_view,
      [device_scalar = unrm.data_handle()] __device__(auto y) { return y / *device_scalar; });

    auto cusparse_h                 = resource::get_cusparse_handle(handle);
    cusparseSpMatDescr_t cusparse_A = raft::sparse::linalg::detail::create_descriptor(A);

    cusparseDnVecDescr_t cusparse_v =
      raft::sparse::linalg::detail::create_descriptor(V_0_view_vector);
    cusparseDnVecDescr_t cusparse_u = raft::sparse::linalg::detail::create_descriptor(u_vector);

    ValueTypeT zero = 0;
    size_t bufferSize;
    raft::sparse::detail::cusparsespmv_buffersize(cusparse_h,
                                                  CUSPARSE_OPERATION_NON_TRANSPOSE,
                                                  &one,
                                                  cusparse_A,
                                                  cusparse_v,
                                                  &zero,
                                                  cusparse_u,
                                                  CUSPARSE_SPMV_ALG_DEFAULT,
                                                  &bufferSize,
                                                  stream);
    auto cusparse_spmv_buffer = raft::make_device_vector<ValueTypeT>(handle, bufferSize);

    raft::sparse::detail::cusparsespmv(cusparse_h,
                                       CUSPARSE_OPERATION_NON_TRANSPOSE,
                                       &one,
                                       cusparse_A,
                                       cusparse_v,
                                       &zero,
                                       cusparse_u,
                                       CUSPARSE_SPMV_ALG_DEFAULT,
                                       cusparse_spmv_buffer.data_handle(),
                                       stream);

    auto alpha_k = raft::make_device_scalar_view<ValueTypeT>(alpha.data_handle() + nEigVecs);

    raft::linalg::dot(
      handle, make_const_mdspan(V_0_view_vector), make_const_mdspan(u_vector), alpha_k);

    raft::linalg::binary_op(handle,
                            make_const_mdspan(u_vector),
                            make_const_mdspan(V_0_view_vector),
                            u_vector,
                            [device_scalar_ptr = alpha_k.data_handle()] __device__(
                              ValueTypeT u_element, ValueTypeT V_0_element) {
                              return u_element - (*device_scalar_ptr) * V_0_element;
                            });

    auto temp = raft::make_device_vector<ValueTypeT, uint32_t>(handle, n);

    auto V_k = raft::make_device_matrix_view<ValueTypeT, uint32_t, raft::row_major>(
      V.data_handle(), nEigVecs, n);
    auto V_k_T =
      raft::make_device_matrix<ValueTypeT, uint32_t, raft::row_major>(handle, n, nEigVecs);

    raft::linalg::transpose(handle, V_k, V_k_T.view());

    ValueTypeT three = 3;
    ValueTypeT two   = 2;

    std::vector<ValueTypeT> M   = {1, 2, 3, 4, 5, 6};
    std::vector<ValueTypeT> vec = {1, 1};

    auto M_dev   = raft::make_device_matrix<ValueTypeT>(handle, 2, 3);
    auto vec_dev = raft::make_device_vector<ValueTypeT>(handle, 2);
    auto out     = raft::make_device_vector<ValueTypeT>(handle, 3);
    raft::copy(M_dev.data_handle(), M.data(), 6, stream);
    raft::copy(vec_dev.data_handle(), vec.data(), 2, stream);

    raft::linalg::gemv(handle,
                       CUBLAS_OP_N,
                       three,
                       two,
                       &one,
                       M_dev.data_handle(),
                       three,
                       vec_dev.data_handle(),
                       1,
                       &zero,
                       out.data_handle(),
                       1,
                       stream);

    raft::linalg::gemv(handle,
                       CUBLAS_OP_N,
                       n,
                       nEigVecs,
                       &one,
                       V_k.data_handle(),
                       n,
                       beta_k.data_handle(),
                       1,
                       &zero,
                       temp.data_handle(),
                       1,
                       stream);

    auto one_scalar = raft::make_device_scalar<ValueTypeT>(handle, 1);
    raft::linalg::binary_op(handle,
                            make_const_mdspan(u_vector),
                            make_const_mdspan(temp.view()),
                            u_vector,
                            [device_scalar_ptr = one_scalar.data_handle()] __device__(
                              ValueTypeT u_element, ValueTypeT temp_element) {
                              return u_element - (*device_scalar_ptr) * temp_element;
                            });

    auto output1 = raft::make_device_vector_view<ValueTypeT, uint32_t>(
      beta.data_handle() + beta.stride(1) * nEigVecs, 1);
    raft::linalg::norm<raft::linalg::L2Norm, raft::Apply::ALONG_ROWS>(
      handle, raft::make_const_mdspan(u.view()), output1, raft::sqrt_op());

    auto V_kplus1 =
      raft::make_device_vector_view<ValueTypeT>(V.data_handle() + V.stride(0) * (nEigVecs + 1), n);

    raft::linalg::unary_op(
      handle,
      make_const_mdspan(u_vector),
      V_kplus1,
      [device_scalar = (beta.data_handle() + beta.stride(1) * nEigVecs)] __device__(auto y) {
        return y / *device_scalar;
      });

    lanczos_aux(handle,
                A,
                V.view(),
                u.view(),
                alpha.view(),
                beta.view(),
                nEigVecs + 1,
                ncv,
                ncv,
                v.view(),
                aux_uu.view(),
                vv.view());
    iter += ncv - nEigVecs;
    lanczos_solve_ritz<IndexTypeT, ValueTypeT>(handle,
                                               alpha.view(),
                                               beta.view(),
                                               beta_k.view(),
                                               nEigVecs,
                                               which,
                                               ncv,
                                               eigenvectors.view(),
                                               eigenvalues.view(),
                                               eigenvectors_k,
                                               eigenvalues_k,
                                               eigenvectors_k_slice,
                                               sm_eigenvalues.view(),
                                               sm_eigenvectors.view());

    auto ritz_eigenvectors = raft::make_device_matrix_view<ValueTypeT, uint32_t, raft::col_major>(
      eigVecs_dev, n, nEigVecs);

    auto V_T =
      raft::make_device_matrix_view<ValueTypeT, uint32_t, raft::col_major>(V.data_handle(), n, ncv);
    raft::linalg::gemm<ValueTypeT, uint32_t, raft::col_major, raft::col_major, raft::col_major>(
      handle, V_T, eigenvectors_k, ritz_eigenvectors);

    auto S_matrix = raft::make_device_matrix_view<ValueTypeT, IndexTypeT, raft::col_major>(
      s.data_handle(), 1, nEigVecs);

    raft::matrix::slice_coordinates<IndexTypeT> coords(ncv - 1, 0, ncv, nEigVecs);
    raft::matrix::slice(handle, make_const_mdspan(eigenvectors_k_slice), S_matrix, coords);

    raft::matrix::fill(handle, beta_k.view(), zero);

    auto beta_scalar = raft::make_device_scalar_view<const ValueTypeT>(
      beta.data_handle() + beta.stride(1) * (ncv - 1));  // &((beta.view())(0, ncv - 1))

    raft::linalg::axpy(handle, beta_scalar, raft::make_const_mdspan(s.view()), beta_k.view());

    raft::device_vector<ValueTypeT, uint32_t> output2 =
      raft::make_device_vector<ValueTypeT, uint32_t>(handle, 1);
    raft::device_matrix_view<const ValueTypeT> input2 =
      raft::make_device_matrix_view<const ValueTypeT>(beta_k.data_handle(), 1, nEigVecs);
    raft::linalg::norm<raft::linalg::L2Norm, raft::Apply::ALONG_ROWS>(
      handle, input2, output2.view(), raft::sqrt_op());
    raft::copy(&res, output2.data_handle(), 1, stream);
    resource::sync_stream(handle, stream);
    RAFT_LOG_TRACE("Iteration %f: residual (tolerance) %d", iter, res);
  }

  raft::copy(eigVals_dev, eigenvalues_k.data_handle(), nEigVecs, stream);
  raft::copy(eigVecs_dev, ritz_eigenvectors.data_handle(), n * nEigVecs, stream);

  return 0;
}

template <typename IndexTypeT, typename ValueTypeT>
auto lanczos_compute_smallest_eigenvectors(
  raft::resources const& handle,
  lanczos_solver_config<ValueTypeT> const& config,
  raft::device_csr_matrix_view<ValueTypeT, IndexTypeT, IndexTypeT, IndexTypeT> A,
  std::optional<raft::device_vector_view<ValueTypeT, uint32_t>> v0,
  raft::device_vector_view<ValueTypeT, uint32_t> eigenvalues,
  raft::device_matrix_view<ValueTypeT, uint32_t, raft::col_major> eigenvectors) -> int
{
  if (v0.has_value()) {
    return lanczos_smallest(handle,
                            A,
                            config.n_components,
                            config.max_iterations,
                            config.ncv,
                            config.tolerance,
                            config.which,
                            eigenvalues.data_handle(),
                            eigenvectors.data_handle(),
                            v0->data_handle(),
                            config.seed);
  } else {
    // Handle the optional v0 initial Lanczos vector if nullopt is used
    auto n       = A.structure_view().get_n_rows();
    auto temp_v0 = raft::make_device_vector<ValueTypeT, uint32_t>(handle, n);
    raft::random::RngState rng_state(config.seed);
    raft::random::uniform(handle, rng_state, temp_v0.view(), ValueTypeT{0.0}, ValueTypeT{1.0});
    return lanczos_smallest(handle,
                            A,
                            config.n_components,
                            config.max_iterations,
                            config.ncv,
                            config.tolerance,
                            config.which,
                            eigenvalues.data_handle(),
                            eigenvectors.data_handle(),
                            temp_v0.data_handle(),
                            config.seed);
  }
}

}  // namespace raft::sparse::solver::detail
