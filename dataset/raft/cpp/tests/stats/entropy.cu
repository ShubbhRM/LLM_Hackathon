/*
 * Copyright (c) 2019-2024, NVIDIA CORPORATION.
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
#include "../test_utils.cuh"

#include <raft/core/interruptible.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <raft/stats/entropy.cuh>
#include <raft/util/cudart_utils.hpp>

#include <rmm/device_uvector.hpp>

#include <gtest/gtest.h>

#include <algorithm>
#include <iostream>
#include <random>

namespace raft {
namespace stats {

struct entropyParam {
  int nElements;
  int lowerLabelRange;
  int upperLabelRange;
  double tolerance;
};

// test fixture class
template <typename T>
class entropyTest : public ::testing::TestWithParam<entropyParam> {
 protected:
  // the constructor
  entropyTest() : stream(resource::get_cuda_stream(handle)) {}

  void SetUp() override
  {
    // getting the parameters
    params = ::testing::TestWithParam<entropyParam>::GetParam();

    nElements       = params.nElements;
    lowerLabelRange = params.lowerLabelRange;
    upperLabelRange = params.upperLabelRange;

    // generating random value test input
    std::vector<int> arr1(nElements, 0);
    std::random_device rd;
    std::default_random_engine dre(rd());
    std::uniform_int_distribution<int> intGenerator(lowerLabelRange, upperLabelRange);

    std::generate(arr1.begin(), arr1.end(), [&]() { return intGenerator(dre); });

    // generating the golden output
    int numUniqueClasses = upperLabelRange - lowerLabelRange + 1;

    const auto p = std::make_unique<int[]>(numUniqueClasses);

    // calculating the bincount array
    for (int i = 0; i < nElements; ++i) {
      ++p[arr1[i] - lowerLabelRange];
    }

    // calculating the aggregate entropy
    for (int i = 0; i < numUniqueClasses; ++i) {
      if (p[i])
        truthEntropy +=
          -1 * (double(p[i]) / double(nElements)) * (log(double(p[i])) - log(double(nElements)));
    }

    // allocating and initializing memory to the GPU
    rmm::device_uvector<T> clusterArray(nElements, stream);
    raft::update_device(clusterArray.data(), &arr1[0], (int)nElements, stream);

    raft::interruptible::synchronize(stream);
    // calling the entropy CUDA implementation
    computedEntropy =
      raft::stats::entropy(handle,
                           raft::make_device_vector_view<const T>(clusterArray.data(), nElements),
                           lowerLabelRange,
                           upperLabelRange);
  }

  raft::resources handle;
  // declaring the data values
  entropyParam params;
  T lowerLabelRange, upperLabelRange;

  int nElements          = 0;
  double truthEntropy    = 0;
  double computedEntropy = 0;
  cudaStream_t stream    = 0;
};

// setting test parameter values
const std::vector<entropyParam> inputs = {{199, 1, 10, 0.000001},
                                          {200, 15, 100, 0.000001},
                                          {100, 1, 20, 0.000001},
                                          {10, 1, 10, 0.000001},
                                          {198, 1, 100, 0.000001},
                                          {300, 3, 99, 0.000001},
                                          {199, 1, 10, 0.000001},
                                          {200, 15, 100, 0.000001},
                                          {100, 1, 20, 0.000001},
                                          {10, 1, 10, 0.000001},
                                          {198, 1, 100, 0.000001},
                                          {300, 3, 99, 0.000001}};

// writing the test suite
typedef entropyTest<int> entropyTestClass;
TEST_P(entropyTestClass, Result) { ASSERT_NEAR(computedEntropy, truthEntropy, params.tolerance); }
INSTANTIATE_TEST_CASE_P(entropy, entropyTestClass, ::testing::ValuesIn(inputs));

}  // end namespace stats
}  // end namespace raft
