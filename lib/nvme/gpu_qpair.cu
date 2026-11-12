#include "spdk_internal/gpu_qpair.h"
#include <stdio.h>

#define GPU_POLL_LIMIT 1000000

__device__ void build_read_cmd(struct spdk_nvme_cmd *c, uint16_t cid,
                               uint64_t prp1, uint64_t lba)
{
        memset(c, 0, sizeof(*c));          /* start from all zeros, so no stale fields */

        c->opc = SPDK_NVME_OPC_READ;    /* the opcode, 0x02 */
        c->cid = cid;                   /* the command ID */
        c->nsid = 1;                    /* the namespace */
        c->dptr.prp.prp1 = prp1;        /* the buffer's bus address */
        c->cdw10 = (uint32_t)lba;	/* low 32 bits of the LBA */
        c->cdw11 = (uint32_t)(lba>>32); /* high 32 bits of the LBA */
        c->cdw12 = 0;			/* number of blocks minus 1 */
}

__global__ void gpu_read_one(struct gpu_qpair q, uint16_t cid, uint64_t prp1, uint64_t lba){
	uint64_t slot = q.sq_tail;
	if(q.cq_dead_flag == 1){
		printf("the cq is dead. Cannot continue\n");
		return;
	}
	struct spdk_nvme_cmd local;

	build_read_cmd(&local, cid, prp1, lba);
	q.cmd[slot] = local;

	slot = (slot+1)%q.size;
	__threadfence_system();	
	*q.gpu_sq_tdbl = slot;
}

__global__ void gpu_complete_one(struct gpu_qpair q, uint16_t cid, int* perrorCode){
	uint16_t head = q.cq_head;
	uint8_t phase = q.phase;
	int i = 0;
	while(i < GPU_POLL_LIMIT){
		if(q.cpl[head].status.p == phase){
			break;
		}
		i++;
	}
	if(i == GPU_POLL_LIMIT){
		printf("GPU timeout\n");
		*perrorCode = timeoutError;
		return;
	}

	__threadfence_system();
	if(q.cpl[head].cid != cid){
		printf("Missmatch between cids (actual %u, expected %u)\n", q.cpl[head].cid, cid);
		*perrorCode = cidError;
		return;
	}

	if(q.cpl[head].status.sc != 0 || q.cpl[head].status.sct != 0){
		printf("missmach between status.sc: %u (expected %u) and status.sct: %u (expected %u)\n", 
			q.cpl[head].status.sc, 0, q.cpl[head].status.sct, 0);
			*perrorCode = statusError;
	}
	
	head = (head+1)%(q.size);
	*(q.gpu_cq_hdbl) = head;

}

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

extern "C" int gpu_read_one_host(struct gpu_qpair *q, uint64_t cid, uint64_t prp1, uint64_t lba){
	if(q->cq_dead_flag == 1){
		printf("the cq is dead. Cannot continue\n");
		return -1;
	}
	int *hostErrorCode;	
	int *devErrorCode;
	cudaHostAlloc((void**)&hostErrorCode, sizeof(int), cudaHostAllocMapped);
	*hostErrorCode = 0;
	cudaHostGetDevicePointer((void**)&devErrorCode, (void*)hostErrorCode, 0);
        gpu_read_one<<<1, 1>>>(*q, cid, prp1, lba);
	cudaError_t err = cudaGetLastError();
	gpu_complete_one<<<1, 1>>>(*q, cid, devErrorCode);
	cudaError_t err2 = cudaGetLastError();
	if(err != cudaSuccess){
		fprintf(stderr, "Launch failure of read_one %s\n", cudaGetErrorString(err));
		cudaFreeHost(hostErrorCode);
		return -1;
	}
	if(err2 != cudaSuccess){
		fprintf(stderr, "Launch failure of complete_one %s\n", cudaGetErrorString(err2));
		cudaFreeHost(hostErrorCode);
		return -1;
	}
	err = cudaDeviceSynchronize();
	if(err != cudaSuccess){
		fprintf(stderr, "Kernel failure %s\n", cudaGetErrorString(err));
		cudaFreeHost(hostErrorCode);
		return -1;
	}
	int errorcode = *hostErrorCode;
	cudaFreeHost(hostErrorCode);
	if(errorcode == cidError){
		printf("Cid mismatch\n");
		q->cq_dead_flag = 1;
		return -1;
	}
	else if(errorcode == timeoutError){
		q->sq_tail = (q->sq_tail+1)%q->size;
		q->cq_dead_flag = 1;
		return -1;
	}
	q->sq_tail = (q->sq_tail+1)%q->size;
	q->cq_head = (q->cq_head+1)%q->size;
	if(q->cq_head == 0){
		q->phase ^= 1;
	}
	if(errorcode == statusError){
		printf("Something failed at completion\n");
		return -1;
	}
	return 0;
}
