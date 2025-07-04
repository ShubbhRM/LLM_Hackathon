# Copyright (c) 2019-2025, NVIDIA CORPORATION.
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

import pickle

import numpy as np
import pytest
import scipy.sparse as scipy_sparse
from sklearn.base import clone
from sklearn.datasets import load_iris, make_classification, make_regression
from sklearn.manifold import trustworthiness
from sklearn.model_selection import train_test_split

import cuml
from cuml.testing.utils import (
    ClassEnumerator,
    array_equal,
    compare_probabilistic_svm,
    compare_svm,
    get_all_base_subclasses,
    stress_param,
    unit_param,
)
from cuml.tsa.arima import ARIMA

regression_config = ClassEnumerator(module=cuml.linear_model)
regression_models = regression_config.get_models()

solver_config = ClassEnumerator(
    module=cuml.solvers,
    # QN uses softmax here because some of the tests uses multiclass
    # logistic regression which requires a softmax loss
    custom_constructors={"QN": lambda: cuml.QN(loss="softmax")},
)
solver_models = solver_config.get_models()

cluster_config = ClassEnumerator(
    module=cuml.cluster,
    exclude_classes=[cuml.DBSCAN, cuml.AgglomerativeClustering, cuml.HDBSCAN],
)
cluster_models = cluster_config.get_models()

decomposition_config = ClassEnumerator(module=cuml.decomposition)
decomposition_models = decomposition_config.get_models()

decomposition_config_xfail = ClassEnumerator(module=cuml.random_projection)
decomposition_models_xfail = decomposition_config_xfail.get_models()

neighbor_config = ClassEnumerator(
    module=cuml.neighbors, exclude_classes=[cuml.neighbors.KernelDensity]
)
neighbor_models = neighbor_config.get_models()

dbscan_model = {"DBSCAN": cuml.DBSCAN}

agglomerative_model = {"AgglomerativeClustering": cuml.AgglomerativeClustering}

hdbscan_model = {"HDBSCAN": cuml.HDBSCAN}

umap_model = {"UMAP": cuml.UMAP}

rf_module = ClassEnumerator(module=cuml.ensemble)
rf_models = rf_module.get_models()

k_neighbors_config = ClassEnumerator(
    module=cuml.neighbors,
    exclude_classes=[
        cuml.neighbors.NearestNeighbors,
        cuml.neighbors.KernelDensity,
    ],
)
k_neighbors_models = k_neighbors_config.get_models()

unfit_pickle_xfail = [
    "ARIMA",
    "AutoARIMA",
    "KalmanFilter",
    "BaseRandomForestModel",
    "ForestInference",
    "MulticlassClassifier",
    "OneVsOneClassifier",
    "OneVsRestClassifier",
]
unfit_clone_xfail = [
    "AutoARIMA",
    "ARIMA",
    "BaseRandomForestModel",
    "GaussianRandomProjection",
    "MulticlassClassifier",
    "OneVsOneClassifier",
    "OneVsRestClassifier",
    "SparseRandomProjection",
    "UMAP",
]

all_models = get_all_base_subclasses()
all_models.update(
    {
        **regression_models,
        **solver_models,
        **cluster_models,
        **decomposition_models,
        **decomposition_models_xfail,
        **neighbor_models,
        **dbscan_model,
        **hdbscan_model,
        **agglomerative_model,
        **umap_model,
        **rf_models,
        **k_neighbors_models,
        "ARIMA": lambda: ARIMA(np.random.normal(0.0, 1.0, (10,))),
        "ExponentialSmoothing": lambda: cuml.ExponentialSmoothing(
            np.array([-217.72, -206.77])
        ),
    }
)


def pickle_save_load(tmpdir, func_create_model, func_assert):
    model, X_test = func_create_model()
    pickle_file = tmpdir.join("cu_model.pickle")
    try:
        with open(pickle_file, "wb") as pf:
            pickle.dump(model, pf)
    except (TypeError, ValueError) as e:
        pf.close()
        pytest.fail(e)

    del model

    with open(pickle_file, "rb") as pf:
        cu_after_pickle_model = pickle.load(pf)

    func_assert(cu_after_pickle_model, X_test)


def make_classification_dataset(datatype, nrows, ncols, n_info, n_classes):
    X, y = make_classification(
        n_samples=nrows,
        n_features=ncols,
        n_informative=n_info,
        n_classes=n_classes,
        random_state=0,
    )
    X = X.astype(datatype)
    y = y.astype(np.int32)
    X_train, X_test, y_train, y_test = train_test_split(X, y, train_size=0.8)
    return X_train, y_train, X_test


def make_dataset(datatype, nrows, ncols, n_info):
    X, y = make_regression(
        n_samples=nrows, n_features=ncols, n_informative=n_info, random_state=0
    )
    X = X.astype(datatype)
    y = y.astype(datatype)
    X_train, X_test, y_train, y_test = train_test_split(X, y, train_size=0.8)
    return X_train, y_train, X_test


@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize("key", rf_models.keys())
@pytest.mark.parametrize("nrows", [unit_param(500)])
@pytest.mark.parametrize("ncols", [unit_param(16)])
@pytest.mark.parametrize("n_info", [unit_param(7)])
@pytest.mark.parametrize("n_classes", [unit_param(2), unit_param(5)])
def test_rf_regression_pickle(
    tmpdir, datatype, nrows, ncols, n_info, n_classes, key
):

    result = {}
    if datatype == np.float64:
        pytest.xfail(
            "Pickling is not supported for dataset with" " dtype float64"
        )

    def create_mod():
        if key == "RandomForestRegressor":
            X_train, y_train, X_test = make_dataset(
                datatype, nrows, ncols, n_info
            )
        else:
            X_train, y_train, X_test = make_classification_dataset(
                datatype, nrows, ncols, n_info, n_classes
            )

        model = rf_models[key]()

        model.fit(X_train, y_train)
        if datatype == np.float32:
            predict_model = "GPU"
        else:
            predict_model = "CPU"
        result["rf_res"] = model.predict(X_test, predict_model=predict_model)
        return model, X_test

    def assert_model(pickled_model, X_test):

        assert array_equal(result["rf_res"], pickled_model.predict(X_test))
        # Confirm no crash from score
        pickled_model.score(
            X_test, np.zeros(X_test.shape[0]), predict_model="GPU"
        )

        pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize("keys", regression_models.keys())
@pytest.mark.parametrize(
    "data_size", [unit_param([500, 20, 10]), stress_param([500000, 1000, 500])]
)
@pytest.mark.parametrize("fit_intercept", [True, False])
def test_regressor_pickle(tmpdir, datatype, keys, data_size, fit_intercept):
    if (
        data_size[0] == 500000
        and datatype == np.float64
        and ("LogisticRegression" in keys or "Ridge" in keys)
        and pytest.max_gpu_memory < 32
    ):
        if pytest.adapt_stress_test:
            data_size[0] = data_size[0] * pytest.max_gpu_memory // 640
            data_size[1] = data_size[1] * pytest.max_gpu_memory // 640
            data_size[2] = data_size[2] * pytest.max_gpu_memory // 640
        else:
            pytest.skip(
                "Insufficient GPU memory for this test."
                "Re-run with 'CUML_ADAPT_STRESS_TESTS=True'"
            )
    result = {}

    def create_mod():
        nrows, ncols, n_info = data_size
        if "LogisticRegression" in keys and nrows == 500000:
            nrows, ncols, n_info = (nrows // 20, ncols // 20, n_info // 20)

        X_train, y_train, X_test = make_dataset(datatype, nrows, ncols, n_info)
        if "MBSGD" in keys:
            model = regression_models[keys](
                fit_intercept=fit_intercept, batch_size=nrows / 100
            )
        else:
            model = regression_models[keys](fit_intercept=fit_intercept)
        model.fit(X_train, y_train)
        result["regressor"] = model.predict(X_test)
        return model, X_test

    def assert_model(pickled_model, X_test):
        assert array_equal(result["regressor"], pickled_model.predict(X_test))

    pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize("keys", solver_models.keys())
@pytest.mark.parametrize(
    "data_size", [unit_param([500, 20, 10]), stress_param([500000, 1000, 500])]
)
def test_solver_pickle(tmpdir, datatype, keys, data_size):
    result = {}

    def create_mod():
        nrows, ncols, n_info = data_size
        if "QN" in keys and nrows == 500000:
            nrows, ncols, n_info = (nrows // 20, ncols // 20, n_info // 20)

        X_train, y_train, X_test = make_dataset(datatype, nrows, ncols, n_info)
        model = solver_models[keys]()
        model.fit(X_train, y_train)
        result["solver"] = model.predict(X_test)
        return model, X_test

    def assert_model(pickled_model, X_test):
        assert array_equal(result["solver"], pickled_model.predict(X_test))

    pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize("keys", cluster_models.keys())
@pytest.mark.parametrize(
    "data_size", [unit_param([500, 20, 10]), stress_param([500000, 1000, 500])]
)
def test_cluster_pickle(tmpdir, datatype, keys, data_size):
    result = {}

    def create_mod():
        nrows, ncols, n_info = data_size
        X_train, y_train, X_test = make_dataset(datatype, nrows, ncols, n_info)
        if keys == "KMeans":
            model = cluster_models[keys](n_init="auto")
        else:
            model = cluster_models[keys]()
        model.fit(X_train)
        result["cluster"] = model.predict(X_test)
        return model, X_test

    def assert_model(pickled_model, X_test):
        assert array_equal(result["cluster"], pickled_model.predict(X_test))

    pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize("keys", decomposition_models_xfail.values())
@pytest.mark.parametrize(
    "data_size", [unit_param([500, 20, 10]), stress_param([500000, 1000, 500])]
)
@pytest.mark.xfail
def test_decomposition_pickle(tmpdir, datatype, keys, data_size):
    result = {}

    def create_mod():
        nrows, ncols, n_info = data_size
        X_train, y_train, X_test = make_dataset(datatype, nrows, ncols, n_info)
        model = decomposition_models_xfail[keys]()
        result["decomposition"] = model.fit_transform(X_train)
        return model, X_train

    def assert_model(pickled_model, X_test):
        assert array_equal(
            result["decomposition"], pickled_model.transform(X_test)
        )

    pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize("keys", umap_model.keys())
def test_umap_pickle(tmpdir, datatype, keys):
    result = {}

    def create_mod():
        X_train = load_iris().data

        model = umap_model[keys](output_type="numpy")
        cu_before_pickle_transform = model.fit_transform(X_train)

        result["umap_embedding"] = model.embedding_
        n_neighbors = model.n_neighbors

        result["umap"] = trustworthiness(
            X_train, cu_before_pickle_transform, n_neighbors=n_neighbors
        )
        return model, X_train

    def assert_model(pickled_model, X_train):
        cu_after_embed = pickled_model.embedding_

        n_neighbors = pickled_model.n_neighbors
        assert array_equal(result["umap_embedding"], cu_after_embed)

        cu_trust_after = trustworthiness(
            X_train, pickled_model.transform(X_train), n_neighbors=n_neighbors
        )
        assert cu_trust_after >= result["umap"] - 0.2

    pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize("keys", decomposition_models.keys())
@pytest.mark.parametrize(
    "data_size", [unit_param([500, 20, 10]), stress_param([500000, 1000, 500])]
)
@pytest.mark.xfail
def test_decomposition_pickle_xfail(tmpdir, datatype, keys, data_size):
    result = {}

    def create_mod():
        nrows, ncols, n_info = data_size
        X_train, _, _ = make_dataset(datatype, nrows, ncols, n_info)
        model = decomposition_models[keys]()
        result["decomposition"] = model.fit_transform(X_train)
        return model, X_train

    def assert_model(pickled_model, X_test):
        assert array_equal(
            result["decomposition"], pickled_model.transform(X_test)
        )

    pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("model_name", all_models.keys())
@pytest.mark.filterwarnings(
    "ignore:Transformers((.|\n)*):UserWarning:" "cuml[.*]"
)
def test_unfit_pickle(model_name):
    # Any model xfailed in this test cannot be used for hyperparameter sweeps
    # with dask or sklearn
    if (
        model_name in decomposition_models_xfail.keys()
        or model_name in unfit_pickle_xfail
    ):
        pytest.xfail()

    # Pickling should work even if fit has not been called
    mod = all_models[model_name]()
    mod_pickled_bytes = pickle.dumps(mod)
    mod_unpickled = pickle.loads(mod_pickled_bytes)
    assert mod_unpickled is not None


@pytest.mark.parametrize("model_name", all_models.keys())
@pytest.mark.filterwarnings(
    "ignore:Transformers((.|\n)*):UserWarning:" "cuml[.*]"
)
@pytest.mark.filterwarnings("ignore::FutureWarning")
def test_unfit_clone(model_name):
    if model_name in unfit_clone_xfail:
        pytest.xfail()

    # Cloning runs into many of the same problems as pickling
    mod = all_models[model_name]()

    clone(mod)
    # TODO: check parameters exactly?


@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize("keys", neighbor_models.keys())
@pytest.mark.parametrize(
    "data_info",
    [unit_param([500, 20, 10, 5]), stress_param([500000, 1000, 500, 50])],
)
def test_neighbors_pickle(tmpdir, datatype, keys, data_info):
    if (
        data_info[0] == 500000
        and pytest.max_gpu_memory < 32
        and ("KNeighborsClassifier" in keys or "KNeighborsRegressor" in keys)
    ):
        if pytest.adapt_stress_test:
            data_info[0] = data_info[0] * pytest.max_gpu_memory // 32
        else:
            pytest.skip(
                "Insufficient GPU memory for this test."
                "Re-run with 'CUML_ADAPT_STRESS_TESTS=True'"
            )

    result = {}

    def create_mod():
        nrows, ncols, n_info, k = data_info
        X_train, y_train, X_test = make_dataset(datatype, nrows, ncols, n_info)

        model = neighbor_models[keys]()
        if keys in k_neighbors_models.keys():
            model.fit(X_train, y_train)
        else:
            model.fit(X_train)
        result["neighbors_D"], result["neighbors_I"] = model.kneighbors(
            X_test, n_neighbors=k
        )
        return model, X_test

    def assert_model(pickled_model, X_test):
        D_after, I_after = pickled_model.kneighbors(
            X_test, n_neighbors=data_info[3]
        )
        assert array_equal(result["neighbors_D"], D_after)
        assert array_equal(result["neighbors_I"], I_after)

    pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize(
    "data_info",
    [
        unit_param([500, 20, 10, 3, 5]),
        stress_param([500000, 1000, 500, 10, 50]),
    ],
)
@pytest.mark.parametrize("keys", k_neighbors_models.keys())
def test_k_neighbors_classifier_pickle(tmpdir, datatype, data_info, keys):
    if (
        data_info[0] == 500000
        and "NearestNeighbors" in keys
        and pytest.max_gpu_memory < 32
    ):
        if pytest.adapt_stress_test:
            data_info[0] = data_info[0] * pytest.max_gpu_memory // 32
        else:
            pytest.skip(
                "Insufficient GPU memory for this test."
                "Re-run with 'CUML_ADAPT_STRESS_TESTS=True'"
            )
    result = {}

    def create_mod():
        nrows, ncols, n_info, n_classes, k = data_info
        X_train, y_train, X_test = make_classification_dataset(
            datatype, nrows, ncols, n_info, n_classes
        )
        model = k_neighbors_models[keys](n_neighbors=k)
        model.fit(X_train, y_train)
        result["neighbors"] = model.predict(X_test)
        return model, X_test

    def assert_model(pickled_model, X_test):
        D_after = pickled_model.predict(X_test)
        assert array_equal(result["neighbors"], D_after)
        state = pickled_model.__dict__
        assert state["n_indices"] == 1
        assert "_fit_X" in state

    pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize(
    "data_info",
    [unit_param([500, 20, 10, 5]), stress_param([500000, 1000, 500, 50])],
)
def test_neighbors_pickle_nofit(tmpdir, datatype, data_info):
    result = {}
    """
    .. note:: This test digs down a bit far into the
    internals of the implementation, but it's
    important that regressions do not occur
    from changes to the class.
    """

    def create_mod():
        nrows, ncols, n_info, k = data_info
        X_train, _, X_test = make_dataset(datatype, nrows, ncols, n_info)
        model = cuml.neighbors.NearestNeighbors()
        result["model"] = model
        return model, [X_train, X_test]

    def assert_model(loaded_model, X):
        state = loaded_model.__dict__
        assert state["n_indices"] == 0
        assert "_fit_X" not in state
        loaded_model.fit(X[0])

        state = loaded_model.__dict__

        assert state["n_indices"] == 1
        assert "_fit_X" in state

    pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize("keys", dbscan_model.keys())
@pytest.mark.parametrize(
    "data_size", [unit_param([500, 20, 10]), stress_param([500000, 1000, 500])]
)
def test_dbscan_pickle(tmpdir, datatype, keys, data_size):
    if data_size[0] == 500000 and pytest.max_gpu_memory < 32:
        if pytest.adapt_stress_test:
            data_size[0] = data_size[0] * pytest.max_gpu_memory // 32
        else:
            pytest.skip(
                "Insufficient GPU memory for this test."
                "Re-run with 'CUML_ADAPT_STRESS_TESTS=True'"
            )
    result = {}

    def create_mod():
        nrows, ncols, n_info = data_size
        X_train, _, _ = make_dataset(datatype, nrows, ncols, n_info)
        model = dbscan_model[keys]()
        result["dbscan"] = model.fit_predict(X_train)
        return model, X_train

    def assert_model(pickled_model, X_train):
        pickle_after_predict = pickled_model.fit_predict(X_train)
        assert array_equal(result["dbscan"], pickle_after_predict)

    pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize("keys", agglomerative_model.keys())
@pytest.mark.parametrize(
    "data_size", [unit_param([500, 20, 10]), stress_param([500000, 1000, 500])]
)
def test_agglomerative_pickle(tmpdir, datatype, keys, data_size):
    result = {}

    def create_mod():
        nrows, ncols, n_info = data_size
        X_train, _, _ = make_dataset(datatype, nrows, ncols, n_info)
        model = agglomerative_model[keys]()
        result["agglomerative"] = model.fit_predict(X_train)
        return model, X_train

    def assert_model(pickled_model, X_train):
        pickle_after_predict = pickled_model.fit_predict(X_train)
        assert array_equal(result["agglomerative"], pickle_after_predict)

    pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize("keys", hdbscan_model.keys())
@pytest.mark.parametrize(
    "data_size", [unit_param([500, 20, 10]), stress_param([500000, 1000, 500])]
)
@pytest.mark.parametrize("prediction_data", [True, False])
def test_hdbscan_pickle(tmpdir, datatype, keys, data_size, prediction_data):
    result = {}
    from cuml.cluster.hdbscan import (
        all_points_membership_vectors,
        approximate_predict,
    )

    def create_mod():
        nrows, ncols, n_info = data_size
        X_train, _, _ = make_dataset(datatype, nrows, ncols, n_info)
        model = hdbscan_model[keys](prediction_data=prediction_data)
        result["hdbscan"] = model.fit_predict(X_train)
        result[
            "hdbscan_single_linkage_tree"
        ] = model.single_linkage_tree_.to_numpy()
        result["condensed_tree"] = model.condensed_tree_.to_numpy()
        if prediction_data:
            result["hdbscan_all_points"] = all_points_membership_vectors(model)
            result["hdbscan_approx"] = approximate_predict(model, X_train)
        return model, X_train

    def assert_model(pickled_model, X_train):
        labels = pickled_model.fit_predict(X_train)
        assert array_equal(result["hdbscan"], labels)
        assert np.all(
            result["hdbscan_single_linkage_tree"]
            == pickled_model.single_linkage_tree_.to_numpy()
        )
        assert np.all(
            result["condensed_tree"]
            == pickled_model.condensed_tree_.to_numpy()
        )
        if prediction_data:
            all_points = all_points_membership_vectors(pickled_model)
            approx = approximate_predict(pickled_model, X_train)
            assert array_equal(result["hdbscan_all_points"], all_points)
            assert array_equal(result["hdbscan_approx"], approx)

    pickle_save_load(tmpdir, create_mod, assert_model)


def test_tsne_pickle(tmpdir):
    result = {}

    def create_mod():
        iris = load_iris()
        iris_selection = np.random.RandomState(42).choice(
            [True, False], 150, replace=True, p=[0.75, 0.25]
        )
        X = iris.data[iris_selection]

        model = cuml.manifold.TSNE(n_components=2, random_state=199)
        result["model"] = model
        return model, X

    def assert_model(pickled_model, X):
        model_params = pickled_model.__dict__
        # Confirm params in model are identical
        new_keys = set(model_params.keys())
        for key, value in zip(model_params.keys(), model_params.values()):
            assert model_params[key] == value
            new_keys -= set([key])

        # Check all keys have been checked
        assert len(new_keys) == 0

        # Transform data
        result["fit_model"] = pickled_model.fit(X)
        result["data"] = X
        result["trust"] = trustworthiness(
            X, pickled_model.embedding_, n_neighbors=10
        )

    def create_mod_2():
        model = result["fit_model"]
        return model, result["data"]

    def assert_second_model(pickled_model, X):
        trust_after = trustworthiness(
            X, pickled_model.embedding_, n_neighbors=10
        )
        assert result["trust"] == trust_after

    pickle_save_load(tmpdir, create_mod, assert_model)
    pickle_save_load(tmpdir, create_mod_2, assert_second_model)


# Probabilistic SVM is tested separately because it is a meta estimator that
# owns a set of base SV classifiers.
@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize(
    "params", [{"probability": True}, {"probability": False}]
)
@pytest.mark.parametrize("multiclass", [True, False])
@pytest.mark.parametrize("sparse", [False, True])
def test_svc_pickle(tmpdir, datatype, params, multiclass, sparse):
    result = {}

    if sparse and params["probability"]:
        pytest.skip("Probabilistic SVC does not support sparse input")

    def create_mod():
        model = cuml.svm.SVC(**params)
        iris = load_iris()
        iris_selection = np.random.RandomState(42).choice(
            [True, False], 150, replace=True, p=[0.75, 0.25]
        )
        X_train = iris.data[iris_selection]
        if sparse:
            X_train = scipy_sparse.csr_matrix(X_train)
        y_train = iris.target[iris_selection]
        if not multiclass:
            y_train = (y_train > 0).astype(datatype)
        data = [X_train, y_train]
        result["model"] = model.fit(X_train, y_train)
        return model, data

    def assert_model(pickled_model, data):
        if result["model"].probability:
            print("Comparing probabilistic svc")
            compare_probabilistic_svm(
                result["model"], pickled_model, data[0], data[1], 0, 0
            )
        else:
            print("comparing base svc")
            compare_svm(result["model"], pickled_model, data[0], data[1])

    pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize(
    "params", [{"probability": True}, {"probability": False}]
)
@pytest.mark.parametrize("multiclass", [True, False])
def test_linear_svc_pickle(tmpdir, datatype, params, multiclass):
    result = {}

    def create_mod():
        model = cuml.svm.LinearSVC(**params)
        iris = load_iris()
        iris_selection = np.random.RandomState(42).choice(
            [True, False], 150, replace=True, p=[0.75, 0.25]
        )
        X_train = iris.data[iris_selection]
        y_train = iris.target[iris_selection]
        if not multiclass:
            y_train = (y_train > 0).astype(datatype)
        data = [X_train, y_train]
        result["model"] = model.fit(X_train, y_train)
        return model, data

    def assert_model(pickled_model, data):
        if result["model"].probability:
            print("Comparing probabilistic LinearSVC")
            compare_probabilistic_svm(
                result["model"], pickled_model, data[0], data[1], 0, 0
            )
        else:
            print("comparing base LinearSVC")
            pred_before = result["model"].predict(data[0])
            pred_after = pickled_model.predict(data[0])
            assert array_equal(pred_before, pred_after)

    pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize("nrows", [unit_param(500)])
@pytest.mark.parametrize("ncols", [unit_param(16)])
@pytest.mark.parametrize("n_info", [unit_param(7)])
@pytest.mark.parametrize("sparse", [False, True])
def test_svr_pickle(tmpdir, datatype, nrows, ncols, n_info, sparse):
    result = {}

    def create_mod():
        X_train, y_train, X_test = make_dataset(datatype, nrows, ncols, n_info)
        if sparse:
            X_train = scipy_sparse.csr_matrix(X_train)
            X_test = scipy_sparse.csr_matrix(X_test)
        model = cuml.svm.SVR()
        model.fit(X_train, y_train)
        result["svr"] = model.predict(X_test)
        return model, X_test

    def assert_model(pickled_model, X_test):
        assert array_equal(result["svr"], pickled_model.predict(X_test))

    pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize("nrows", [unit_param(500)])
@pytest.mark.parametrize("ncols", [unit_param(16)])
@pytest.mark.parametrize("n_info", [unit_param(7)])
def test_svr_pickle_nofit(tmpdir, datatype, nrows, ncols, n_info):
    def create_mod():
        X_train, y_train, X_test = make_dataset(datatype, nrows, ncols, n_info)
        model = cuml.svm.SVR()
        return model, [X_train, y_train, X_test]

    def assert_model(pickled_model, X):
        state = pickled_model.__dict__

        assert state["fit_status_"] == -1

        pickled_model.fit(X[0], X[1])
        state = pickled_model.__dict__

        assert state["fit_status_"] == 0

    pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("datatype", [np.float64])
@pytest.mark.parametrize("nrows", [unit_param(1024)])
@pytest.mark.parametrize("ncols", [unit_param(300000)])
@pytest.mark.parametrize("n_info", [unit_param(2)])
def test_sparse_svr_pickle(tmpdir, datatype, nrows, ncols, n_info):
    """
    A separate test to cover the case when the SVM model
    parameters are sparse. Spares input alone does not
    guarantee that the model parameters (SvmModel.support_matrix)
    are sparse (a dense representation can be chosen for
    performance reason). The large number of features used
    here will result in a sparse model representation.
    """
    result = {}

    def create_mod():
        X_train = scipy_sparse.random(
            nrows,
            ncols,
            density=0.001,
            format="csr",
            dtype=datatype,
            random_state=42,
        )
        y_train = np.random.RandomState(42).rand(nrows)
        X_test = X_train
        model = cuml.svm.SVR(max_iter=1)
        model.fit(X_train, y_train)
        result["svr"] = model.predict(X_test)
        return model, X_test

    def assert_model(pickled_model, X_test):
        assert array_equal(result["svr"], pickled_model.predict(X_test))

    pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("datatype", [np.float32, np.float64])
@pytest.mark.parametrize("nrows", [unit_param(500)])
@pytest.mark.parametrize("ncols", [unit_param(16)])
@pytest.mark.parametrize("n_info", [unit_param(7)])
@pytest.mark.parametrize(
    "params", [{"probability": True}, {"probability": False}]
)
def test_svc_pickle_nofit(tmpdir, datatype, nrows, ncols, n_info, params):
    def create_mod():
        X_train, y_train, X_test = make_classification_dataset(
            datatype, nrows, ncols, n_info, n_classes=2
        )
        model = cuml.svm.SVC(**params)
        return model, [X_train, y_train, X_test]

    def assert_model(pickled_model, X):
        state = pickled_model.__dict__

        assert state["fit_status_"] == -1

        pickled_model.fit(X[0], X[1])
        state = pickled_model.__dict__

        assert state["fit_status_"] == 0

    pickle_save_load(tmpdir, create_mod, assert_model)


@pytest.mark.parametrize("datatype", [np.float32])
@pytest.mark.parametrize("key", ["RandomForestClassifier"])
@pytest.mark.parametrize("nrows", [unit_param(100)])
@pytest.mark.parametrize("ncols", [unit_param(20)])
@pytest.mark.parametrize("n_info", [unit_param(10)])
@pytest.mark.filterwarnings(
    "ignore:((.|\n)*)n_streams((.|\n)*):UserWarning:" "cuml[.*]"
)
def test_small_rf(tmpdir, key, datatype, nrows, ncols, n_info):

    result = {}

    def create_mod():
        X_train, y_train, X_test = make_classification_dataset(
            datatype, nrows, ncols, n_info, n_classes=2
        )
        model = rf_models[key](
            n_estimators=1,
            max_depth=1,
            max_features=1.0,
            random_state=10,
            n_bins=32,
        )
        model.fit(X_train, y_train)
        result["rf_res"] = model.predict(X_test)
        return model, X_test

    def assert_model(pickled_model, X_test):
        assert array_equal(result["rf_res"], pickled_model.predict(X_test))

    pickle_save_load(tmpdir, create_mod, assert_model)
