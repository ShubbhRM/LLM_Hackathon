/*
 * Copyright (c) 2024, NVIDIA CORPORATION.
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

#include <raft/core/bitset.hpp>
#include <raft/core/detail/mdspan_util.cuh>
#include <raft/core/device_container_policy.hpp>
#include <raft/core/device_mdarray.hpp>
#include <raft/core/resources.hpp>

#include <type_traits>

namespace raft::core {
/**
 * @defgroup bitmap Bitmap
 * @{
 */
/**
 * @brief View of a RAFT Bitmap.
 *
 * This lightweight structure which represents and manipulates a two-dimensional bitmap matrix view
 * with row major order. This class provides functionality for handling a matrix where each element
 * is represented as a bit in a bitmap.
 *
 * @tparam bitmap_t Underlying type of the bitmap array. Default is uint32_t.
 * @tparam index_t Indexing type used. Default is uint32_t.
 */
template <typename bitmap_t = uint32_t, typename index_t = uint32_t>
struct bitmap_view : public bitset_view<bitmap_t, index_t> {
  using bitset_view<bitmap_t, index_t>::set;
  using bitset_view<bitmap_t, index_t>::test;

  static_assert((std::is_same<typename std::remove_const<bitmap_t>::type, uint32_t>::value ||
                 std::is_same<typename std::remove_const<bitmap_t>::type, uint64_t>::value),
                "The bitmap_t must be uint32_t or uint64_t.");
  /**
   * @brief Create a bitmap view from a device raw pointer.
   *
   * @param bitmap_ptr Device raw pointer
   * @param rows Number of row in the matrix.
   * @param cols Number of col in the matrix.
   * @param original_nbits Original number of bits used when the bitmap was created, to handle
   * potential mismatches of data types. This is useful for using ANN indexes when a bitmap was
   * originally created with a different data type than the ones currently supported in cuVS ANN
   * indexes.
   */
  _RAFT_HOST_DEVICE bitmap_view(bitmap_t* bitmap_ptr,
                                index_t rows,
                                index_t cols,
                                index_t original_nbits = 0)
    : bitset_view<bitmap_t, index_t>(bitmap_ptr, rows * cols, original_nbits),
      rows_(rows),
      cols_(cols)
  {
  }

  /**
   * @brief Create a bitmap view from a device vector view of the bitset.
   *
   * @param bitmap_span Device vector view of the bitmap
   * @param rows Number of row in the matrix.
   * @param cols Number of col in the matrix.
   * @param original_nbits Original number of bits used when the bitmap was created, to handle
   * potential mismatches of data types. This is useful for using ANN indexes when a bitmap was
   * originally created with a different data type than the ones currently supported in cuVS ANN
   * indexes.
   */
  _RAFT_HOST_DEVICE bitmap_view(raft::device_vector_view<bitmap_t, index_t> bitmap_span,
                                index_t rows,
                                index_t cols,
                                index_t original_nbits = 0)
    : bitset_view<bitmap_t, index_t>(bitmap_span, rows * cols, original_nbits),
      rows_(rows),
      cols_(cols)
  {
  }

 private:
  // Hide the constructors of bitset_view.
  _RAFT_HOST_DEVICE bitmap_view(bitmap_t* bitmap_ptr, index_t bitmap_len)
    : bitset_view<bitmap_t, index_t>(bitmap_ptr, bitmap_len)
  {
  }

  _RAFT_HOST_DEVICE bitmap_view(raft::device_vector_view<bitmap_t, index_t> bitmap_span,
                                index_t bitmap_len)
    : bitset_view<bitmap_t, index_t>(bitmap_span, bitmap_len)
  {
  }

 public:
  /**
   * @brief Device function to test if a given row and col are set in the bitmap.
   *
   * @param row Row index of the bit to test
   * @param col Col index of the bit to test
   * @return bool True if index has not been unset in the bitset
   */
  inline _RAFT_HOST_DEVICE bool test(const index_t row, const index_t col) const;

  /**
   * @brief Device function to set a given row and col to set_value in the bitset.
   *
   * @param row Row index of the bit to set
   * @param col Col index of the bit to set
   * @param new_value Value to set the bit to (true or false)
   */
  inline _RAFT_DEVICE void set(const index_t row, const index_t col, bool new_value) const;

  /**
   * @brief Get the total number of rows
   * @return index_t The total number of rows
   */
  inline _RAFT_HOST_DEVICE index_t get_n_rows() const { return rows_; }

  /**
   * @brief Get the total number of columns
   * @return index_t The total number of columns
   */
  inline _RAFT_HOST_DEVICE index_t get_n_cols() const { return cols_; }

  /**
   * @brief Converts to a Compressed Sparse Row (CSR) format matrix.
   *
   * This method transforms a two-dimensional bitmap matrix into a CSR representation,
   * where each '1' bit in the bitmap corresponds to a non-zero entry in the CSR matrix.
   * The bitmap is interpreted as a row-major matrix, with rows and columns defined by
   * the dimensions of the bitmap.
   *
   * @tparam csr_matrix_t Specifies the CSR matrix type, constrained to raft::device_csr_matrix.
   *
   * @param[in] res RAFT resources for managing CUDA streams and execution policies.
   * @param[out] csr Output parameter where the resulting CSR matrix is stored. Each '1' bit in
   * the bitmap corresponds to a non-zero element in the CSR matrix.
   *
   * The caller must ensure that: The `csr` matrix is pre-allocated with dimensions and non-zero
   * count matching the expected output.
   */
  template <typename csr_matrix_t>
  void to_csr(const raft::resources& res, csr_matrix_t& csr) const;

 private:
  index_t rows_;
  index_t cols_;
};

/** @} */
}  // end namespace raft::core
