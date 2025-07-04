#
# Copyright (c) 2020-2025, NVIDIA CORPORATION.
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

from cuml.cluster import DBSCAN
from cuml.common.doc_utils import generate_docstring


class DBSCANMG(DBSCAN):
    """
    A Multi-Node Multi-GPU implementation of DBSCAN
    NOTE: This implementation of DBSCAN is meant to be used with an
    initialized cumlCommunicator instance inside an existing distributed
    system. Refer to the Dask DBSCAN implementation in
    `cuml.dask.cluster.dbscan`.
    """

    def __init__(self, **kwargs):
        super().__init__(**kwargs)

    @generate_docstring(skip_parameters_heading=True)
    def fit(self, X, out_dtype="int32", sample_weight=None) -> "DBSCANMG":
        """
        Perform DBSCAN clustering in a multi-node multi-GPU setting.
        Parameters
        ----------
        out_dtype: dtype Determines the precision of the output labels array.
            default: "int32". Valid values are { "int32", np.int32,
            "int64", np.int64}.

        sample_weight: array-like of shape (n_samples,), default=None
            Weight of each sample, such that a sample with a weight of at
            least min_samples is by itself a core sample; a sample with a
            negative weight may inhibit its eps-neighbor from being core.
            default: None (which is equivalent to weight 1 for all samples).
        """
        return self._fit(X, out_dtype, True, sample_weight)
