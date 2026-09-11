#include "gpu_funcs.h"

__global__ void gpu_mmio_write_kernel(volatile uint32_t *dbl, uint32_t val){
	*dbl = val;
}

extern "C" void gpu_mmio_write(volatile uint32_t *dbl, uint32_t val)
{
    	gpu_mmio_write_kernel<<<1, 1>>>(dbl, val);
    	cudaDeviceSynchronize();
}
