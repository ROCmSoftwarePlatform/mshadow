#include "hip/hip_runtime.h"
/*!
 *  Copyright (c) 2014 by Contributors
 * \file tensor_gpu-inl.cuh
 * \brief implementation of GPU code using CUDA
 * \author Bing Xu, Tianqi Chen
 */
#ifndef MSHADOW_CUDA_TENSOR_GPU_INL_CUH_
#define MSHADOW_CUDA_TENSOR_GPU_INL_CUH_
#include <thrust/device_ptr.h>
#include <thrust/sort.h>
#if CUDA_VERSION >= 7000
#include <thrust/system/cuda/execution_policy.h>
#endif
#include "../tensor.h"
#include "./reduce.cuh"
#define MSHADOW_CUDA_POST_KERNEL_CHECK(x) \
  /* Code block avoids redefinition of hipError_t err */ \
  do { \
    hipError_t  err = hipPeekAtLastError(); \
    CHECK_EQ(err, hipSuccess) << "Name: " << #x << " ErrStr:" << hipGetErrorString(err); \
  } while (0)
namespace mshadow {
namespace cuda {
/* load unit for memory access, if CUDAARCH not defined, this is advanced nvcc */
#if MSHADOW_OLD_CUDA
const int kMemUnitBits = 4;
const int kMaxThreadsPerBlock = 512;
#else
const int kMemUnitBits = 5;
const int kMaxThreadsPerBlock = 1024;
#endif
/*! \brief number of units that can do synchronized update, half warp size */
const int kMemUnit = 1 << kMemUnitBits;
/*! \brief mask that could be helpful sometime */
const int kMemUnitMask = kMemUnit - 1;
/*! \brief suggested thread number(logscale) for mapping kernel */
const int kBaseThreadBits = 8;
/*! \brief suggested thread number for mapping kernel */
const int kBaseThreadNum  = 1 << kBaseThreadBits;
/*! \brief maximum value of grid */
const int kMaxGridNum = 65535;
/*! \brief maximum value of grid within each dimension */
const int kMaxGridDim = 65535;
/*! \brief suggested grid number for mapping kernel */
const int kBaseGridNum = 1024;
/*! \brief get align stride for given size in x dimension */
inline index_t GetAlignStride(index_t xsize) {
  if (xsize >= MSHADOW_MIN_PAD_RATIO * 32) {
    return ((xsize  + kMemUnit - 1) >> kMemUnitBits) << kMemUnitBits;
  } else {
    // if originally space is not aligned, no necessary to to alligned thread allocation
    return xsize;
  }
}
inline void CheckLaunchParam(dim3 dimGrid, dim3 dimBlock, const char *estr = "") {
  if (dimBlock.x * dimBlock.y * dimBlock.z > static_cast<unsigned>(kMaxThreadsPerBlock) ||
      dimGrid.x > kMaxGridDim || dimGrid.y > kMaxGridDim) {
    LOG(FATAL) << "too large launch parameter: "
      << estr << "["
      << dimGrid.x << ","
      << dimGrid.y << "], ["
      << dimBlock.x << ","
      << dimBlock.y << ","
      << dimBlock.z << "]";
  }
}
template<typename Saver, typename DstPlan,
         typename Plan, int block_dim_bits>
__device__ void MapPlanProc(DstPlan dst, index_t xstride,
                            Shape<2> dshape, const Plan exp, int block_idx) {
  const index_t tid = (block_idx << block_dim_bits) + hipThreadIdx_x;
  const int y = tid / xstride;
  const int x = tid % xstride;
  if (y < dshape[0] && x < dshape[1]) {
    Saver::Save(dst.REval(y, x), exp.Eval(y,x));
  }
}
template<typename Saver,int block_dim_bits,
         typename DstPlan, typename Plan>
__global__ void MapPlanKernel( DstPlan dst, index_t xstride,
                              Shape<2> dshape, const Plan exp) {
  MapPlanProc<Saver, DstPlan, Plan, block_dim_bits>
      (dst, xstride, dshape, exp, hipBlockIdx_x);
}
template<typename Saver, int block_dim_bits, int grid_size,
         typename DstPlan, typename Plan>
__global__ void MapPlanLargeKernel( DstPlan dst, index_t xstride,
                                   Shape<2> dshape, const Plan exp, int repeat) {
  for (int i = 0; i < repeat; ++i) {
  MapPlanProc<Saver, DstPlan, Plan, block_dim_bits>
      (dst, xstride, dshape, exp, hipBlockIdx_x + i * grid_size);
  }
}

template<typename Saver, typename DstExp, typename E, typename DType>
inline void MapPlan(expr::Plan<DstExp, DType> dst,
                    const expr::Plan<E, DType> &plan,
                    Shape<2> dshape,
                    hipStream_t stream) {
  const index_t xstride = GetAlignStride(dshape[1]);
  const int num_block = (dshape[0] * xstride + kBaseThreadNum-1) / kBaseThreadNum;
  dim3 dimBlock(kBaseThreadNum, 1, 1);

  if (num_block < kMaxGridNum) {
    dim3 dimGrid(num_block, 1, 1);
    hipLaunchKernel(HIP_KERNEL_NAME(MapPlanKernel<Saver, kBaseThreadBits,
                  expr::Plan<DstExp, DType>,
                  expr::Plan<E, DType> >), dim3(dimGrid), dim3(dimBlock), 0, stream, dst, xstride, dshape, plan);
    MSHADOW_CUDA_POST_KERNEL_CHECK(MapPlanKernel);
  } else {
    int repeat = (num_block + kBaseGridNum-1) / kBaseGridNum;
    dim3 dimGrid(kBaseGridNum, 1 , 1);
    hipLaunchKernel(HIP_KERNEL_NAME(MapPlanLargeKernel<Saver, kBaseThreadBits, kBaseGridNum,
                       expr::Plan<DstExp, DType>,
                       expr::Plan<E, DType> >), dim3(dimGrid), dim3(dimBlock), 0, stream, dst, xstride, dshape, plan, repeat);
    MSHADOW_CUDA_POST_KERNEL_CHECK(MapPlanLargeKernel);
  }
}

template<typename Saver,typename Reducer, int warp_bits,
         typename DType, typename DstPlan, typename Plan>
__global__ void
__launch_bounds__( kMemUnit*kMemUnit, 1)
MapRedKeepLowestKernel(DstPlan dst, Plan plan,
                       DType scale, Shape<2> eshape) {
  const unsigned warp_size = 1 << warp_bits;
  const unsigned x = (hipBlockIdx_x << warp_bits) + hipThreadIdx_x;
  // to avoid bank conflict
  __shared__ DType s_res[warp_size][warp_size + 1];
  // note: reverse store [y][x], so that we can reduce over hipThreadIdx_x, use warp optimization
  if (hipThreadIdx_y < eshape[0] && x < eshape[1]) {
    s_res[hipThreadIdx_x][hipThreadIdx_y] = plan.Eval(hipThreadIdx_y, x);
  }
  for (unsigned y = warp_size; y < eshape[0]; y += warp_size) {
    if (hipThreadIdx_y + y < eshape[0] && x < eshape[1]) {
      Reducer::Reduce(s_res[hipThreadIdx_x][hipThreadIdx_y], plan.Eval(hipThreadIdx_y + y, x));
    }
  }
  __syncthreads();
  if (eshape[0] >= warp_size) {
    Reduce1D<Reducer, warp_bits>(s_res[hipThreadIdx_y]);
  } else {
    Reduce1DNotAlign<Reducer, warp_bits>(s_res[hipThreadIdx_y], eshape[0]);
  }
  __syncthreads();

  if (hipThreadIdx_y == 0 && x < eshape[1]) {
    Saver::Save(dst.REval(0, x),  DType(s_res[hipThreadIdx_x][0] * scale));
  }
}

template<typename Saver, typename Reducer,
         typename DstExp, typename E, typename DType>
inline void MapReduceKeepLowest(expr::Plan<DstExp, DType> dst,
                                const expr::Plan<E, DType> &plan,
                                DType scale, Shape<2> eshape,
                                hipStream_t stream) {
  dim3 dimBlock(kMemUnit, kMemUnit);
  dim3 dimGrid((eshape[1] + kMemUnit - 1) >> kMemUnitBits);
  CheckLaunchParam(dimGrid, dimBlock, "MapRedKeepLowestKernel");
  hipLaunchKernel(HIP_KERNEL_NAME(MapRedKeepLowestKernel<Saver, Reducer, kMemUnitBits, DType,
                         expr::Plan<DstExp, DType>,
                         expr::Plan<E, DType> >), dim3(dimGrid), dim3(dimBlock), 0, stream, dst, plan, scale, eshape);
  MSHADOW_CUDA_POST_KERNEL_CHECK(MapRedKeepLowestKernel);
}

template<typename Saver, typename Reducer, int block_dim_bits,
         typename DType, typename DstPlan, typename Plan>
__global__ void MapReduceKeepDim1Kernel( DstPlan dst, Plan plan, DType scale, Shape<4> pshape) {
  const int block_size = 1 << block_dim_bits;
  __shared__ DType s_rec[block_size];
  const int c = hipBlockIdx_x;
  const index_t tot = pshape[3] * pshape[2] * pshape[0];

  DType res; Reducer::SetInitValue(res);
  for (index_t i_offset = 0; i_offset < tot; i_offset += block_size) {
    index_t i = i_offset + hipThreadIdx_x;
    if (i< tot) {
      const index_t x = i % pshape[3];
      i /= pshape[3];
      const index_t y = i % pshape[2];
      const index_t n = i / pshape[2];
      Reducer::Reduce(res, plan.Eval((n * pshape[1] + c) * pshape[2] + y, x));
    }
  }
  s_rec[hipThreadIdx_x] = res;
  __syncthreads();
  Reduce1D<Reducer, block_dim_bits>(s_rec);
  if (hipThreadIdx_x == 0) {
    Saver::Save(dst.REval(0, c), DType(s_rec[0] * scale));
  }
}

template<typename Saver, typename Reducer, typename DstExp, typename E, typename DType>
inline void MapReduceKeepDim1(expr::Plan<DstExp, DType> dst,
                              const expr::Plan<E, DType> &plan,
                              DType scale, Shape<4> pshape,
                              hipStream_t stream) {
  dim3 dimBlock(kBaseThreadNum);
  dim3 dimGrid (pshape[1]);
  CheckLaunchParam(dimGrid, dimBlock, "MapReduceKeepDim1");
  hipLaunchKernel(HIP_KERNEL_NAME(MapReduceKeepDim1Kernel<Saver,Reducer,kBaseThreadBits, DType,
                          expr::Plan<DstExp, DType>,
                          expr::Plan<E, DType> >), dim3(dimGrid), dim3(dimBlock), 0, stream, dst, plan, scale, pshape);
  MSHADOW_CUDA_POST_KERNEL_CHECK(MapReduceKeepDim1Kernel);
}

template<int x_bits, typename DType>
__global__ void GetBatchedViewKernel( DType **dst, DType *src, int num, int stride) {
  const int x_size = 1 << x_bits;
  const int start = hipThreadIdx_x;
  // Copy the addresses of src to dst every stride steps
  for (int i = start; i < num; i += x_size) {
    dst[i] = src + i * stride;
  }
}

template<typename DType>
inline void GetBatchedView(DType **dst, DType *src, int num, int stride,
                           Stream<gpu> *stream) {
  hipStream_t stream_ = Stream<gpu>::GetStream(stream);
  dim3 dimBlock(kBaseThreadNum);
  dim3 dimGrid(1);
  CheckLaunchParam(dimGrid, dimBlock, "GetBatchedView");
  //hipLaunchKernel(HIP_KERNEL_NAME(GetBatchedViewKernel<kBaseThreadBits, DType>), dim3(dimGrid), dim3(dimBlock), 0, stream_, dst, src, num, stride); //TODO HIP
  MSHADOW_CUDA_POST_KERNEL_CHECK(GetBatchedViewKernel);
}

template<int x_bits, typename DType, typename DstPlan, typename SrcPlan1, typename SrcPlan2>
__global__ void SoftmaxGradKernel( DstPlan dst, SrcPlan1 src, SrcPlan2 label, index_t xmax) {
  const unsigned x_size = 1 << x_bits;
  const int y = hipBlockIdx_x;
  const int k = static_cast<int>(label.Eval(0, y));

  // calculate normalizer, with writeback
  for (unsigned x = 0; x < xmax; x += x_size) {
    const unsigned xindex = x + hipThreadIdx_x;
    if (xindex < xmax) {
      if (xindex == k) {
        dst.REval(y, xindex) = src.Eval(y, xindex) - 1.0f;
      } else {
        dst.REval(y, xindex) = src.Eval(y, xindex);
      }
    }
  }
}

template<int x_bits, typename DType, typename DstPlan, typename SrcPlan1, typename SrcPlan2>
__global__ void SoftmaxGradKernel( DstPlan dst, SrcPlan1 src, SrcPlan2 label, index_t xmax,
                                  DType ignore_label) {
  const unsigned x_size = 1 << x_bits;
  const int y = hipBlockIdx_x;
  const int k = static_cast<int>(label.Eval(0, y));

  // calculate normalizer, with writeback
  for (unsigned x = 0; x < xmax; x += x_size) {
    const unsigned xindex = x + hipThreadIdx_x;
    if (xindex < xmax) {
      if (static_cast<int>(ignore_label) == k) {
        dst.REval(y, xindex) = 0.0f;
      } else {
        if (xindex == k) {
          dst.REval(y, xindex) = src.Eval(y, xindex) - 1.0f;
        } else {
          dst.REval(y, xindex) = src.Eval(y, xindex);
        }
      }
    }
  }
}

template<int x_bits, typename DType,  typename DstPlan, typename SrcPlan>
__global__ void SoftmaxKernel( DstPlan dst, SrcPlan src, index_t xmax) {
  const unsigned x_size = 1 << x_bits;
  const int y = hipBlockIdx_x;
  __shared__ DType s_rec[x_size];
  // step 1: get max
  if (hipThreadIdx_x < xmax) {
    s_rec[hipThreadIdx_x] = src.Eval(y, hipThreadIdx_x);
  }
  for (unsigned x = x_size; x < xmax; x += x_size) {
    if (x + hipThreadIdx_x < xmax) {
      DType a = src.Eval(y, x + hipThreadIdx_x);
      s_rec[hipThreadIdx_x] = max(a, s_rec[hipThreadIdx_x]);
    }
  }
  __syncthreads();
  if (hipThreadIdx_x >= xmax) {
    s_rec[hipThreadIdx_x] = s_rec[0];
  }
  __syncthreads();
  Reduce1D<red::maximum, x_bits>(s_rec);
  __syncthreads();
  DType smax = s_rec[0];
  __syncthreads();
  s_rec[hipThreadIdx_x] = 0.0f;
  __syncthreads();

  // calculate normalizer, with writeback
  for (unsigned x = 0; x < xmax; x += x_size) {
    if (x + hipThreadIdx_x < xmax) {
      DType p = expf(src.Eval(y, x + hipThreadIdx_x) - smax);
      s_rec[hipThreadIdx_x] += p;
      // write back first, will fetch later
      dst.REval(y, x + hipThreadIdx_x) = p;
    }
  }
  // calculate normalizer
  __syncthreads();
  Reduce1D<red::sum, x_bits>(s_rec);
  __syncthreads();
  DType ssum = s_rec[0];

  for (unsigned x = 0; x < xmax; x += x_size) {
    if (x + hipThreadIdx_x < xmax) {
      dst.REval(y, x + hipThreadIdx_x) /= ssum;
    }
  }
}

template<typename DType>
inline void Softmax(Tensor<gpu, 2, DType> &dst,
                    const Tensor<gpu, 2, DType> &src) {
  dim3 dimBlock(kBaseThreadNum);
  dim3 dimGrid(dst.size(0));
  CHECK_EQ(dst.shape_, src.shape_) << "Softmax: shape mismatch";
  CheckLaunchParam(dimGrid, dimBlock, "Softmax");
  hipStream_t stream = Stream<gpu>::GetStream(dst.stream_);
  hipLaunchKernel(HIP_KERNEL_NAME(SoftmaxKernel<kBaseThreadBits, DType>), dim3(dimGrid), dim3(dimBlock), 0, stream, expr::MakePlan(dst),
       expr::MakePlan(src),
       dst.size(1));
  MSHADOW_CUDA_POST_KERNEL_CHECK(SoftmaxKernel);
}

template<typename DType>
inline void SoftmaxGrad(Tensor<gpu, 2, DType> &dst,
                        const Tensor<gpu, 2, DType> &src,
                        const Tensor<gpu, 1, DType> &label) {
  dim3 dimBlock(kBaseThreadNum);
  dim3 dimGrid(dst.size(0));
  CHECK_EQ(dst.shape_, src.shape_) << "SoftmaxGrad: shape mismatch";
  CHECK_EQ(dst.size(0), label.size(0)) << "SoftmaxGrad: label shape mismatch";
  CheckLaunchParam(dimGrid, dimBlock, "SoftmaxGrad");
  hipStream_t stream = Stream<gpu>::GetStream(dst.stream_);
  hipLaunchKernel(HIP_KERNEL_NAME(SoftmaxGradKernel<kBaseThreadBits, DType>), dim3(dimGrid), dim3(dimBlock), 0, stream, expr::MakePlan(dst),
       expr::MakePlan(src),
       expr::MakePlan(label),
       dst.size(1));
  MSHADOW_CUDA_POST_KERNEL_CHECK(SoftmaxGradKernel);
}

template<typename DType>
inline void SoftmaxGrad(Tensor<gpu, 2, DType> &dst,
                        const Tensor<gpu, 2, DType> &src,
                        const Tensor<gpu, 1, DType> &label,
                        const DType &ignore_label) {
  dim3 dimBlock(kBaseThreadNum);
  dim3 dimGrid(dst.size(0));
  CHECK_EQ(dst.shape_, src.shape_) << "SoftmaxGrad: shape mismatch";
  CHECK_EQ(dst.size(0), label.size(0)) << "SoftmaxGrad: label shape mismatch";
  CheckLaunchParam(dimGrid, dimBlock, "SoftmaxGrad");
  hipStream_t stream = Stream<gpu>::GetStream(dst.stream_);
  hipLaunchKernel(HIP_KERNEL_NAME(SoftmaxGradKernel<kBaseThreadBits, DType>), dim3(dimGrid), dim3(dimBlock), 0, stream, expr::MakePlan(dst),
       expr::MakePlan(src),
       expr::MakePlan(label),
       dst.size(1),
       ignore_label);
  MSHADOW_CUDA_POST_KERNEL_CHECK(SoftmaxGradKernel);
}

template<int n_bits, typename DType>
__global__ void Softmax3DGradKernel( Tensor<gpu, 3, DType> dst,
                                    const Tensor<gpu, 3, DType> src,
                                    const Tensor<gpu, 2, DType> label) {
  const index_t xmax = dst.size(1);
  const index_t nmax = dst.size(2);
  const unsigned n_size = 1 << n_bits;
  const int y = hipBlockIdx_x;
  const int n = hipThreadIdx_x;

  for (index_t n_index = n; n_index < nmax; n_index += n_size) {
    const int k = static_cast<int>(label[y][n_index]);
    for (index_t i = 0; i < xmax; ++i) {
      if (i == k) {
        dst[y][i][n_index] = src[y][i][n_index] - 1.0f;
      } else {
        dst[y][i][n_index] = src[y][i][n_index];
      }
    }
  }
}

template<int n_bits, typename DType>
__global__ void Softmax3DGradKernel( Tensor<gpu, 3, DType> dst,
                                    const Tensor<gpu, 3, DType> src,
                                    const Tensor<gpu, 2, DType> label,
                                    DType ignore_label) {
  const index_t xmax = dst.size(1);
  const index_t nmax = dst.size(2);
  const unsigned n_size = 1 << n_bits;
  const int y = hipBlockIdx_x;
  const int n = hipThreadIdx_x;
  for (index_t n_index = n; n_index < nmax; n_index += n_size) {
    int k = static_cast<int>(label[y][n_index]);
    if (k == static_cast<int>(ignore_label)) {
      for (index_t i = 0; i < xmax; ++i) {
        dst[y][i][n_index] = 0.0f;
      }
    } else {
      for (index_t i = 0; i < xmax; ++i) {
        if (i == k) {
          dst[y][i][n_index] = src[y][i][n_index] - 1.0f;
        } else {
          dst[y][i][n_index] = src[y][i][n_index];
        }
      }
    }
  }
}

template<int n_bits, typename DType>
__global__ void Softmax3DKernel( Tensor<gpu, 3, DType> dst,
                    const Tensor<gpu, 3, DType> src) {
  const index_t xmax = dst.size(1);
  const index_t nmax = dst.size(2);
  const unsigned n_size = 1 << n_bits;
  const int y = hipBlockIdx_x;
  const int n = hipThreadIdx_x;

  for (index_t n_index = n; n_index < nmax; n_index += n_size) {
    DType smax = src[y][0][n_index];
    for (index_t i = 1; i < xmax; ++i) {
      smax = max(smax, src[y][i][n_index]);
    }
    DType ssum = 0.0f;
    for (index_t i = 0; i < xmax; ++i) {
      DType p = expf(src[y][i][n_index] - smax);
      ssum += p;
      dst[y][i][n_index] = p;
    }
    for (index_t i = 0; i < xmax; ++i) {
      dst[y][i][n_index] /= ssum;
    }
  }
}

template<typename DType>
inline void Softmax(Tensor<gpu, 3, DType> &dst,
                    const Tensor<gpu, 3, DType> &src) {
  dim3 dimBlock(kBaseThreadNum);
  dim3 dimGrid(dst.size(0));
  CHECK_EQ(dst.shape_, src.shape_) << "Softmax: shape mismatch";
  CheckLaunchParam(dimGrid, dimBlock, "Softmax");
  hipStream_t stream = Stream<gpu>::GetStream(dst.stream_);
  hipLaunchKernel(HIP_KERNEL_NAME(Softmax3DKernel<kBaseThreadBits, DType>), dim3(dimGrid), dim3(dimBlock), 0, stream, dst, src);
  MSHADOW_CUDA_POST_KERNEL_CHECK(Softmax3DKernel);
}

template<typename DType>
inline void SoftmaxGrad(Tensor<gpu, 3, DType> &dst,
                        const Tensor<gpu, 3, DType> &src,
                        const Tensor<gpu, 2, DType> &label) {
  dim3 dimBlock(kBaseThreadNum);
  dim3 dimGrid(dst.size(0));
  CHECK_EQ(dst.shape_, src.shape_) << "SoftmaxGrad: shape mismatch";
  CHECK_EQ(dst.size(0), label.size(0)) << "SoftmaxGrad: label shape mismatch";
  CHECK_EQ(dst.size(2), label.size(1)) << "SoftmaxGrad: label shape mismatch";
  CheckLaunchParam(dimGrid, dimBlock, "SoftmaxGrad");
  hipStream_t stream = Stream<gpu>::GetStream(dst.stream_);
  hipLaunchKernel(HIP_KERNEL_NAME(Softmax3DGradKernel<kBaseThreadBits, DType>), dim3(dimGrid), dim3(dimBlock), 0, stream, dst, src, label);
  MSHADOW_CUDA_POST_KERNEL_CHECK(Softmax3DGradKernel);
}

template<typename DType>
inline void SoftmaxGrad(Tensor<gpu, 3, DType> &dst,
                        const Tensor<gpu, 3, DType> &src,
                        const Tensor<gpu, 2, DType> &label,
                        const DType &ignore_label) {
  dim3 dimBlock(kBaseThreadNum);
  dim3 dimGrid(dst.size(0));
  CHECK_EQ(dst.shape_, src.shape_) << "SoftmaxGrad: shape mismatch";
  CHECK_EQ(dst.size(0), label.size(0)) << "SoftmaxGrad: label shape mismatch";
  CHECK_EQ(dst.size(2), label.size(1)) << "SoftmaxGrad: label shape mismatch";
  CheckLaunchParam(dimGrid, dimBlock, "SoftmaxGrad");
  hipStream_t stream = Stream<gpu>::GetStream(dst.stream_);
  hipLaunchKernel(HIP_KERNEL_NAME(Softmax3DGradKernel<kBaseThreadBits, DType>), dim3(dimGrid), dim3(dimBlock), 0, stream, dst, src, label, ignore_label);
  MSHADOW_CUDA_POST_KERNEL_CHECK(Softmax3DGradKernel);
}

template<int x_bits, typename DType, typename DstPlan, typename SrcPlan1, typename SrcPlan2>
__global__ void AddTakeGradKernel( DstPlan dst,
                                  SrcPlan1 index, SrcPlan2 src,
                                  index_t ymax, index_t xmax, const int K) {
  const unsigned x_size = 1 << x_bits;
  const int xindex = hipBlockIdx_x * x_size + hipThreadIdx_x;
  __shared__ int ptr;
  for (unsigned y = 0; y < ymax; ++y) {
    if (hipThreadIdx_x == 0) {
      ptr = index.Eval(0, y);
      if (ptr <= 0) ptr = 0;
      else if (ptr >= K) ptr = K - 1;
    }
    __syncthreads();
    if (xindex < xmax) {
      dst.REval(ptr, xindex) += src.Eval(y, xindex);
    }
  }
}

template<int warp_bits, int SZ, typename DType, typename IdxType>
__global__ void AddTakeGradLargeBatchKernel( DType* dst,
                                            const IdxType *sorted, const IdxType *index, const DType *src,
                                            int ymax, int xmax) {
  // Based on Torch's Version https://github.com/torch/cunn/blob/master/lib/THCUNN/LookupTable.cu
  // Each warp is responsible for an input into the LookupTable.
  // If the preceeding input has the same as this input, then the warp
  // exits immediately. The warp also processes subsequent inputs with the
  // same value.
  //
  // Input Warp
  // 1     <warp 1>
  // 1     <warp 1> (<warp 2> exits without doing any work)
  // 5     <warp 3>
  // 8     <warp 4>
  // Also, all warp will loop for SZ times to increase the throughput.

  const int warp_size = 1 << warp_bits;
  int idx = hipBlockIdx_x * hipBlockDim_y + hipThreadIdx_y;

  if (idx < ymax
    && (idx == 0 || sorted[idx] != sorted[idx - 1])) {
    do {
      const int start_feature = hipThreadIdx_x + hipBlockIdx_y * hipBlockDim_x * SZ;
      const int dst_row = static_cast<int>(sorted[idx]) * xmax;
      const int src_row = static_cast<int>(index[idx]) * xmax;
      float grad_out[SZ];
      float grad_weight[SZ];
      #pragma unroll
      for (int ii = 0; ii < SZ; ii++)
      {
        int feature_dim = start_feature + ii * warp_size;
        if (feature_dim < xmax)
        {
          grad_out[ii] = src[src_row + feature_dim];
          grad_weight[ii] = dst[dst_row + feature_dim];
        }
      }

      #pragma unroll
      for (int ii = 0; ii < SZ; ii++) {
        grad_weight[ii] += grad_out[ii];
      }

      #pragma unroll
      for (int ii = 0; ii < SZ; ii++) {
        int feature_dim = start_feature + ii * warp_size;
        if (feature_dim < xmax) {
          dst[dst_row + feature_dim] = grad_weight[ii];
        }
      }
      idx++;
    } while (idx < ymax && (sorted[idx] == sorted[idx - 1]));
  }
}

template<typename IndexType, typename DType>
inline void AddTakeGrad(Tensor<gpu, 2, DType> dst,
                        const Tensor<gpu, 1, IndexType>& index,
                        const Tensor<gpu, 2, DType> &src) {
  CHECK_EQ(dst.CheckContiguous(), true);
  CHECK_EQ(index.CheckContiguous(), true);
  CHECK_EQ(src.CheckContiguous(), true);
  const int kUnitBits = kMemUnitBits + 1;
  dim3 dimBlock(1 << kUnitBits);
  dim3 dimGrid((dst.size(1) + (1 << kUnitBits) - 1) >> kUnitBits);

  CHECK_EQ(dst.size(1), src.size(1)) << "AddTakeGrad: shape mismatch";
  CHECK_EQ(index.size(0), src.size(0)) << "AddTakeGrad: shape mismatch";
  CheckLaunchParam(dimGrid, dimBlock, "AddTakeGrad");
  hipStream_t stream = Stream<gpu>::GetStream(dst.stream_);
  const int K = dst.shape_[0];

  hipLaunchKernel(HIP_KERNEL_NAME(AddTakeGradKernel<kUnitBits, DType>), dim3(dimGrid), dim3(dimBlock), 0, stream, expr::MakePlan(dst),
       expr::MakePlan(index),
       expr::MakePlan(src),
       src.size(0),
       src.size(1), K);
  MSHADOW_CUDA_POST_KERNEL_CHECK(AddTakeGradKernel);
}

template<typename IndexType, typename DType>
inline void AddTakeGradLargeBatch(Tensor<gpu, 2, DType> dst,
                                  const Tensor<gpu, 1, IndexType>& sorted,
                                  const Tensor<gpu, 1, IndexType>& index,
                                  const Tensor<gpu, 2, DType> &src) {
  CHECK_EQ(dst.CheckContiguous(), true);
  CHECK_EQ(sorted.CheckContiguous(), true);
  CHECK_EQ(index.CheckContiguous(), true);
  CHECK_EQ(src.CheckContiguous(), true);
  const int kWarpBits = kMemUnitBits;
  const int SZ = 4;
  const int block_dim_x = 1 << kWarpBits;
  const int block_dim_y = 4;
  const int grid_dim_x = (src.size(0) + block_dim_y - 1) / block_dim_y;
  const int grid_dim_y = (src.size(1) + block_dim_x * SZ - 1) / (block_dim_x * SZ);
  dim3 dimBlock(block_dim_x, block_dim_y);
  dim3 dimGrid(grid_dim_x, grid_dim_y);

  CHECK_EQ(dst.size(1), src.size(1)) << "AddTakeGradLargeBatch: shape mismatch";
  CHECK_EQ(index.size(0), src.size(0)) << "AddTakeGradLargeBatch: shape mismatch";
  CheckLaunchParam(dimGrid, dimBlock, "AddTakeGradLargeBatch");
  hipStream_t stream = Stream<gpu>::GetStream(dst.stream_);

  hipLaunchKernel(HIP_KERNEL_NAME(AddTakeGradLargeBatchKernel<kWarpBits, SZ, DType>), dim3(dimGrid), dim3(dimBlock), 0, stream, dst.dptr_,
       sorted.dptr_,
       index.dptr_,
       src.dptr_,
       static_cast<int>(src.size(0)),
       static_cast<int>(src.size(1)));
  MSHADOW_CUDA_POST_KERNEL_CHECK(AddTakeGradLargeBatchKernel);
}

template<int warp_bits, typename DType, typename DstPlan, typename IndexPlan, typename SrcPlan>
__global__ void IndexFillKernel( DstPlan dst,
                                IndexPlan index, SrcPlan src,
                                index_t ymax, int xmax) {
  int src_idx = hipBlockIdx_x * hipBlockDim_y + hipThreadIdx_y;
  if (src_idx < ymax) {
    int dst_idx = static_cast<int>(index.Eval(0, src_idx));
    for (int i = hipThreadIdx_x; i < xmax; i += hipBlockDim_x) {
      dst.REval(dst_idx, i) = src.Eval(src_idx, i);
    }
  }
}

template<typename IndexType, typename DType>
inline void IndexFill(Tensor<gpu, 2, DType> dst,
                      const Tensor<gpu, 1, IndexType>& index,
                      const Tensor<gpu, 2, DType> &src) {
  CHECK_EQ(dst.CheckContiguous(), true);
  CHECK_EQ(index.CheckContiguous(), true);
  CHECK_EQ(src.CheckContiguous(), true);
  CHECK_EQ(dst.size(1), src.size(1)) << "IndexFill: shape mismatch";
  CHECK_EQ(index.size(0), src.size(0)) << "IndexFill: shape mismatch";
  const int block_dim_x = 1 << kMemUnitBits;
  const int block_dim_y = 4;
  const int grid_dim_x = (src.size(0) + block_dim_y - 1) / block_dim_y;
  dim3 dimBlock(block_dim_x, block_dim_y);
  dim3 dimGrid(grid_dim_x);
  CheckLaunchParam(dimGrid, dimBlock, "IndexFill");
  hipStream_t stream = Stream<gpu>::GetStream(dst.stream_);

  hipLaunchKernel(HIP_KERNEL_NAME(IndexFillKernel<kMemUnitBits, DType>), dim3(dimGrid), dim3(dimBlock), 0, stream, expr::MakePlan(dst),
       expr::MakePlan(index),
       expr::MakePlan(src),
       src.size(0),
       src.size(1));
  MSHADOW_CUDA_POST_KERNEL_CHECK(IndexFillKernel);
}

template<typename KDType, typename VDType>
inline void SortByKey(Tensor<gpu, 1, KDType> keys, Tensor<gpu, 1, VDType> values,
                      bool is_ascend) {
  CHECK_EQ(keys.CheckContiguous(), true);
  CHECK_EQ(values.CheckContiguous(), true);
#if CUDA_VERSION >= 7000
  hipStream_t stream = Stream<gpu>::GetStream(keys.stream_);
  thrust::device_ptr<KDType> key_iter = thrust::device_pointer_cast(keys.dptr_);
  thrust::device_ptr<VDType> value_iter = thrust::device_pointer_cast(values.dptr_);
  if (is_ascend) {
    thrust::stable_sort_by_key(
      thrust::cuda::par.on(stream),
      key_iter, key_iter + keys.size(0), value_iter, thrust::less<KDType>());
  } else {
    thrust::stable_sort_by_key(
      thrust::cuda::par.on(stream),
      key_iter, key_iter + keys.size(0), value_iter, thrust::greater<KDType>());
  }
  MSHADOW_CUDA_POST_KERNEL_CHECK(SortByKey);
#else
  LOG(FATAL) << "SortByKey is only supported for CUDA version >=7.0!";
#endif
}

template<typename DType>
inline void SortByKey(Tensor<gpu, 1, mshadow::half::half_t> keys, Tensor<gpu, 1, DType> values,
                      bool is_ascend) {
  LOG(FATAL) << "SortByKey for half_t is not implemented!";
}

template<typename DType>
inline void SortByKey(Tensor<gpu, 1, DType> keys, Tensor<gpu, 1, mshadow::half::half_t> values,
  bool is_ascend) {
  LOG(FATAL) << "SortByKey for half_t is not implemented!";
}
}  // namespace cuda
}  // namespace mshadow
#endif  // MSHADOW_CUDA_TENSOR_GPU_INL_CUH_
