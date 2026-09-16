#ifndef GPU_SPDK_HEADER_FILE
#define GPU_SPDK_HEADER_FILE

#include <cuda_runtime_api.h>
void gpu_mmio_write(volatile uint32_t *dbl, uint32_t val);

#endif
