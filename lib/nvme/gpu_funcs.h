#ifndef GPU_SPDK_HEADER_FILE
#define GPU_SPDK_HEADER_FILE

#include <stdint.h>
#include <cuda_runtime_api.h>


#ifdef __cplusplus
extern "C"
#endif
void gpu_mmio_write(volatile uint32_t *dbl, uint32_t val);

#endif
