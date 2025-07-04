# Copyright (c) 2021-2025, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

import cupy as cp
import hdbscan
import numpy as np
import pytest
from sklearn import datasets
from sklearn.datasets import make_blobs
from sklearn.model_selection import train_test_split

import cuml
from cuml.cluster.hdbscan import (
    HDBSCAN,
    all_points_membership_vectors,
    approximate_predict,
    membership_vector,
)
from cuml.cluster.hdbscan.hdbscan import _condense_hierarchy, _extract_clusters
from cuml.internals import logger
from cuml.metrics import adjusted_rand_score
from cuml.testing.datasets import make_pattern
from cuml.testing.utils import array_equal

dataset_names = ["noisy_circles", "noisy_moons", "varied"]


def assert_cluster_counts(sk_agg, cuml_agg, digits=25):
    sk_unique, sk_counts = np.unique(sk_agg.labels_, return_counts=True)
    sk_counts = np.sort(sk_counts)

    cu_unique, cu_counts = cp.unique(cuml_agg.labels_, return_counts=True)
    cu_counts = cp.sort(cu_counts).get()

    np.testing.assert_almost_equal(sk_counts, cu_counts, decimal=-1 * digits)


def get_children(roots, parents, arr):
    """
    Simple helper function to return the children of the condensed tree
    given an array of parents.
    """
    ret = []
    for root in roots:
        level = np.where(parents == root)
        ret.extend(arr[level])

    return np.array(ret).ravel()


def get_bfs_level(n, roots, parents, children, arr):
    """
    Simple helper function to perform a bfs through n
    levels of a condensed tree.
    """
    level = roots
    for i in range(n - 1):
        level = get_children(level, parents, children)

    return get_children(level, parents, arr)


def assert_condensed_trees(sk_agg, min_cluster_size):
    """
    Because of differences in the renumbering and sort ordering,
    the condensed tree arrays from cuml and scikit-learn cannot
    be compared directly. This function performs a BFS through
    the condensed trees, comparing the cluster sizes and lambda
    values at each level of the trees.
    """

    slt = sk_agg.single_linkage_tree_._linkage

    condensed_tree = _condense_hierarchy(slt, min_cluster_size)

    cu_parents = condensed_tree["parent"]
    sk_parents = sk_agg.condensed_tree_._raw_tree["parent"]

    cu_children = condensed_tree["child"]
    sk_children = sk_agg.condensed_tree_._raw_tree["child"]

    cu_lambda = condensed_tree["lambda_val"]
    sk_lambda = sk_agg.condensed_tree_._raw_tree["lambda_val"]

    cu_child_size = condensed_tree["child_size"]
    sk_child_size = sk_agg.condensed_tree_._raw_tree["child_size"]

    # Start at the root, perform bfs

    l2_cu = [1000]
    l2_sk = [1000]

    lev = 1
    while len(l2_cu) != 0 or len(l2_sk) != 0:
        l2_cu = get_bfs_level(lev, [1000], cu_parents, cu_children, cu_lambda)
        l2_sk = get_bfs_level(lev, [1000], sk_parents, sk_children, sk_lambda)

        s2_cu = get_bfs_level(
            lev, [1000], cu_parents, cu_children, cu_child_size
        )
        s2_sk = get_bfs_level(
            lev, [1000], sk_parents, sk_children, sk_child_size
        )

        s2_cu.sort()
        s2_sk.sort()
        l2_cu.sort()
        l2_sk.sort()

        lev += 1

        assert np.allclose(l2_cu, l2_sk, atol=1e-5, rtol=1e-6)
        assert np.allclose(s2_cu, s2_sk, atol=1e-5, rtol=1e-6)
    assert lev > 1


def assert_membership_vectors(cu_vecs, sk_vecs):
    """
    Assert the membership vectors by taking the adjusted rand score
    of the argsorted membership vectors.
    """
    if sk_vecs.shape == cu_vecs.shape:
        cu_labels_sorted = np.argsort(cu_vecs)[::-1]
        sk_labels_sorted = np.argsort(sk_vecs)[::-1]

        k = min(sk_vecs.shape[1], 10)
        for i in range(k):
            assert (
                adjusted_rand_score(
                    cu_labels_sorted[:, i], sk_labels_sorted[:, i]
                )
                >= 0.90
            )


@pytest.mark.parametrize("nrows", [500])
@pytest.mark.parametrize("ncols", [25])
@pytest.mark.parametrize("nclusters", [2, 5])
@pytest.mark.parametrize("min_samples", [25, 60])
@pytest.mark.parametrize("allow_single_cluster", [True, False])
@pytest.mark.parametrize("min_cluster_size", [30, 50])
@pytest.mark.parametrize("cluster_selection_epsilon", [0.0])
@pytest.mark.parametrize("max_cluster_size", [0])
@pytest.mark.parametrize("cluster_selection_method", ["eom", "leaf"])
def test_hdbscan_blobs(
    nrows,
    ncols,
    nclusters,
    cluster_selection_epsilon,
    cluster_selection_method,
    allow_single_cluster,
    min_cluster_size,
    max_cluster_size,
    min_samples,
):

    X, y = make_blobs(
        n_samples=int(nrows),
        n_features=ncols,
        centers=nclusters,
        cluster_std=0.7,
        shuffle=False,
        random_state=42,
    )

    cuml_agg = HDBSCAN(
        verbose=logger.level_enum.info,
        allow_single_cluster=allow_single_cluster,
        min_samples=min_samples,
        max_cluster_size=max_cluster_size,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
    )

    cuml_agg.fit(X)
    sk_agg = hdbscan.HDBSCAN(
        allow_single_cluster=allow_single_cluster,
        approx_min_span_tree=False,
        gen_min_span_tree=True,
        min_samples=min_samples,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        algorithm="generic",
    )

    sk_agg.fit(cp.asnumpy(X))

    assert_condensed_trees(sk_agg, min_cluster_size)
    assert_cluster_counts(sk_agg, cuml_agg)

    assert adjusted_rand_score(cuml_agg.labels_, sk_agg.labels_) >= 0.95
    assert len(np.unique(sk_agg.labels_)) == len(cp.unique(cuml_agg.labels_))

    assert np.allclose(
        np.sort(sk_agg.cluster_persistence_),
        np.sort(cuml_agg.cluster_persistence_),
        rtol=0.01,
        atol=0.01,
    )


@pytest.mark.skipif(
    cp.cuda.driver.get_build_version() <= 11020,
    reason="Test failing on driver 11.2",
)
@pytest.mark.parametrize("cluster_selection_epsilon", [0.0, 50.0, 150.0])
@pytest.mark.parametrize(
    "min_samples_cluster_size_bounds", [(150, 150, 0), (50, 25, 0)]
)
@pytest.mark.parametrize("allow_single_cluster", [True, False])
@pytest.mark.parametrize("cluster_selection_method", ["eom", "leaf"])
def test_hdbscan_sklearn_datasets(
    supervised_learning_dataset,
    cluster_selection_epsilon,
    cluster_selection_method,
    min_samples_cluster_size_bounds,
    allow_single_cluster,
):

    (
        min_samples,
        min_cluster_size,
        max_cluster_size,
    ) = min_samples_cluster_size_bounds

    X = supervised_learning_dataset

    cuml_agg = HDBSCAN(
        verbose=logger.level_enum.info,
        allow_single_cluster=allow_single_cluster,
        gen_min_span_tree=True,
        min_samples=min_samples,
        max_cluster_size=max_cluster_size,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
    )

    cuml_agg.fit(X)

    sk_agg = hdbscan.HDBSCAN(
        allow_single_cluster=allow_single_cluster,
        approx_min_span_tree=False,
        gen_min_span_tree=True,
        min_samples=min_samples,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        algorithm="generic",
    )

    sk_agg.fit(cp.asnumpy(X))

    assert_condensed_trees(sk_agg, min_cluster_size)
    assert_cluster_counts(sk_agg, cuml_agg)

    assert len(np.unique(sk_agg.labels_)) == len(cp.unique(cuml_agg.labels_))
    assert adjusted_rand_score(cuml_agg.labels_, sk_agg.labels_) > 0.85

    assert np.allclose(
        np.sort(sk_agg.cluster_persistence_),
        np.sort(cuml_agg.cluster_persistence_),
        rtol=0.1,
        atol=0.1,
    )


@pytest.mark.parametrize("cluster_selection_epsilon", [0.0, 50.0, 150.0])
@pytest.mark.parametrize("min_samples", [150, 50, 5, 400])
@pytest.mark.parametrize("min_cluster_size", [150, 25, 5, 250])
@pytest.mark.parametrize("max_cluster_size", [0])
@pytest.mark.parametrize("allow_single_cluster", [True, False])
@pytest.mark.parametrize("cluster_selection_method", ["eom", "leaf"])
def test_hdbscan_sklearn_extract_clusters(
    supervised_learning_dataset,
    cluster_selection_epsilon,
    cluster_selection_method,
    min_samples,
    min_cluster_size,
    max_cluster_size,
    allow_single_cluster,
):
    sk_agg = hdbscan.HDBSCAN(
        allow_single_cluster=allow_single_cluster,
        approx_min_span_tree=False,
        gen_min_span_tree=True,
        min_samples=min_samples,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        algorithm="generic",
    )

    sk_agg.fit(supervised_learning_dataset)

    labels, probabilties = _extract_clusters(
        sk_agg.condensed_tree_.to_numpy(),
        allow_single_cluster=allow_single_cluster,
        max_cluster_size=max_cluster_size,
        cluster_selection_method=cluster_selection_method,
        cluster_selection_epsilon=cluster_selection_epsilon,
    )

    assert adjusted_rand_score(labels, sk_agg.labels_) == 1.0
    np.testing.assert_allclose(probabilties, sk_agg.probabilities_, rtol=1e-5)


@pytest.mark.parametrize("nrows", [1000])
@pytest.mark.parametrize("dataset", dataset_names)
@pytest.mark.parametrize("min_samples", [15])
@pytest.mark.parametrize("cluster_selection_epsilon", [0.0])
@pytest.mark.parametrize("min_cluster_size", [25])
@pytest.mark.parametrize("allow_single_cluster", [True, False])
@pytest.mark.parametrize("max_cluster_size", [0])
@pytest.mark.parametrize("cluster_selection_method", ["eom"])
def test_hdbscan_cluster_patterns(
    dataset,
    nrows,
    cluster_selection_epsilon,
    cluster_selection_method,
    min_cluster_size,
    allow_single_cluster,
    max_cluster_size,
    min_samples,
):

    # This also tests duplicate data points
    X, y = make_pattern(dataset, nrows)[0]

    cuml_agg = HDBSCAN(
        verbose=logger.level_enum.info,
        allow_single_cluster=allow_single_cluster,
        min_samples=min_samples,
        max_cluster_size=max_cluster_size,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
    )

    cuml_agg.fit(X)

    sk_agg = hdbscan.HDBSCAN(
        allow_single_cluster=allow_single_cluster,
        approx_min_span_tree=False,
        gen_min_span_tree=True,
        min_samples=min_samples,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        algorithm="generic",
    )

    sk_agg.fit(cp.asnumpy(X))

    assert_condensed_trees(sk_agg, min_cluster_size)
    assert_cluster_counts(sk_agg, cuml_agg)

    assert len(np.unique(sk_agg.labels_)) == len(cp.unique(cuml_agg.labels_))
    assert adjusted_rand_score(cuml_agg.labels_, sk_agg.labels_) > 0.95

    assert np.allclose(
        np.sort(sk_agg.cluster_persistence_),
        np.sort(cuml_agg.cluster_persistence_),
        rtol=0.1,
        atol=0.1,
    )


@pytest.mark.parametrize("nrows", [1000])
@pytest.mark.parametrize("dataset", dataset_names)
@pytest.mark.parametrize("min_samples", [5, 50, 400, 800])
@pytest.mark.parametrize("cluster_selection_epsilon", [0.0, 50.0, 150.0])
@pytest.mark.parametrize("min_cluster_size", [10, 25, 100, 350])
@pytest.mark.parametrize("allow_single_cluster", [True, False])
@pytest.mark.parametrize("max_cluster_size", [0])
@pytest.mark.parametrize("cluster_selection_method", ["eom", "leaf"])
def test_hdbscan_cluster_patterns_extract_clusters(
    dataset,
    nrows,
    cluster_selection_epsilon,
    cluster_selection_method,
    min_cluster_size,
    allow_single_cluster,
    max_cluster_size,
    min_samples,
):

    # This also tests duplicate data points
    X, y = make_pattern(dataset, nrows)[0]

    sk_agg = hdbscan.HDBSCAN(
        allow_single_cluster=allow_single_cluster,
        approx_min_span_tree=False,
        gen_min_span_tree=True,
        min_samples=min_samples,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        algorithm="generic",
    )
    sk_agg.fit(X)

    labels, probabilties = _extract_clusters(
        sk_agg.condensed_tree_.to_numpy(),
        allow_single_cluster=allow_single_cluster,
        max_cluster_size=max_cluster_size,
        cluster_selection_method=cluster_selection_method,
        cluster_selection_epsilon=cluster_selection_epsilon,
    )

    assert adjusted_rand_score(labels, sk_agg.labels_) == 1.0
    np.testing.assert_allclose(probabilties, sk_agg.probabilities_, rtol=1e-5)


def test_hdbscan_core_dists_bug_4054():
    """
    This test explicitly verifies that the MRE from
    https://github.com/rapidsai/cuml/issues/4054
    matches the reference impl
    """

    X, y = datasets.make_moons(n_samples=10000, noise=0.12, random_state=0)

    cu_labels_ = HDBSCAN(min_samples=25, min_cluster_size=25).fit_predict(X)
    sk_labels_ = hdbscan.HDBSCAN(
        min_samples=25, min_cluster_size=25, approx_min_span_tree=False
    ).fit_predict(X)

    assert adjusted_rand_score(cu_labels_, sk_labels_) > 0.99


@pytest.mark.parametrize(
    "metric, supported",
    [("euclidean", True), ("l1", False), ("l2", True), ("abc", False)],
)
def test_hdbscan_metric_parameter_input(metric, supported):
    """
    tests how valid and invalid arguments to the metric
    parameter are handled
    """
    X, y = make_blobs(n_samples=10000, n_features=15, random_state=12)

    clf = HDBSCAN(metric=metric)
    if supported:
        clf.fit(X)
    else:
        with pytest.raises(ValueError):
            clf.fit(X)


def test_hdbscan_empty_cluster_tree():
    raw_tree = np.recarray(
        shape=(5,),
        formats=[np.intp, np.intp, float, np.intp],
        names=("parent", "child", "lambda_val", "child_size"),
    )
    raw_tree["parent"] = np.asarray([5, 5, 5, 5, 5])
    raw_tree["child"] = [0, 1, 2, 3, 4]
    raw_tree["lambda_val"] = [1.0, 1.0, 1.0, 1.0, 1.0]
    raw_tree["child_size"] = [1, 1, 1, 1, 1]

    labels, probabilties = _extract_clusters(
        raw_tree,
        allow_single_cluster=True,
        cluster_selection_method="eom",
    )
    # We just care that all points are assigned to the root cluster
    assert np.sum(labels) == 0


def test_hdbscan_plots():
    X, y = make_blobs(
        n_samples=int(100),
        n_features=100,
        centers=10,
        cluster_std=0.7,
        shuffle=False,
        random_state=42,
    )
    model = HDBSCAN(gen_min_span_tree=True)

    # All attributes not available before fit
    attrs = [
        "condensed_tree_",
        "minimum_spanning_tree_",
        "single_linkage_tree_",
    ]
    for name in attrs:
        assert not hasattr(model, name)

    model.fit(X)

    # All attributes available after fit
    for name in attrs:
        assert getattr(model, name) is not None

    # minimum_spanning_tree_ not available if not requested
    model = HDBSCAN(gen_min_span_tree=False).fit(X)
    assert not hasattr(model, "minimum_spanning_tree_")


@pytest.mark.parametrize("nrows", [1000])
@pytest.mark.parametrize("ncols", [10, 25])
@pytest.mark.parametrize("nclusters", [10, 15])
@pytest.mark.parametrize("allow_single_cluster", [False, True])
@pytest.mark.parametrize("min_cluster_size", [30, 60])
@pytest.mark.parametrize("cluster_selection_epsilon", [0.0, 0.5])
@pytest.mark.parametrize("max_cluster_size", [0])
@pytest.mark.parametrize("cluster_selection_method", ["eom", "leaf"])
@pytest.mark.parametrize("batch_size", [128, 1000])
def test_all_points_membership_vectors_blobs(
    nrows,
    ncols,
    nclusters,
    cluster_selection_epsilon,
    cluster_selection_method,
    min_cluster_size,
    allow_single_cluster,
    max_cluster_size,
    batch_size,
):
    X, y = make_blobs(
        n_samples=nrows,
        n_features=ncols,
        centers=nclusters,
        cluster_std=0.7,
        shuffle=True,
        random_state=42,
    )

    cuml_agg = HDBSCAN(
        verbose=logger.level_enum.info,
        allow_single_cluster=allow_single_cluster,
        max_cluster_size=max_cluster_size,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        prediction_data=True,
    ).fit(X)

    sk_agg = hdbscan.HDBSCAN(
        allow_single_cluster=allow_single_cluster,
        approx_min_span_tree=False,
        gen_min_span_tree=True,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        algorithm="generic",
        prediction_data=True,
    ).fit(X)

    cu_membership_vectors = all_points_membership_vectors(cuml_agg, batch_size)
    cu_membership_vectors.sort(axis=1)
    sk_membership_vectors = hdbscan.all_points_membership_vectors(
        sk_agg
    ).astype("float32")
    sk_membership_vectors.sort(axis=1)
    assert_membership_vectors(cu_membership_vectors, sk_membership_vectors)


@pytest.mark.parametrize("nrows", [1000])
@pytest.mark.parametrize("min_samples", [5, 15])
@pytest.mark.parametrize("min_cluster_size", [300, 500])
@pytest.mark.parametrize("cluster_selection_epsilon", [0.0, 0.5])
@pytest.mark.parametrize("allow_single_cluster", [True, False])
@pytest.mark.parametrize("max_cluster_size", [0])
@pytest.mark.parametrize("cluster_selection_method", ["eom", "leaf"])
@pytest.mark.parametrize("batch_size", [128, 1000])
def test_all_points_membership_vectors_moons(
    nrows,
    min_samples,
    cluster_selection_epsilon,
    cluster_selection_method,
    min_cluster_size,
    allow_single_cluster,
    max_cluster_size,
    batch_size,
):

    X, y = datasets.make_moons(n_samples=nrows, noise=0.05, random_state=42)

    cuml_agg = HDBSCAN(
        verbose=logger.level_enum.info,
        min_samples=min_samples,
        allow_single_cluster=allow_single_cluster,
        max_cluster_size=max_cluster_size,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        prediction_data=True,
    )
    cuml_agg.fit(X)

    sk_agg = hdbscan.HDBSCAN(
        min_samples=min_samples,
        allow_single_cluster=allow_single_cluster,
        approx_min_span_tree=False,
        gen_min_span_tree=True,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        algorithm="generic",
        prediction_data=True,
    )

    sk_agg.fit(X)

    cu_membership_vectors = all_points_membership_vectors(cuml_agg, batch_size)
    sk_membership_vectors = hdbscan.all_points_membership_vectors(
        sk_agg
    ).astype("float32")

    assert_membership_vectors(cu_membership_vectors, sk_membership_vectors)


@pytest.mark.parametrize("nrows", [1000])
@pytest.mark.parametrize("min_samples", [5, 15])
@pytest.mark.parametrize("min_cluster_size", [300, 500])
@pytest.mark.parametrize("cluster_selection_epsilon", [0.0, 0.5])
@pytest.mark.parametrize("allow_single_cluster", [True, False])
@pytest.mark.parametrize("max_cluster_size", [0])
@pytest.mark.parametrize("cluster_selection_method", ["eom", "leaf"])
@pytest.mark.parametrize("batch_size", [128, 1000])
def test_all_points_membership_vectors_circles(
    nrows,
    min_samples,
    cluster_selection_epsilon,
    cluster_selection_method,
    min_cluster_size,
    allow_single_cluster,
    max_cluster_size,
    batch_size,
):
    X, y = datasets.make_circles(
        n_samples=nrows, factor=0.5, noise=0.05, random_state=42
    )

    cuml_agg = HDBSCAN(
        verbose=logger.level_enum.info,
        min_samples=min_samples,
        allow_single_cluster=allow_single_cluster,
        max_cluster_size=max_cluster_size,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        prediction_data=True,
    )
    cuml_agg.fit(X)

    sk_agg = hdbscan.HDBSCAN(
        min_samples=min_samples,
        allow_single_cluster=allow_single_cluster,
        approx_min_span_tree=False,
        gen_min_span_tree=True,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        algorithm="generic",
        prediction_data=True,
    )

    sk_agg.fit(X)

    cu_membership_vectors = all_points_membership_vectors(cuml_agg, batch_size)
    sk_membership_vectors = hdbscan.all_points_membership_vectors(
        sk_agg
    ).astype("float32")

    assert_membership_vectors(cu_membership_vectors, sk_membership_vectors)


@pytest.mark.skipif(
    cp.cuda.driver.get_build_version() <= 11020,
    reason="Test failing on driver 11.2",
)
@pytest.mark.parametrize("nrows", [1000])
@pytest.mark.parametrize("n_points_to_predict", [200, 500])
@pytest.mark.parametrize("ncols", [10, 25])
@pytest.mark.parametrize("nclusters", [15])
@pytest.mark.parametrize("min_cluster_size", [30, 60])
@pytest.mark.parametrize("cluster_selection_epsilon", [0.0, 0.5])
@pytest.mark.parametrize("max_cluster_size", [0])
@pytest.mark.parametrize("allow_single_cluster", [True, False])
@pytest.mark.parametrize("cluster_selection_method", ["eom", "leaf"])
def test_approximate_predict_blobs(
    nrows,
    n_points_to_predict,
    ncols,
    nclusters,
    cluster_selection_epsilon,
    cluster_selection_method,
    min_cluster_size,
    max_cluster_size,
    allow_single_cluster,
):
    X, y = make_blobs(
        n_samples=nrows,
        n_features=ncols,
        centers=nclusters,
        cluster_std=0.7,
        shuffle=True,
        random_state=42,
    )

    points_to_predict, _ = make_blobs(
        n_samples=n_points_to_predict,
        n_features=ncols,
        centers=nclusters,
        cluster_std=0.7,
        shuffle=True,
        random_state=42,
    )

    cuml_agg = HDBSCAN(
        verbose=logger.level_enum.info,
        allow_single_cluster=allow_single_cluster,
        max_cluster_size=max_cluster_size,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        prediction_data=True,
    )
    cuml_agg.fit(X)

    sk_agg = hdbscan.HDBSCAN(
        allow_single_cluster=allow_single_cluster,
        approx_min_span_tree=False,
        gen_min_span_tree=True,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        algorithm="generic",
        prediction_data=True,
    )

    sk_agg.fit(cp.asnumpy(X))

    cu_labels, cu_probs = approximate_predict(cuml_agg, points_to_predict)
    sk_labels, sk_probs = hdbscan.approximate_predict(
        sk_agg, points_to_predict
    )

    assert adjusted_rand_score(cu_labels, sk_labels) >= 0.95
    assert np.allclose(cu_probs, sk_probs, atol=0.05)


@pytest.mark.parametrize("nrows", [1000])
@pytest.mark.parametrize("n_points_to_predict", [50])
@pytest.mark.parametrize("min_samples", [15, 30])
@pytest.mark.parametrize("cluster_selection_epsilon", [0.0, 0.5])
@pytest.mark.parametrize("min_cluster_size", [5, 15])
@pytest.mark.parametrize("allow_single_cluster", [True, False])
@pytest.mark.parametrize("max_cluster_size", [0])
@pytest.mark.parametrize("cluster_selection_method", ["eom", "leaf"])
def test_approximate_predict_moons(
    nrows,
    n_points_to_predict,
    min_samples,
    cluster_selection_epsilon,
    min_cluster_size,
    allow_single_cluster,
    max_cluster_size,
    cluster_selection_method,
):

    X, y = datasets.make_moons(
        n_samples=nrows + n_points_to_predict, noise=0.05, random_state=42
    )

    X_train = X[:nrows]
    X_test = X[nrows:]

    cuml_agg = HDBSCAN(
        verbose=logger.level_enum.info,
        allow_single_cluster=allow_single_cluster,
        min_samples=min_samples,
        max_cluster_size=max_cluster_size,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        prediction_data=True,
    )

    cuml_agg.fit(X_train)

    sk_agg = hdbscan.HDBSCAN(
        allow_single_cluster=allow_single_cluster,
        approx_min_span_tree=False,
        gen_min_span_tree=True,
        min_samples=min_samples,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        algorithm="generic",
        prediction_data=True,
    )

    sk_agg.fit(cp.asnumpy(X_train))

    cu_labels, cu_probs = approximate_predict(cuml_agg, X_test)
    sk_labels, sk_probs = hdbscan.approximate_predict(sk_agg, X_test)

    sk_unique = np.unique(sk_labels)
    cu_unique = np.unique(cu_labels)
    if len(sk_unique) == len(cu_unique):
        assert adjusted_rand_score(cu_labels, sk_labels) >= 0.99
        assert array_equal(cu_probs, sk_probs, unit_tol=0.05, total_tol=0.005)


@pytest.mark.parametrize("nrows", [1000])
@pytest.mark.parametrize("n_points_to_predict", [50])
@pytest.mark.parametrize("min_samples", [5, 15])
@pytest.mark.parametrize("cluster_selection_epsilon", [0.0, 0.5])
@pytest.mark.parametrize("min_cluster_size", [50, 100])
@pytest.mark.parametrize("allow_single_cluster", [True, False])
@pytest.mark.parametrize("max_cluster_size", [0])
@pytest.mark.parametrize("cluster_selection_method", ["eom", "leaf"])
def test_approximate_predict_circles(
    nrows,
    n_points_to_predict,
    min_samples,
    cluster_selection_epsilon,
    min_cluster_size,
    allow_single_cluster,
    max_cluster_size,
    cluster_selection_method,
):
    X, y = datasets.make_circles(
        n_samples=nrows + n_points_to_predict,
        factor=0.8,
        noise=0.05,
        random_state=42,
    )

    X_train = X[:nrows]
    X_test = X[nrows:]

    cuml_agg = HDBSCAN(
        verbose=logger.level_enum.info,
        allow_single_cluster=allow_single_cluster,
        min_samples=min_samples,
        max_cluster_size=max_cluster_size,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        prediction_data=True,
    )

    cuml_agg.fit(X_train)

    sk_agg = hdbscan.HDBSCAN(
        allow_single_cluster=allow_single_cluster,
        approx_min_span_tree=False,
        gen_min_span_tree=True,
        min_samples=min_samples,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        algorithm="generic",
        prediction_data=True,
    )

    sk_agg.fit(cp.asnumpy(X_train))

    cu_labels, cu_probs = approximate_predict(cuml_agg, X_test)
    sk_labels, sk_probs = hdbscan.approximate_predict(sk_agg, X_test)

    sk_unique = np.unique(sk_labels)
    cu_unique = np.unique(cu_labels)
    if len(sk_unique) == len(cu_unique):
        assert adjusted_rand_score(cu_labels, sk_labels) >= 0.99
        assert array_equal(cu_probs, sk_probs, unit_tol=0.05, total_tol=0.005)


@pytest.mark.parametrize("n_points_to_predict", [200])
@pytest.mark.parametrize("min_samples", [15])
@pytest.mark.parametrize("cluster_selection_epsilon", [0.5])
@pytest.mark.parametrize("min_cluster_size", [100])
@pytest.mark.parametrize("allow_single_cluster", [False])
@pytest.mark.parametrize("max_cluster_size", [0])
@pytest.mark.parametrize("cluster_selection_method", ["eom"])
def test_approximate_predict_digits(
    n_points_to_predict,
    min_samples,
    cluster_selection_epsilon,
    min_cluster_size,
    allow_single_cluster,
    max_cluster_size,
    cluster_selection_method,
):
    digits = datasets.load_digits()
    X, y = digits.data, digits.target

    X_train, X_test, y_train, y_test = train_test_split(
        X,
        y,
        test_size=n_points_to_predict,
        train_size=X.shape[0] - n_points_to_predict,
        random_state=42,
        shuffle=True,
        stratify=y,
    )

    cuml_agg = HDBSCAN(
        verbose=logger.level_enum.info,
        allow_single_cluster=allow_single_cluster,
        min_samples=min_samples,
        max_cluster_size=max_cluster_size,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        prediction_data=True,
    )

    cuml_agg.fit(X_train)

    sk_agg = hdbscan.HDBSCAN(
        allow_single_cluster=allow_single_cluster,
        approx_min_span_tree=False,
        gen_min_span_tree=True,
        min_samples=min_samples,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        algorithm="generic",
        prediction_data=True,
    )

    sk_agg.fit(X_train)

    cu_labels, cu_probs = approximate_predict(cuml_agg, X_test)
    sk_labels, sk_probs = hdbscan.approximate_predict(sk_agg, X_test)

    assert adjusted_rand_score(cu_labels, sk_labels) >= 0.98
    assert array_equal(cu_probs, sk_probs, unit_tol=0.001, total_tol=0.006)


@pytest.mark.parametrize("nrows", [1000])
@pytest.mark.parametrize("n_points_to_predict", [200, 500])
@pytest.mark.parametrize("ncols", [10, 25])
@pytest.mark.parametrize("nclusters", [15])
@pytest.mark.parametrize("min_cluster_size", [30, 60])
@pytest.mark.parametrize("cluster_selection_epsilon", [0.0, 0.5])
@pytest.mark.parametrize("max_cluster_size", [0])
@pytest.mark.parametrize("allow_single_cluster", [True, False])
@pytest.mark.parametrize("cluster_selection_method", ["eom", "leaf"])
@pytest.mark.parametrize("batch_size", [128])
def test_membership_vector_blobs(
    nrows,
    n_points_to_predict,
    ncols,
    nclusters,
    cluster_selection_epsilon,
    cluster_selection_method,
    min_cluster_size,
    allow_single_cluster,
    max_cluster_size,
    batch_size,
):
    X, y = make_blobs(
        n_samples=nrows,
        n_features=ncols,
        centers=nclusters,
        cluster_std=0.7,
        shuffle=True,
        random_state=42,
    )

    points_to_predict, _ = make_blobs(
        n_samples=n_points_to_predict,
        n_features=ncols,
        centers=nclusters,
        cluster_std=0.7,
        shuffle=True,
        random_state=42,
    )

    cuml_agg = HDBSCAN(
        verbose=logger.level_enum.info,
        allow_single_cluster=allow_single_cluster,
        max_cluster_size=max_cluster_size,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        prediction_data=True,
    )
    cuml_agg.fit(X)

    sk_agg = hdbscan.HDBSCAN(
        allow_single_cluster=allow_single_cluster,
        approx_min_span_tree=False,
        gen_min_span_tree=True,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        algorithm="generic",
        prediction_data=True,
    )

    sk_agg.fit(cp.asnumpy(X))

    cu_membership_vectors = membership_vector(
        cuml_agg, points_to_predict, batch_size
    )
    cu_membership_vectors.sort(axis=1)
    sk_membership_vectors = hdbscan.membership_vector(
        sk_agg,
        points_to_predict,
    ).astype("float32")
    sk_membership_vectors.sort(axis=1)
    assert_membership_vectors(cu_membership_vectors, sk_membership_vectors)


@pytest.mark.parametrize("nrows", [1000])
@pytest.mark.parametrize("n_points_to_predict", [50])
@pytest.mark.parametrize("min_samples", [5, 15])
@pytest.mark.parametrize("min_cluster_size", [300, 500])
@pytest.mark.parametrize("cluster_selection_epsilon", [0.0, 0.5])
@pytest.mark.parametrize("allow_single_cluster", [True, False])
@pytest.mark.parametrize("max_cluster_size", [0])
@pytest.mark.parametrize("cluster_selection_method", ["eom", "leaf"])
@pytest.mark.parametrize("batch_size", [16])
def test_membership_vector_moons(
    nrows,
    n_points_to_predict,
    min_samples,
    cluster_selection_epsilon,
    cluster_selection_method,
    min_cluster_size,
    allow_single_cluster,
    max_cluster_size,
    batch_size,
):

    X, y = datasets.make_moons(
        n_samples=nrows + n_points_to_predict, noise=0.05, random_state=42
    )

    X_train = X[:nrows]
    X_test = X[nrows:]

    cuml_agg = HDBSCAN(
        verbose=logger.level_enum.info,
        min_samples=min_samples,
        allow_single_cluster=allow_single_cluster,
        max_cluster_size=max_cluster_size,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        prediction_data=True,
    )
    cuml_agg.fit(X_train)

    sk_agg = hdbscan.HDBSCAN(
        min_samples=min_samples,
        allow_single_cluster=allow_single_cluster,
        approx_min_span_tree=False,
        gen_min_span_tree=True,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        algorithm="generic",
        prediction_data=True,
    )

    sk_agg.fit(X_train)

    cu_membership_vectors = membership_vector(cuml_agg, X_test, batch_size)
    sk_membership_vectors = hdbscan.membership_vector(sk_agg, X_test).astype(
        "float32"
    )

    assert_membership_vectors(cu_membership_vectors, sk_membership_vectors)


@pytest.mark.parametrize("nrows", [1000])
@pytest.mark.parametrize("n_points_to_predict", [50])
@pytest.mark.parametrize("min_samples", [20, 30])
@pytest.mark.parametrize("min_cluster_size", [100, 150])
@pytest.mark.parametrize("cluster_selection_epsilon", [0.0, 0.5])
@pytest.mark.parametrize("allow_single_cluster", [True, False])
@pytest.mark.parametrize("max_cluster_size", [0])
@pytest.mark.parametrize("cluster_selection_method", ["eom", "leaf"])
@pytest.mark.parametrize("batch_size", [16])
def test_membership_vector_circles(
    nrows,
    n_points_to_predict,
    min_samples,
    cluster_selection_epsilon,
    cluster_selection_method,
    min_cluster_size,
    allow_single_cluster,
    max_cluster_size,
    batch_size,
):
    X, y = datasets.make_circles(
        n_samples=nrows + n_points_to_predict,
        factor=0.8,
        noise=0.05,
        random_state=42,
    )

    X_train = X[:nrows]
    X_test = X[nrows:]

    cuml_agg = HDBSCAN(
        verbose=logger.level_enum.info,
        min_samples=min_samples,
        allow_single_cluster=allow_single_cluster,
        max_cluster_size=max_cluster_size,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        prediction_data=True,
    )
    cuml_agg.fit(X_train)

    sk_agg = hdbscan.HDBSCAN(
        min_samples=min_samples,
        allow_single_cluster=allow_single_cluster,
        approx_min_span_tree=False,
        gen_min_span_tree=True,
        min_cluster_size=min_cluster_size,
        cluster_selection_epsilon=cluster_selection_epsilon,
        cluster_selection_method=cluster_selection_method,
        algorithm="generic",
        prediction_data=True,
    )

    sk_agg.fit(X_train)

    cu_membership_vectors = membership_vector(cuml_agg, X_test, batch_size)
    sk_membership_vectors = hdbscan.membership_vector(sk_agg, X_test).astype(
        "float32"
    )

    assert_membership_vectors(cu_membership_vectors, sk_membership_vectors)


def test_prediction_namespace_deprecated():
    # Attribute access warns
    with pytest.warns(FutureWarning, match="all_points_membership_vectors"):
        func = cuml.cluster.hdbscan.prediction.all_points_membership_vectors

    assert func is cuml.cluster.hdbscan.all_points_membership_vectors

    # Imports warn
    with pytest.warns(FutureWarning, match="all_points_membership_vectors"):
        from cuml.cluster.hdbscan.prediction import (
            all_points_membership_vectors as func,
        )

    assert func is cuml.cluster.hdbscan.all_points_membership_vectors
