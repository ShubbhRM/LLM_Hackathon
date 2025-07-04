/*
 * Copyright (c) 2022-2025, NVIDIA CORPORATION.
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

#include "compression_common.hpp"
#include "parquet_common.hpp"

#include <cudf_test/base_fixture.hpp>
#include <cudf_test/column_utilities.hpp>
#include <cudf_test/column_wrapper.hpp>
#include <cudf_test/cudf_gtest.hpp>
#include <cudf_test/io_metadata_utilities.hpp>
#include <cudf_test/iterator_utilities.hpp>
#include <cudf_test/table_utilities.hpp>
#include <cudf_test/type_lists.hpp>

#include <cudf/column/column.hpp>
#include <cudf/column/column_factories.hpp>
#include <cudf/concatenate.hpp>
#include <cudf/copying.hpp>
#include <cudf/detail/iterator.cuh>
#include <cudf/detail/structs/utilities.hpp>
#include <cudf/fixed_point/fixed_point.hpp>
#include <cudf/io/data_sink.hpp>
#include <cudf/io/datasource.hpp>
#include <cudf/io/parquet.hpp>
#include <cudf/io/parquet_schema.hpp>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/table/table.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/utilities/memory_resource.hpp>
#include <cudf/utilities/span.hpp>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/iterator/counting_iterator.h>

#include <src/io/parquet/compact_protocol_reader.hpp>

#include <fstream>
#include <type_traits>

namespace {

using int32s_col       = cudf::test::fixed_width_column_wrapper<int32_t>;
using int64s_col       = cudf::test::fixed_width_column_wrapper<int64_t>;
using strings_col      = cudf::test::strings_column_wrapper;
using structs_col      = cudf::test::structs_column_wrapper;
using int32s_lists_col = cudf::test::lists_column_wrapper<int32_t>;

auto write_file(std::vector<std::unique_ptr<cudf::column>>& input_columns,
                std::string const& filename,
                bool nullable,
                bool delta_encoding,
                std::size_t max_page_size_bytes = cudf::io::default_max_page_size_bytes,
                std::size_t max_page_size_rows  = cudf::io::default_max_page_size_rows)
{
  if (nullable) {
    // Generate deterministic bitmask instead of random bitmask for easy computation of data size.
    auto const valid_iter = cudf::detail::make_counting_transform_iterator(
      0, [](cudf::size_type i) { return i % 4 != 3; });

    cudf::size_type offset{0};
    for (auto& col : input_columns) {
      auto const [null_mask, null_count] =
        cudf::test::detail::make_null_mask(valid_iter + offset, valid_iter + col->size() + offset);
      col = cudf::structs::detail::superimpose_and_sanitize_nulls(
        static_cast<cudf::bitmask_type const*>(null_mask.data()),
        null_count,
        std::move(col),
        cudf::get_default_stream(),
        cudf::get_current_device_resource_ref());

      // Shift nulls of the next column by one position, to avoid having all nulls
      // in the same table rows.
      ++offset;
    }
  }

  auto input_table = std::make_unique<cudf::table>(std::move(input_columns));

  auto file_name = filename;
  if (nullable) { file_name = file_name + "_nullable"; }
  if (delta_encoding) { file_name = file_name + "_delta"; }
  auto const filepath = temp_env->get_temp_filepath(file_name + ".parquet");

  auto const dict_policy =
    delta_encoding ? cudf::io::dictionary_policy::NEVER : cudf::io::dictionary_policy::ALWAYS;
  auto const v2_headers = delta_encoding;
  auto const write_opts =
    cudf::io::parquet_writer_options::builder(cudf::io::sink_info{filepath}, *input_table)
      .max_page_size_bytes(max_page_size_bytes)
      .max_page_size_rows(max_page_size_rows)
      .max_page_fragment_size(cudf::io::default_max_page_fragment_size)
      .dictionary_policy(dict_policy)
      .write_v2_headers(v2_headers)
      .build();
  cudf::io::write_parquet(write_opts);

  return std::pair{std::move(input_table), std::move(filepath)};
}

auto chunked_read(std::vector<std::string> const& filepaths,
                  std::size_t output_limit,
                  std::size_t input_limit = 0)
{
  auto const read_opts =
    cudf::io::parquet_reader_options::builder(cudf::io::source_info{filepaths}).build();
  auto reader = cudf::io::chunked_parquet_reader(output_limit, input_limit, read_opts);

  auto num_chunks = 0;
  auto out_tables = std::vector<std::unique_ptr<cudf::table>>{};

  do {
    auto chunk = reader.read_chunk();
    // If the input file is empty, the first call to `read_chunk` will return an empty table.
    // Thus, we only check for non-empty output table from the second call.
    if (num_chunks > 0) {
      CUDF_EXPECTS(chunk.tbl->num_rows() != 0, "Number of rows in the new chunk is zero.");
    }
    ++num_chunks;
    out_tables.emplace_back(std::move(chunk.tbl));
  } while (reader.has_next());

  auto out_tviews = std::vector<cudf::table_view>{};
  for (auto const& tbl : out_tables) {
    out_tviews.emplace_back(tbl->view());
  }

  return std::pair(cudf::concatenate(out_tviews), num_chunks);
}

auto chunked_read(std::string const& filepath,
                  std::size_t output_limit,
                  std::size_t input_limit = 0)
{
  std::vector<std::string> vpath{filepath};
  return chunked_read(vpath, output_limit, input_limit);
}

auto const read_table_and_nrows_per_source(cudf::io::chunked_parquet_reader const& reader)
{
  auto out_tables       = std::vector<std::unique_ptr<cudf::table>>{};
  int num_chunks        = 0;
  auto nrows_per_source = std::vector<size_t>{};
  while (reader.has_next()) {
    auto chunk = reader.read_chunk();
    out_tables.emplace_back(std::move(chunk.tbl));
    num_chunks++;
    if (nrows_per_source.empty()) {
      nrows_per_source = std::move(chunk.metadata.num_rows_per_source);
    } else {
      std::transform(chunk.metadata.num_rows_per_source.cbegin(),
                     chunk.metadata.num_rows_per_source.cend(),
                     nrows_per_source.begin(),
                     nrows_per_source.begin(),
                     std::plus<size_t>());
    }
  }
  auto out_tviews = std::vector<cudf::table_view>{};
  for (auto const& tbl : out_tables) {
    out_tviews.emplace_back(tbl->view());
  }

  return std::tuple(cudf::concatenate(out_tviews), num_chunks, nrows_per_source);
}

}  // namespace

struct ParquetChunkedReaderTest : public cudf::test::BaseFixture {};

using ParquetChunkedDecompressionTest = DecompressionTest<ParquetChunkedReaderTest>;

TEST_F(ParquetChunkedReaderTest, TestChunkedReadNoData)
{
  std::vector<std::unique_ptr<cudf::column>> input_columns;
  input_columns.emplace_back(int32s_col{}.release());
  input_columns.emplace_back(int64s_col{}.release());

  auto const [expected, filepath] = write_file(input_columns, "chunked_read_empty", false, false);
  auto const [result, num_chunks] = chunked_read(filepath, 1'000);
  // EXPECT_EQ(num_chunks, 1);
  EXPECT_EQ(result->num_rows(), 0);
  EXPECT_EQ(result->num_columns(), 2);
  CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
}

TEST_F(ParquetChunkedReaderTest, TestChunkedReadSimpleData)
{
  auto constexpr num_rows = 40'000;

  auto const generate_input = [num_rows](bool nullable, bool use_delta) {
    std::vector<std::unique_ptr<cudf::column>> input_columns;
    auto const value_iter = thrust::make_counting_iterator(0);
    input_columns.emplace_back(int32s_col(value_iter, value_iter + num_rows).release());
    input_columns.emplace_back(int64s_col(value_iter, value_iter + num_rows).release());

    return write_file(input_columns, "chunked_read_simple", nullable, false);
  };

  {
    auto const [expected, filepath] = generate_input(false, false);
    auto const [result, num_chunks] = chunked_read(filepath, 240'000);
    // EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  {
    auto const [expected, filepath] = generate_input(false, true);
    auto const [result, num_chunks] = chunked_read(filepath, 240'000);
    // EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  {
    auto const [expected, filepath] = generate_input(true, false);
    auto const [result, num_chunks] = chunked_read(filepath, 240'000);
    // EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  {
    auto const [expected, filepath] = generate_input(true, true);
    auto const [result, num_chunks] = chunked_read(filepath, 240'000);
    // EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }
}

TEST_F(ParquetChunkedReaderTest, TestChunkedReadBoundaryCases)
{
  // Tests some specific boundary conditions in the split calculations.

  auto constexpr num_rows = 40'000;

  auto const [expected, filepath] = [num_rows]() {
    std::vector<std::unique_ptr<cudf::column>> input_columns;
    auto const value_iter = thrust::make_counting_iterator(0);
    input_columns.emplace_back(int32s_col(value_iter, value_iter + num_rows).release());
    return write_file(
      input_columns, "chunked_read_simple_boundary", false /*nullable*/, false /*delta_encoding*/);
  }();

  // Test with zero limit: everything will be read in one chunk
  {
    auto const [result, num_chunks] = chunked_read(filepath, 0);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a very small limit: 1 byte
  {
    auto const [result, num_chunks] = chunked_read(filepath, 1);
    // EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a very large limit
  {
    auto const [result, num_chunks] = chunked_read(filepath, 2L << 40);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a limit slightly less than one page of data
  {
    auto const [result, num_chunks] = chunked_read(filepath, 79'000);
    // EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a limit exactly the size one page of data
  {
    auto const [result, num_chunks] = chunked_read(filepath, 80'000);
    // EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a limit slightly more the size one page of data
  {
    auto const [result, num_chunks] = chunked_read(filepath, 81'000);
    // EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a limit slightly less than two pages of data
  {
    auto const [result, num_chunks] = chunked_read(filepath, 159'000);
    // EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a limit exactly the size of two pages of data minus one byte
  {
    auto const [result, num_chunks] = chunked_read(filepath, 159'999);
    // EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a limit exactly the size of two pages of data
  {
    auto const [result, num_chunks] = chunked_read(filepath, 160'000);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a limit slightly more the size two pages of data
  {
    auto const [result, num_chunks] = chunked_read(filepath, 161'000);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }
}

TEST_F(ParquetChunkedReaderTest, TestChunkedReadWithString)
{
  auto constexpr num_rows = 60'000;

  auto const generate_input = [num_rows](bool nullable, bool use_delta) {
    std::vector<std::unique_ptr<cudf::column>> input_columns;
    auto const value_iter = thrust::make_counting_iterator(0);

    // ints                                            Page    total bytes   cumulative bytes
    // 20000 rows of 4 bytes each                    = A0      80000         80000
    // 20000 rows of 4 bytes each                    = A1      80000         160000
    // 20000 rows of 4 bytes each                    = A2      80000         240000
    input_columns.emplace_back(int32s_col(value_iter, value_iter + num_rows).release());

    // strings                                         Page    total bytes   cumulative bytes
    // 20000 rows of 1 char each    (20000  + 80004) = B0      100004        100004
    // 20000 rows of 4 chars each   (80000  + 80004) = B1      160004        260008
    // 20000 rows of 16 chars each  (320000 + 80004) = B2      400004        660012
    auto const strings  = std::vector<std::string>{"a", "bbbb", "cccccccccccccccc"};
    auto const str_iter = cudf::detail::make_counting_transform_iterator(0, [&](int32_t i) {
      if (i < 20000) { return strings[0]; }
      if (i < 40000) { return strings[1]; }
      return strings[2];
    });
    input_columns.emplace_back(strings_col(str_iter, str_iter + num_rows).release());

    // Cumulative sizes:
    // A0 + B0 :  180004
    // A1 + B1 :  420008
    // A2 + B2 :  900012
    //                                    skip_rows / num_rows
    // byte_limit==500000  should give 2 chunks: {0, 40000}, {40000, 20000}
    // byte_limit==1000000 should give 1 chunks: {0, 60000},
    return write_file(input_columns,
                      "chunked_read_with_strings",
                      nullable,
                      use_delta,
                      512 * 1024,  // 512KB per page
                      20000        // 20k rows per page
    );
  };

  auto const [expected_no_null, filepath_no_null]                   = generate_input(false, false);
  auto const [expected_with_nulls, filepath_with_nulls]             = generate_input(true, false);
  auto const [expected_no_null_delta, filepath_no_null_delta]       = generate_input(false, true);
  auto const [expected_with_nulls_delta, filepath_with_nulls_delta] = generate_input(true, true);

  // Test with zero limit: everything will be read in one chunk
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 0);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 0);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null_delta, 0);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null_delta, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls_delta, 0);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls_delta, *result);
  }

  // Test with a very small limit: 1 byte
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1);
    EXPECT_EQ(num_chunks, 3);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 1);
    EXPECT_EQ(num_chunks, 3);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null_delta, 1);
    EXPECT_EQ(num_chunks, 3);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null_delta, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls_delta, 1);
    EXPECT_EQ(num_chunks, 3);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls_delta, *result);
  }

  // Test with a very large limit
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 2L << 40);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 2L << 40);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null_delta, 2L << 40);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null_delta, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls_delta, 2L << 40);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls_delta, *result);
  }

  // Other tests:

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 500'000);
    // EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 500'000);
    // EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null_delta, 500'000);
    // EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null_delta, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls_delta, 500'000);
    // EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls_delta, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1'000'000);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 1'000'000);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null_delta, 1'000'000);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null_delta, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls_delta, 1'000'000);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls_delta, *result);
  }
}

TEST_F(ParquetChunkedReaderTest, TestChunkedReadWithStringPrecise)
{
  auto constexpr num_rows = 60'000;

  auto const generate_input = [num_rows](bool nullable, bool use_delta) {
    std::vector<std::unique_ptr<cudf::column>> input_columns;

    // strings                                                 Page    total bytes   cumulative
    // 20000 rows alternating 1-4 chars each (50000 + 80004)   A0      130004        130004
    // 20000 rows alternating 1-4 chars each (50000 + 80004)   A1      130004        260008
    // ...
    auto const strings = std::vector<std::string>{"a", "bbbb"};
    auto const str_iter =
      cudf::detail::make_counting_transform_iterator(0, [&](int32_t i) { return strings[i % 2]; });
    input_columns.emplace_back(strings_col(str_iter, str_iter + num_rows).release());

    // Cumulative sizes:
    // A0 :  130004
    // A1 :  260008
    // A2 :  390012
    return write_file(input_columns,
                      "chunked_read_with_strings_precise",
                      nullable,
                      use_delta,
                      512 * 1024,  // 512KB per page
                      20000        // 20k rows per page
    );
  };

  auto const [expected_no_null, filepath_no_null] = generate_input(false, false);

  // a chunk limit of 1 byte less than 2 pages should force it to produce 3 chunks:
  // each 1 page in size
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 260'007);
    // EXPECT_EQ(num_chunks, 3);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }

  // a chunk limit of exactly equal to 2 pages should force it to produce 2 chunks
  // pages 0-1 and page 2
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 260'008);
    // EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
}

TEST_F(ParquetChunkedReaderTest, TestChunkedReadWithStructs)
{
  auto constexpr num_rows = 100'000;

  auto const generate_input = [num_rows](bool nullable) {
    std::vector<std::unique_ptr<cudf::column>> input_columns;
    auto const int_iter = thrust::make_counting_iterator(0);
    input_columns.emplace_back(int32s_col(int_iter, int_iter + num_rows).release());
    input_columns.emplace_back([=] {
      auto child1 = int32s_col(int_iter, int_iter + num_rows);
      auto child2 = int32s_col(int_iter + num_rows, int_iter + num_rows * 2);

      auto const str_iter = cudf::detail::make_counting_transform_iterator(
        0, [&](int32_t i) { return std::to_string(i); });
      auto child3 = strings_col{str_iter, str_iter + num_rows};

      return structs_col{{child1, child2, child3}}.release();
    }());

    return write_file(input_columns,
                      "chunked_read_with_structs",
                      nullable,
                      false /*delta_encoding*/,
                      512 * 1024,  // 512KB per page
                      20000        // 20k rows per page
    );
  };

  auto const [expected_no_null, filepath_no_null]       = generate_input(false);
  auto const [expected_with_nulls, filepath_with_nulls] = generate_input(true);

  // Test with zero limit: everything will be read in one chunk
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 0);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 0);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Test with a very small limit: 1 byte
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 1);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Test with a very large limit
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 2L << 40);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 2L << 40);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Other tests:

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 500'000);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 500'000);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }
}

TEST_F(ParquetChunkedReaderTest, TestChunkedReadWithListsNoNulls)
{
  auto constexpr num_rows = 100'000;

  auto const [expected, filepath] = [num_rows]() {
    std::vector<std::unique_ptr<cudf::column>> input_columns;
    // 20000 rows in 1 page consist of:
    //
    // 20001 offsets :   80004  bytes
    // 30000 ints    :   120000 bytes
    // total         :   200004 bytes
    auto const template_lists = int32s_lists_col{
      int32s_lists_col{}, int32s_lists_col{0}, int32s_lists_col{1, 2}, int32s_lists_col{3, 4, 5}};

    auto const gather_iter =
      cudf::detail::make_counting_transform_iterator(0, [&](int32_t i) { return i % 4; });
    auto const gather_map = int32s_col(gather_iter, gather_iter + num_rows);
    input_columns.emplace_back(
      std::move(cudf::gather(cudf::table_view{{template_lists}}, gather_map)->release().front()));

    return write_file(input_columns,
                      "chunked_read_with_lists_no_null",
                      false /*nullable*/,
                      false /*delta_encoding*/,
                      512 * 1024,  // 512KB per page
                      20000        // 20k rows per page
    );
  }();

  // Test with zero limit: everything will be read in one chunk
  {
    auto const [result, num_chunks] = chunked_read(filepath, 0);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a very small limit: 1 byte
  {
    auto const [result, num_chunks] = chunked_read(filepath, 1);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a very large limit
  {
    auto const [result, num_chunks] = chunked_read(filepath, 2L << 40);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // chunk size slightly less than 1 page (forcing it to be at least 1 page per read)
  {
    auto const [result, num_chunks] = chunked_read(filepath, 200'000);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // chunk size exactly 1 page
  {
    auto const [result, num_chunks] = chunked_read(filepath, 200'004);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // chunk size 2 pages. 3 chunks (2 pages + 2 pages + 1 page)
  {
    auto const [result, num_chunks] = chunked_read(filepath, 400'008);
    // EXPECT_EQ(num_chunks, 3);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // chunk size 2 pages minus one byte: each chunk will be just one page
  {
    auto const [result, num_chunks] = chunked_read(filepath, 400'007);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }
}

TEST_F(ParquetChunkedReaderTest, TestChunkedReadWithListsHavingNulls)
{
  auto constexpr num_rows = 100'000;

  auto const [expected, filepath] = [num_rows]() {
    std::vector<std::unique_ptr<cudf::column>> input_columns;
    // 20000 rows in 1 page consist of:
    //
    // 625 validity words :   2500 bytes   (a null every 4 rows: null at indices [3, 7, 11, ...])
    // 20001 offsets      :   80004  bytes
    // 15000 ints         :   60000 bytes
    // total              :   142504 bytes
    auto const template_lists =
      int32s_lists_col{// these will all be null
                       int32s_lists_col{},
                       int32s_lists_col{0},
                       int32s_lists_col{1, 2},
                       int32s_lists_col{3, 4, 5, 6, 7, 8, 9} /* this list will be nullified out */};
    auto const gather_iter =
      cudf::detail::make_counting_transform_iterator(0, [&](int32_t i) { return i % 4; });
    auto const gather_map = int32s_col(gather_iter, gather_iter + num_rows);
    input_columns.emplace_back(
      std::move(cudf::gather(cudf::table_view{{template_lists}}, gather_map)->release().front()));

    return write_file(input_columns,
                      "chunked_read_with_lists_nulls",
                      true /*nullable*/,
                      false /*delta_encoding*/,
                      512 * 1024,  // 512KB per page
                      20000        // 20k rows per page
    );
  }();

  // Test with zero limit: everything will be read in one chunk
  {
    auto const [result, num_chunks] = chunked_read(filepath, 0);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a very small limit: 1 byte
  {
    auto const [result, num_chunks] = chunked_read(filepath, 1);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // Test with a very large limit
  {
    auto const [result, num_chunks] = chunked_read(filepath, 2L << 40);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // chunk size slightly less than 1 page (forcing it to be at least 1 page per read)
  {
    auto const [result, num_chunks] = chunked_read(filepath, 142'500);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // chunk size exactly 1 page
  {
    auto const [result, num_chunks] = chunked_read(filepath, 142'504);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // chunk size 2 pages. 3 chunks (2 pages + 2 pages + 1 page)
  {
    auto const [result, num_chunks] = chunked_read(filepath, 285'008);
    // EXPECT_EQ(num_chunks, 3);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  // chunk size 2 pages minus 1 byte: each chunk will be just one page
  {
    auto const [result, num_chunks] = chunked_read(filepath, 285'007);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }
}

TEST_F(ParquetChunkedReaderTest, TestChunkedReadWithStructsOfLists)
{
  auto constexpr num_rows = 100'000;

  auto const generate_input = [num_rows](bool nullable) {
    std::vector<std::unique_ptr<cudf::column>> input_columns;
    auto const int_iter = thrust::make_counting_iterator(0);
    input_columns.emplace_back(int32s_col(int_iter, int_iter + num_rows).release());
    input_columns.emplace_back([=] {
      std::vector<std::unique_ptr<cudf::column>> child_columns;
      child_columns.emplace_back(int32s_col(int_iter, int_iter + num_rows).release());
      child_columns.emplace_back(
        int32s_col(int_iter + num_rows, int_iter + num_rows * 2).release());

      auto const str_iter = cudf::detail::make_counting_transform_iterator(0, [&](int32_t i) {
        return std::to_string(i) + "++++++++++++++++++++" + std::to_string(i);
      });
      child_columns.emplace_back(strings_col{str_iter, str_iter + num_rows}.release());

      auto const template_lists = int32s_lists_col{
        int32s_lists_col{}, int32s_lists_col{0}, int32s_lists_col{0, 1}, int32s_lists_col{0, 1, 2}};
      auto const gather_iter =
        cudf::detail::make_counting_transform_iterator(0, [&](int32_t i) { return i % 4; });
      auto const gather_map = int32s_col(gather_iter, gather_iter + num_rows);
      child_columns.emplace_back(
        std::move(cudf::gather(cudf::table_view{{template_lists}}, gather_map)->release().front()));

      return structs_col(std::move(child_columns)).release();
    }());

    return write_file(input_columns,
                      "chunked_read_with_structs_of_lists",
                      nullable,
                      false /*delta_encoding*/,
                      512 * 1024,  // 512KB per page
                      20000        // 20k rows per page
    );
  };

  auto const [expected_no_null, filepath_no_null]       = generate_input(false);
  auto const [expected_with_nulls, filepath_with_nulls] = generate_input(true);

  // Test with zero limit: everything will be read in one chunk
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 0);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 0);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Test with a very small limit: 1 byte
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1);
    // EXPECT_EQ(num_chunks, 10);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 1);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Test with a very large limit
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 2L << 40);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 2L << 40);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Other tests:

  // for these tests, different columns get written to different numbers of pages so it's a
  // little tricky to describe the expected results by page counts. To get an idea of how
  // these values are chosen, see the debug output from the call to print_cumulative_page_info() in
  // reader_impl_preprocess.cu -> find_splits()

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1'000'000);
    // EXPECT_EQ(num_chunks, 7);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1'500'000);
    // EXPECT_EQ(num_chunks, 4);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 2'000'000);
    // EXPECT_EQ(num_chunks, 4);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 5'000'000);
    // EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 1'000'000);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 1'500'000);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 2'000'000);
    // EXPECT_EQ(num_chunks, 3);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 5'000'000);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }
}

TEST_F(ParquetChunkedReaderTest, TestChunkedReadWithListsOfStructs)
{
  auto constexpr num_rows = 100'000;

  auto const generate_input = [num_rows](bool nullable) {
    std::vector<std::unique_ptr<cudf::column>> input_columns;
    auto const int_iter = thrust::make_counting_iterator(0);
    input_columns.emplace_back(int32s_col(int_iter, int_iter + num_rows).release());

    auto offsets = std::vector<cudf::size_type>{};
    offsets.reserve(num_rows * 2);
    cudf::size_type num_structs = 0;
    for (int i = 0; i < num_rows; ++i) {
      offsets.push_back(num_structs);
      auto const new_list_size = i % 4;
      num_structs += new_list_size;
    }
    offsets.push_back(num_structs);

    auto const make_structs_col = [=] {
      auto child1 = int32s_col(int_iter, int_iter + num_structs);
      auto child2 = int32s_col(int_iter + num_structs, int_iter + num_structs * 2);

      auto const str_iter = cudf::detail::make_counting_transform_iterator(
        0, [&](int32_t i) { return std::to_string(i) + std::to_string(i) + std::to_string(i); });
      auto child3 = strings_col{str_iter, str_iter + num_structs};

      return structs_col{{child1, child2, child3}}.release();
    };

    input_columns.emplace_back(
      cudf::make_lists_column(static_cast<cudf::size_type>(offsets.size() - 1),
                              int32s_col(offsets.begin(), offsets.end()).release(),
                              make_structs_col(),
                              0,
                              rmm::device_buffer{}));

    return write_file(input_columns,
                      "chunked_read_with_lists_of_structs",
                      nullable,
                      false /*delta_encoding*/,
                      512 * 1024,  // 512KB per page
                      20000        // 20k rows per page
    );
  };

  auto const [expected_no_null, filepath_no_null]       = generate_input(false);
  auto const [expected_with_nulls, filepath_with_nulls] = generate_input(true);

  // Test with zero limit: everything will be read in one chunk
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 0);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 0);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Test with a very small limit: 1 byte
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1);
    // EXPECT_EQ(num_chunks, 10);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 1);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // Test with a very large limit
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 2L << 40);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }
  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 2L << 40);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  // for these tests, different columns get written to different numbers of pages so it's a
  // little tricky to describe the expected results by page counts. To get an idea of how
  // these values are chosen, see the debug output from the call to print_cumulative_page_info() in
  // reader_impl_preprocess.cu -> find_splits()
  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1'000'000);
    // EXPECT_EQ(num_chunks, 7);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 1'500'000);
    // EXPECT_EQ(num_chunks, 4);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 2'000'000);
    // EXPECT_EQ(num_chunks, 4);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_no_null, 5'000'000);
    // EXPECT_EQ(num_chunks, 2);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_no_null, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 1'000'000);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 1'500'000);
    // EXPECT_EQ(num_chunks, 5);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 2'000'000);
    // EXPECT_EQ(num_chunks, 3);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath_with_nulls, 5'000'000);
    // EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected_with_nulls, *result);
  }
}

TEST_F(ParquetChunkedReaderTest, TestChunkedReadNullCount)
{
  auto constexpr num_rows = 100'000;

  auto const sequence = cudf::detail::make_counting_transform_iterator(0, [](auto i) { return 1; });
  auto const validity =
    cudf::detail::make_counting_transform_iterator(0, [](auto i) { return i % 4 != 3; });
  cudf::test::fixed_width_column_wrapper<int32_t> col{sequence, sequence + num_rows, validity};
  std::vector<std::unique_ptr<cudf::column>> cols;
  cols.push_back(col.release());
  auto const expected = std::make_unique<cudf::table>(std::move(cols));

  auto const filepath        = temp_env->get_temp_filepath("chunked_reader_null_count.parquet");
  auto const page_limit_rows = num_rows / 5;
  auto const write_opts =
    cudf::io::parquet_writer_options::builder(cudf::io::sink_info{filepath}, *expected)
      .max_page_size_rows(page_limit_rows)  // 20k rows per page
      .build();
  cudf::io::write_parquet(write_opts);

  auto const byte_limit = page_limit_rows * sizeof(int);
  auto const read_opts =
    cudf::io::parquet_reader_options::builder(cudf::io::source_info{filepath}).build();
  auto reader = cudf::io::chunked_parquet_reader(byte_limit, read_opts);

  do {
    // Every fourth row is null
    EXPECT_EQ(reader.read_chunk().tbl->get_column(0).null_count(), page_limit_rows / 4);
  } while (reader.has_next());
}

namespace {
constexpr size_t input_limit_expected_file_count = 4;

std::vector<std::string> input_limit_get_test_names(std::string const& base_filename)
{
  return {base_filename + "_a.parquet",
          base_filename + "_b.parquet",
          base_filename + "_c.parquet",
          base_filename + "_d.parquet"};
}

void input_limit_test_write_one(std::string const& filepath,
                                cudf::table_view const& t,
                                cudf::io::compression_type compression,
                                cudf::io::dictionary_policy dict_policy)
{
  cudf::io::parquet_writer_options out_opts =
    cudf::io::parquet_writer_options::builder(cudf::io::sink_info{filepath}, t)
      .compression(compression)
      .dictionary_policy(dict_policy);
  cudf::io::write_parquet(out_opts);
}

void input_limit_test_write(std::vector<std::string> const& test_filenames,
                            cudf::table_view const& t)
{
  CUDF_EXPECTS(test_filenames.size() == 4, "Unexpected count of test filenames");
  CUDF_EXPECTS(test_filenames.size() == input_limit_expected_file_count,
               "Unexpected count of test filenames");

  // no compression
  input_limit_test_write_one(
    test_filenames[0], t, cudf::io::compression_type::NONE, cudf::io::dictionary_policy::NEVER);
  // compression with a codec that uses a lot of scratch space at decode time (2.5x the total
  // decompressed buffer size)
  input_limit_test_write_one(
    test_filenames[1], t, cudf::io::compression_type::ZSTD, cudf::io::dictionary_policy::NEVER);
  // compression with a codec that uses no scratch space at decode time
  input_limit_test_write_one(
    test_filenames[2], t, cudf::io::compression_type::SNAPPY, cudf::io::dictionary_policy::NEVER);
  input_limit_test_write_one(
    test_filenames[3], t, cudf::io::compression_type::SNAPPY, cudf::io::dictionary_policy::ALWAYS);
}

void input_limit_test_read(std::vector<std::string> const& test_filenames,
                           cudf::table_view const& t,
                           size_t output_limit,
                           size_t input_limit,
                           int const expected_chunk_counts[input_limit_expected_file_count])
{
  CUDF_EXPECTS(test_filenames.size() == input_limit_expected_file_count,
               "Unexpected count of test filenames");

  for (size_t idx = 0; idx < test_filenames.size(); idx++) {
    auto result = chunked_read(test_filenames[idx], output_limit, input_limit);
    // CUDF_EXPECTS(result.second == expected_chunk_counts[idx],
    //            "Unexpected number of chunks produced in chunk read");
    CUDF_TEST_EXPECT_TABLES_EQUIVALENT(*result.first, t);
  }
}
}  // namespace

struct ParquetChunkedReaderInputLimitConstrainedTest : public cudf::test::BaseFixture {};

TEST_F(ParquetChunkedReaderInputLimitConstrainedTest, SingleFixedWidthColumn)
{
  auto base_path      = temp_env->get_temp_filepath("single_col_fixed_width");
  auto test_filenames = input_limit_get_test_names(base_path);

  constexpr auto num_rows = 1'000'000;
  auto iter1              = thrust::make_constant_iterator(15);
  cudf::test::fixed_width_column_wrapper<double> col1(iter1, iter1 + num_rows);
  auto tbl = cudf::table_view{{col1}};

  input_limit_test_write(test_filenames, tbl);

  // semi-reasonable limit
  constexpr int expected_a[] = {1, 25, 5, 1};
  input_limit_test_read(test_filenames, tbl, 0, 2 * 1024 * 1024, expected_a);
  // an unreasonable limit
  constexpr int expected_b[] = {1, 50, 50, 1};
  input_limit_test_read(test_filenames, tbl, 0, 1, expected_b);
}

TEST_F(ParquetChunkedReaderInputLimitConstrainedTest, MixedColumns)
{
  auto base_path      = temp_env->get_temp_filepath("mixed_columns");
  auto test_filenames = input_limit_get_test_names(base_path);

  constexpr auto num_rows = 1'000'000;

  auto iter1 = thrust::make_counting_iterator<int>(0);
  cudf::test::fixed_width_column_wrapper<int> col1(iter1, iter1 + num_rows);

  auto iter2 = thrust::make_counting_iterator<double>(0);
  cudf::test::fixed_width_column_wrapper<double> col2(iter2, iter2 + num_rows);

  auto const strings  = std::vector<std::string>{"abc", "de", "fghi"};
  auto const str_iter = cudf::detail::make_counting_transform_iterator(0, [&](int32_t i) {
    if (i < 250000) { return strings[0]; }
    if (i < 750000) { return strings[1]; }
    return strings[2];
  });
  auto col3           = strings_col(str_iter, str_iter + num_rows);

  auto tbl = cudf::table_view{{col1, col2, col3}};

  input_limit_test_write(test_filenames, tbl);

  constexpr int expected_a[] = {1, 50, 13, 7};
  input_limit_test_read(test_filenames, tbl, 0, 2 * 1024 * 1024, expected_a);
  constexpr int expected_b[] = {1, 50, 50, 50};
  input_limit_test_read(test_filenames, tbl, 0, 1, expected_b);
}

struct ParquetChunkedReaderInputLimitTest : public cudf::test::BaseFixture {};

namespace {
struct offset_gen {
  int const group_size;
  __device__ int operator()(int i) { return i * group_size; }
};

template <typename T>
struct value_gen {
  __device__ T operator()(int i) { return i % 1024; }
};

struct bool_gen {
  __device__ bool operator()(int i) { return i % 2 == 0; }
};

}  // namespace

TEST_F(ParquetChunkedReaderInputLimitTest, List)
{
  auto base_path      = temp_env->get_temp_filepath("list");
  auto test_filenames = input_limit_get_test_names(base_path);

  constexpr int num_rows  = 10'000'000;
  constexpr int list_size = 4;

  auto const stream = cudf::get_default_stream();

  auto offset_iter = cudf::detail::make_counting_transform_iterator(0, offset_gen{list_size});
  auto offset_col  = cudf::make_fixed_width_column(
    cudf::data_type{cudf::type_id::INT32}, num_rows + 1, cudf::mask_state::UNALLOCATED);
  thrust::copy(rmm::exec_policy(stream),
               offset_iter,
               offset_iter + num_rows + 1,
               offset_col->mutable_view().begin<int>());

  // list<int>
  constexpr int num_ints = num_rows * list_size;
  auto value_iter        = cudf::detail::make_counting_transform_iterator(0, value_gen<int>{});
  auto value_col         = cudf::make_fixed_width_column(
    cudf::data_type{cudf::type_id::INT32}, num_ints, cudf::mask_state::UNALLOCATED);
  thrust::copy(rmm::exec_policy(stream),
               value_iter,
               value_iter + num_ints,
               value_col->mutable_view().begin<int>());
  auto col1 =
    cudf::make_lists_column(num_rows,
                            std::move(offset_col),
                            std::move(value_col),
                            0,
                            cudf::create_null_mask(num_rows, cudf::mask_state::UNALLOCATED),
                            stream);

  auto tbl = cudf::table_view{{*col1}};

  input_limit_test_write(test_filenames, tbl);

  // even though we have a very large limit here, there are two cases where we actually produce
  // splits.
  // - uncompressed data (with no dict). This happens because the code has to make a guess at how
  // much
  //   space to reserve for compressed/uncompressed data prior to reading. It does not know that
  //   everything it will be reading in this case is uncompressed already, so this guess ends up
  //   causing it to generate two top level passes. in practice, this shouldn't matter because we
  //   never really see uncompressed data in the wild.
  //
  // - ZSTD (with no dict). In this case, ZSTD simple requires a huge amount of temporary
  // space: 2.5x the total
  //   size of the decompressed data. so 2 GB is actually not enough to hold the whole thing at
  //   once.
  //
  // Note that in the dictionary cases, both of these revert down to 1 chunk because the
  // dictionaries dramatically shrink the size of the uncompressed data.
  constexpr int expected_a[] = {3, 3, 1, 1};
  input_limit_test_read(test_filenames, tbl, 0, 256 * 1024 * 1024, expected_a);
  // smaller limit
  constexpr int expected_b[] = {5, 5, 2, 1};
  input_limit_test_read(test_filenames, tbl, 0, 128 * 1024 * 1024, expected_b);
  // include output chunking as well
  constexpr int expected_c[] = {10, 9, 8, 7};
  input_limit_test_read(test_filenames, tbl, 32 * 1024 * 1024, 64 * 1024 * 1024, expected_c);
}

namespace {
void tiny_list_rowgroup_test(bool just_list_col)
{
  auto iter = thrust::make_counting_iterator(0);

  // test a specific edge case:  a list column composed of multiple row groups, where each row
  // group contains a single, relatively small row.
  std::vector<int> row_sizes{12, 7, 16, 20, 10, 3, 15};
  std::vector<std::unique_ptr<cudf::table>> row_groups;
  for (size_t idx = 0; idx < row_sizes.size(); idx++) {
    std::vector<std::unique_ptr<cudf::column>> cols;

    // add a column before the list
    if (!just_list_col) {
      cudf::test::fixed_width_column_wrapper<int> int_col({idx});
      cols.push_back(int_col.release());
    }

    // write out the single-row list column as it's own file
    cudf::test::fixed_width_column_wrapper<int> values(iter, iter + row_sizes[idx]);
    cudf::test::fixed_width_column_wrapper<int> offsets({0, row_sizes[idx]});
    cols.push_back(cudf::make_lists_column(1, offsets.release(), values.release(), 0, {}));

    // add a column after the list
    if (!just_list_col) {
      cudf::test::fixed_width_column_wrapper<float> float_col({idx});
      cols.push_back(float_col.release());
    }

    auto tbl = std::make_unique<cudf::table>(std::move(cols));

    auto filepath = temp_env->get_temp_filepath("Tlrg" + std::to_string(idx));
    auto const write_opts =
      cudf::io::parquet_writer_options::builder(cudf::io::sink_info{filepath}, *tbl).build();
    cudf::io::write_parquet(write_opts);

    // store off the table
    row_groups.push_back(std::move(tbl));
  }

  // build expected
  std::vector<cudf::table_view> views;
  std::transform(row_groups.begin(),
                 row_groups.end(),
                 std::back_inserter(views),
                 [](std::unique_ptr<cudf::table> const& tbl) { return tbl->view(); });
  auto expected = cudf::concatenate(views);

  // load the individual files all at once
  std::vector<std::string> source_files;
  std::transform(iter, iter + row_groups.size(), std::back_inserter(source_files), [](int i) {
    return temp_env->get_temp_filepath("Tlrg" + std::to_string(i));
  });
  auto result =
    chunked_read(source_files, size_t{2} * 1024 * 1024 * 1024, size_t{2} * 1024 * 1024 * 1024);

  CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *(result.first));
}
}  // namespace

TEST_F(ParquetChunkedReaderInputLimitTest, TinyListRowGroupsSingle)
{
  // test with just a single list column
  tiny_list_rowgroup_test(true);
}

TEST_F(ParquetChunkedReaderInputLimitTest, TinyListRowGroupsMixed)
{
  // test with other columns mixed in
  tiny_list_rowgroup_test(false);
}

namespace {
struct char_values {
  __device__ int8_t operator()(int i)
  {
    int const index = (i / 2) % 3;
    // generate repeating 3-runs of 2 values each. aabbcc
    return index == 0 ? 'a' : (index == 1 ? 'b' : 'c');
  }
};
}  // namespace

TEST_F(ParquetChunkedReaderInputLimitTest, Mixed)
{
  auto base_path      = temp_env->get_temp_filepath("mixed_types");
  auto test_filenames = input_limit_get_test_names(base_path);

  constexpr int num_rows  = 10'000'000;
  constexpr int list_size = 4;
  constexpr int str_size  = 3;

  auto const stream = cudf::get_default_stream();

  auto offset_iter = cudf::detail::make_counting_transform_iterator(0, offset_gen{list_size});
  auto offset_col  = cudf::make_fixed_width_column(
    cudf::data_type{cudf::type_id::INT32}, num_rows + 1, cudf::mask_state::UNALLOCATED);
  thrust::copy(rmm::exec_policy(stream),
               offset_iter,
               offset_iter + num_rows + 1,
               offset_col->mutable_view().begin<int>());

  // list<int>
  constexpr int num_ints = num_rows * list_size;
  auto value_iter        = cudf::detail::make_counting_transform_iterator(0, value_gen<int>{});
  auto value_col         = cudf::make_fixed_width_column(
    cudf::data_type{cudf::type_id::INT32}, num_ints, cudf::mask_state::UNALLOCATED);
  thrust::copy(rmm::exec_policy(stream),
               value_iter,
               value_iter + num_ints,
               value_col->mutable_view().begin<int>());
  auto col1 =
    cudf::make_lists_column(num_rows,
                            std::move(offset_col),
                            std::move(value_col),
                            0,
                            cudf::create_null_mask(num_rows, cudf::mask_state::UNALLOCATED),
                            stream);

  // strings
  constexpr int num_chars = num_rows * str_size;
  auto str_offset_iter    = cudf::detail::make_counting_transform_iterator(0, offset_gen{str_size});
  auto str_offset_col     = cudf::make_fixed_width_column(
    cudf::data_type{cudf::type_id::INT32}, num_rows + 1, cudf::mask_state::UNALLOCATED);
  thrust::copy(rmm::exec_policy(stream),
               str_offset_iter,
               str_offset_iter + num_rows + 1,
               str_offset_col->mutable_view().begin<int>());
  auto str_iter = cudf::detail::make_counting_transform_iterator(0, char_values{});
  rmm::device_buffer str_chars(num_chars, stream);
  thrust::copy(rmm::exec_policy(stream),
               str_iter,
               str_iter + num_chars,
               static_cast<int8_t*>(str_chars.data()));
  auto col2 =
    cudf::make_strings_column(num_rows,
                              std::move(str_offset_col),
                              std::move(str_chars),
                              0,
                              cudf::create_null_mask(num_rows, cudf::mask_state::UNALLOCATED));

  // doubles
  auto double_iter = cudf::detail::make_counting_transform_iterator(0, value_gen<double>{});
  auto col3        = cudf::make_fixed_width_column(
    cudf::data_type{cudf::type_id::FLOAT64}, num_rows, cudf::mask_state::UNALLOCATED);
  thrust::copy(rmm::exec_policy(stream),
               double_iter,
               double_iter + num_rows,
               col3->mutable_view().begin<double>());

  auto tbl = cudf::table_view{{*col1, *col2, *col3}};

  input_limit_test_write(test_filenames, tbl);

  // even though we have a very large limit here, there are two cases where we actually produce
  // splits.
  // - uncompressed data (with no dict). This happens because the code has to make a guess at how
  // much
  //   space to reserve for compressed/uncompressed data prior to reading. It does not know that
  //   everything it will be reading in this case is uncompressed already, so this guess ends up
  //   causing it to generate two top level passes. in practice, this shouldn't matter because we
  //   never really see uncompressed data in the wild.
  //
  // - ZSTD (with no dict). In this case, ZSTD simple requires a huge amount of temporary
  // space: 2.5x the total
  //   size of the decompressed data. so 2 GB is actually not enough to hold the whole thing at
  //   once.
  //
  // Note that in the dictionary cases, both of these revert down to 1 chunk because the
  // dictionaries dramatically shrink the size of the uncompressed data.
  constexpr int expected_a[] = {5, 5, 2, 1};
  input_limit_test_read(test_filenames, tbl, 0, 256 * 1024 * 1024, expected_a);
  // smaller limit
  constexpr int expected_b[] = {10, 9, 3, 1};
  input_limit_test_read(test_filenames, tbl, 0, 128 * 1024 * 1024, expected_b);
  // include output chunking as well
  constexpr int expected_c[] = {20, 18, 15, 12};
  input_limit_test_read(test_filenames, tbl, 32 * 1024 * 1024, 64 * 1024 * 1024, expected_c);
}

TEST_F(ParquetChunkedReaderTest, TestChunkedReadOutOfBoundChunks)
{
  auto const generate_input = [](int num_rows, bool nullable) {
    std::vector<std::unique_ptr<cudf::column>> input_columns;
    auto const value_iter = thrust::make_counting_iterator(0);
    input_columns.emplace_back(int32s_col(value_iter, value_iter + num_rows).release());
    input_columns.emplace_back(int64s_col(value_iter, value_iter + num_rows).release());

    auto filename = "chunked_out_of_bounds_" + std::to_string(num_rows);

    return write_file(input_columns, filename, nullable, false);
  };

  auto const read_chunks_with_while_loop = [](cudf::io::chunked_parquet_reader const& reader) {
    auto out_tables = std::vector<std::unique_ptr<cudf::table>>{};
    int num_chunks  = 0;
    // should always be true
    EXPECT_EQ(reader.has_next(), true);
    while (reader.has_next()) {
      out_tables.emplace_back(reader.read_chunk().tbl);
      num_chunks++;
    }
    auto out_tviews = std::vector<cudf::table_view>{};
    for (auto const& tbl : out_tables) {
      out_tviews.emplace_back(tbl->view());
    }

    return std::pair(cudf::concatenate(out_tviews), num_chunks);
  };

  // empty table to compare with the out of bound chunks
  auto const empty_table = generate_input(0, false).first;

  {
    auto constexpr num_rows          = 0;
    auto const [expected, filepath]  = generate_input(num_rows, false);
    auto constexpr output_read_limit = 1'000;
    auto const options =
      cudf::io::parquet_reader_options_builder(cudf::io::source_info{filepath}).build();
    auto const reader =
      cudf::io::chunked_parquet_reader(output_read_limit, 0, options, cudf::get_default_stream());
    auto const [result, num_chunks]     = read_chunks_with_while_loop(reader);
    auto const out_of_bound_table_chunk = reader.read_chunk().tbl;

    EXPECT_EQ(num_chunks, 1);
    EXPECT_EQ(reader.has_next(), false);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*out_of_bound_table_chunk, *empty_table);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  {
    auto constexpr num_rows          = 40'000;
    auto constexpr output_read_limit = 240'000;
    auto const [expected, filepath]  = generate_input(num_rows, false);
    auto const options =
      cudf::io::parquet_reader_options_builder(cudf::io::source_info{filepath}).build();
    auto const reader =
      cudf::io::chunked_parquet_reader(output_read_limit, 0, options, cudf::get_default_stream());
    auto const [result, num_chunks]     = read_chunks_with_while_loop(reader);
    auto const out_of_bound_table_chunk = reader.read_chunk().tbl;

    // EXPECT_EQ(num_chunks, 2);
    EXPECT_EQ(reader.has_next(), false);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*out_of_bound_table_chunk, *empty_table);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }
}

TEST_F(ParquetChunkedReaderTest, TestNumRowsPerSource)
{
  constexpr int num_rows          = 10'723;  // A prime number
  constexpr int rows_in_row_group = 500;

  // Table with single col of random int64 values
  auto const int64_data = random_values<int64_t>(num_rows);
  auto int64_col        = int64s_col(int64_data.begin(), int64_data.end()).release();

  std::vector<std::unique_ptr<cudf::column>> input_columns;
  input_columns.emplace_back(std::move(int64_col));

  // Write to Parquet
  auto const [expected, filepath] = write_file(input_columns,
                                               "num_rows_per_source",
                                               false,
                                               false,
                                               cudf::io::default_max_page_size_bytes,
                                               rows_in_row_group);

  // Chunked-read single data source skipping all rows
  {
    auto const rows_to_skip          = num_rows + 1;
    auto constexpr output_read_limit = 1'500;
    auto constexpr pass_read_limit   = 3'500;

    auto const options = cudf::io::parquet_reader_options_builder(cudf::io::source_info{filepath})
                           .skip_rows(rows_to_skip)
                           .build();
    auto const reader = cudf::io::chunked_parquet_reader(
      output_read_limit, pass_read_limit, options, cudf::get_default_stream());

    auto const [result, num_chunks, num_rows_per_source] = read_table_and_nrows_per_source(reader);

    auto int64_col_selected = int64s_col(int64_data.begin(), int64_data.begin()).release();
    cudf::table_view const expected_selected({int64_col_selected->view()});

    // Should read an empty table
    CUDF_TEST_EXPECT_TABLES_EQUAL(expected_selected, result->view());
    EXPECT_EQ(num_chunks, 1);
    EXPECT_EQ(num_rows_per_source.size(), 1);
    EXPECT_EQ(num_rows_per_source[0], 0);
  }

  // Chunked-read single data source entirely
  {
    auto constexpr output_read_limit = 1'500;
    auto constexpr pass_read_limit   = 3'500;

    auto const options =
      cudf::io::parquet_reader_options_builder(cudf::io::source_info{filepath}).build();
    auto const reader = cudf::io::chunked_parquet_reader(
      output_read_limit, pass_read_limit, options, cudf::get_default_stream());

    auto const [result, num_chunks, num_rows_per_source] = read_table_and_nrows_per_source(reader);

    CUDF_TEST_EXPECT_TABLES_EQUAL(expected->view(), result->view());
    EXPECT_EQ(num_rows_per_source.size(), 1);
    EXPECT_EQ(num_rows_per_source[0], num_rows);
  }

  // Chunked-read rows_to_read rows skipping rows_to_skip from single data source
  {
    auto const rows_to_skip          = 1'237;
    auto const rows_to_read          = 7'232;
    auto constexpr output_read_limit = 1'500;
    auto constexpr pass_read_limit   = 3'500;

    auto const options = cudf::io::parquet_reader_options_builder(cudf::io::source_info{filepath})
                           .skip_rows(rows_to_skip)
                           .num_rows(rows_to_read)
                           .build();
    auto const reader = cudf::io::chunked_parquet_reader(
      output_read_limit, pass_read_limit, options, cudf::get_default_stream());

    auto const [result, num_chunks, num_rows_per_source] = read_table_and_nrows_per_source(reader);

    auto int64_col_selected = int64s_col(int64_data.begin() + rows_to_skip,
                                         int64_data.begin() + rows_to_skip + rows_to_read)
                                .release();

    cudf::table_view const expected_selected({int64_col_selected->view()});

    CUDF_TEST_EXPECT_TABLES_EQUAL(expected_selected, result->view());
    EXPECT_EQ(num_rows_per_source.size(), 1);
    EXPECT_EQ(num_rows_per_source[0], rows_to_read);
  }

  // Chunked-read two data sources skipping the first entire file completely
  {
    auto constexpr rows_to_skip      = 15'723;
    auto constexpr output_read_limit = 1'024'000;
    auto constexpr pass_read_limit   = 1'024'000;

    auto constexpr nsources = 2;
    std::vector<std::string> const datasources(nsources, filepath);

    auto const options =
      cudf::io::parquet_reader_options_builder(cudf::io::source_info{datasources})
        .skip_rows(rows_to_skip)
        .build();

    auto const reader = cudf::io::chunked_parquet_reader(
      output_read_limit, pass_read_limit, options, cudf::get_default_stream());

    auto const [result, num_chunks, num_rows_per_source] = read_table_and_nrows_per_source(reader);

    auto int64_col_selected =
      int64s_col(int64_data.begin() + rows_to_skip - num_rows, int64_data.end()).release();

    cudf::table_view const expected_selected({int64_col_selected->view()});

    CUDF_TEST_EXPECT_TABLES_EQUAL(expected_selected, result->view());

    EXPECT_EQ(num_rows_per_source.size(), 2);
    EXPECT_EQ(num_rows_per_source[0], 0);
    EXPECT_EQ(num_rows_per_source[1], nsources * num_rows - rows_to_skip);
  }

  // Chunked-read from single data source skipping rows_to_skip
  {
    auto const rows_to_skip          = 1'237;
    auto constexpr output_read_limit = 1'500;
    auto constexpr pass_read_limit   = 1'800;

    auto const options = cudf::io::parquet_reader_options_builder(cudf::io::source_info{filepath})
                           .skip_rows(rows_to_skip)
                           .build();
    auto const reader = cudf::io::chunked_parquet_reader(
      output_read_limit, pass_read_limit, options, cudf::get_default_stream());

    auto const [result, num_chunks, num_rows_per_source] = read_table_and_nrows_per_source(reader);

    auto int64_col_selected =
      int64s_col(int64_data.begin() + rows_to_skip, int64_data.end()).release();

    cudf::table_view const expected_selected({int64_col_selected->view()});

    CUDF_TEST_EXPECT_TABLES_EQUAL(expected_selected, result->view());
    EXPECT_EQ(num_rows_per_source.size(), 1);
    EXPECT_EQ(num_rows_per_source[0], num_rows - rows_to_skip);
  }

  // Filtered chunked-read from single data source
  {
    int64_t const max_value          = int64_data[int64_data.size() / 2];
    auto constexpr output_read_limit = 1'500;
    auto constexpr pass_read_limit   = 3'500;
    auto literal_value               = cudf::numeric_scalar<int64_t>{max_value};
    auto literal                     = cudf::ast::literal{literal_value};
    auto col_ref                     = cudf::ast::column_reference(0);
    auto filter_expression =
      cudf::ast::operation(cudf::ast::ast_operator::LESS_EQUAL, col_ref, literal);

    auto const options = cudf::io::parquet_reader_options_builder(cudf::io::source_info{filepath})
                           .filter(filter_expression)
                           .build();
    auto const reader = cudf::io::chunked_parquet_reader(
      output_read_limit, pass_read_limit, options, cudf::get_default_stream());

    auto const [result, num_chunks, num_rows_per_source] = read_table_and_nrows_per_source(reader);

    std::vector<int64_t> int64_data_filtered;
    int64_data_filtered.reserve(num_rows);
    std::copy_if(
      int64_data.begin(), int64_data.end(), std::back_inserter(int64_data_filtered), [=](auto val) {
        return val <= max_value;
      });

    auto int64_col_filtered =
      int64s_col(int64_data_filtered.begin(), int64_data_filtered.end()).release();

    cudf::table_view expected_filtered({int64_col_filtered->view()});

    CUDF_TEST_EXPECT_TABLES_EQUAL(expected_filtered, result->view());
    EXPECT_TRUE(num_rows_per_source.empty());
  }
}

TEST_F(ParquetChunkedReaderTest, TestNumRowsPerSourceMultipleSources)
{
  constexpr int num_rows          = 10'723;  // A prime number
  constexpr int rows_in_row_group = 500;

  // Table with single col of random int64 values
  auto const int64_data = random_values<int64_t>(num_rows);
  auto int64_col        = int64s_col(int64_data.begin(), int64_data.end()).release();

  std::vector<std::unique_ptr<cudf::column>> input_columns;
  input_columns.emplace_back(std::move(int64_col));

  // Write to Parquet
  auto const [expected, filepath] = write_file(input_columns,
                                               "num_rows_per_source",
                                               false,
                                               false,
                                               cudf::io::default_max_page_size_bytes,
                                               rows_in_row_group);

  // Function to initialize a vector of expected counts per source
  auto initialize_expected_counts =
    [](int const nsources, int const num_rows, int const rows_to_skip, int const rows_to_read) {
      // Initialize expected_counts
      std::vector<size_t> expected_counts(nsources, num_rows);

      // Adjust expected_counts for rows_to_skip
      int64_t counter = 0;
      for (auto& nrows : expected_counts) {
        if (counter < rows_to_skip) {
          counter += nrows;
          nrows = (counter >= rows_to_skip) ? counter - rows_to_skip : 0;
        } else {
          break;
        }
      }

      // Reset the counter
      counter = 0;

      // Adjust expected_counts for rows_to_read
      for (auto& nrows : expected_counts) {
        if (counter < rows_to_read) {
          counter += nrows;
          nrows = (counter >= rows_to_read) ? rows_to_read - counter + nrows : nrows;
        } else if (counter > rows_to_read) {
          nrows = 0;
        }
      }

      return expected_counts;
    };

  // Chunked-read six data sources entirely
  {
    auto const nsources              = 6;
    auto constexpr output_read_limit = 15'000;
    auto constexpr pass_read_limit   = 35'000;
    std::vector<std::string> const datasources(nsources, filepath);

    auto const options =
      cudf::io::parquet_reader_options_builder(cudf::io::source_info{datasources}).build();
    auto const reader = cudf::io::chunked_parquet_reader(
      output_read_limit, pass_read_limit, options, cudf::get_default_stream());

    auto const [result, num_chunks, num_rows_per_source] = read_table_and_nrows_per_source(reader);

    // Initialize expected_counts
    std::vector<size_t> const expected_counts(nsources, num_rows);

    EXPECT_EQ(num_rows_per_source.size(), nsources);
    EXPECT_TRUE(
      std::equal(expected_counts.cbegin(), expected_counts.cend(), num_rows_per_source.cbegin()));
  }

  // Chunked-read rows_to_read rows skipping rows_to_skip from eight data sources
  {
    auto const rows_to_skip          = 25'571;
    auto const rows_to_read          = 11'232;
    auto constexpr output_read_limit = 15'000;
    auto constexpr pass_read_limit   = 35'000;
    auto const nsources              = 8;
    std::vector<int64_t> int64_selected_data{};
    int64_selected_data.reserve(nsources * num_rows);

    std::for_each(
      thrust::make_counting_iterator(0),
      thrust::make_counting_iterator(nsources),
      [&](auto const i) {
        std::copy(int64_data.begin(), int64_data.end(), std::back_inserter(int64_selected_data));
      });

    std::vector<std::string> const datasources(nsources, filepath);

    auto const options =
      cudf::io::parquet_reader_options_builder(cudf::io::source_info{datasources})
        .skip_rows(rows_to_skip)
        .num_rows(rows_to_read)
        .build();
    auto const reader = cudf::io::chunked_parquet_reader(
      output_read_limit, pass_read_limit, options, cudf::get_default_stream());

    auto const [result, num_chunks, num_rows_per_source] = read_table_and_nrows_per_source(reader);

    // Initialize expected_counts
    auto const expected_counts =
      initialize_expected_counts(nsources, num_rows, rows_to_skip, rows_to_read);

    // Initialize expected table
    auto int64_col_selected = int64s_col(int64_selected_data.begin() + rows_to_skip,
                                         int64_selected_data.begin() + +rows_to_skip + rows_to_read)
                                .release();

    cudf::table_view const expected_selected({int64_col_selected->view()});

    CUDF_TEST_EXPECT_TABLES_EQUAL(expected_selected, result->view());
    EXPECT_EQ(num_rows_per_source.size(), nsources);
    EXPECT_TRUE(
      std::equal(expected_counts.cbegin(), expected_counts.cend(), num_rows_per_source.cbegin()));
  }

  // Chunked-read four data sources skipping three files completely
  {
    auto const nsources              = 4;
    int constexpr rows_to_skip       = num_rows * 3 + 1;
    auto constexpr output_read_limit = 15'000;
    auto constexpr pass_read_limit   = 35'000;
    std::vector<int64_t> int64_selected_data{};
    int64_selected_data.reserve(nsources * num_rows);

    std::for_each(
      thrust::make_counting_iterator(0),
      thrust::make_counting_iterator(nsources),
      [&](auto const i) {
        std::copy(int64_data.begin(), int64_data.end(), std::back_inserter(int64_selected_data));
      });

    std::vector<std::string> const datasources(nsources, filepath);
    auto const options =
      cudf::io::parquet_reader_options_builder(cudf::io::source_info{datasources})
        .skip_rows(rows_to_skip)
        .build();
    auto const reader = cudf::io::chunked_parquet_reader(
      output_read_limit, pass_read_limit, options, cudf::get_default_stream());

    auto const [result, num_chunks, num_rows_per_source] = read_table_and_nrows_per_source(reader);

    // Initialize expected_counts
    auto const expected_counts =
      initialize_expected_counts(nsources, num_rows, rows_to_skip, num_rows * nsources);

    // Initialize expected table
    auto int64_col_selected =
      int64s_col(int64_selected_data.begin() + rows_to_skip, int64_selected_data.end()).release();

    cudf::table_view const expected_selected({int64_col_selected->view()});

    CUDF_TEST_EXPECT_TABLES_EQUAL(expected_selected, result->view());
    EXPECT_EQ(num_rows_per_source.size(), nsources);
    EXPECT_TRUE(
      std::equal(expected_counts.cbegin(), expected_counts.cend(), num_rows_per_source.cbegin()));
  }
}

TEST_F(ParquetChunkedReaderTest, TestNumRowsPerSourceEmptyTable)
{
  auto constexpr output_read_limit = 4'500;
  auto constexpr pass_read_limit   = 8'500;
  auto const nsources              = 10;

  // Table with single col of random int64 values
  auto int64_empty_col = int64s_col{}.release();

  std::vector<std::unique_ptr<cudf::column>> input_empty_columns;
  input_empty_columns.emplace_back(std::move(int64_empty_col));

  // Write to Parquet
  auto const [expected_empty, filepath_empty] = write_file(input_empty_columns,
                                                           "num_rows_per_source_empty",
                                                           false,
                                                           false,
                                                           cudf::io::default_max_page_size_bytes,
                                                           500);

  std::vector<std::string> const datasources(nsources, filepath_empty);

  auto const options =
    cudf::io::parquet_reader_options_builder(cudf::io::source_info{datasources}).build();
  auto const reader = cudf::io::chunked_parquet_reader(
    output_read_limit, pass_read_limit, options, cudf::get_default_stream());

  auto const [result, num_chunks, num_rows_per_source] = read_table_and_nrows_per_source(reader);

  // Initialize expected_counts
  std::vector<size_t> const expected_counts(nsources, 0);

  CUDF_TEST_EXPECT_TABLES_EQUAL(expected_empty->view(), result->view());

  EXPECT_EQ(num_chunks, 1);
  EXPECT_EQ(num_rows_per_source.size(), nsources);
  EXPECT_TRUE(
    std::equal(expected_counts.cbegin(), expected_counts.cend(), num_rows_per_source.cbegin()));
}

TEST_F(ParquetReaderTest, ManyLargeLists)
{
  auto const stream = cudf::get_default_stream();

  // Generate a large list<bool> column
  constexpr cudf::size_type num_rows      = 10'000'000;
  constexpr cudf::size_type bools_per_row = 2;
  auto offsets_iter = cudf::detail::make_counting_transform_iterator(0, offset_gen{bools_per_row});
  auto offsets_col  = cudf::make_fixed_width_column(
    cudf::data_type{cudf::type_id::INT32}, num_rows + 1, cudf::mask_state::UNALLOCATED);
  thrust::copy(rmm::exec_policy_nosync(stream),
               offsets_iter,
               offsets_iter + num_rows + 1,
               offsets_col->mutable_view().begin<int>());

  auto bools_iter = cudf::detail::make_counting_transform_iterator(0, bool_gen{});
  auto bools_col  = cudf::make_fixed_width_column(
    cudf::data_type{cudf::type_id::BOOL8}, num_rows * bools_per_row, cudf::mask_state::UNALLOCATED);
  thrust::copy(rmm::exec_policy_nosync(stream),
               bools_iter,
               bools_iter + (num_rows * bools_per_row),
               bools_col->mutable_view().begin<bool>());

  stream.synchronize();

  auto list_col = cudf::make_lists_column(
    num_rows, std::move(offsets_col), std::move(bools_col), 0, rmm::device_buffer{});

  auto const table    = cudf::table_view({*list_col});
  auto const filepath = temp_env->get_temp_filepath("ManyLargeLists.parquet");
  auto const out_opts =
    cudf::io::parquet_writer_options::builder(cudf::io::sink_info{filepath}, table).build();
  // Write the table to parquet
  cudf::io::write_parquet(out_opts);

  // Times to concat filepath to overflow cudf column size limits
  constexpr cudf::size_type reads_to_overflow =
    (std::numeric_limits<cudf::size_type>::max() / (num_rows * bools_per_row)) + 1;

  auto const in_opts =
    cudf::io::parquet_reader_options::builder(
      cudf::io::source_info{std::vector<std::string>(reads_to_overflow, filepath)})
      .build();

  // Expect an overflow error when reading the files
  EXPECT_THROW(cudf::io::read_parquet(in_opts), std::overflow_error);
}

TEST_P(ParquetChunkedDecompressionTest, RoundTripBasic)
{
  auto const compression_type = std::get<1>(GetParam());

  srand(31337);
  auto expected = create_compressible_fixed_table<int>(4, 23456, 3, true);

  auto const filepath = temp_env->get_temp_filepath("chunked_decompression");
  cudf::io::parquet_writer_options args =
    cudf::io::parquet_writer_options::builder(cudf::io::sink_info{filepath}, *expected)
      .compression(compression_type)
      .row_group_size_rows(2000);
  cudf::io::write_parquet(args);

  {
    auto const [result, num_chunks] = chunked_read(filepath, 0, 2'400'000);
    EXPECT_EQ(num_chunks, 1);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath, 0, 240'000);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }

  {
    auto const [result, num_chunks] = chunked_read(filepath, 0, 24'000);
    CUDF_TEST_EXPECT_TABLES_EQUAL(*expected, *result);
  }
}

INSTANTIATE_TEST_CASE_P(Nvcomp,
                        ParquetChunkedDecompressionTest,
                        ::testing::Combine(::testing::Values("NVCOMP"),
                                           ::testing::Values(cudf::io::compression_type::AUTO,
                                                             cudf::io::compression_type::SNAPPY,
                                                             cudf::io::compression_type::LZ4,
                                                             cudf::io::compression_type::ZSTD)));

INSTANTIATE_TEST_CASE_P(DeviceInternal,
                        ParquetChunkedDecompressionTest,
                        ::testing::Combine(::testing::Values("DEVICE_INTERNAL"),
                                           ::testing::Values(cudf::io::compression_type::AUTO,
                                                             cudf::io::compression_type::SNAPPY)));

INSTANTIATE_TEST_CASE_P(Host,
                        ParquetChunkedDecompressionTest,
                        ::testing::Combine(::testing::Values("HOST"),
                                           ::testing::Values(cudf::io::compression_type::AUTO,
                                                             cudf::io::compression_type::SNAPPY,
                                                             cudf::io::compression_type::ZSTD)));
