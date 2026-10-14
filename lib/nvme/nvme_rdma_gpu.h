/*   SPDX-License-Identifier: BSD-3-Clause
 *   Copyright (C) 2026 Hyungsun Yoo.
 *   All rights reserved.
 */

/*
 * GPU I/O queues for the RDMA transport.
 *
 * A GPU queue is connected through the same steps as any RDMA queue in
 * nvme_rdma.c. Where its handling differs (its queue pair and completion queues
 * are in GPU memory, its buffers are GPU memory, and the GPU sends its Fabrics
 * Connect), nvme_rdma.c calls the nvme_rdma_gpu_qpair_*() functions below,
 * implemented in nvme_rdma_gpu.cu. The queues created together form a set that
 * shares the GPU and NIC handles and the GPU memory (nvme_rdma_gpu_set_*()).
 */

#ifndef SPDK_NVME_RDMA_GPU_H
#define SPDK_NVME_RDMA_GPU_H

#include "spdk/stdinc.h"
#include "spdk/nvmf_spec.h"

#ifdef __cplusplus
extern "C" {
#endif

struct rdma_cm_id;
struct spdk_nvme_qpair;
struct spdk_nvme_gpu_qpair;

/* What the queues of a set share. Its layout is private to nvme_rdma_gpu.cu. */
struct nvme_rdma_gpu_set;

/* Host-side state of one GPU queue. Its layout is private to nvme_rdma_gpu.cu. */
struct nvme_rdma_gpu_qpair;

/* What a GPU queue's Fabrics Connect command carries. Filled in by nvme_rdma.c. */
struct nvme_rdma_gpu_connect_info {
	uint16_t				qid;
	/* Queue size, 0-based. */
	uint16_t				sqsize;
	uint32_t				kato;
	bool					disable_sq_flow_control;
	struct spdk_nvmf_fabric_connect_data	data;
};

/* nvme_rdma_gpu.cu */

/*
 * Allocate a set of num_qpairs GPU queues. Nothing is created on the GPU or the NIC
 * until its first queue's route is resolved.
 */
struct nvme_rdma_gpu_set *nvme_rdma_gpu_set_alloc(uint32_t nsid, uint32_t num_qpairs,
		uint32_t num_slots, uint32_t slot_size, uint32_t block_size);

/* Release what the set shares. Every queue of the set must be destroyed first. */
void nvme_rdma_gpu_set_free(struct nvme_rdma_gpu_set *set);

/* Device-side views of the set's queues, an array in GPU memory. */
struct spdk_nvme_gpu_qpair *nvme_rdma_gpu_set_get_device(struct nvme_rdma_gpu_set *set);

/* Allocate the host-side state of queue index of a set. */
struct nvme_rdma_gpu_qpair *nvme_rdma_gpu_qpair_alloc(struct nvme_rdma_gpu_set *set,
		uint32_t index);

/* Free what nvme_rdma_gpu_qpair_alloc() allocated. Call nvme_rdma_gpu_qpair_destroy() first. */
void nvme_rdma_gpu_qpair_free(struct nvme_rdma_gpu_qpair *gq);

/* Create the queue pair and its completion queues in GPU memory, once the route is resolved. */
int nvme_rdma_gpu_qpair_create(struct nvme_rdma_gpu_qpair *gq, struct rdma_cm_id *cm_id);

/* Number of the queue pair, sent in the connection request. */
uint32_t nvme_rdma_gpu_qpair_get_qp_num(struct nvme_rdma_gpu_qpair *gq);

/* Move the queue pair to ready-to-send once the target accepted the connection, and finish it. */
int nvme_rdma_gpu_qpair_complete_connect(struct nvme_rdma_gpu_qpair *gq, struct rdma_cm_id *cm_id);

/* Prepare every command of the queue in its part of the set's buffer pool. */
int nvme_rdma_gpu_qpair_prepare(struct nvme_rdma_gpu_qpair *gq,
				const struct nvme_rdma_gpu_connect_info *info);

/* Have the GPU post the receive buffers, send the Fabrics Connect and check its response. */
int nvme_rdma_gpu_qpair_fabric_connect(struct nvme_rdma_gpu_qpair *gq);

/* Release the queue's queue pairs. Safe to call more than once. */
void nvme_rdma_gpu_qpair_destroy(struct nvme_rdma_gpu_qpair *gq);

/* nvme_rdma.c */

/*
 * Make an RDMA queue that is created but not connected a GPU queue. The queue takes
 * ownership of gq.
 */
int nvme_rdma_qpair_set_gpu(struct spdk_nvme_qpair *qpair, struct nvme_rdma_gpu_qpair *gq,
			    uint32_t num_slots);

#ifdef __cplusplus
}
#endif

#endif /* SPDK_NVME_RDMA_GPU_H */
