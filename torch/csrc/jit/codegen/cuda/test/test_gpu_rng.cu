#include <gmock/gmock-matchers.h>
#include <gtest/gtest.h>

#include <ATen/cuda/CUDAGeneratorImpl.h>
#include <c10/util/Optional.h>
#include <torch/csrc/jit/codegen/cuda/arith.h>
#include <torch/csrc/jit/codegen/cuda/fusion.h>
#include <torch/csrc/jit/codegen/cuda/ir_all_nodes.h>
#include <torch/csrc/jit/codegen/cuda/kernel_cache.h>
#include <torch/csrc/jit/codegen/cuda/test/test_gpu_validator.h>
#include <torch/csrc/jit/codegen/cuda/test/test_utils.h>
#include <ATen/cuda/CUDAGraphsUtils.cuh>

#include <cassert>
#include <type_traits>

#include <curand.h>
#include <curand_kernel.h>
#include <curand_philox4x32_x.h>

// Tests go in torch::jit
namespace torch {
namespace jit {

using namespace torch::jit::fuser::cuda;

namespace {

template <typename T>
__global__ void generate_uniform_kernel(
    T* output,
    int64_t size,
    PhiloxCudaState philox_args) {
  int64_t tid = blockIdx.x * blockDim.x + threadIdx.x;

  auto seeds = at::cuda::philox::unpack(philox_args);
  curandStatePhilox4_32_10_t state;
  curand_init(std::get<0>(seeds), tid, std::get<1>(seeds), &state);

  if (std::is_same<T, double>::value) {
    double2 result = curand_uniform2_double(&state);
    if (tid * 2 < size) {
      output[tid * 2] = result.x;
    }
    if (tid * 2 + 1 < size) {
      output[tid * 2 + 1] = result.y;
    }
  } else {
    auto is_float = std::is_same<T, float>::value;
    assert(is_float);
    float4 result = curand_uniform4(&state);
    if (tid * 4 < size) {
      output[tid * 4] = result.x;
    }
    if (tid * 4 + 1 < size) {
      output[tid * 4 + 1] = result.y;
    }
    if (tid * 4 + 2 < size) {
      output[tid * 4 + 2] = result.z;
    }
    if (tid * 4 + 3 < size) {
      output[tid * 4 + 3] = result.w;
    }
  }
}

at::Tensor generate_uniform(int64_t size, at::ScalarType dtype) {
  auto options = at::TensorOptions().dtype(dtype).device(at::kCUDA, 0);
  auto result = at::empty({size}, options);

  auto gen = get_generator_or_default<CUDAGeneratorImpl>(
      c10::nullopt, at::cuda::detail::getDefaultCUDAGenerator());
  PhiloxCudaState rng_engine_inputs;
  {
    // See Note [Acquire lock when using random generators]
    std::lock_guard<std::mutex> lock(gen->mutex_);
    rng_engine_inputs = gen->philox_cuda_state(4);
  }

  if (dtype == kFloat) {
    int64_t block = 128;
    int64_t block_elems = block * 4;
    int64_t grid = (size + block_elems - 1) / block_elems;
    generate_uniform_kernel<<<
        grid,
        block,
        0,
        at::cuda::getCurrentCUDAStream()>>>(
        result.data_ptr<float>(), size, rng_engine_inputs);
  } else {
    TORCH_CHECK(dtype == kDouble);
    int64_t block = 128;
    int64_t block_elems = block * 2;
    int64_t grid = (size + block_elems - 1) / block_elems;
    generate_uniform_kernel<<<
        grid,
        block,
        0,
        at::cuda::getCurrentCUDAStream()>>>(
        result.data_ptr<double>(), size, rng_engine_inputs);
  }
  return result;
}

} // namespace

TEST_F(NVFuserTest, FusionRNGValidateWithCURand_CUDA) {
  for (int64_t size : {16, 1024, 10001, 10002, 10003, 100000, 10000001}) {
    for (auto dtype : {kFloat, kDouble}) {
      std::unique_ptr<Fusion> fusion_ptr = std::make_unique<Fusion>();
      auto fusion = fusion_ptr.get();
      FusionGuard fg(fusion);

      TensorView* tv0 = makeSymbolicTensor(1, aten_to_data_type(dtype));
      fusion->addInput(tv0);
      auto tv1 = randlike(tv0);
      fusion->addOutput(tv1);

      FusionExecutorCache fec(std::move(fusion_ptr));

      auto options = at::TensorOptions().dtype(dtype).device(at::kCUDA, 0);
      at::Tensor t0 = at::zeros({size}, options);

      at::manual_seed(0);
      auto cg_outputs = fec.runFusionWithInputs({t0});
      auto out = cg_outputs[0];

      at::manual_seed(0);
      auto ref = generate_uniform(size, dtype);

      testValidate(fec.fusion(), {out}, {t0}, {ref}, __LINE__, __FILE__);
    }
  }
}

TEST_F(NVFuserTest, FusionRNGSimpleValidateWithCURand_CUDA) {
  int64_t size = 128;
  auto dtype = kFloat;
  std::unique_ptr<Fusion> fusion_ptr = std::make_unique<Fusion>();
  auto fusion = fusion_ptr.get();
  FusionGuard fg(fusion);

  TensorView* tv0 = makeSymbolicTensor(1, aten_to_data_type(dtype));
  fusion->addInput(tv0);
  auto tv1 = randlike(tv0);
  auto tv2 = set(tv1);
  fusion->addOutput(tv2);

  tv2->split(0, 8);
  tv2->axis(0)->parallelize(ParallelType::TIDx);

  tv0->computeAt(tv2, 1);

  auto options = at::TensorOptions().dtype(dtype).device(at::kCUDA, 0);
  at::Tensor t0 = at::zeros({size}, options);

  FusionExecutor fe;
  fe.compileFusion(fusion, {t0});

  at::manual_seed(0);
  auto cg_outputs = fe.runFusion({t0});
  auto out = cg_outputs[0];

  at::manual_seed(0);
  auto ref = generate_uniform(size, dtype);

  testValidate(fusion, {out}, {t0}, {ref}, __LINE__, __FILE__);
}

TEST_F(NVFuserTest, FusionBroadcastingRNG_CUDA) {
  for (auto dtype : {kFloat, kDouble}) {
    std::unique_ptr<Fusion> fusion_ptr = std::make_unique<Fusion>();
    auto fusion = fusion_ptr.get();
    FusionGuard fg(fusion);

    TensorView* tv0 = makeConcreteTensor({5, 1}, aten_to_data_type(dtype));
    TensorView* tv1 = makeConcreteTensor({5, 5}, aten_to_data_type(dtype));
    fusion->addInput(tv0);
    fusion->addInput(tv1);
    auto tv2 = randlike(tv0);
    auto tv3 = add(tv1, tv2);
    auto tv4 = add(tv0, tv3);
    fusion->addOutput(tv4);

    FusionExecutorCache fec(std::move(fusion_ptr));

    auto options = at::TensorOptions().dtype(dtype).device(at::kCUDA, 0);
    at::Tensor t0 = at::zeros({5, 1}, options);
    at::Tensor t1 = at::zeros({5, 5}, options);

    auto cg_outputs = fec.runFusionWithInputs({t0, t1});
    auto out = cg_outputs[0];
    TORCH_CHECK((out.select(1, 0) == out.select(1, 1)).all().item<bool>())
    TORCH_CHECK((out.select(1, 0) == out.select(1, 2)).all().item<bool>())
    TORCH_CHECK((out.select(1, 0) == out.select(1, 3)).all().item<bool>())
    TORCH_CHECK((out.select(1, 0) == out.select(1, 4)).all().item<bool>())
  }
}

TEST_F(NVFuserTest, FusionBroadcastingRNG2_CUDA) {
  for (int64_t size : {16, 1024, 10001, 10002, 10003, 100000, 10000001}) {
    for (auto dtype : {kFloat, kDouble}) {
      std::unique_ptr<Fusion> fusion_ptr = std::make_unique<Fusion>();
      auto fusion = fusion_ptr.get();
      FusionGuard fg(fusion);

      TensorView* tv0 = makeConcreteTensor({1}, aten_to_data_type(dtype));
      TensorView* tv1 = makeSymbolicTensor(1, aten_to_data_type(dtype));
      fusion->addInput(tv0);
      fusion->addInput(tv1);
      auto tv2 = randlike(tv0);
      auto tv3 = add(tv1, tv2);
      fusion->addOutput(tv3);

      FusionExecutorCache fec(std::move(fusion_ptr));

      auto options = at::TensorOptions().dtype(dtype).device(at::kCUDA, 0);
      at::Tensor t0 = at::zeros({1}, options);
      at::Tensor t1 = at::zeros({size}, options);

      at::manual_seed(0);
      auto cg_outputs = fec.runFusionWithInputs({t0, t1});
      auto out = cg_outputs[0];

      at::manual_seed(0);
      auto ref = generate_uniform(1, dtype).expand_as(t1);

      testValidate(fec.fusion(), {out}, {t0, t1}, {ref}, __LINE__, __FILE__);
    }
  }
}

} // namespace jit
} // namespace torch
