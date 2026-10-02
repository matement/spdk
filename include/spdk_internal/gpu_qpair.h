#ifndef GPU_QPAIR
#define GPU_QPAIR

#include "spdk/nvme_spec.h"
#include <stdint.h>

struct gpu_qpair{
	struct spdk_nvme_cmd *cmd;		//submition queue
	volatile struct spdk_nvme_cpl *cpl; 	//completion queue
	volatile uint32_t *gpu_sq_tdbl;		//sq doorbell register
	volatile uint32_t *gpu_cq_hdbl;		//cq doorbell register
	uint16_t size;				//the size of the queues
	uint16_t sq_tail;			//position we write into in the sq 
	uint16_t cq_head;			//position we write into in the cq
	uint8_t phase;				//tbh idk wth is this one
};
#endif
