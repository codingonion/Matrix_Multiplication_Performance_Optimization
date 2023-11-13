#include "../include/gemm.h"
#include <fstream>

#define TSM 128 // Tile-size in dim M
#define TSN 128 // Tile-size in dim N
#define TSK 16  // Tile-size in dim K
#define WPTM 8  // works per thread in dim M
#define WPTN 8  // works per thread in dim N
#define RTSM (TSM / WPTM) // The reduce tile-size in dim M(thread nums in dim M)
#define RTSN (TSN / WPTN) // The reduce tile-size in dim M(thread nums in dim N)
#define LPTA ((TSK * TSM) / (RTSM * RTSN)) // Load-per-thread for A
#define LPTB ((TSK * TSN) / (RTSM * RTSN)) // Load-per-thread for B

__global__ void gemm_tiling_wpt_block_rect_kernel(const int M, const int N, const int K, float* A, float* B, float* C)
{
    /* M×K * K×N = M×N */
    __shared__ float Ads[TSM][TSK];
    __shared__ float Bds[TSK][TSN + 2];

    Ads[threadIdx.y][threadIdx.x] = 0.;
    Bds[threadIdx.y][threadIdx.x] = 0.;

    int row = blockIdx.y * TSM + threadIdx.y;
    int col = blockIdx.x * TSN + threadIdx.x;

    /* Init the acc registers */
    float acc[WPTM][WPTN];
    for (int wm = 0; wm < WPTM; wm++)
    {
#pragma unroll
        for (int wn = 0; wn < WPTN; wn++)
        {
            acc[wm][wn] = 0.0f;
        }
    }

    for (int ph = 0; ph < ceil(float(K) / float(TSK)); ph++)
    {
#pragma unroll
        for (int la = 0; la < LPTA; la++)
        {
            int tid = threadIdx.y * RTSM + threadIdx.x;
            int id = la * RTSM * RTSN + tid;
            int rr = id / TSK;
            int cc = id % TSK;
            Ads[rr][cc] = A[(blockIdx.y * TSM + rr) * K + ph * TSK + cc]; // Collaborative
            Bds[cc][rr] = B[(blockIdx.x * TSN + rr) + K * (ph * TSK + cc)]; // Collaborative

            // debug
            /*if(blockIdx.y==1 && blockIdx.x==0 && ph == 0){
                int idx_a = (blockIdx.y*TSM + rr) * K + ph * TSK + cc;
                int idx_b = (blockIdx.x*TSN + cc) + K * (ph * TSK + rr);
                printf("tid=%d, rr=%d, cc=%d, row=%d, col=%d, idx_a=%d, idx_b=%d\n", tid, rr, cc, row, col, idx_a, idx_b);
            }*/

            //debug bank confilct
            /*if(tid < 32){
                int ads_bank_idx = (rr * TSK + cc) % 32;
                int bds_bank_idx = (cc * (TSN+2) + rr) % 32;
                printf("tid=%d, ads_bank_idx=%d, bds_bank_idx=%d\n", tid, ads_bank_idx, bds_bank_idx);
            }*/
        }
        __syncthreads();

#pragma unroll
        for (int i = 0; i < TSK; i++)
        {
#pragma unroll
            for (int wm = 0; wm < WPTM; wm++)
            {
#pragma unroll
                for (int wn = 0; wn < WPTN; wn++)
                {
                    acc[wm][wn] += Ads[threadIdx.y + wm * RTSM][i] * Bds[i][threadIdx.x + wn * RTSN];
                    //debug bank confilct
                    /*int tid = threadIdx.y * (TILE_WIDTH/WPT) + threadIdx.x;
                    if(tid < 32){
                        int ads_bank_idx = ((threadIdx.y + wm*(TILE_WIDTH/WPT)) * TILE_WIDTH + i) ;//% 32;
                        int bds_bank_idx = (i * TILE_WIDTH + threadIdx.x + threadIdx.x + wn*(TILE_WIDTH/WPT)) % 32;
                        printf("tid=%d, ads_bank_idx=%d, bds_bank_idx=%d\n", tid, ads_bank_idx, bds_bank_idx);
                    }*/
                }
            }
        }
        __syncthreads();
    }

#pragma unroll
    for (int wm = 0; wm < WPTM; wm++)
    {
#pragma unroll
        for (int wn = 0; wn < WPTN; wn++)
        {
            if ((row + wm * RTSM) < M && (col + wn * RTSN) < N)
            {
                C[(row + wm * RTSM) * N + col + wn * RTSN] = acc[wm][wn];
            }
        }   
    }
}


void gemm_gpu_tiling_wpt_block_rect(const int M, const int K, const int N, float* A, float* B, float* C, int nIter)
{
    std::cout <<"My gemm gpu tiling wpt." << std::endl;
    double flopsPerMatrixMul = 2.0 * M * N * K;

    /* 0. Malloc gpu for input & output */
    void* d_A = safeCudaMalloc(sizeof(float) * M * K);
    void* d_B = safeCudaMalloc(sizeof(float) * K * N);
    void* d_C = safeCudaMalloc(sizeof(float) * M * N);

    /* 1. Create cuda stream */
    cudaStream_t stream;
    CUDA_CHECK(cudaStreamCreate(&stream));

    /* 2. DMA(Direct Memory Access) the input to the GPU */
    CUDA_CHECK(cudaMemcpyAsync(d_A, A, sizeof(float) * M * K, cudaMemcpyHostToDevice, stream));
    CUDA_CHECK(cudaMemcpyAsync(d_B, B, sizeof(float) * K * N, cudaMemcpyHostToDevice, stream));

    /* 3. Launch kernel */
    dim3 dimBlock(TSM / WPTM, TSN / WPTN, 1);
    dim3 dimGrid(ceil(float(M) / float(dimBlock.x) / float(WPTM)), ceil(float(N) / float(dimBlock.y) / float(WPTN)), 1);
    std::cout<<dimBlock.x<<" "<<dimBlock.y<<" "<<dimGrid.x<<" "<<dimGrid.y<<std::endl;

    cudaEvent_t start, stop;
    CUDA_CHECK(cudaEventCreate(&start));
    CUDA_CHECK(cudaEventCreate(&stop));
    float mseTotal = 0.;

    CUDA_CHECK(cudaEventRecord(start));
    for(int run = 0; run < nIter; ++run)
    {
        gemm_tiling_wpt_block_rect_kernel<<<dimGrid, dimBlock, 0>>>(
            M, K, N,
            static_cast<float*>(d_A),
            static_cast<float*>(d_B),
            static_cast<float*>(d_C)
        );
    }
    CUDA_CHECK(cudaEventRecord(stop));
    CUDA_CHECK(cudaEventSynchronize(stop));
    CUDA_CHECK(cudaEventElapsedTime(&mseTotal, start, stop));

    /* 4. Synchronize device and host */
    CUDA_CHECK(cudaMemcpyAsync(C, d_C, sizeof(float) * M * N, cudaMemcpyDeviceToHost, stream));
    CUDA_CHECK(cudaDeviceSynchronize());

    /* Cal kernel FLOPS */
    double msePerMatrixMul = mseTotal / nIter;
    double gigaFlops = (flopsPerMatrixMul * 1.0e-9f) / (msePerMatrixMul / 1000.0f);
    printf(
        "My gemm Performance = %0.2f GFlops, Time = %0.3f mse, Size = %.0f Ops.\n",
        gigaFlops,
        msePerMatrixMul,
        flopsPerMatrixMul
    );

    /* Cal cublas FLOPS */
    cublasHandle_t blas_handle;
    checkCuBlasErrors(cublasCreate(&blas_handle));
    float alpha = 1.0;
    float beta = 0;
    CUDA_CHECK(cudaEventRecord(start));
    for(int run = 0; run < nIter; ++run)
    {
        checkCuBlasErrors (
            cublasSgemm(
                blas_handle, CUBLAS_OP_T, CUBLAS_OP_T,
                M, N, K, &alpha,
                static_cast<float*>(d_A), M,
                static_cast<float*>(d_B), K,
                &beta,
                static_cast<float*>(d_C), K
            )
        );
    }
    CUDA_CHECK(cudaEventRecord(stop));
    CUDA_CHECK(cudaEventSynchronize(stop));
    CUDA_CHECK(cudaEventElapsedTime(&mseTotal, start, stop));
    std::vector<float> tmp(M * N);
    float* C1 = tmp.data();
    CUDA_CHECK(cudaMemcpyAsync(C1, d_C, sizeof(float) * M * N, cudaMemcpyDeviceToHost, stream));

    msePerMatrixMul = mseTotal / nIter;
    gigaFlops = (flopsPerMatrixMul * 1.0e-9f) / (msePerMatrixMul / 1000.0f);
    printf(
        "My gemm Performance = %0.2f GFlops, Time = %0.3f mse, Size = %.0f Ops.\n",
        gigaFlops,
        msePerMatrixMul,
        flopsPerMatrixMul
    );

    double eps = 1.e-6;
    bool correct = true;
    for (int i = 0; i < M * N; i++)
    {
        // C1 is transpose
        int row = i / N;
        int col = i % N;
        double abs_err = fabs(C[i] - C1[col * M + row]);
        double dot_length = M;
        double abs_val = fabs(C[i]);
        double rel_err = abs_err / abs_val / dot_length;
        if(rel_err > eps)
        {
            printf(
                "Error! Matrix[%05d] = %.8f, ref = %.8f error term is > %E\n",
                i, C[i], C1[col * M + row], eps
            );
            correct = false;
            break;
        }
    }
    printf("Correct = %d\n", correct);

    /* 5. Destroy & Clean */
    cublasDestroy(blas_handle);
    cudaStreamDestroy(stream);
    cudaFree(d_A);
    cudaFree(d_B);
    cudaFree(d_C);
}