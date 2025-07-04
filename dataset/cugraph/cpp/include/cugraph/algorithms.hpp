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
#pragma once

#include <cugraph/api_helpers.hpp>
#include <cugraph/dendrogram.hpp>
#include <cugraph/edge_property.hpp>
#include <cugraph/graph.hpp>
#include <cugraph/graph_view.hpp>
#include <cugraph/legacy/graph.hpp>
#include <cugraph/legacy/internals.hpp>

#include <raft/core/device_span.hpp>
#include <raft/core/handle.hpp>
#include <raft/random/rng_state.hpp>

#include <rmm/resource_ref.hpp>

#include <optional>
#include <tuple>

/** @ingroup cpp_api
 *  @{
 */

/** @defgroup centrality_cpp C++ centrality algorithms
 */

/** @defgroup community_cpp C++ community Algorithms
 */

/** @defgroup sampling_cpp C++ sampling algorithms
 */

/** @defgroup similarity_cpp C++ similarity algorithms
 */

/** @defgroup traversal_cpp C++ traversal algorithms
 */

/** @defgroup linear_cpp C++ linear assignment algorithms
 */

/** @defgroup link_analysis_cpp C++ link Analysis algorithms
 */

/** @defgroup layout_cpp C++ layout algorithms
 */

/** @defgroup components_cpp C++ component algorithms
 */

/** @defgroup tree_cpp C++ tree algorithms
 */

/** @defgroup utility_cpp C++ utility algorithms
 */

namespace cugraph {

/**
 * @ingroup similarity_cpp
 * @brief     Compute jaccard similarity coefficient for all vertices
 *
 * Computes the Jaccard similarity coefficient for every pair of vertices in the graph
 * which are connected by an edge.
 *
 * @throws                 cugraph::logic_error when an error occurs.
 *
 * @tparam VT              Type of vertex identifiers. Supported value : int (signed, 32-bit)
 * @tparam ET              Type of edge identifiers. Supported value : int (signed, 32-bit)
 * @tparam WT              Type of edge weights. Supported value : float or double.
 *
 * @param[in] graph        The input graph object
 * @param[in] weights      device pointer to input vertex weights for weighted Jaccard, may be NULL
 * for unweighted Jaccard.
 * @param[out] result      Device pointer to result values, memory needs to be pre-allocated by
 * caller
 */
template <typename VT, typename ET, typename WT>
void jaccard(legacy::GraphCSRView<VT, ET, WT> const& graph, WT const* weights, WT* result);

/**
 * @ingroup similarity_cpp
 * @brief     Compute jaccard similarity coefficient for selected vertex pairs
 *
 * Computes the Jaccard similarity coefficient for each pair of specified vertices.
 * Vertices are specified as pairs where pair[n] = (first[n], second[n])
 *
 * @throws                 cugraph::logic_error when an error occurs.
 *
 * @tparam VT              Type of vertex identifiers. Supported value : int (signed, 32-bit)
 * @tparam ET              Type of edge identifiers. Supported value : int (signed, 32-bit)
 * @tparam WT              Type of edge weights. Supported value : float or double.
 *
 * @param[in] graph        The input graph object
 * @param[in] weights      The input vertex weights for weighted Jaccard, may be NULL for
 *                         unweighted Jaccard.
 * @param[in] num_pairs    The number of vertex ID pairs specified
 * @param[in] first        Device pointer to first vertex ID of each pair
 * @param[in] second       Device pointer to second vertex ID of each pair
 * @param[out] result      Device pointer to result values, memory needs to be pre-allocated by
 * caller
 */
template <typename VT, typename ET, typename WT>
void jaccard_list(legacy::GraphCSRView<VT, ET, WT> const& graph,
                  WT const* weights,
                  ET num_pairs,
                  VT const* first,
                  VT const* second,
                  WT* result);

/**
 * @ingroup similarity_cpp
 * @brief     Compute overlap coefficient for all vertices in the graph
 *
 * Computes the Overlap Coefficient for every pair of vertices in the graph which are
 * connected by an edge.
 *
 * @throws                 cugraph::logic_error when an error occurs.
 *
 * @tparam VT              Type of vertex identifiers. Supported value : int (signed, 32-bit)
 * @tparam ET              Type of edge identifiers. Supported value : int (signed, 32-bit)
 * @tparam WT              Type of edge weights. Supported value : float or double.
 *
 * @param[in] graph        The input graph object
 * @param[in] weights      device pointer to input vertex weights for weighted overlap, may be NULL
 * for unweighted overlap.
 * @param[out] result      Device pointer to result values, memory needs to be pre-allocated by
 * caller
 */
template <typename VT, typename ET, typename WT>
void overlap(legacy::GraphCSRView<VT, ET, WT> const& graph, WT const* weights, WT* result);

/**
 * @ingroup similarity_cpp
 * @brief     Compute overlap coefficient for select pairs of vertices
 *
 * Computes the overlap coefficient for each pair of specified vertices.
 * Vertices are specified as pairs where pair[n] = (first[n], second[n])
 *
 * @throws                 cugraph::logic_error when an error occurs.
 *
 * @tparam VT              Type of vertex identifiers. Supported value : int (signed, 32-bit)
 * @tparam ET              Type of edge identifiers. Supported value : int (signed, 32-bit)
 * @tparam WT              Type of edge weights. Supported value : float or double.
 *
 * @param[in] graph        The input graph object
 * @param[in] weights      device pointer to input vertex weights for weighted overlap, may be NULL
 * for unweighted overlap.
 * @param[in] num_pairs    The number of vertex ID pairs specified
 * @param[in] first        Device pointer to first vertex ID of each pair
 * @param[in] second       Device pointer to second vertex ID of each pair
 * @param[out] result      Device pointer to result values, memory needs to be pre-allocated by
 * caller
 */
template <typename VT, typename ET, typename WT>
void overlap_list(legacy::GraphCSRView<VT, ET, WT> const& graph,
                  WT const* weights,
                  ET num_pairs,
                  VT const* first,
                  VT const* second,
                  WT* result);

/**
 * @ingroup layout_cpp
 * @brief                                       ForceAtlas2 is a continuous graph layout algorithm
 * for handy network visualization.
 *
 *                                              NOTE: Peak memory allocation occurs at 17*V.
 *
 * @throws                                      cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t                                   Type of vertex identifiers. Supported value :
 * int (signed, 32-bit)
 * @tparam edge_t                                   Type of edge identifiers.  Supported value : int
 * (signed, 32-bit)
 * @tparam weight_t                                   Type of edge weights. Supported values : float
 * or double.
 *
 * @param[in] handle                            Library handle (RAFT). If a communicator is set in
 * the handle, the multi GPU version will be selected.
 * @param[in] graph                             cuGraph graph descriptor, should contain the
 * connectivity information as a COO. Graph is considered undirected. Edge weights are used for this
 * algorithm and set to 1 by default.
 * @param[out] pos                              Device array (2, n) containing x-axis and y-axis
 * positions;
 * @param[in] max_iter                          The maximum number of iterations Force Atlas 2
 * should run for.
 * @param[in] x_start                           Device array containing starting x-axis positions;
 * @param[in] y_start                           Device array containing starting y-axis positions;
 * @param[in] outbound_attraction_distribution  Distributes attraction along outbound edges. Hubs
 * attract less and thus are pushed to the borders.
 * @param[in] lin_log_mode                      Switch ForceAtlas’ model from lin-lin to lin-log
 * (tribute to Andreas Noack). Makes clusters more tight.
 * @param[in] prevent_overlapping               Prevent nodes from overlapping.
 * @param[in] edge_weight_influence             How much influence you give to the edges weight. 0
 * is “no influence” and 1 is “normal”.
 * @param[in] jitter_tolerance                  How much swinging you allow. Above 1 discouraged.
 * Lower gives less speed and more precision.
 * @param[in] barnes_hut_optimize:              Whether to use the Barnes Hut approximation or the
 * slower exact version.
 * @param[in] barnes_hut_theta:                 Float between 0 and 1. Tradeoff for speed (1) vs
 * accuracy (0) for Barnes Hut only.
 * @params[in] scaling_ratio                    Float strictly positive. How much repulsion you
 * want. More makes a more sparse graph. Switching from regular mode to LinLog mode needs a
 * readjustment of the scaling parameter.
 * @params[in] strong_gravity_mode              Sets a force
 * that attracts the nodes that are distant from the center more. It is so strong that it can
 * sometimes dominate other forces.
 * @params[in] gravity                          Attracts nodes to the center. Prevents islands from
 * drifting away.
 * @params[in] verbose                          Output convergence info at each interation.
 * @params[in] callback                         An instance of GraphBasedDimRedCallback class to
 * intercept the internal state of positions while they are being trained.
 *
 */
template <typename vertex_t, typename edge_t, typename weight_t>
void force_atlas2(raft::handle_t const& handle,
                  // raft::random::RngState& rng_state,
                  legacy::GraphCOOView<vertex_t, edge_t, weight_t>& graph,
                  float* pos,
                  const int max_iter                            = 500,
                  float* x_start                                = nullptr,
                  float* y_start                                = nullptr,
                  bool outbound_attraction_distribution         = true,
                  bool lin_log_mode                             = false,
                  bool prevent_overlapping                      = false,
                  const float edge_weight_influence             = 1.0,
                  const float jitter_tolerance                  = 1.0,
                  bool barnes_hut_optimize                      = true,
                  const float barnes_hut_theta                  = 0.5,
                  const float scaling_ratio                     = 2.0,
                  bool strong_gravity_mode                      = false,
                  const float gravity                           = 1.0,
                  bool verbose                                  = false,
                  internals::GraphBasedDimRedCallback* callback = nullptr);

/**
 * @ingroup centrality_cpp
 * @brief     Compute betweenness centrality for a graph
 *
 * Betweenness centrality for a vertex is the sum of the fraction of
 * all pairs shortest paths that pass through the vertex.
 *
 * The current implementation does not support a weighted graph.
 *
 * @throws                                  cugraph::logic_error if `result == nullptr` or
 * `number_of_sources < 0` or `number_of_sources !=0 and sources == nullptr`.
 * @tparam vertex_t                               Type of vertex identifiers. Supported value : int
 * (signed, 32-bit)
 * @tparam edge_t                               Type of edge identifiers.  Supported value : int
 * (signed, 32-bit)
 * @tparam weight_t                               Type of edge weights. Supported values : float or
 * double.
 * @tparam result_t                         Type of computed result.  Supported values :  float or
 * double
 * @param[in] handle                        Library handle (RAFT). If a communicator is set in the
 * handle, the multi GPU version will be selected.
 * @param[in] graph                         cuGRAPH graph descriptor, should contain the
 * connectivity information as a CSR
 * @param[out] result                       Device array of centrality scores
 * @param[in] normalized                    If true, return normalized scores, if false return
 * unnormalized scores.
 * @param[in] endpoints                     If true, include endpoints of paths in score, if false
 * do not
 * @param[in] weight                        If specified, device array of weights for each edge
 * @param[in] k                             If specified, number of vertex samples defined in the
 * vertices array.
 * @param[in] vertices                      If specified, host array of vertex ids to estimate
 * betweenness these vertices will serve as sources for the traversal
 * algorihtm to obtain shortest path counters.
 * @param[in] total_number_of_source_used   If specified use this number to normalize results
 * when using subsampling, it allows accumulation of results across multiple calls.
 *
 */
template <typename vertex_t, typename edge_t, typename weight_t, typename result_t>
void betweenness_centrality(const raft::handle_t& handle,
                            legacy::GraphCSRView<vertex_t, edge_t, weight_t> const& graph,
                            result_t* result,
                            bool normalized          = true,
                            bool endpoints           = false,
                            weight_t const* weight   = nullptr,
                            vertex_t k               = 0,
                            vertex_t const* vertices = nullptr);

/**
 * @ingroup centrality_cpp
 * @brief     Compute edge betweenness centrality for a graph
 *
 * Betweenness centrality of an edge is the sum of the fraction of all-pairs shortest paths that
 * pass through this edge. The weight parameter is currenlty not supported
 *
 * @throws                                  cugraph::logic_error if `result == nullptr` or
 * `number_of_sources < 0` or `number_of_sources !=0 and sources == nullptr` or `endpoints ==
 * true`.
 * @tparam vertex_t                               Type of vertex identifiers. Supported value : int
 * (signed, 32-bit)
 * @tparam edge_t                               Type of edge identifiers.  Supported value : int
 * (signed, 32-bit)
 * @tparam weight_t                               Type of edge weights. Supported values : float or
 * double.
 * @tparam result_t                         Type of computed result.  Supported values :  float or
 * double
 * @param[in] handle                        Library handle (RAFT). If a communicator is set in the
 * handle, the multi GPU version will be selected.
 * @param[in] graph                         cuGraph graph descriptor, should contain the
 * connectivity information as a CSR
 * @param[out] result                       Device array of centrality scores
 * @param[in] normalized                    If true, return normalized scores, if false return
 * unnormalized scores.
 * @param[in] weight                        If specified, device array of weights for each edge
 * @param[in] k                             If specified, number of vertex samples defined in the
 * vertices array.
 * @param[in] vertices                      If specified, host array of vertex ids to estimate
 * betweenness these vertices will serve as sources for the traversal
 * algorihtm to obtain shortest path counters.
 * @param[in] total_number_of_source_used   If specified use this number to normalize results
 * when using subsampling, it allows accumulation of results across multiple calls.
 *
 */
template <typename vertex_t, typename edge_t, typename weight_t, typename result_t>
void edge_betweenness_centrality(const raft::handle_t& handle,
                                 legacy::GraphCSRView<vertex_t, edge_t, weight_t> const& graph,
                                 result_t* result,
                                 bool normalized          = true,
                                 weight_t const* weight   = nullptr,
                                 vertex_t k               = 0,
                                 vertex_t const* vertices = nullptr);

/**
 * @ingroup centrality_cpp
 * @brief     Compute betweenness centrality for a graph
 *
 * Betweenness centrality for a vertex is the sum of the fraction of
 * all pairs shortest paths that pass through the vertex.
 *
 * The current implementation does not support a weighted graph.
 *
 * @p vertices is optional.  If it is not specified the algorithm will compute exact betweenness
 * (compute betweenness using a traversal from all vertices).
 *
 * If @p vertices is specified as a device_span, it will compute approximate betweenness
 * using the provided @p vertices as the seeds of the traversals.
 *
 * @throws                 cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 *
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view. Currently,
 * edge_weight_view.has_value() should be false as we don't support weighted graphs, yet.
 * @param vertices Optional, if specified this provides a device_span identifying a list of
 * pre-selected vertices to use as seeds for the traversals for approximating betweenness.
 * @param normalized         A flag indicating results should be normalized
 * @param include_endpoints  A flag indicating whether endpoints of a path should be counted
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 *
 * @return device vector containing the centralities.
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
rmm::device_uvector<weight_t> betweenness_centrality(
  const raft::handle_t& handle,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
  std::optional<raft::device_span<vertex_t const>> vertices,
  bool const normalized         = true,
  bool const include_endpoints  = false,
  bool const do_expensive_check = false);

/**
 * @ingroup centrality_cpp
 * @brief     Compute edge betweenness centrality for a graph
 *
 * Betweenness centrality of an edge is the sum of the fraction of all-pairs shortest paths that
 * pass through this edge. The weight parameter is currenlty not supported
 *
 * @p vertices is optional.  If it is not specified the algorithm will compute exact betweenness
 * (compute betweenness using a traversal from all vertices).
 *
 * If @p vertices is specified as a device_span, it will compute approximate betweenness
 * using the provided @p vertices as the seeds of the traversals.
 *
 * @throws                 cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 *
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view. Currently,
 * edge_weight_view.has_value() should be false as we don't support weighted graphs, yet.
 * @param vertices Optional, if specified this provides a device_span identifying a list of
 * pre-selected vertices to use as seeds for the traversals for approximating betweenness.
 * @param normalized         A flag indicating whether or not to normalize the result
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 *
 * @return edge_property_t containing the centralities.
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
edge_property_t<edge_t, weight_t> edge_betweenness_centrality(
  const raft::handle_t& handle,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
  std::optional<raft::device_span<vertex_t const>> vertices,
  bool normalized         = true,
  bool do_expensive_check = false);

enum class cugraph_cc_t {
  CUGRAPH_STRONG,  ///> Strongly Connected Components
  NUM_CONNECTIVITY_TYPES
};

/**
 * @ingroup components_cpp
 * @brief      Compute connected components.
 *
 * This implementation comes from [1] and solves component labeling problem in
 * parallel on CSR-indexes based upon the vertex degree and adjacency graph.
 *
 * [1] Hawick, K.A et al, 2010. "Parallel graph component labelling with GPUs and CUDA"
 *
 * The strong version (for directed or undirected graphs) is based on:
 * [2] Gilbert, J. et al, 2011. "Graph Algorithms in the Language of Linear Algebra"
 *
 * C = I | A | A^2 |...| A^k
 * where matrix multiplication is via semi-ring:
 * (combine, reduce) == (&, |) (bitwise ops)
 * Then: X = C & transpose(C); and finally, apply get_labels(X);
 *
 * @throws                cugraph::logic_error when an error occurs.
 *
 * @tparam VT                     Type of vertex identifiers. Supported value : int (signed, 32-bit)
 * @tparam ET                     Type of edge identifiers.  Supported value : int (signed, 32-bit)
 * @tparam WT                     Type of edge weights. Supported values : float or double.
 *
 * @param[in] graph               cuGraph graph descriptor, should contain the connectivity
 * information as a CSR
 * @param[in] connectivity_type   STRONG or WEAK
 * @param[out] labels             Device array of component labels (labels[i] indicates the label
 * associated with vertex id i.
 */
template <typename VT, typename ET, typename WT>
void connected_components(legacy::GraphCSRView<VT, ET, WT> const& graph,
                          cugraph_cc_t connectivity_type,
                          VT* labels);

/**
 * @ingroup linear_cpp
 * @brief      Compute Hungarian algorithm on a weighted bipartite graph
 *
 * The Hungarian algorithm computes an assigment of "jobs" to "workers".  This function accepts
 * a weighted graph and a vertex list identifying the "workers".  The weights in the weighted
 * graph identify the cost of assigning a particular job to a worker.  The algorithm computes
 * a minimum cost assignment and returns the cost as well as a vector identifying the assignment.
 *
 * @throws     cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t                  Type of vertex identifiers. Supported value : int (signed,
 * 32-bit)
 * @tparam edge_t                    Type of edge identifiers.  Supported value : int (signed,
 * 32-bit)
 * @tparam weight_t                  Type of edge weights. Supported values : float or double.
 *
 * @param[in]  handle                Library handle (RAFT). If a communicator is set in the
 * handle,
 * @param[in]  graph                 cuGRAPH COO graph
 * @param[in]  num_workers           number of vertices in the worker set
 * @param[in]  workers               device pointer to an array of worker vertex ids
 * @param[out] assignments           device pointer to an array to which the assignment will be
 * written. The array should be num_workers long, and will identify which vertex id (job) is
 * assigned to that worker
 */
template <typename vertex_t, typename edge_t, typename weight_t>
weight_t hungarian(raft::handle_t const& handle,
                   legacy::GraphCOOView<vertex_t, edge_t, weight_t> const& graph,
                   vertex_t num_workers,
                   vertex_t const* workers,
                   vertex_t* assignments);

/**
 * @ingroup linear_cpp
 * @brief      Compute Hungarian algorithm on a weighted bipartite graph
 *
 * The Hungarian algorithm computes an assigment of "jobs" to "workers".  This function accepts
 * a weighted graph and a vertex list identifying the "workers".  The weights in the weighted
 * graph identify the cost of assigning a particular job to a worker.  The algorithm computes
 * a minimum cost assignment and returns the cost as well as a vector identifying the assignment.
 *
 * @throws     cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t                  Type of vertex identifiers. Supported value : int (signed,
 * 32-bit)
 * @tparam edge_t                    Type of edge identifiers.  Supported value : int (signed,
 * 32-bit)
 * @tparam weight_t                  Type of edge weights. Supported values : float or double.
 *
 * @param[in]  handle                Library handle (RAFT). If a communicator is set in the handle,
 * @param[in]  graph                 cuGRAPH COO graph
 * @param[in]  num_workers           number of vertices in the worker set
 * @param[in]  workers               device pointer to an array of worker vertex ids
 * @param[out] assignments           device pointer to an array to which the assignment will be
 * written. The array should be num_workers long, and will identify which vertex id (job) is
 * assigned to that worker
 * @param[in]  epsilon               parameter to define precision of comparisons
 *                                   in reducing weights to zero.
 */
template <typename vertex_t, typename edge_t, typename weight_t>
weight_t hungarian(raft::handle_t const& handle,
                   legacy::GraphCOOView<vertex_t, edge_t, weight_t> const& graph,
                   vertex_t num_workers,
                   vertex_t const* workers,
                   vertex_t* assignments,
                   weight_t epsilon);

/**
 * @ingroup community_cpp
 * @brief      Louvain implementation
 *
 * Compute a clustering of the graph by maximizing modularity
 *
 * Computed using the Louvain method described in:
 *
 *    VD Blondel, J-L Guillaume, R Lambiotte and E Lefebvre: Fast unfolding of
 *    community hierarchies in large networks, J Stat Mech P10008 (2008),
 *    http://arxiv.org/abs/0803.0476
 *
 * @throws cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 *
 * @param[in]  handle            Library handle (RAFT). If a communicator is set in the handle,
 * @param[in]  rng_state         The RngState instance holding pseudo-random number generator state.
 * @param[in]  graph_view        Input graph view object.
 * @param[in]  edge_weight_view  Optional view object holding edge weights for @p graph_view.
 *                               If @pedge_weight_view.has_value() == false, edge weights
 *                               are assumed to be 1.0.
  @param[out] clustering         Pointer to device array where the clustering should be stored
 * @param[in]  max_level         (optional) maximum number of levels to run (default 100)
 * @param[in]  threshold         (optional) threshold for convergence at each level (default 1e-7)
 * @param[in]  resolution        (optional) The value of the resolution parameter to use.
 *                               Called gamma in the modularity formula, this changes the size
 *                               of the communities.  Higher resolutions lead to more smaller
 *                               communities, lower resolutions lead to fewer larger
 *                               communities. (default 1)
 *
 * @return                       a pair containing:
 *                                 1) number of levels of the returned clustering
 *                                 2) modularity of the returned clustering
 *
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::pair<size_t, weight_t> louvain(
  raft::handle_t const& handle,
  std::optional<std::reference_wrapper<raft::random::RngState>> rng_state,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
  vertex_t* clustering,
  size_t max_level    = 100,
  weight_t threshold  = weight_t{1e-7},
  weight_t resolution = weight_t{1});

/**
 * @ingroup community_cpp
 * @brief      Louvain implementation, returning dendrogram
 *
 * Compute a clustering of the graph by maximizing modularity
 *
 * Computed using the Louvain method described in:
 *
 *    VD Blondel, J-L Guillaume, R Lambiotte and E Lefebvre: Fast unfolding of
 *    community hierarchies in large networks, J Stat Mech P10008 (2008),
 *    http://arxiv.org/abs/0803.0476
 *
 * @throws     cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 *
 * @param[in]  handle            Library handle (RAFT). If a communicator is set in the handle,
 * @param[in]  rng_state         The RngState instance holding pseudo-random number generator state.
 * @param[in]  graph_view        Input graph view object.
 * @param[in]  edge_weight_view  Optional view object holding edge weights for @p graph_view.
 *                               If @pedge_weight_view.has_value() == false, edge weights
 *                               are assumed to be 1.0.
 * @param[in]  max_level         (optional) maximum number of levels to run (default 100)
 * @param[in]  threshold         (optional) threshold for convergence at each level (default 1e-7)
 * @param[in]  resolution        (optional) The value of the resolution parameter to use.
 *                               Called gamma in the modularity formula, this changes the size
 *                               of the communities.  Higher resolutions lead to more smaller
 *                               communities, lower resolutions lead to fewer larger
 *                               communities. (default 1)
 * @return                       a pair containing:
 *                                 1) unique pointer to dendrogram
 *                                 2) modularity of the returned clustering
 *
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::pair<std::unique_ptr<Dendrogram<vertex_t>>, weight_t> louvain(
  raft::handle_t const& handle,
  std::optional<std::reference_wrapper<raft::random::RngState>> rng_state,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
  size_t max_level    = 100,
  weight_t threshold  = weight_t{1e-7},
  weight_t resolution = weight_t{1});

/**
 * @ingroup community_cpp
 * @brief      Flatten a Dendrogram at a particular level
 *
 * A Dendrogram represents a hierarchical clustering/partitioning of
 * a graph.  This function will flatten the hierarchical clustering into
 * a label for each vertex representing the final cluster/partition to
 * which it is assigned
 *
 * @throws     cugraph::logic_error when an error occurs.
 *
 * @tparam     graph_view_t          Type of graph
 *
 * @param[in]  handle                Library handle (RAFT). If a communicator is set in the handle,
 * @param[in]  graph                 input graph object
 * @param[in]  dendrogram            input dendrogram object
 * @param[out] clustering            Pointer to device array where the clustering should be stored
 *
 */
template <typename graph_view_t>
void flatten_dendrogram(raft::handle_t const& handle,
                        graph_view_t const& graph_view,
                        Dendrogram<typename graph_view_t::vertex_type> const& dendrogram,
                        typename graph_view_t::vertex_type* clustering);

/**
 * @ingroup community_cpp
 * @brief      Leiden implementation
 *
 * Compute a clustering of the graph by maximizing modularity using the Leiden improvements
 * to the Louvain method.
 *
 * Computed using the Leiden method described in:
 *
 *    Traag, V. A., Waltman, L., & van Eck, N. J. (2019). From Louvain to Leiden:
 *    guaranteeing well-connected communities. Scientific reports, 9(1), 5233.
 *    doi: 10.1038/s41598-019-41695-z
 *
 * @throws cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t                  Type of vertex identifiers.
 *                                   Supported value : int (signed, 32-bit)
 * @tparam edge_t                    Type of edge identifiers.
 *                                   Supported value : int (signed, 32-bit)
 * @tparam weight_t                  Type of edge weights. Supported values : float or double.
 *
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param rng_state The RngState instance holding pseudo-random number generator state.
 * @param graph_view Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view. If @p
 * edge_weight_view.has_value() == false, edge weights are assumed to be 1.0.
 * @param[in]  max_level             (optional) maximum number of levels to run (default 100)
 * @param[in]  resolution            (optional) The value of the resolution parameter to use.
 *                                   Called gamma in the modularity formula, this changes the size
 *                                   of the communities.  Higher resolutions lead to more smaller
 *                                   communities, lower resolutions lead to fewer larger
 * communities. (default 1)
 * @param[in]  theta                 (optional) The value of the parameter to scale modularity
 *                                    gain in Leiden refinement phase. It is used to compute
 *                                    the probability of joining a random leiden community.
 *                                    Called theta in the Leiden algorithm.
 *
 * @return                           a pair containing:
 *                                     1) unique pointer to dendrogram
 *                                     2) modularity of the returned clustering
 *
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::pair<std::unique_ptr<Dendrogram<vertex_t>>, weight_t> leiden(
  raft::handle_t const& handle,
  raft::random::RngState& rng_state,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
  size_t max_level    = 100,
  weight_t resolution = weight_t{1},
  weight_t theta      = weight_t{1});

/**
.* @ingroup community_cpp
 * @brief      Leiden implementation
 *
 * Compute a clustering of the graph by maximizing modularity using the Leiden improvements
 * to the Louvain method.
 *
 * Computed using the Leiden method described in:
 *
 *    Traag, V. A., Waltman, L., & van Eck, N. J. (2019). From Louvain to Leiden:
 *    guaranteeing well-connected communities. Scientific reports, 9(1), 5233.
 *    doi: 10.1038/s41598-019-41695-z
 *
 * @throws cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t                  Type of vertex identifiers.
 *                                   Supported value : int (signed, 32-bit)
 * @tparam edge_t                    Type of edge identifiers.
 *                                   Supported value : int (signed, 32-bit)
 * @tparam weight_t                  Type of edge weights. Supported values : float or double.
 *
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param rng_state The RngState instance holding pseudo-random number generator state.
 * @param graph_view Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view. If @p
 * edge_weight_view.has_value() == false, edge weights are assumed to be 1.0.
 * @param[in]  max_level             (optional) maximum number of levels to run (default 100)
 * @param[in]  resolution            (optional) The value of the resolution parameter to use.
 *                                   Called gamma in the modularity formula, this changes the size
 *                                   of the communities.  Higher resolutions lead to more smaller
 *                                   communities, lower resolutions lead to fewer larger
 * communities. (default 1)
 * @param[in]  theta                 (optional) The value of the parameter to scale modularity
 *                                    gain in Leiden refinement phase. It is used to compute
 *                                    the probability of joining a random leiden community.
 *                                    Called theta in the Leiden algorithm.
 * communities. (default 1)
 *
 * @return                           a pair containing:
 *                                     1) number of levels of the returned clustering
 *                                     2) modularity of the returned clustering
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::pair<size_t, weight_t> leiden(
  raft::handle_t const& handle,
  raft::random::RngState& rng_state,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
  vertex_t* clustering,  // FIXME: Use (device_)span instead
  size_t max_level    = 100,
  weight_t resolution = weight_t{1},
  weight_t theta      = weight_t{1});

/**
.* @ingroup community_cpp
 * @brief Computes the ecg clustering of the given graph.
 *
 * ECG runs truncated Louvain on an ensemble of permutations of the input graph,
 * then uses the ensemble partitions to determine weights for the input graph.
 * The final result is found by running full Louvain on the input graph using
 * the determined weights. See https://arxiv.org/abs/1809.05578 for further
 * information.
 *
 * @throws     cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 *
 * @param[in]  handle            Library handle (RAFT). If a communicator is set in the handle,
 * @param[in]  rng_state         The RngState instance holding pseudo-random number generator state.
 * @param[in]  graph_view        Input graph view object
 * @param[in]  edge_weight_view  View object holding edge weights for @p graph_view.
 * @param[in]  min_weight        Minimum edge weight to use in the final call of the clustering
 *                               algorithm if an edge does not appear in any of the ensemble runs.
 * @param[in]  ensemble_size     The ensemble size parameter
 * @param[in]  max_level         (optional) maximum number of levels to run (default 100)
 * @param[in]  threshold         (optional) threshold for convergence at each level (default 1e-7)
 * @param[in]  resolution        (optional) The value of the resolution parameter to use.
 *                               Called gamma in the modularity formula, this changes the size
 *                               of the communities.  Higher resolutions lead to more smaller
 *                               communities, lower resolutions lead to fewer larger
 *                               communities. (default 1)
 *
 * @return                       a tuple containing:
 *                                 1) Device vector containing clustering result
 *                                 2) number of levels of the returned clustering
 *                                 3) modularity of the returned clustering
 *
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::tuple<rmm::device_uvector<vertex_t>, size_t, weight_t> ecg(
  raft::handle_t const& handle,
  raft::random::RngState& rng_state,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
  weight_t min_weight,
  size_t ensemble_size,
  size_t max_level    = 100,
  weight_t threshold  = weight_t{1e-7},
  weight_t resolution = weight_t{1});

/**
 * @ingroup tree_cpp
 * @brief Generate edges in a minimum spanning forest of an undirected weighted graph.
 *
 * A minimum spanning tree is a subgraph of the graph (a tree) with the minimum sum of edge weights.
 * A spanning forest is a union of the spanning trees for each connected component of the graph.
 * If the graph is connected it returns the minimum spanning tree.
 *
 * @throws     cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t                  Type of vertex identifiers. Supported value : int (signed,
 * 32-bit)
 * @tparam edge_t                    Type of edge identifiers.  Supported value : int (signed,
 * 32-bit)
 * @tparam weight_t                  Type of edge weights. Supported values : float or double.
 *
 * @param[in]  handle                Library handle (RAFT). If a communicator is set in the handle,
 * @param[in]  graph_csr             input graph object (CSR) expected to be symmetric
 * @param[in]  mr                    Memory resource used to allocate the returned graph
 * @return out_graph             Unique pointer to MSF subgraph in COO format
 */
template <typename vertex_t, typename edge_t, typename weight_t>
std::unique_ptr<legacy::GraphCOO<vertex_t, edge_t, weight_t>> minimum_spanning_tree(
  raft::handle_t const& handle,
  legacy::GraphCSRView<vertex_t, edge_t, weight_t> const& graph,
  rmm::device_async_resource_ref mr = rmm::mr::get_current_device_resource());

namespace subgraph {
/**
.* @ingroup utility_cpp
 * @brief             Extract subgraph by vertices
 *
 * This function will identify all edges that connect pairs of vertices
 * that are both contained in the vertices list and return a COO containing
 * these edges.
 *
 * @throws     cugraph::logic_error when an error occurs.
 *
 * @tparam VT                        Type of vertex identifiers. Supported value : int (signed,
 * 32-bit)
 * @tparam ET                        Type of edge identifiers.  Supported value : int (signed,
 * 32-bit)
 * @tparam WT                        Type of edge weights. Supported values : float or double.
 *
 * @param[in]  graph                 input graph object (COO)
 * @param[in]  vertices              device pointer to an array of vertex ids
 * @param[in]  num_vertices          number of vertices in the array vertices
 * @param[out] result                a graph in COO format containing the edges in the subgraph
 */
template <typename VT, typename ET, typename WT>
std::unique_ptr<legacy::GraphCOO<VT, ET, WT>> extract_subgraph_vertex(
  legacy::GraphCOOView<VT, ET, WT> const& graph, VT const* vertices, VT num_vertices);
}  // namespace subgraph

/**
 * @ingroup community_cpp
 * @brief     Wrapper function for Nvgraph balanced cut clustering
 *
 * @throws     cugraph::logic_error when an error occurs.
 *
 * @tparam VT                        Type of vertex identifiers. Supported value : int (signed,
 * 32-bit)
 * @tparam ET                        Type of edge identifiers.  Supported value : int (signed,
 * 32-bit)
 * @tparam WT                        Type of edge weights. Supported values : float or double.
 *
 * @param[in]  graph                 input graph object (CSR)
 * @param[in]  num_clusters          The desired number of clusters
 * @param[in]  num_eigen_vects       The number of eigenvectors to use
 * @param[in]  evs_tolerance         The tolerance to use for the eigenvalue solver
 * @param[in]  evs_max_iter          The maximum number of iterations of the eigenvalue solver
 * @param[in]  kmean_tolerance       The tolerance to use for the kmeans solver
 * @param[in]  kmean_max_iter        The maximum number of iteration of the k-means solver
 * @param[out] clustering            Pointer to device memory where the resulting clustering will
 * be stored
 */

namespace ext_raft {
template <typename VT, typename ET, typename WT>
void balancedCutClustering(legacy::GraphCSRView<VT, ET, WT> const& graph,
                           VT num_clusters,
                           VT num_eigen_vects,
                           WT evs_tolerance,
                           int evs_max_iter,
                           WT kmean_tolerance,
                           int kmean_max_iter,
                           VT* clustering);

/**
 * @ingroup community_cpp
 * @brief      Wrapper function for Nvgraph spectral modularity maximization algorithm
 *
 * @throws     cugraph::logic_error when an error occurs.
 *
 * @tparam VT                        Type of vertex identifiers. Supported value : int (signed,
 * 32-bit)
 * @tparam ET                        Type of edge identifiers.  Supported value : int (signed,
 * 32-bit)
 * @tparam WT                        Type of edge weights. Supported values : float or double.
 *
 * @param[in]  graph                 input graph object (CSR)
 * @param[in]  num_clusters          The desired number of clusters
 * @param[in]  num_eigen_vects       The number of eigenvectors to use
 * @param[in]  evs_tolerance         The tolerance to use for the eigenvalue solver
 * @param[in]  evs_max_iter          The maximum number of iterations of the eigenvalue solver
 * @param[in]  kmean_tolerance       The tolerance to use for the kmeans solver
 * @param[in]  kmean_max_iter        The maximum number of iteration of the k-means solver
 * @param[out] clustering            Pointer to device memory where the resulting clustering will
 * be stored
 */
template <typename VT, typename ET, typename WT>
void spectralModularityMaximization(legacy::GraphCSRView<VT, ET, WT> const& graph,
                                    VT n_clusters,
                                    VT n_eig_vects,
                                    WT evs_tolerance,
                                    int evs_max_iter,
                                    WT kmean_tolerance,
                                    int kmean_max_iter,
                                    VT* clustering);

/**
 * @ingroup community_cpp
 * @brief      Wrapper function for Nvgraph clustering modularity metric
 *
 * @throws     cugraph::logic_error when an error occurs.
 *
 * @tparam VT                        Type of vertex identifiers. Supported value : int (signed,
 * 32-bit)
 * @tparam ET                        Type of edge identifiers.  Supported value : int (signed,
 * 32-bit)
 * @tparam WT                        Type of edge weights. Supported values : float or double.
 *
 * @param[in]  graph                 input graph object (CSR)
 * @param[in]  n_clusters            Number of clusters in the clustering
 * @param[in]  clustering            Pointer to device array containing the clustering to analyze
 * @param[out] score                 Pointer to a float in which the result will be written
 */
template <typename VT, typename ET, typename WT>
void analyzeClustering_modularity(legacy::GraphCSRView<VT, ET, WT> const& graph,
                                  int n_clusters,
                                  VT const* clustering,
                                  WT* score);

/**
 * @ingroup community_cpp
 * @brief      Wrapper function for Nvgraph clustering edge cut metric
 *
 * @throws     cugraph::logic_error when an error occurs.
 *
 * @tparam VT                        Type of vertex identifiers. Supported value : int (signed,
 * 32-bit)
 * @tparam ET                        Type of edge identifiers.  Supported value : int (signed,
 * 32-bit)
 * @tparam WT                        Type of edge weights. Supported values : float or double.
 *
 * @param[in]  graph                 input graph object (CSR)
 * @param[in]  n_clusters            Number of clusters in the clustering
 * @param[in]  clustering            Pointer to device array containing the clustering to analyze
 * @param[out] score                 Pointer to a float in which the result will be written
 */
template <typename VT, typename ET, typename WT>
void analyzeClustering_edge_cut(legacy::GraphCSRView<VT, ET, WT> const& graph,
                                int n_clusters,
                                VT const* clustering,
                                WT* score);

/**
 * @ingroup community_cpp
 * @brief      Wrapper function for Nvgraph clustering ratio cut metric
 *
 * @throws     cugraph::logic_error when an error occurs.
 *
 * @tparam VT                        Type of vertex identifiers. Supported value : int (signed,
 * 32-bit)
 * @tparam ET                        Type of edge identifiers.  Supported value : int (signed,
 * 32-bit)
 * @tparam WT                        Type of edge weights. Supported values : float or double.
 *
 * @param[in]  graph                 input graph object (CSR)
 * @param[in]  n_clusters            Number of clusters in the clustering
 * @param[in]  clustering            Pointer to device array containing the clustering to analyze
 * @param[out] score                 Pointer to a float in which the result will be written
 */
template <typename VT, typename ET, typename WT>
void analyzeClustering_ratio_cut(legacy::GraphCSRView<VT, ET, WT> const& graph,
                                 int n_clusters,
                                 VT const* clustering,
                                 WT* score);

}  // namespace ext_raft

namespace dense {
/**
 * @ingroup linear_cpp
 * @brief      Compute Hungarian algorithm on a weighted bipartite graph
 *
 * The Hungarian algorithm computes an assigment of "jobs" to "workers".  This function accepts
 * a weighted graph and a vertex list identifying the "workers".  The weights in the weighted
 * graph identify the cost of assigning a particular job to a worker.  The algorithm computes
 * a minimum cost assignment and returns the cost as well as a vector identifying the assignment.
 *
 * @throws     cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t                  Type of vertex identifiers. Supported value : int (signed,
 * 32-bit)
 * @tparam weight_t                  Type of edge weights. Supported values : float or double.
 *
 * @param[in]  handle                Library handle (RAFT). If a communicator is set in the handle,
 * @param[in]  costs                 pointer to array of costs, stored in row major order
 * @param[in]  num_rows              number of rows in dense matrix
 * @param[in]  num_cols              number of cols in dense matrix
 * @param[out] assignments           device pointer to an array to which the assignment will be
 *                                   written. The array should be num_cols long, and will identify
 *                                   which vertex id (job) is assigned to that worker
 */
template <typename vertex_t, typename weight_t>
weight_t hungarian(raft::handle_t const& handle,
                   weight_t const* costs,
                   vertex_t num_rows,
                   vertex_t num_columns,
                   vertex_t* assignments);

/**
 * @ingroup linear_cpp
 * @brief      Compute Hungarian algorithm on a weighted bipartite graph
 *
 * The Hungarian algorithm computes an assigment of "jobs" to "workers".  This function accepts
 * a weighted graph and a vertex list identifying the "workers".  The weights in the weighted
 * graph identify the cost of assigning a particular job to a worker.  The algorithm computes
 * a minimum cost assignment and returns the cost as well as a vector identifying the assignment.
 *
 * @throws     cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t                  Type of vertex identifiers. Supported value : int (signed,
 * 32-bit)
 * @tparam weight_t                  Type of edge weights. Supported values : float or double.
 *
 * @param[in]  handle                Library handle (RAFT). If a communicator is set in the handle,
 * @param[in]  costs                 pointer to array of costs, stored in row major order
 * @param[in]  num_rows              number of rows in dense matrix
 * @param[in]  num_cols              number of cols in dense matrix
 * @param[out] assignments           device pointer to an array to which the assignment will be
 *                                   written. The array should be num_cols long, and will identify
 *                                   which vertex id (job) is assigned to that worker
 * @param[in]  epsilon               parameter to define precision of comparisons
 *                                   in reducing weights to zero.
 */
template <typename vertex_t, typename weight_t>
weight_t hungarian(raft::handle_t const& handle,
                   weight_t const* costs,
                   vertex_t num_rows,
                   vertex_t num_columns,
                   vertex_t* assignments,
                   weight_t epsilon);

}  // namespace dense

/**
 * @ingroup traversal_cpp
 * @brief Run breadth-first search to find the distances (and predecessors) from the source
 * vertex.
 *
 * This function computes the distances (minimum number of hops to reach the vertex) from the source
 * vertex. If @p predecessors is not `nullptr`, this function calculates the predecessor of each
 * vertex (parent vertex in the breadth-first search tree) as well.
 *
 * @throws cugraph::logic_error on erroneous input arguments.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * or multi-GPU (true).
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param distances Pointer to the output distance array.
 * @param predecessors Pointer to the output predecessor array or `nullptr`.
 * @param sources Source vertices to start breadth-first search (root vertex of the breath-first
 * search tree). If more than one source is passed, there must be a single source per component.
 * In a multi-gpu context the source vertices should be local to this GPU.
 * @param n_sources number of sources (one source per component at most).
 * @param direction_optimizing If set to true, this algorithm switches between the push based
 * breadth-first search and pull based breadth-first search depending on the size of the
 * breadth-first search frontier (currently unsupported). This option is valid only for symmetric
 * input graphs.
 * @param depth_limit Sets the maximum number of breadth-first search iterations. Any vertices
 * farther than @p depth_limit hops from @p source_vertex will be marked as unreachable.
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 */
template <typename vertex_t, typename edge_t, bool multi_gpu>
void bfs(raft::handle_t const& handle,
         graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
         vertex_t* distances,
         vertex_t* predecessors,
         vertex_t const* sources,
         size_t n_sources          = 1,
         bool direction_optimizing = false,
         vertex_t depth_limit      = std::numeric_limits<vertex_t>::max(),
         bool do_expensive_check   = false);

/**
 * @ingroup traversal_cpp
 * @brief Extract paths from breadth-first search output
 *
 * This function extracts paths from the BFS output.  BFS outputs distances
 * and predecessors.  The path from a vertex v back to the original source vertex
 * can be extracted by recursively looking up the predecessor vertex until you arrive
 * back at the original source vertex.
 *
 * @throws cugraph::logic_error on erroneous input arguments.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * or multi-GPU (true).
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param distances Pointer to the distance array constructed by bfs.
 * @param predecessors Pointer to the predecessor array constructed by bfs.
 * @param destinations Destination vertices, extract path from source to each of these destinations
 * In a multi-gpu context the destination vertex should be local to this GPU.
 * @param n_destinations number of destinations (one source per component at most).
 *
 * @return std::tuple<rmm::device_uvector<vertex_t>, vertex_t> pair containing
 *       the paths as a dense matrix in the vector and the maximum path length.
 *       Unused elements in the paths will be set to invalid_vertex_id (-1 for a signed
 *       vertex_t, std::numeric_limits<vertex_t>::max() for an unsigned vertex_t type).
 */
template <typename vertex_t, typename edge_t, bool multi_gpu>
std::tuple<rmm::device_uvector<vertex_t>, vertex_t> extract_bfs_paths(
  raft::handle_t const& handle,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  vertex_t const* distances,
  vertex_t const* predecessors,
  vertex_t const* destinations,
  size_t n_destinations);

/**
 * @ingroup traversal_cpp
 * @brief Run single-source shortest-path to compute the minimum distances (and predecessors) from
 * the source vertex.
 *
 * This function computes the distances (minimum edge weight sums) from the source vertex. If @p
 * predecessors is not `nullptr`, this function calculates the predecessor of each vertex in the
 * shortest-path as well. Graph edge weights should be non-negative.
 *
 * @throws cugraph::logic_error on erroneous input arguments.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * or multi-GPU (true).
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param edge_weight_view View object holding edge weights for @p graph_view.
 * @param distances Pointer to the output distance array.
 * @param predecessors Pointer to the output predecessor array or `nullptr`.
 * @param source_vertex Source vertex to start single-source shortest-path.
 * In a multi-gpu context the source vertex should be local to this GPU.
 * @param cutoff Single-source shortest-path terminates if no more vertices are reachable within the
 * distance of @p cutoff. Any vertex farther than @p cutoff will be marked as unreachable.
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
void sssp(raft::handle_t const& handle,
          graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
          edge_property_view_t<edge_t, weight_t const*> edge_weight_view,
          weight_t* distances,
          vertex_t* predecessors,
          vertex_t source_vertex,
          weight_t cutoff         = std::numeric_limits<weight_t>::max(),
          bool do_expensive_check = false);

/**
.* @ingroup traversal_cpp
 * @brief Compute the shortest distances from the given origins to all the given destinations.
 *
 * This algorithm is designed for large diameter graphs. For small diameter graphs, running the
 * cugraph::sssp function in a sequentially executed loop might be faster. This algorithms currently
 * works only for single-GPU (we are not aware of large diameter graphs that won't fit in a single
 * GPU).
 *
 * @throws cugraph::logic_error on erroneous input arguments.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * or multi-GPU (true).
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param edge_weight_view View object holding edge weights for @p graph_view.
 * @param origins An array of origins (starting vertices) to find shortest distances. There should
 * be no duplicates in @p origins.
 * @param destinations An array of destinations (end vertices) to find shortest distances. There
 * should be no duplicates in @p destinations.
 * @param cutoff Any destinations farther than @p cutoff will be marked as unreachable.
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 * @return A vector of size @p origins.size() * @p destinations.size(). The i'th element of the
 * returned vector is the shortest distance from the (i / @p destinations.size())'th origin to the
 * (i % @p destinations.size())'th destination.
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
rmm::device_uvector<weight_t> od_shortest_distances(
  raft::handle_t const& handle,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  edge_property_view_t<edge_t, weight_t const*> edge_weight_view,
  raft::device_span<vertex_t const> origins,
  raft::device_span<vertex_t const> destinations,
  weight_t cutoff         = std::numeric_limits<weight_t>::max(),
  bool do_expensive_check = false);

/**
 * @ingroup link_analysis_cpp
 * @brief Compute PageRank scores.
 *
 * @deprecated This API will be deprecated to replaced by the new version below
 *             that returns metadata about the algorithm.
 *
 * This function computes general (if @p personalization_vertices is `nullptr`) or personalized (if
 * @p personalization_vertices is not `nullptr`.) PageRank scores.
 *
 * @throws cugraph::logic_error on erroneous input arguments or if fails to converge before @p
 * max_iterations.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam result_t Type of PageRank scores.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * or multi-GPU (true).
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view. If @p
 * edge_weight_view.has_value() == false, edge weights are assumed to be 1.0.
 * @param precomputed_vertex_out_weight_sums Pointer to an array storing sums of out-going edge
 * weights for the vertices (for re-use) or `std::nullopt`. If `std::nullopt`, these values are
 * freshly computed. Computing these values outside this function reduces the number of memory
 * allocations/deallocations and computing if a user repeatedly computes PageRank scores using the
 * same graph with different personalization vectors.
 * @param personalization_vertices Pointer to an array storing personalization vertex identifiers
 * (compute personalized PageRank) or `std::nullopt` (compute general PageRank).
 * @param personalization_values Pointer to an array storing personalization values for the vertices
 * in the personalization set. Relevant only if @p personalization_vertices is not `std::nullopt`.
 * @param personalization_vector_size Size of the personalization set. If @personalization_vertices
 * is not `std::nullopt`, the sizes of the arrays pointed by @p personalization_vertices and @p
 * personalization_values should be @p personalization_vector_size.
 * @param pageranks Pointer to the output PageRank score array.
 * @param alpha PageRank damping factor.
 * @param epsilon Error tolerance to check convergence. Convergence is assumed if the sum of the
 * differences in PageRank values between two consecutive iterations is less than the number of
 * vertices in the graph multiplied by @p epsilon.
 * @param max_iterations Maximum number of PageRank iterations.
 * @param has_initial_guess If set to `true`, values in the PageRank output array (pointed by @p
 * pageranks) is used as initial PageRank values. If false, initial PageRank values are set to 1.0
 * divided by the number of vertices in the graph.
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 */
template <typename vertex_t, typename edge_t, typename weight_t, typename result_t, bool multi_gpu>
void pagerank(raft::handle_t const& handle,
              graph_view_t<vertex_t, edge_t, true, multi_gpu> const& graph_view,
              std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
              std::optional<weight_t const*> precomputed_vertex_out_weight_sums,
              std::optional<vertex_t const*> personalization_vertices,
              std::optional<result_t const*> personalization_values,
              std::optional<vertex_t> personalization_vector_size,
              result_t* pageranks,
              result_t alpha,
              result_t epsilon,
              size_t max_iterations   = 500,
              bool has_initial_guess  = false,
              bool do_expensive_check = false);

/**
 * @brief Metadata about the execution of one of the centrality algorithms
 */
// FIXME:  This structure should be propagated to other algorithms that converge
//   (eigenvector centrality, hits and katz centrality)
//
struct centrality_algorithm_metadata_t {
  size_t number_of_iterations_{};
  bool converged_{};
};

/**
.* @ingroup link_analysis_cpp
 * @brief Compute PageRank scores.
 *
 * This function computes general (if @p personalization_vertices is `nullptr`) or personalized (if
 * @p personalization_vertices is not `nullptr`.) PageRank scores.
 *
 * @throws cugraph::logic_error on erroneous input arguments or if fails to converge before @p
 * max_iterations.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam result_t Type of PageRank scores.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * or multi-GPU (true).
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view. If @p
 * edge_weight_view.has_value() == false, edge weights are assumed to be 1.0.
 * @param precomputed_vertex_out_weight_sums Pointer to an array storing sums of out-going edge
 * weights for the vertices (for re-use) or `std::nullopt`. If `std::nullopt`, these values are
 * freshly computed. Computing these values outside this function reduces the number of memory
 * allocations/deallocations and computing if a user repeatedly computes PageRank scores using the
 * same graph with different personalization vectors.
 * @param personalization Optional tuple containing device spans of vertex identifiers and
 * personalization values for the vertices (compute personalized PageRank) or `std::nullopt`
 * (compute general PageRank).
 * @param initial_pageranks Optional device span containing initial PageRank values.  If
 * specified this array will be used as the initial values and the PageRank values will be
 * updated in place.  If not specified then the initial values will be set to 1.0 divided by
 * the number of vertices in the graph and the return value will contain an `rmm::device_uvector`
 * containing the resulting PageRank values.
 * @param alpha PageRank damping factor.
 * @param epsilon Error tolerance to check convergence. Convergence is assumed if the sum of the
 * differences in PageRank values between two consecutive iterations is less than the number of
 * vertices in the graph multiplied by @p epsilon.
 * @param max_iterations Maximum number of PageRank iterations.
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 * @return tuple containing the optional pagerank results (populated if @p initial_pageranks is
 * set to `std::nullopt`) and a metadata structure with metadata indicating how many iterations
 * were run and whether the algorithm converged or not.
 */
template <typename vertex_t, typename edge_t, typename weight_t, typename result_t, bool multi_gpu>
std::tuple<rmm::device_uvector<result_t>, centrality_algorithm_metadata_t> pagerank(
  raft::handle_t const& handle,
  graph_view_t<vertex_t, edge_t, true, multi_gpu> const& graph_view,
  std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
  std::optional<raft::device_span<weight_t const>> precomputed_vertex_out_weight_sums,
  std::optional<std::tuple<raft::device_span<vertex_t const>, raft::device_span<result_t const>>>
    personalization,
  std::optional<raft::device_span<result_t const>> initial_pageranks,
  result_t alpha,
  result_t epsilon,
  size_t max_iterations   = 500,
  bool do_expensive_check = false);

/**
.* @ingroup centrality_cpp
 * @brief Compute Eigenvector Centrality scores.
 *
 * This function computes eigenvector centrality scores using the power method.
 *
 * @throws cugraph::logic_error on erroneous input arguments or if fails to converge before @p
 * max_iterations.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * or multi-GPU (true).
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view. If @p
 * edge_weight_view.has_value() == false, edge weights are assumed to be 1.0.
 * @param initial_centralities Optional device span containing initial values for the eigenvector
 * centralities
 * @param epsilon Error tolerance to check convergence. Convergence is assumed if the sum of the
 * differences in eigenvector centrality values between two consecutive iterations is less than the
 * number of vertices in the graph multiplied by @p epsilon.
 * @param max_iterations Maximum number of power iterations.
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 * @return device vector containing the centralities.
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
rmm::device_uvector<weight_t> eigenvector_centrality(
  raft::handle_t const& handle,
  graph_view_t<vertex_t, edge_t, true, multi_gpu> const& graph_view,
  std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
  std::optional<raft::device_span<weight_t const>> initial_centralities,
  weight_t epsilon,
  size_t max_iterations   = 500,
  bool do_expensive_check = false);

/**
.* @ingroup link_analysis_cpp
 * @brief Compute HITS scores.
 *
 * This function computes HITS scores for the vertices of a graph
 *
 * @throws cugraph::logic_error on erroneous input arguments
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * or multi-GPU (true).
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param hubs Pointer to the input/output hub score array.
 * @param authorities Pointer to the output authorities score array.
 * @param epsilon Error tolerance to check convergence. Convergence is assumed if the sum of the
 * differences in hub values between two consecutive iterations is less than @p epsilon
 * @param max_iterations Maximum number of HITS iterations.
 * @param has_initial_guess If set to `true`, values in the hubs output array (pointed by @p
 * hubs) is used as initial hub values. If false, initial hub values are set to 1.0
 * divided by the number of vertices in the graph.
 * @param normalize If set to `true`, final hub and authority scores are normalized (the L1-norm of
 * the returned hub and authority score arrays is 1.0) before returning.
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 * @return std::tuple<result_t, size_t> A tuple of sum of the differences of hub scores of the last
 * two iterations and the total number of iterations taken to reach the final result
 */
template <typename vertex_t, typename edge_t, typename result_t, bool multi_gpu>
std::tuple<result_t, size_t> hits(raft::handle_t const& handle,
                                  graph_view_t<vertex_t, edge_t, true, multi_gpu> const& graph_view,
                                  result_t* hubs,
                                  result_t* authorities,
                                  result_t epsilon,
                                  size_t max_iterations,
                                  bool has_initial_hubs_guess,
                                  bool normalize,
                                  bool do_expensive_check);

/**
.* @ingroup centrality_cpp
 * @brief Compute Katz Centrality scores.
 *
 * This function computes Katz Centrality scores.
 *
 * @throws cugraph::logic_error on erroneous input arguments or if fails to converge before @p
 * max_iterations.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam result_t Type of Katz Centrality scores.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * or multi-GPU (true).
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view. If @p
 * edge_weight_view.has_value() == false, edge weights are assumed to be 1.0.
 * @param betas Pointer to an array holding the values to be added to each vertex's new Katz
 * Centrality score in every iteration or `nullptr`. If set to `nullptr`, constant @p beta is used
 * instead.
 * @param katz_centralities Pointer to the output Katz Centrality score array.
 * @param alpha Katz Centrality attenuation factor. This should be smaller than the inverse of the
 * maximum eigenvalue of the adjacency matrix of @p graph.
 * @param beta Constant value to be added to each vertex's new Katz Centrality score in every
 * iteration. Relevant only when @p betas is `nullptr`.
 * @param epsilon Error tolerance to check convergence. Convergence is assumed if the sum of the
 * differences in Katz Centrality values between two consecutive iterations is less than the number
 * of vertices in the graph multiplied by @p epsilon.
 * @param max_iterations Maximum number of Katz Centrality iterations.
 * @param has_initial_guess If set to `true`, values in the Katz Centrality output array (pointed by
 * @p katz_centralities) is used as initial Katz Centrality values. If false, zeros are used as
 * initial Katz Centrality values.
 * @param normalize If set to `true`, final Katz Centrality scores are normalized (the L2-norm of
 * the returned Katz Centrality score array is 1.0) before returning.
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 */
template <typename vertex_t, typename edge_t, typename weight_t, typename result_t, bool multi_gpu>
void katz_centrality(raft::handle_t const& handle,
                     graph_view_t<vertex_t, edge_t, true, multi_gpu> const& graph_view,
                     std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
                     result_t const* betas,
                     result_t* katz_centralities,
                     result_t alpha,
                     result_t beta,
                     result_t epsilon,
                     size_t max_iterations   = 500,
                     bool has_initial_guess  = false,
                     bool normalize          = false,
                     bool do_expensive_check = false);

/**
.* @ingroup community_cpp
 * @brief returns induced EgoNet subgraph(s) of neighbors centered at nodes in source_vertex within
 * a given radius.
 *
 * @deprecated This algorithm will be deprecated to replaced by the new version
 *             that uses the raft::device_span.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * or multi-GPU (true).
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms. Must have at least one worker stream.
 * @param graph_view Graph view object of, we extract induced egonet subgraphs from @p graph_view.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view.
 * @param source_vertex Pointer to egonet center vertices (size == @p n_subgraphs).
 * @param n_subgraphs Number of induced EgoNet subgraphs to extract (ie. number of elements in @p
 * source_vertex).
 * @param radius  Include all neighbors of distance <= radius from @p source_vertex.
 * @return Quadraplet of edge source vertices, edge destination vertices, edge weights (if @p
 * edge_weight_view.has_value() == true), and edge offsets for each induced EgoNet subgraph.
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::tuple<rmm::device_uvector<vertex_t>,
           rmm::device_uvector<vertex_t>,
           std::optional<rmm::device_uvector<weight_t>>,
           rmm::device_uvector<size_t>>
extract_ego(raft::handle_t const& handle,
            graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
            std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
            vertex_t* source_vertex,
            vertex_t n_subgraphs,
            vertex_t radius);

/**
.* @ingroup community_cpp
 * @brief returns induced EgoNet subgraph(s) of neighbors centered at nodes in source_vertex within
 * a given radius.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * or multi-GPU (true).
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms. Must have at least one worker stream.
 * @param graph_view Graph view object of, we extract induced egonet subgraphs from @p graph_view.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view.
 * @param source_vertex Pointer to egonet center vertices (size == @p n_subgraphs).
 * @param n_subgraphs Number of induced EgoNet subgraphs to extract (ie. number of elements in @p
 * source_vertex).
 * @param radius  Include all neighbors of distance <= radius from @p source_vertex.
 * @return std::tuple<rmm::device_uvector<vertex_t>, rmm::device_uvector<vertex_t>,
 * rmm::device_uvector<weight_t>, rmm::device_uvector<size_t>> Quadraplet of edge source vertices,
 * edge destination vertices, edge weights, and edge offsets for each induced EgoNet subgraph.
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::tuple<rmm::device_uvector<vertex_t>,
           rmm::device_uvector<vertex_t>,
           std::optional<rmm::device_uvector<weight_t>>,
           rmm::device_uvector<size_t>>
extract_ego(raft::handle_t const& handle,
            graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
            std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
            raft::device_span<vertex_t const> source_vertices,
            vertex_t radius,
            bool do_expensive_check = false);

/**
.* @ingroup sampling_cpp
 * @brief returns random walks (RW) from starting sources, where each path is of given maximum
 * length. Uniform distribution is assumed for the random engine.
 *
 * @deprecated This algorithm will be deprecated once all of the functionality is migrated
 *             to the newer APIS: uniform_random_walks(), biased_random_walks(), and
 *             node2vec_random_walks().
 *
 * @tparam graph_t Type of graph/view (typically, graph_view_t).
 * @tparam index_t Type used to store indexing and sizes.
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph Graph (view )object to generate RW on.
 * @param ptr_d_start Device pointer to set of starting vertex indices for the RW.
 * @param num_paths = number(paths).
 * @param max_depth maximum length of RWs.
 * @param use_padding (optional) specifies if return uses padded format (true), or coalesced
 * (compressed) format; when padding is used the output is a matrix of vertex paths and a matrix of
 * edges paths (weights); in this case the matrices are stored in row major order; the vertex path
 * matrix is padded with `num_vertices` values and the weight matrix is padded with `0` values;
 * @param sampling_strategy pointer for sampling strategy: uniform, biased, etc.; possible
 * values{0==uniform, 1==biased, 2==node2vec}; defaults to nullptr == uniform;
 * @return std::tuple<rmm::device_uvector<vertex_t>, rmm::device_uvector<weight_t>,
 * rmm::device_uvector<index_t>> Triplet of either padded or coalesced RW paths; in the coalesced
 * case (default), the return consists of corresponding vertex and edge weights for each, and
 * corresponding path sizes. This is meant to minimize the number of DF's to be passed to the Python
 * layer. The meaning of "coalesced" here is that a 2D array of paths of different sizes is
 * represented as a 1D contiguous array. In the padded case the return is a matrix of num_paths x
 * max_depth vertex paths; and num_paths x (max_depth-1) edge (weight) paths, with an empty array of
 * sizes. Note: if the graph is un-weighted the edge (weight) paths consists of `weight_t{1}`
 * entries;
 */
template <typename vertex_t, typename edge_t, typename weight_t, typename index_t, bool multi_gpu>
std::
  tuple<rmm::device_uvector<vertex_t>, rmm::device_uvector<weight_t>, rmm::device_uvector<index_t>>
  random_walks(raft::handle_t const& handle,
               graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
               std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
               vertex_t const* ptr_d_start,
               index_t num_paths,
               index_t max_depth,
               bool use_padding                                     = false,
               std::unique_ptr<sampling_params_t> sampling_strategy = nullptr);

/**
.* @ingroup sampling_cpp
 * @brief returns uniform random walks from starting sources, where each path is of given
 * maximum length.
 *
 * @p start_vertices can contain duplicates, in which case different random walks will
 * be generated for each instance.
 *
 * If @p edge_weight_view.has_value() is true, the return contains edge weights.  If @p
 * edge_weight_view.has_value() is false, the returned value will be std::nullopt.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view graph view to operate on
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view.
 * @param start_vertices Device span defining the starting vertices
 * @param max_length maximum length of random walk
 * @param seed (optional, defaults to system time), seed for random number generation
 * @return tuple containing device vectors of vertices and the edge weights (if
 *         @p edge_weight_view.has_value() is true)<br>
 *         For each input selector there will be (max_length+1) elements in the
 *         vertex vector with the starting vertex followed by the subsequent
 *         vertices in the random walk.  If a path terminates before max_length,
 *         the vertices will be populated with invalid_vertex_id
 *         (-1 for signed vertex_t, std::numeric_limits<vertex_t>::max() for an
 *         unsigned vertex_t type)<br>
 *         For each input selector there will be max_length elements in the weights
 *         vector with the edge weight for the edge in the path.  If a path
 *         terminates before max_length the subsequent edge weights will be
 *         set to weight_t{0}.
 */
// FIXME: Do I care about transposed or not?  I want to be able to operate in either
// direction.
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::tuple<rmm::device_uvector<vertex_t>, std::optional<rmm::device_uvector<weight_t>>>
uniform_random_walks(raft::handle_t const& handle,
                     raft::random::RngState& rng_state,
                     graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
                     std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
                     raft::device_span<vertex_t const> start_vertices,
                     size_t max_length);

/**
.* @ingroup sampling_cpp
 * @brief returns biased random walks from starting sources, where each path is of given
 * maximum length.
 *
 * The next vertex is biased based on the edge weights.  The probability of traversing a
 * departing edge will be the edge weight divided by the sum of the departing edge weights.
 *
 * @p start_vertices can contain duplicates, in which case different random walks will
 * be generated for each instance.
 *
 * @throws                 cugraph::logic_error if the graph is unweighted
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view graph view to operate on
 * @param edge_weight_view View object holding edge weights for @p graph_view.
 * @param start_vertices Device span defining the starting vertices
 * @param max_length maximum length of random walk
 * @param seed (optional, defaults to system time), seed for random number generation
 * @return tuple containing device vectors of vertices and the edge weights<br>
 *         For each input selector there will be (max_length+1) elements in the
 *         vertex vector with the starting vertex followed by the subsequent
 *         vertices in the random walk.  If a path terminates before max_length,
 *         the vertices will be populated with invalid_vertex_id
 *         (-1 for signed vertex_t, std::numeric_limits<vertex_t>::max() for an
 *         unsigned vertex_t type)<br>
 *         For each input selector there will be max_length elements in the weights
 *         vector with the edge weight for the edge in the path.  If a path
 *         terminates before max_length the subsequent edge weights will be
 *         set to weight_t{0}.
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::tuple<rmm::device_uvector<vertex_t>, std::optional<rmm::device_uvector<weight_t>>>
biased_random_walks(raft::handle_t const& handle,
                    raft::random::RngState& rng_state,
                    graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
                    edge_property_view_t<edge_t, weight_t const*> edge_weight_view,
                    raft::device_span<vertex_t const> start_vertices,
                    size_t max_length);

/**
.* @ingroup sampling_cpp
 * @brief returns biased random walks with node2vec biases from starting sources,
 * where each path is of given maximum length.
 *
 * @p start_vertices can contain duplicates, in which case different random walks will
 * be generated for each instance.
 *
 * If the @p edge_weight_view.has_value() = true, the return contains edge weights and the node2vec
 * computation will utilize the edge weights.  If @p edge_weight_view.has_value() == false, then the
 * return will not contain edge weights and the node2vec computation will assume an edge weight of 1
 * for all edges.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view graph view to operate on
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view. If @p
 * edge_weight_view.has_value() == false, edge weights are assumed to be 1.0.
 * @param start_vertices Device span defining the starting vertices
 * @param max_length maximum length of random walk
 * @param p node2vec return parameter
 * @param q node2vec in-out parameter
 * @param seed (optional, defaults to system time), seed for random number generation
 * @return tuple containing device vectors of vertices and the edge weights<br>
 *         For each input selector there will be (max_length+1) elements in the
 *         vertex vector with the starting vertex followed by the subsequent
 *         vertices in the random walk.  If a path terminates before max_length,
 *         the vertices will be populated with invalid_vertex_id
 *         (-1 for signed vertex_t, std::numeric_limits<vertex_t>::max() for an
 *         unsigned vertex_t type)<br>
 *         For each input selector there will be max_length elements in the weights
 *         vector with the edge weight for the edge in the path.  If a path
 *         terminates before max_length the subsequent edge weights will be
 *         set to weight_t{0}.
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::tuple<rmm::device_uvector<vertex_t>, std::optional<rmm::device_uvector<weight_t>>>
node2vec_random_walks(raft::handle_t const& handle,
                      raft::random::RngState& rng_state,
                      graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
                      std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
                      raft::device_span<vertex_t const> start_vertices,
                      size_t max_length,
                      weight_t p,
                      weight_t q);

/**
.* @ingroup components_cpp
 * @brief Finds (weakly-connected-)component IDs of each vertices in the input graph.
 *
 * The input graph must be symmetric. Component IDs can be arbitrary integers (they can be
 * non-consecutive and are not ordered by component size or any other criterion).
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * or multi-GPU (true).
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param components Pointer to the output component ID array.
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 */
template <typename vertex_t, typename edge_t, bool multi_gpu>
void weakly_connected_components(raft::handle_t const& handle,
                                 graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
                                 vertex_t* components,
                                 bool do_expensive_check = false);

/**
.* @ingroup core_cpp
 * @brief  Identify whether the core number computation should be based off incoming edges,
 *         outgoing edges or both.
 */
enum class k_core_degree_type_t { IN = 0, OUT = 1, INOUT = 2 };

/**
.* @ingroup core_cpp
 * @brief   Compute core numbers of individual vertices from K-Core decomposition.
 *
 * This algorithms does not support multi-graphs. Self-loops are excluded in computing core
nuumbers.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * or multi-GPU (true).
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param core_numbers Pointer to the output core number array.
 * @param degree_type Dictate whether to compute the K-Core decomposition based on in-degrees,
 * out-degrees, or in-degrees + out_degrees.
 * @param k_first Find K-Cores from K = k_first. Any vertices that do not belong to k_first-core
 * will have core numbers of 0.
 * @param k_last Find K-Cores to K = k_last. Any vertices that belong to (k_last)-core will have
 * their core numbers set to their degrees on k_last-core.
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 */
template <typename vertex_t, typename edge_t, bool multi_gpu>
void core_number(raft::handle_t const& handle,
                 graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
                 edge_t* core_numbers,
                 k_core_degree_type_t degree_type,
                 size_t k_first          = 0,
                 size_t k_last           = std::numeric_limits<size_t>::max(),
                 bool do_expensive_check = false);

/**
.* @ingroup core_cpp
 * @brief   Extract K-Core of a graph
 *
 * This function internally calls core_number (if @p core_numbers.has_value() is false). core_number
does not support multi-graphs. Self-loops are excluded in computing core nuumbers. Note that the
extracted K-Core can still include self-loops.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param  graph_view      Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view.
 * @param  k               Order of the core. This value must not be negative.
 * @param degree_type Optional parameter to dictate whether to compute the K-Core decomposition
 *                    based on in-degrees, out-degrees, or in-degrees + out_degrees.  One of @p
 *                    degree_type and @p core_numbers must be specified.
 * @param  core_numbers    Optional output from core_number algorithm.  If not specified then
 *                         k_core will call core_number itself using @p degree_type
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 *
 * @return edge list for the graph
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::tuple<rmm::device_uvector<vertex_t>,
           rmm::device_uvector<vertex_t>,
           std::optional<rmm::device_uvector<weight_t>>>
k_core(raft::handle_t const& handle,
       graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
       std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
       size_t k,
       std::optional<k_core_degree_type_t> degree_type,
       std::optional<raft::device_span<edge_t const>> core_numbers,
       bool do_expensive_check = false);

/**
 * @ingroup community_cpp
 * @brief Compute triangle counts.
 *
 * Compute triangle counts for the entire set of vertices (if @p vertices is std::nullopt) or the
 * given vertices (@p vertices.has_value() is true).
 *
 * This algorithms does not support multi-graphs. Self-loops are excluded in computing triangle
 * counts.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param vertices Vertices to compute triangle counts. If @p vertices.has_value() is false, compute
 * triangle counts for the entire set of vertices.
 * @param counts Output triangle count array. The size of the array should be the local vertex
 * partition range size (if @p vertices is std::nullopt) or the size of @p vertices (if @p
 * vertices.has_value() is true).
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 */
template <typename vertex_t, typename edge_t, bool multi_gpu>
void triangle_count(raft::handle_t const& handle,
                    graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
                    std::optional<raft::device_span<vertex_t const>> vertices,
                    raft::device_span<edge_t> counts,
                    bool do_expensive_check = false);

/**
.* @ingroup community_cpp
 * @brief Compute edge triangle counts.
 *
 * Compute edge triangle counts for the entire set of edges.
 *
 * This algorithms does not support multi-graphs. Self-loops are excluded in computing edge triangle
counts (they will have a triangle count of 0).
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 *  * @param do_expensive_check A flag to run expensive checks for input arguments (if set to
 * `true`).
 *
 * @return edge_property_t containing the edge triangle count
 */
template <typename vertex_t, typename edge_t, bool multi_gpu>
edge_property_t<edge_t, edge_t> edge_triangle_count(
  raft::handle_t const& handle,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  bool do_expensive_check = false);

/**
.* @ingroup community_cpp
 * @brief Compute K-Truss.
 *
 * Extract the K-Truss subgraph of a graph
 *
 * This algorithms does not support multi-graphs. Self-loops are excluded in computing K-Truss.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view.
 * @param k The desired k to be used for extracting the K-Truss subgraph
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 * @return edge list of the K-Truss subgraph
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::tuple<rmm::device_uvector<vertex_t>,
           rmm::device_uvector<vertex_t>,
           std::optional<rmm::device_uvector<weight_t>>>
k_truss(raft::handle_t const& handle,
        graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
        std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
        edge_t k,
        bool do_expensive_check = false);

/**
.* @ingroup similarity_cpp
 * @brief     Compute Jaccard similarity coefficient
 *
 * Similarity is computed for every pair of vertices specified. Note that
 * similarity algorithms expect a symmetric graph.
 *
 * @throws                 cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view. If @p
 * edge_weight_view.has_value() == true, use the weights associated with the graph. If false, assume
 * a weight of 1 for all edges.
 * @param vertex_pairs tuple of device spans defining the vertex pairs to compute similarity for
 * In a multi-gpu context each vertex pair should be local to this GPU.
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 * @return similarity coefficient for the corresponding @p vertex_pairs
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
rmm::device_uvector<weight_t> jaccard_coefficients(
  raft::handle_t const& handle,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
  std::tuple<raft::device_span<vertex_t const>, raft::device_span<vertex_t const>> vertex_pairs,
  bool do_expensive_check = false);

/**
.* @ingroup similarity_cpp
 * @brief     Compute Cosine similarity coefficient
 *
 * Similarity is computed for every pair of vertices specified. Note that
 * similarity algorithms expect a symmetric graph.
 *
 * @throws                 cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view. If @p
 * edge_weight_view.has_value() == true, use the weights associated with the graph. If false, assume
 * a weight of 1 for all edges.
 * @param vertex_pairs tuple of device spans defining the vertex pairs to compute similarity for
 * In a multi-gpu context each vertex pair should be local to this GPU.
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 * @return similarity coefficient for the corresponding @p vertex_pairs
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
rmm::device_uvector<weight_t> cosine_similarity_coefficients(
  raft::handle_t const& handle,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
  std::tuple<raft::device_span<vertex_t const>, raft::device_span<vertex_t const>> vertex_pairs,
  bool do_expensive_check = false);

/**
.* @ingroup similarity_cpp
 * @brief     Compute Sorensen similarity coefficient
 *
 * Similarity is computed for every pair of vertices specified. Note that
 * similarity algorithms expect a symmetric graph.
 *
 * @throws                 cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view. If @p
 * edge_weight_view.has_value() == true, use the weights associated with the graph. If false, assume
 * a weight of 1 for all edges.
 * @param vertex_pairs tuple of device spans defining the vertex pairs to compute similarity for
 * @param vertex_pairs tuple of device spans defining the vertex pairs to compute similarity for
 * In a multi-gpu context each vertex pair should be local to this GPU.
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 * @return similarity coefficient for the corresponding @p vertex_pairs
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
rmm::device_uvector<weight_t> sorensen_coefficients(
  raft::handle_t const& handle,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
  std::tuple<raft::device_span<vertex_t const>, raft::device_span<vertex_t const>> vertex_pairs,
  bool do_expensive_check = false);

/**
.* @ingroup similarity_cpp
 * @brief     Compute overlap similarity coefficient
 *
 * Similarity is computed for every pair of vertices specified. Note that
 * similarity algorithms expect a symmetric graph.
 *
 * @throws                 cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view. If @p
 * edge_weight_view.has_value() == true, use the weights associated with the graph. If false, assume
 * a weight of 1 for all edges.
 * @param vertex_pairs tuple of device spans defining the vertex pairs to compute similarity for
 * @param vertex_pairs tuple of device spans defining the vertex pairs to compute similarity for
 * In a multi-gpu context each vertex pair should be local to this GPU.
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 * @return similarity coefficient for the corresponding @p vertex_pairs
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
rmm::device_uvector<weight_t> overlap_coefficients(
  raft::handle_t const& handle,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
  std::tuple<raft::device_span<vertex_t const>, raft::device_span<vertex_t const>> vertex_pairs,
  bool do_expensive_check = false);

/**
.* @ingroup similarity_cpp
 * @brief     Compute Jaccard all pairs similarity coefficient
 *
 * Similarity is computed for all pairs of vertices.  Note that in a sparse
 * graph, many of the vertex pairs will have a score of zero.  We actually
 * compute similarity only for vertices that are two hop neighbors within
 * the graph, since vertices that are not two hop neighbors will have
 * a score of 0.
 *
 * If @p vertices is specified we will compute similarity on two hop
 * neighbors the @p vertices.  If @p vertices is not specified it will
 * compute similarity on all two hop neighbors in the graph.
 *
 * If @p topk is specified only the top @p topk scoring vertex pairs
 * will be returned, if not specified then scores for all computed vertex pairs
 * will be returned.
 *
 * Note the list of two hop neighbors in the entire graph might be a large
 * number of vertex pairs.  If the graph is dense enough it could be as large
 * as the the number of vertices squared, which might run out of memory.
 *
 * @throws                 cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view. If @p
 * edge_weight_view.has_value() == true, use the weights associated with the graph. If false, assume
 * a weight of 1 for all edges.
 * @param vertices optional device span defining the seed vertices. In a multi-gpu context the
 * vertices should be local to this GPU.
 * @param topk optional specification of the how many of the top scoring vertex pairs should be
 * returned
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 * @return tuple containing three device vectors (v1, v2, score) of the same length.  Corresponding
 * elements in the vectors identify a result, v1 identifying a vertex in the graph, v2 identifying
 * one of v1's two hop neighors, and the score identifying the similarity score between v1 and v2.
 * If @p topk was specified then the vectors will be no longer than @p topk elements.  In a
 * multi-gpu context, if @p topk is specified all results will return on GPU rank 0, otherwise they
 * will be returned on the local GPU for vertex v1.
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::
  tuple<rmm::device_uvector<vertex_t>, rmm::device_uvector<vertex_t>, rmm::device_uvector<weight_t>>
  jaccard_all_pairs_coefficients(
    raft::handle_t const& handle,
    graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
    std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
    std::optional<raft::device_span<vertex_t const>> vertices,
    std::optional<size_t> topk,
    bool do_expensive_check = false);

/**
.* @ingroup similarity_cpp
 * @brief     Compute Consine all pairs similarity coefficient
 *
 * Similarity is computed for all pairs of vertices.  Note that in a sparse
 * graph, many of the vertex pairs will have a score of zero.  We actually
 * compute similarity only for vertices that are two hop neighbors within
 * the graph, since vertices that are not two hop neighbors will have
 * a score of 0.
 *
 * If @p vertices is specified we will compute similarity on two hop
 * neighbors the @p vertices.  If @p vertices is not specified it will
 * compute similarity on all two hop neighbors in the graph.
 *
 * If @p topk is specified only the top @p topk scoring vertex pairs
 * will be returned, if not specified then scores for all computed vertex pairs
 * will be returned.
 *
 * Note the list of two hop neighbors in the entire graph might be a large
 * number of vertex pairs.  If the graph is dense enough it could be as large
 * as the the number of vertices squared, which might run out of memory.
 *
 * @throws                 cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view. If @p
 * edge_weight_view.has_value() == true, use the weights associated with the graph. If false, assume
 * a weight of 1 for all edges.
 * @param vertices optional device span defining the seed vertices. In a multi-gpu context the
 * vertices should be local to this GPU.
 * @param topk optional specification of the how many of the top scoring vertex pairs should be
 * returned
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 * @return tuple containing three device vectors (v1, v2, score) of the same length.  Corresponding
 * elements in the vectors identify a result, v1 identifying a vertex in the graph, v2 identifying
 * one of v1's two hop neighors, and the score identifying the similarity score between v1 and v2.
 * If @p topk was specified then the vectors will be no longer than @p topk elements.  In a
 * multi-gpu context, if @p topk is specified all results will return on GPU rank 0, otherwise they
 * will be returned on the local GPU for vertex v1.
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::
  tuple<rmm::device_uvector<vertex_t>, rmm::device_uvector<vertex_t>, rmm::device_uvector<weight_t>>
  cosine_similarity_all_pairs_coefficients(
    raft::handle_t const& handle,
    graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
    std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
    std::optional<raft::device_span<vertex_t const>> vertices,
    std::optional<size_t> topk,
    bool do_expensive_check = false);

/**
.* @ingroup similarity_cpp
 * @brief     Compute Sorensen similarity coefficient
 *
 * Similarity is computed for all pairs of vertices.  Note that in a sparse
 * graph, many of the vertex pairs will have a score of zero.  We actually
 * compute similarity only for vertices that are two hop neighbors within
 * the graph, since vertices that are not two hop neighbors will have
 * a score of 0.
 *
 * If @p vertices is specified we will compute similarity on two hop
 * neighbors the @p vertices.  If @p vertices is not specified it will
 * compute similarity on all two hop neighbors in the graph.
 *
 * If @p topk is specified only the top @p topk scoring vertex pairs
 * will be returned, if not specified then scores for all computed vertex pairs
 * will be returned.
 *
 * Note the list of two hop neighbors in the entire graph might be a large
 * number of vertex pairs.  If the graph is dense enough it could be as large
 * as the the number of vertices squared, which might run out of memory.
 *
 * @throws                 cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view. If @p
 * edge_weight_view.has_value() == true, use the weights associated with the graph. If false, assume
 * a weight of 1 for all edges.
 * @param vertices optional device span defining the seed vertices.
 * @param topk optional specification of the how many of the top scoring vertex pairs should be
 * returned
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 * @return tuple containing three device vectors (v1, v2, score) of the same length.  Corresponding
 * elements in the vectors identify a result, v1 identifying a vertex in the graph, v2 identifying
 * one of v1's two hop neighors, and the score identifying the similarity score between v1 and v2.
 * If @p topk was specified then the vectors will be no longer than @p topk elements.  In a
 * multi-gpu context, if @p topk is specified all results will return on GPU rank 0, otherwise they
 * will be returned on the local GPU for vertex v1.
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::
  tuple<rmm::device_uvector<vertex_t>, rmm::device_uvector<vertex_t>, rmm::device_uvector<weight_t>>
  sorensen_all_pairs_coefficients(
    raft::handle_t const& handle,
    graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
    std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
    std::optional<raft::device_span<vertex_t const>> vertices,
    std::optional<size_t> topk,
    bool do_expensive_check = false);

/**
.* @ingroup similarity_cpp
 * @brief     Compute overlap similarity coefficient
 *
 * Similarity is computed for all pairs of vertices.  Note that in a sparse
 * graph, many of the vertex pairs will have a score of zero.  We actually
 * compute similarity only for vertices that are two hop neighbors within
 * the graph, since vertices that are not two hop neighbors will have
 * a score of 0.
 *
 * If @p vertices is specified we will compute similarity on two hop
 * neighbors the @p vertices.  If @p vertices is not specified it will
 * compute similarity on all two hop neighbors in the graph.
 *
 * If @p topk is specified only the top @p topk scoring vertex pairs
 * will be returned, if not specified then scores for all computed vertex pairs
 * will be returned.
 *
 * Note the list of two hop neighbors in the entire graph might be a large
 * number of vertex pairs.  If the graph is dense enough it could be as large
 * as the the number of vertices squared, which might run out of memory.
 *
 * @throws                 cugraph::logic_error when an error occurs.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam weight_t Type of edge weights. Needs to be a floating point type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param edge_weight_view Optional view object holding edge weights for @p graph_view. If @p
 * edge_weight_view.has_value() == true, use the weights associated with the graph. If false, assume
 * a weight of 1 for all edges.
 * @param vertices optional device span defining the seed vertices.
 * @param topk optional specification of the how many of the top scoring vertex pairs should be
 * returned
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 * @return tuple containing three device vectors (v1, v2, score) of the same length.  Corresponding
 * elements in the vectors identify a result, v1 identifying a vertex in the graph, v2 identifying
 * one of v1's two hop neighors, and the score identifying the similarity score between v1 and v2.
 * If @p topk was specified then the vectors will be no longer than @p topk elements.  In a
 * multi-gpu context, if @p topk is specified all results will return on GPU rank 0, otherwise they
 * will be returned on the local GPU for vertex v1.
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::
  tuple<rmm::device_uvector<vertex_t>, rmm::device_uvector<vertex_t>, rmm::device_uvector<weight_t>>
  overlap_all_pairs_coefficients(
    raft::handle_t const& handle,
    graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
    std::optional<edge_property_view_t<edge_t, weight_t const*>> edge_weight_view,
    std::optional<raft::device_span<vertex_t const>> vertices,
    std::optional<size_t> topk,
    bool do_expensive_check = false);

/*
.* @ingroup utility_cpp
 * @brief Enumerate K-hop neighbors
 *
 * Note that the number of K-hop neighbors (and memory footprint) can grow very fast if there are
 * high-degree vertices. Limit the number of start vertices and @p k to avoid rapid increase in
 * memory footprint.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param start_vertices Find K-hop neighbors from each vertex in @p start_vertices.
 * @param k Number of hops to make to enumerate neighbors.
 * @param do_expensive_check A flag to run expensive checks for input arguments (if set to `true`).
 * @return Tuple of two arrays: offsets and K-hop neighbors. The size of the offset array is @p
 * start_vertices.size() + 1. The i'th and (i+1)'th elements of the offset array demarcates the
 * beginning (inclusive) and end (exclusive) of the K-hop neighbors of the i'th element of @p
 * start_vertices, respectively.
 */
template <typename vertex_t, typename edge_t, bool multi_gpu>
std::tuple<rmm::device_uvector<size_t>, rmm::device_uvector<vertex_t>> k_hop_nbrs(
  raft::handle_t const& handle,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  raft::device_span<vertex_t const> start_vertices,
  size_t k,
  bool do_expensive_check = false);

/**
 * @ingroup tree_cpp
 * @brief Find a Maximal Independent Set
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param rng_state The RngState instance holding pseudo-random number generator state.
 * @return A device vector containing vertices in the maximal independent set.
 */
template <typename vertex_t, typename edge_t, bool multi_gpu>
rmm::device_uvector<vertex_t> maximal_independent_set(
  raft::handle_t const& handle,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  raft::random::RngState& rng_state);

/**
 * @ingroup utility_cpp
 * @brief Find a Greedy Vertex Coloring
 *
 * A vertex coloring is an assignment of colors or labels to each vertex of a graph so that
 * no two adjacent vertices have the same color or label. Finding the minimum number of colors
 * needed to color the vertices of a graph is an NP-hard problem and therefore for practical
 * use cases greedy coloring is used. Here we provide an implementation of greedy vertex
 * coloring based on maximal independent set.
 * See
 * https://research.nvidia.com/sites/default/files/pubs/2015-05_Parallel-Graph-Coloring/nvr-2015-001.pdf
 * for further information.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator, and
 * handles to various CUDA libraries) to run graph algorithms.
 * @param graph_view Graph view object.
 * @param rng_state The RngState instance holding pseudo-random number generator state.
 * @return A device vector containing color for each vertex.
 */
template <typename vertex_t, typename edge_t, bool multi_gpu>
rmm::device_uvector<vertex_t> vertex_coloring(
  raft::handle_t const& handle,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  raft::random::RngState& rng_state);

/**
.* @ingroup utility_cpp
 * @brief Approximate Weighted Matching
 *
 * A matching in an undirected graph G = (V, E) is a pairing of adjacent vertices
 * such that each vertex is matched with at most one other vertex, the objective
 * being to match as many vertices as possible or to maximise the sum of the
 * weights of the matched edges. Here we provide an implementation of an
 * approximation algorithm to the weighted Maximum matching. See
 * https://web.archive.org/web/20081031230449id_/http://www.ii.uib.no/~fredrikm/fredrik/papers/CP75.pdf
 * for further information.
 *
 * @tparam vertex_t Type of vertex identifiers. Needs to be an integral type.
 * @tparam edge_t Type of edge identifiers. Needs to be an integral type.
 * @tparam multi_gpu Flag indicating whether template instantiation should target single-GPU (false)
 * @param[in] handle RAFT handle object to encapsulate resources (e.g. CUDA stream, communicator,
 * and handles to various CUDA libraries) to run graph algorithms.
 * @param[in] graph_view Graph view object.
 * @param[in] edge_weight_view View object holding edge weights for @p graph_view.
 * @return A tuple of device vector of matched vertex ids and sum of the weights of the matched
 * edges.
 */
template <typename vertex_t, typename edge_t, typename weight_t, bool multi_gpu>
std::tuple<rmm::device_uvector<vertex_t>, weight_t> approximate_weighted_matching(
  raft::handle_t const& handle,
  graph_view_t<vertex_t, edge_t, false, multi_gpu> const& graph_view,
  edge_property_view_t<edge_t, weight_t const*> edge_weight_view);
}  // namespace cugraph

/**
 * @}
 */
