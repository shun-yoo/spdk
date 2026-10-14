/*   SPDX-License-Identifier: BSD-3-Clause
 *   Copyright (C) 2026 Hyungsun Yoo.
 *   Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES.
 *   All rights reserved.
 */

/** \file
 * Device-side functions for GPU-initiated NVMe-oF I/O queues (RDMA transport)
 *
 * Queues created with spdk_nvme_ctrlr_alloc_gpu_io_qpairs() (spdk/nvme_gpu.h) are
 * driven from GPU code with the functions below:
 *
 * - spdk_nvme_gpu_ns_cmd_read() fills a free slot's command with the block address
 *   and sends it. Any GPU thread may call it; the caller keeps track of free slots.
 * - spdk_nvme_gpu_qpair_process_completions() returns the slots whose reads have
 *   completed. Only one GPU thread per queue may call it.
 * - spdk_nvme_gpu_qpair_slot_buf() is where a slot's data lands.
 *
 * The queue uses DOCA GPUNetIO for the GPU's access to the NIC. GPUNetIO's device
 * queue handle has a send side only, so the receive side (posting receive buffers
 * and checking their completions) is implemented here on the same mlx5 structures.
 * nvme_gpu_post_recv(), nvme_gpu_send() and nvme_gpu_poll_recv_at() are adapted
 * from GPUNetIO's doca_gpunetio_dev_verbs_qp.cuh and doca_gpunetio_dev_verbs_cq.cuh.
 */

#ifndef SPDK_NVME_GPU_CUH
#define SPDK_NVME_GPU_CUH

#include "spdk/nvme_spec.h"

#include <linux/types.h>
#include <doca_gpunetio_dev_verbs_qp.cuh>
#include <doca_gpunetio_dev_verbs_cq.cuh>

/** Receive side of a GPU I/O queue's queue pair. */
struct spdk_nvme_gpu_rq {
	/** Receive ring, in GPU memory. */
	uint8_t				*wqe_daddr;

	/** Receive doorbell record. */
	__be32				*dbrec;

	/** Ring entries, a power of two. */
	uint32_t			wqe_num;
	uint32_t			wqe_mask;

	/** Bytes per receive descriptor. */
	uint32_t			wqe_stride;

	/** Producer index. */
	uint64_t			pi;

	/** Completions of received messages. */
	struct doca_gpu_dev_verbs_cq	cq;
};

/** Device-side view of a GPU I/O queue. Filled in on the host. */
struct spdk_nvme_gpu_qpair {
	/** Send side of the queue pair (GPUNetIO handle). */
	struct doca_gpu_dev_verbs_qp	*qp;

	/** Receive side of the queue pair. */
	struct spdk_nvme_gpu_rq		rq;

	/**
	 * Queue pair connected to itself, used to make NIC writes visible in order
	 * before data is read (see nvme_gpu_flush()). NULL when the GPU already
	 * guarantees that order.
	 */
	struct doca_gpu_dev_verbs_qp	*flush_qp;

	/** 64 bytes of scratch memory written by nvme_gpu_flush(). */
	uint8_t				*flush_buf;

	/** The queue's Fabrics Connect capsule, sent once when the queue connects. */
	uint8_t				*connect_capsule;

	/** One prefilled command per slot. */
	struct spdk_nvme_cmd		*cmds;

	/** Response buffers, num_rsps entries, filled by the NIC in receive order. */
	struct spdk_nvme_cpl		*rsps;

	/** Data buffers, num_slots * slot_size bytes. */
	uint8_t				*data;

	/** Send work request index of each slot's last command. */
	uint64_t			*slot_wqe;

	/** Local and remote memory keys of all of the above. */
	uint32_t			lkey;
	uint32_t			rkey;

	uint32_t			num_slots;

	/** Number of response buffers, a power of two not smaller than num_slots. */
	uint32_t			num_rsps;

	/** Bytes of each slot's data buffer. */
	uint32_t			slot_size;

	/** log2 of the namespace block size. */
	uint32_t			block_shift;
};

/*
 * Post one receive buffer. Each message from the target consumes one; with none
 * posted the target drops the connection. Only one thread per queue posts.
 */
__device__ static __forceinline__ void
nvme_gpu_post_recv(struct spdk_nvme_gpu_rq *rq, uint64_t addr, uint32_t lkey, uint32_t bytes)
{
	uint64_t idx = rq->pi++;
	struct doca_gpunetio_ib_mlx5_wqe_data_seg wqe;

	wqe.byte_count = doca_gpu_dev_verbs_bswap32(bytes);
	wqe.lkey = doca_gpu_dev_verbs_bswap32(lkey);
	wqe.addr = doca_gpu_dev_verbs_bswap64(addr);
	doca_gpu_dev_verbs_store_wqe_seg((uint64_t *)(rq->wqe_daddr + (idx & rq->wqe_mask) *
					 rq->wqe_stride),
					 (uint64_t *)&wqe);

	/*
	 * A receive queue has no doorbell register, only the doorbell record in memory.
	 * Write it after a release fence with the library's store, so that the compiler
	 * cannot drop or merge it (only the NIC reads it).
	 */
	doca_gpu_dev_verbs_fence_release<DOCA_GPUNETIO_VERBS_SYNC_SCOPE_SYS>();
	doca_gpu_dev_common_update_dbr((uint32_t *)rq->dbrec, (uint32_t)rq->pi);
}

/*
 * Send one message. This is GPUNetIO's RDMA write work request with the send opcode
 * and without the remote address segment. The send work request index is stored in
 * *wqe_out before the doorbell is rung, so that it is in place before the response
 * can arrive. Safe from many threads.
 */
__device__ static __forceinline__ void
nvme_gpu_send(struct doca_gpu_dev_verbs_qp *qp, uint64_t addr, uint32_t lkey, uint32_t bytes,
	      uint64_t *wqe_out)
{
	uint64_t wqe_idx = doca_gpu_dev_verbs_reserve_wq_slots <
			   DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU, DOCA_GPUNETIO_VERBS_QP_SQ > (qp, 1);
	struct doca_gpu_dev_verbs_wqe *wqe = doca_gpu_dev_verbs_get_wqe_ptr(qp, wqe_idx);
	struct doca_gpunetio_ib_mlx5_wqe_ctrl_seg cseg;
	struct doca_gpunetio_ib_mlx5_wqe_data_seg dseg;

	/* The index field is 16 bits; the bits above it hold the opcode modifier. */
	cseg.opmod_idx_opcode = doca_gpu_dev_verbs_bswap32(((uint32_t)(uint16_t)wqe_idx <<
				DOCA_GPUNETIO_VERBS_WQE_IDX_SHIFT) |
				DOCA_GPUNETIO_IB_MLX5_OPCODE_SEND);
	cseg.qpn_ds = doca_gpu_dev_verbs_load_const(&qp->sq_num_shift8_be_2ds);
	cseg.fm_ce_se = DOCA_GPUNETIO_IB_MLX5_WQE_CTRL_CQ_UPDATE;
	cseg.imm = 0;

	dseg.byte_count = doca_gpu_dev_verbs_bswap32(bytes);
	dseg.lkey = doca_gpu_dev_verbs_bswap32(lkey);
	dseg.addr = doca_gpu_dev_verbs_bswap64(addr);

	doca_gpu_dev_verbs_store_wqe_seg((uint64_t *) & (wqe->dseg0), (uint64_t *)&cseg);
	doca_gpu_dev_verbs_store_wqe_seg((uint64_t *) & (wqe->dseg1), (uint64_t *)&dseg);

	*wqe_out = wqe_idx;

	doca_gpu_dev_verbs_mark_wqes_ready<DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU>(qp, wqe_idx,
			wqe_idx);
	doca_gpu_dev_verbs_submit <DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
				  DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU,
				  DOCA_GPUNETIO_VERBS_NIC_HANDLER_GPU_SM_DB > (qp, wqe_idx + 1);
}

/*
 * Check receive completion cons_index without waiting. Return 0 if it has arrived,
 * EBUSY if not, -EIO if it reports an error.
 *
 * GPUNetIO's poller is written for send queues and treats only the send error
 * opcode as an error; a failed receive reports the receive error opcode.
 */
__device__ static __forceinline__ int
nvme_gpu_poll_recv_at(struct doca_gpu_dev_verbs_cq *cq, uint64_t cons_index)
{
	uint8_t *base = (uint8_t *)doca_gpu_dev_verbs_load_const((uintptr_t *)&cq->cqe_daddr);
	const uint32_t cqe_num = doca_gpu_dev_verbs_load_const(&cq->cqe_num);
	struct doca_gpunetio_ib_mlx5_cqe64 *cqe64 = (struct doca_gpunetio_ib_mlx5_cqe64 *)(base +
			(cons_index & (cqe_num - 1)) * DOCA_GPUNETIO_VERBS_CQE_SIZE);

	uint64_t cqe_ci = doca_gpu_dev_verbs_load_relaxed<DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU>
			  (&cq->cqe_ci);
	if (cons_index < cqe_ci) {
		return 0;
	}
	if (cons_index >= cqe_ci + cqe_num) {
		return EBUSY;
	}

	/*
	 * Read the owner bit and the WQE counter together and require both to match:
	 * the ring is reused, so the owner bit alone cannot tell this pass from the
	 * previous one.
	 */
	uint32_t chunk = doca_gpu_dev_verbs_load_relaxed_sys_global(&cqe64->wqe_counter_sig_op_own_raw);
	chunk = doca_gpu_dev_verbs_bswap32(chunk);
	uint16_t wqe_counter = (uint16_t)(chunk >> 16);
	uint8_t opown = (uint8_t)(chunk & 0xff);

	bool observed = !((opown & DOCA_GPUNETIO_IB_MLX5_CQE_OWNER_MASK) ^ !!(cons_index & cqe_num)) &&
			(wqe_counter == ((uint32_t)cons_index & 0xffff));
	if (!observed) {
		return EBUSY;
	}

	uint8_t opcode = opown >> DOCA_GPUNETIO_VERBS_MLX5_CQE_OPCODE_SHIFT;
	return (opcode == DOCA_GPUNETIO_IB_MLX5_CQE_RESP_ERR) * -EIO;
}

/*
 * Make every NIC write to GPU memory issued so far visible to this GPU.
 *
 * On some systems NIC writes into GPU memory may become visible out of order, so a
 * completion can be seen before the data or response it announces. Making the NIC
 * read GPU memory once fixes this: PCIe orders a device's read behind its earlier
 * writes. GPUNetIO does this with a dump work request, which some NICs (ConnectX-5)
 * reject; a one-byte RDMA write on a queue pair connected to itself does the same,
 * since the NIC must read the source byte from GPU memory. Whether a system needs
 * this is decided when the queue is created (flush_qp is NULL if not).
 *
 * Return 0 on success.
 */
__device__ static __forceinline__ int
nvme_gpu_flush(struct spdk_nvme_gpu_qpair *q)
{
	struct doca_gpu_dev_verbs_qp *qp = q->flush_qp;
	uint64_t wqe_idx = doca_gpu_dev_verbs_reserve_wq_slots <
			   DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU, DOCA_GPUNETIO_VERBS_QP_SQ > (qp, 1);
	struct doca_gpu_dev_verbs_wqe *wqe = doca_gpu_dev_verbs_get_wqe_ptr(qp, wqe_idx);

	/* Keys are passed big-endian (DOCA_GPUNETIO_VERBS_MKEY_SWAPPED). */
	doca_gpu_dev_verbs_wqe_prepare_write(qp, wqe, (uint16_t)wqe_idx,
					     DOCA_GPUNETIO_IB_MLX5_OPCODE_RDMA_WRITE,
					     DOCA_GPUNETIO_IB_MLX5_WQE_CTRL_CQ_UPDATE, 0,
					     (uint64_t)q->flush_buf + 32, doca_gpu_dev_verbs_bswap32(q->rkey),
					     (uint64_t)q->flush_buf, doca_gpu_dev_verbs_bswap32(q->lkey), 1);
	doca_gpu_dev_verbs_mark_wqes_ready<DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU>(qp, wqe_idx,
			wqe_idx);
	doca_gpu_dev_verbs_submit <DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
				  DOCA_GPUNETIO_VERBS_SYNC_SCOPE_GPU,
				  DOCA_GPUNETIO_VERBS_NIC_HANDLER_GPU_SM_DB > (qp, wqe_idx + 1);
	return doca_gpu_dev_verbs_poll_cq_at <DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
	       DOCA_GPUNETIO_VERBS_QP_SQ > (qp, wqe_idx);
}

/**
 * Get a slot's data buffer.
 *
 * \param q GPU I/O queue.
 * \param slot Slot number.
 *
 * \return where the slot's read data lands, in GPU memory.
 */
__device__ static __forceinline__ void *
spdk_nvme_gpu_qpair_slot_buf(struct spdk_nvme_gpu_qpair *q, uint32_t slot)
{
	return q->data + (size_t)slot * q->slot_size;
}

/**
 * Submit a read into a slot's data buffer.
 *
 * The slot's command was prepared when the queue was created; only the block
 * address and count are written here. Any GPU thread may call this.
 *
 * \param q GPU I/O queue.
 * \param slot Free slot to use. The caller keeps track of which slots are free.
 * \param lba Starting block.
 * \param lba_count Number of blocks. Must fit in the slot's data buffer.
 */
__device__ static __forceinline__ void
spdk_nvme_gpu_ns_cmd_read(struct spdk_nvme_gpu_qpair *q, uint32_t slot, uint64_t lba,
			  uint32_t lba_count)
{
	struct spdk_nvme_cmd *cmd = &q->cmds[slot];

	cmd->cdw10 = (uint32_t)lba;
	cmd->cdw11 = (uint32_t)(lba >> 32);
	cmd->cdw12 = lba_count - 1;
	cmd->dptr.sgl1.keyed.length = lba_count << q->block_shift;
	nvme_gpu_send(q->qp, (uint64_t)cmd, q->lkey, sizeof(*cmd), &q->slot_wqe[slot]);
}

/**
 * Reap completed reads without waiting.
 *
 * As on the CPU, a slot is reported only after both its response has arrived and
 * its command's send has completed, so its command buffer can be reused at once.
 * Used response buffers are posted again. Only one GPU thread per queue may call
 * this.
 *
 * \param q GPU I/O queue.
 * \param slots Filled with the slots whose reads completed.
 * \param status Filled with each read's NVMe status field (completion bits 15:1),
 * 0 on success.
 * \param max Most completions to reap.
 *
 * \return the number of completions reaped, 0 if none has arrived, or -EIO on a
 * transport error.
 */
__device__ static __forceinline__ int
spdk_nvme_gpu_qpair_process_completions(struct spdk_nvme_gpu_qpair *q, uint32_t *slots,
					uint16_t *status, int max)
{
	const uint64_t ci0 = q->rq.cq.cqe_ci;
	const uint32_t mask = q->num_rsps - 1;
	int rc = 0;

	int k = 0;
	while (k < max && (rc = nvme_gpu_poll_recv_at(&q->rq.cq, ci0 + k)) == 0) {
		++k;
	}
	if (k == 0) {
		/* A failed receive is reported, as the CPU path fails the queue on it. */
		return rc < 0 ? rc : 0;
	}

	/* One ordering step covers every response taken in this call. */
	if (q->flush_qp != NULL && nvme_gpu_flush(q) != 0) {
		k = -1;
	}

	if (k > 0) {
		doca_gpu_dev_verbs_fence_acquire_nvidia_nic();
		for (int j = 0; j < k; ++j) {
			/*
			 * Responses land in receive order, so the (ci0 + j)-th completion is in the
			 * (ci0 + j)-th response buffer. Bytes 12..15 of a response are the command
			 * identifier and the status.
			 */
			const uint32_t tail = doca_gpu_dev_verbs_load_relaxed_sys_global(
						      (uint32_t *)&q->rsps[(ci0 + j) & mask].cid);
			const uint32_t slot = tail & 0xffff;

			/* As on the CPU, a command buffer is reused only after its send has completed. */
			if (doca_gpu_dev_verbs_poll_cq_at <DOCA_GPUNETIO_VERBS_RESOURCE_SHARING_MODE_GPU,
			    DOCA_GPUNETIO_VERBS_QP_SQ > (q->qp, q->slot_wqe[slot]) != 0) {
				k = -1;
				break;
			}
			slots[j] = slot;
			status[j] = (uint16_t)((tail >> 16) >> 1);
		}
	}

	/* A failed ordering step still consumed one entry. */
	const int n = (k > 0) ? k : 1;
	doca_gpu_dev_verbs_cq_update_dbrec<false>(&q->rq.cq, (uint32_t)n);
	for (int j = 0; j < n; ++j) {
		nvme_gpu_post_recv(&q->rq, (uint64_t)&q->rsps[(ci0 + j) & mask], q->lkey,
				   sizeof(struct spdk_nvme_cpl));
	}

	return k > 0 ? k : -EIO;
}

#endif /* SPDK_NVME_GPU_CUH */
