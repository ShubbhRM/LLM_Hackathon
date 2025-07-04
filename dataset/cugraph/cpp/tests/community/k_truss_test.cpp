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
 * See the License for the specific language governin_from_mtxg permissions and
 * limitations under the License.
 */

#include "utilities/base_fixture.hpp"
#include "utilities/check_utilities.hpp"
#include "utilities/conversion_utilities.hpp"
#include "utilities/test_graphs.hpp"
#include "utilities/thrust_wrapper.hpp"

#include <cugraph/algorithms.hpp>
#include <cugraph/graph.hpp>
#include <cugraph/graph_functions.hpp>
#include <cugraph/graph_view.hpp>
#include <cugraph/utilities/high_res_timer.hpp>

#include <raft/core/handle.hpp>
#include <raft/util/cudart_utils.hpp>

#include <gtest/gtest.h>

#include <algorithm>
#include <iterator>
#include <limits>
#include <numeric>
#include <random>
#include <set>
#include <vector>

struct KTruss_Usecase {
  int32_t k_{3};
  bool test_weighted_{false};
  bool check_correctness_{true};
};

template <typename input_usecase_t>
class Tests_KTruss : public ::testing::TestWithParam<std::tuple<KTruss_Usecase, input_usecase_t>> {
 public:
  Tests_KTruss() {}

  static void SetUpTestCase() {}
  static void TearDownTestCase() {}

  virtual void SetUp() {}
  virtual void TearDown() {}

  // FIXME: There is an utility equivalent functor not
  // supporting host vectors.
  template <typename type_t>
  struct host_nearly_equal {
    const type_t threshold_ratio;
    const type_t threshold_magnitude;

    bool operator()(type_t lhs, type_t rhs) const
    {
      return std::abs(lhs - rhs) <
             std::max(std::max(lhs, rhs) * threshold_ratio, threshold_magnitude);
    }
  };

  template <typename vertex_t, typename edge_t, typename weight_t>
  std::tuple<std::vector<vertex_t>, std::vector<vertex_t>, std::optional<std::vector<weight_t>>>
  k_truss_reference(std::vector<vertex_t> h_offsets,
                    std::vector<vertex_t> h_indices,  // this assumes that h_indices are sorted in
                                                      // [h_offsets[i], h_offsets[i + 1])
                    std::optional<std::vector<weight_t>> h_values,
                    edge_t k)
  {
    auto constexpr invalid_vertex_id = cugraph::invalid_vertex_id_v<vertex_t>;

    auto n_dropped = 1;
    while (n_dropped > 0) {
      n_dropped = 0;
      std::vector<vertex_t> seen{};
      // Go over all the vertices.
      for (vertex_t u = 0; u < static_cast<vertex_t>(h_offsets.size() - 1); ++u) {
        std::vector<vertex_t> nbrs_u{};
        // Find all neighbors of u from the offsets and indices array
        for (auto i = h_offsets[u]; i < h_offsets[u + 1]; ++i) {
          auto nbr = h_indices[i];
          if ((nbr != invalid_vertex_id) && (nbr != u)) { nbrs_u.push_back(nbr); }
        }

        seen.push_back(u);
        std::vector<vertex_t> new_nbrs(nbrs_u.size());
        new_nbrs.resize(std::distance(
          new_nbrs.begin(),
          std::set_difference(
            nbrs_u.begin(), nbrs_u.end(), seen.begin(), seen.end(), new_nbrs.begin())));

        // Finding the neighbors of v
        for (size_t i = 0; i < new_nbrs.size(); ++i) {
          auto v = new_nbrs[i];
          std::vector<vertex_t> nbrs_v{};
          // Find all neighbors of v from the offsets and indices array
          for (auto i = h_offsets[v]; i < h_offsets[v + 1]; ++i) {
            auto nbr = h_indices[i];
            if ((nbr != invalid_vertex_id) && (nbr != v)) { nbrs_v.push_back(nbr); }
          }

          std::vector<vertex_t> nbr_intersection_u_v(std::min(nbrs_u.size(), nbrs_v.size()));
          // Find the intersection of nbr_u and nbr_v
          nbr_intersection_u_v.resize(
            std::distance(nbr_intersection_u_v.begin(),
                          std::set_intersection(nbrs_u.begin(),
                                                nbrs_u.end(),
                                                nbrs_v.begin(),
                                                nbrs_v.end(),
                                                nbr_intersection_u_v.begin())));

          if (nbr_intersection_u_v.size() < (k - 2)) {
            auto del_v =
              std::find(h_indices.begin() + h_offsets[u], h_indices.begin() + h_offsets[u + 1], v);
            *del_v = invalid_vertex_id;

            // Delete edge in both directions
            auto del_u =
              std::find(h_indices.begin() + h_offsets[v], h_indices.begin() + h_offsets[v + 1], u);
            *del_u = invalid_vertex_id;

            n_dropped += 1;
          }
        }
      }
    }

    std::vector<vertex_t> h_k_truss_srcs{};
    std::vector<vertex_t> h_k_truss_dsts{};
    auto h_k_truss_values = h_values ? std::make_optional(std::vector<weight_t>{}) : std::nullopt;

    for (vertex_t u = 0; u < static_cast<vertex_t>(h_offsets.size() - 1); ++u) {
      for (auto i = h_offsets[u]; i < h_offsets[u + 1]; ++i) {
        auto v = h_indices[i];
        if ((v != invalid_vertex_id) && (v != u)) {
          h_k_truss_srcs.push_back(u);
          h_k_truss_dsts.push_back(v);
          if (h_k_truss_values) { h_k_truss_values->push_back((*h_values)[i]); }
        }
      }
    }

    return std::make_tuple(
      std::move(h_k_truss_srcs), std::move(h_k_truss_dsts), std::move(h_k_truss_values));
  }

  template <typename vertex_t, typename edge_t, typename weight_t>
  void run_current_test(std::tuple<KTruss_Usecase const&, input_usecase_t const&> const& param)
  {
    constexpr bool renumber               = false;
    auto [k_truss_usecase, input_usecase] = param;
    raft::handle_t handle{};

    HighResTimer hr_timer{};

    if (cugraph::test::g_perf) {
      RAFT_CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement
      hr_timer.start("SG Construct graph");
    }

    auto [graph, edge_weight, d_renumber_map_labels] =
      cugraph::test::construct_graph<vertex_t, edge_t, weight_t, false, false>(
        handle, input_usecase, k_truss_usecase.test_weighted_, renumber, false, true);

    if (cugraph::test::g_perf) {
      RAFT_CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement
      hr_timer.stop();
      hr_timer.display_and_clear(std::cout);
    }

    auto graph_view = graph.view();

    if (cugraph::test::g_perf) {
      RAFT_CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement
      hr_timer.start("K-truss");
    }

    auto [d_cugraph_srcs, d_cugraph_dsts, d_cugraph_wgts] =
      cugraph::k_truss<vertex_t, edge_t, weight_t, false>(
        handle,
        graph_view,
        edge_weight ? std::make_optional((*edge_weight).view()) : std::nullopt,
        k_truss_usecase.k_,
        false);

    if (cugraph::test::g_perf) {
      RAFT_CUDA_TRY(cudaDeviceSynchronize());  // for consistent performance measurement
      hr_timer.stop();
      hr_timer.display_and_clear(std::cout);
    }

    if (k_truss_usecase.check_correctness_) {
      auto [h_offsets, h_indices, h_values] = cugraph::test::graph_to_host_csr(
        handle,
        graph_view,
        edge_weight ? std::make_optional((*edge_weight).view()) : std::nullopt,
        std::optional<raft::device_span<vertex_t const>>(std::nullopt));

      rmm::device_uvector<weight_t> d_sorted_cugraph_wgts{0, handle.get_stream()};
      rmm::device_uvector<vertex_t> d_sorted_cugraph_srcs{0, handle.get_stream()};
      rmm::device_uvector<vertex_t> d_sorted_cugraph_dsts{0, handle.get_stream()};

      if (edge_weight) {
        std::tie(d_sorted_cugraph_srcs, d_sorted_cugraph_dsts, d_sorted_cugraph_wgts) =
          cugraph::test::sort_by_key<vertex_t, weight_t>(
            handle, d_cugraph_srcs, d_cugraph_dsts, *d_cugraph_wgts);
      } else {
        std::tie(d_sorted_cugraph_srcs, d_sorted_cugraph_dsts) =
          cugraph::test::sort<vertex_t>(handle, d_cugraph_srcs, d_cugraph_dsts);
      }

      auto h_cugraph_srcs = cugraph::test::to_host(handle, d_sorted_cugraph_srcs);

      auto h_cugraph_dsts = cugraph::test::to_host(handle, d_sorted_cugraph_dsts);

      auto [h_reference_srcs, h_reference_dsts, h_reference_wgts] =
        k_truss_reference<vertex_t, edge_t, weight_t>(
          h_offsets, h_indices, h_values, k_truss_usecase.k_);

      EXPECT_EQ(h_cugraph_srcs.size(), h_reference_srcs.size());
      ASSERT_TRUE(
        std::equal(h_cugraph_srcs.begin(), h_cugraph_srcs.end(), h_reference_srcs.begin()));

      ASSERT_TRUE(
        std::equal(h_cugraph_dsts.begin(), h_cugraph_dsts.end(), h_reference_dsts.begin()));

      if (edge_weight) {
        auto h_cugraph_wgts  = cugraph::test::to_host(handle, d_sorted_cugraph_wgts);
        auto compare_functor = host_nearly_equal<weight_t>{
          weight_t{1e-3},
          weight_t{(weight_t{1} / static_cast<weight_t>((h_cugraph_wgts).size())) *
                   weight_t{1e-3}}};
        EXPECT_TRUE(std::equal((h_cugraph_wgts).begin(),
                               (h_cugraph_wgts).end(),
                               (*h_reference_wgts).begin(),
                               compare_functor));
      }
    }
  }
};

using Tests_KTruss_File = Tests_KTruss<cugraph::test::File_Usecase>;
using Tests_KTruss_Rmat = Tests_KTruss<cugraph::test::Rmat_Usecase>;

TEST_P(Tests_KTruss_File, CheckInt32Int32Float)
{
  run_current_test<int32_t, int32_t, float>(
    override_File_Usecase_with_cmd_line_arguments(GetParam()));
}

TEST_P(Tests_KTruss_File, CheckInt64Int64Float)
{
  run_current_test<int64_t, int64_t, float>(
    override_File_Usecase_with_cmd_line_arguments(GetParam()));
}

TEST_P(Tests_KTruss_Rmat, CheckInt32Int32Float)
{
  run_current_test<int32_t, int32_t, float>(
    override_Rmat_Usecase_with_cmd_line_arguments(GetParam()));
}

TEST_P(Tests_KTruss_Rmat, CheckInt64Int64Float)
{
  run_current_test<int64_t, int64_t, float>(
    override_Rmat_Usecase_with_cmd_line_arguments(GetParam()));
}

INSTANTIATE_TEST_SUITE_P(
  simple_test,
  Tests_KTruss_File,
  ::testing::Combine(
    // enable correctness checks
    ::testing::Values(KTruss_Usecase{5, true, false},
                      KTruss_Usecase{4, true, false},
                      KTruss_Usecase{9, true, true},
                      KTruss_Usecase{7, true, true}),
    ::testing::Values(cugraph::test::File_Usecase("test/datasets/netscience.mtx"),
                      cugraph::test::File_Usecase("test/datasets/dolphins.mtx"))));

INSTANTIATE_TEST_SUITE_P(rmat_small_test,
                         Tests_KTruss_Rmat,
                         // enable correctness checks
                         ::testing::Combine(::testing::Values(KTruss_Usecase{5, false, true},
                                                              KTruss_Usecase{4, false, true},
                                                              KTruss_Usecase{9, true, true},
                                                              KTruss_Usecase{7, true, true}),
                                            ::testing::Values(cugraph::test::Rmat_Usecase(
                                              10, 16, 0.57, 0.19, 0.19, 0, true, false))));

INSTANTIATE_TEST_SUITE_P(
  rmat_benchmark_test, /* note that scale & edge factor can be overridden in benchmarking (with
                          --gtest_filter to select only the rmat_benchmark_test with a specific
                          vertex & edge type combination) by command line arguments and do not
                          include more than one Rmat_Usecase that differ only in scale or edge
                          factor (to avoid running same benchmarks more than once) */
  Tests_KTruss_Rmat,
  // disable correctness checks for large graphs
  // FIXME: High memory footprint. Perform nbr_intersection in chunks.
  ::testing::Combine(
    ::testing::Values(KTruss_Usecase{12, false, false}),
    ::testing::Values(cugraph::test::Rmat_Usecase(14, 16, 0.57, 0.19, 0.19, 0, true, false))));

CUGRAPH_TEST_PROGRAM_MAIN()
