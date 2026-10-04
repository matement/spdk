#include "spdk_internal/gpu_qpair.h"
#include <stdio.h>

int translate_to_gpu(struct gpu_qpair *q){
	struct spdk_nvme_cmd *cmd = q->cmd;              
        volatile struct spdk_nvme_cpl *cpl = q->cpl;

	struct spdk_nvme_cmd *dev_cmd = NULL;
	struct spdk_nvme_cpl *dev_cpl = NULL;
	cudaError_t err = cudaHostRegister(cmd, (q->size)*sizeof(struct spdk_nvme_cmd), cudaHostRegisterMapped);
	if(err != cudaSuccess) {
		fprintf(stderr, "gpu_qpair: cudaHostRegister(SQ) failed: %s\n", cudaGetErrorString(err));
		return -1;
	}
	err = cudaHostGetDevicePointer((void **)&dev_cmd, cmd, 0);
	if(err != cudaSuccess) {
		fprintf(stderr, "gpu_qpair: cudaHostGetDevicePointer(SQ) failed: %s\n", cudaGetErrorString(err));
		cudaHostUnregister((void *)cmd);
		return -1;
	}
	err = cudaHostRegister((void *)cpl, (q->size)*sizeof(struct spdk_nvme_cpl), cudaHostRegisterMapped);
	if(err != cudaSuccess){ 
		fprintf(stderr, "gpu_qpair: cudaHostRegister(CQ) failed: %s\n", cudaGetErrorString(err));
		cudaHostUnregister((void *)cmd);
		return -1;
	}
	err = cudaHostGetDevicePointer((void **)&dev_cpl, (void *)cpl, 0);
	if(err != cudaSuccess) {
		fprintf(stderr, "gpu_qpair: cudaHostGetDevicePointer(CQ) failed: %s\n", cudaGetErrorString(err));
		cudaHostUnregister((void *)cmd);
		cudaHostUnregister((void *)cpl);
		return -1;
	
	}
	
	q->cmd = dev_cmd;
	q->cpl = (volatile spdk_nvme_cpl *)dev_cpl;
	

	return 0;
}
