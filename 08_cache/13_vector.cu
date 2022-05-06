#include <iostream>
#include <typeinfo>
#include <random>
#include <stdint.h>
#include <cublas_v2.h>
#include <chrono>
using namespace std;

__global__ void kernel(int dim_m, int dim_n, int dim_k,
		       float *d_a, float *d_b, float *d_c) {
  int offset_a_m = 64 * blockIdx.x;
  int offset_b_n = 64 * blockIdx.y;
  int a_m = threadIdx.x % 8 * 8;
  int a_k = threadIdx.x / 8;
  int b_n = threadIdx.x;

  struct __align__(16) vec_t { float d[8]; };
  vec_t *tile_a;
  vec_t *tile_b;
  vec_t __align__(16) thread_a;
  vec_t __align__(16) thread_b;
  __shared__ float __align__(16) block_a[8][64];
  __shared__ float __align__(16) block_b[8][64];
  float __align__(16) fragment_a[8];
  float __align__(16) fragment_b[8];
  float __align__(16) fragment_c[8][8];

  tile_a = reinterpret_cast<vec_t*>(&d_a[offset_a_m + a_m + a_k * dim_m]);
  tile_b = reinterpret_cast<vec_t*>(&d_b[(offset_b_n + b_n) * dim_k]);
  for (int m = 0; m < 8; ++m)
    for (int n = 0; n < 8; ++n)
      fragment_c[m][n] = 0;

  int warp_id = threadIdx.x / 32;
  int warp_x = 0;
  int warp_y = warp_id;
  int lane_id = threadIdx.x % 32;
  int lane_x = lane_id / 4;
  int lane_y = lane_id % 4;
  int offset_x = warp_x * 64 + lane_x * 8;
  int offset_y = warp_y * 32 + lane_y * 8;
  int offset_a_k = 0;
  int offset_b_k = 0;
  for (int kk = 0; kk < dim_k; kk += 8) {
    thread_a = tile_a[offset_a_k];
    thread_b = tile_b[offset_b_k];
    __syncthreads();
    for (int j = 0; j < 8; ++j) {
      block_a[a_k][a_m + j] = thread_a.d[j];
      block_b[j][b_n] = thread_b.d[j];
    }
    __syncthreads();
    offset_a_k += dim_m;
    offset_b_k ++;
#pragma unroll
    for (int k = 0; k < 8; k++) {
      for (int j = 0; j < 8; ++j) {
	fragment_a[j] = block_a[k][offset_y + j];
	fragment_b[j] = block_b[k][offset_x + j];
      }
      for (int m = 0; m < 8; ++m) {
	for (int n = 0; n < 8; ++n) {
	  fragment_c[m][n] += fragment_a[m] * fragment_b[n];
	}
      }
    }
  }
  for (int j = 0; j < 8; ++j) {
    int tx = offset_x + j;
    int ty = offset_y;
    int bx = 64 * blockIdx.y + tx;
    int by = 64 * blockIdx.x + ty;
    for (int i = 0; i < 8; ++i) {
      if (bx < dim_n && (by + i) < dim_m) {
	d_c[bx * dim_m + by + i] = fragment_c[i][j];
      }
    }
  }
}

int main(int argc, const char **argv) {
  int m = 10240;
  int k = 4096;
  int n = 8192;
  float alpha = 1.0;
  float beta = 0.0;
  int Nt = 10;
  float *A, *B, *C, *C2;
  cudaMallocManaged(&A, m * k * sizeof(float));
  cudaMallocManaged(&B, k * n * sizeof(float));
  cudaMallocManaged(&C, m * n * sizeof(float));
  cudaMallocManaged(&C2, m * n * sizeof(float));
  for (int i=0; i<m; i++)
    for (int j=0; j<k; j++)
      A[k*i+j] = drand48();
  for (int i=0; i<k; i++)
    for (int j=0; j<n; j++)
      B[n*i+j] = drand48();
  for (int i=0; i<n; i++)
    for (int j=0; j<m; j++)
      C[m*i+j] = C2[m*i+j] = 0;
  cublasHandle_t cublas_handle;
  cublasCreate(&cublas_handle);
  auto tic = chrono::steady_clock::now();
  for (int i = 0; i < Nt+2; i++) {
    if (i == 2) tic = chrono::steady_clock::now();
    cublasSgemm(cublas_handle,
		CUBLAS_OP_N,
		CUBLAS_OP_N,
		m,
		n,
		k,
		&alpha,
		A,
		m,
		B,
		k,
		&beta,
		C,
		m);
    cudaDeviceSynchronize();
  }
  auto toc = chrono::steady_clock::now();
  int64_t num_flops = (2 * int64_t(m) * int64_t(n) * int64_t(k)) + (2 * int64_t(m) * int64_t(n));
  double tcublas = chrono::duration<double>(toc - tic).count() / Nt;
  double cublas_flops = double(num_flops) / tcublas / 1.0e9;
  int tile = 64;
  dim3 block = dim3(tile);
  dim3 grid = dim3((m+tile-1)/tile, (n+tile-1)/tile);
  for (int i = 0; i < Nt+2; i++) {
    if (i == 2) tic = chrono::steady_clock::now();
    kernel<<< grid, block >>>(m,
			      n,
			      k,
			      A,
			      B,
			      C2);
    cudaDeviceSynchronize();
  }
  toc = chrono::steady_clock::now();
  double tcutlass = chrono::duration<double>(toc - tic).count() / Nt;
  double cutlass_flops = double(num_flops) / tcutlass / 1.0e9;
  printf("CUBLAS: %.2f Gflops, CUTLASS: %.2f Gflops\n", cublas_flops, cutlass_flops);
  double err = 0;
  for (int i=0; i<n; i++) {
    for (int j=0; j<m; j++) {
      err += fabs(C[m*i+j] - C2[m*i+j]);
    }
  }
  printf("error: %lf\n", err/n/m);
  cudaFree(A);
  cudaFree(B);
  cudaFree(C);
  cudaFree(C2);
  cublasDestroy(cublas_handle);
}