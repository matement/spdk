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

	struct spdk_nvme_cmd local;

	build_read_cmd(&local, cid, prp1, lba);
	q.cmd[slot] = local;

	slot = (slot+1)%q.size;
	__threadfence_system();	
	*q.gpu_sq_tdbl = slot;
}

__global__ void gpu_complete_one(struct gpu_qpair q, uint16_t cid){
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
		return;
	}

	__threadfence_system();
	if(q.cpl[head].cid != cid || q.cpl[head].status.sc != 0 || q.cpl[head].status.sct != 0){
		printf("missmach between cid: %u (expected %u), status.sc: %u and status.cst: %u\n", 
			q.cpl[head].cid, cid, q.cpl[head].status.sc, q.cpl[head].status.sct);
			return;
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

extern "C" int gpu_read_one_host(struct gpu_qpair *q, uint64_t cid, uint64_t prp1, uint64_t lba)
{
        gpu_read_one<<<1, 1>>>(*q, cid, prp1, lba);
	cudaError err = cudaGetLastError();
	gpu_complete_one<<<1, 1>>>(*q, cid);
	cudaError_t err2 = cudaGetLastError();
	if(err != cudaSuccess){
		fprintf(stderr, "Launch failure of read_one %s\n", cudaGetErrorString(err));
		return -1;
	}
	if(err2 != cudaSuccess){
		fprintf(stderr, "Launch failure of complete_one %s\n", cudaGetErrorString(err2));
		return -1;
	}

	err = cudaDeviceSynchronize();
	if(err != cudaSuccess){
		fprintf(stderr, "Kernel failure %s\n", cudaGetErrorString(err));
		return -1;
	}

	q->sq_tail = (q->sq_tail+1)%q->size;
	q->cq_head = (q->cq_head+1)%q->size;
	if(q->cq_head == 0){
		q->phase ^= 1;
	}
	return 0;
}
