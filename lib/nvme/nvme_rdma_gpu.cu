/*   SPDX-License-Identifier: BSD-3-Clause
 *   Copyright (C) 2026 Hyungsun Yoo.
 *   All rights reserved.
 */

/*
 * Host side of GPU I/O queues for the RDMA transport.
 *
 * The queues of one spdk_nvme_ctrlr_alloc_gpu_io_qpairs() call form a set and share
 * its GPU and NIC handles, the GPU memory of their queue pairs (registered with the
 * NIC once) and one pool of buffers (registered once). Each queue has its own queue
 * pair and completion queues in that memory, and the GPU sends each queue's Fabrics
 * Connect. The device-side functions are in spdk/nvme_gpu.cuh.
 */

#include "spdk/stdinc.h"
#include "spdk/log.h"
#include "spdk/util.h"
#include "spdk/nvme_spec.h"
#include "spdk/nvmf_spec.h"
#include "spdk/nvme_gpu.cuh"
#include "spdk_internal/rdma_utils.h"

extern "C" {
#include "spdk_internal/rdma_cm.h"
}

#include "nvme_rdma_gpu.h"

#include <cuda_runtime.h>
#include <doca_gpunetio.h>
#include <doca_verbs.h>

/* Response buffers, and thus receive work requests, are never fewer than this. */
#define NVME_RDMA_GPU_MIN_RSPS		32
/* Bytes of the Fabrics Connect capsule: the command and its in-capsule data. */
#define NVME_RDMA_GPU_CONNECT_BYTES	(sizeof(struct spdk_nvme_cmd) + \
					 sizeof(struct spdk_nvmf_fabric_connect_data))
/* Entries of the loopback queue pair; it only holds the ordering writes in flight. */
#define NVME_RDMA_GPU_FLUSH_WQES	64
/* Polling iterations the GPU waits for the Connect response before giving up. */
#define NVME_RDMA_GPU_CONNECT_SPINS	2000000000ull

/*
 * GPU memory for queue pairs' own structures (completion rings, work rings,
 * doorbell records), taken from one allocation that is registered with the NIC
 * once; each piece starts at a page-aligned offset. Registering every piece
 * separately uses a BAR1 mapping per registration, and BAR1 is small on some GPUs.
 */
struct nvme_rdma_gpu_arena {
	uint8_t			*base;
	size_t			size;
	size_t			used;
	doca_verbs_umem_t	*umem;
};

/* One queue pair created with GPUNetIO, with what has to be released with it. */
struct nvme_rdma_gpu_qp {
	doca_verbs_qp_t		*qp;
	struct doca_gpu_verbs_qp *gverbs;
	doca_verbs_cq_t		*cq_sq;
	doca_verbs_cq_t		*cq_rq;
	doca_verbs_uar_t	*uar;
};

/* Path attributes rdma_cm negotiated; the loopback queue pair reuses them, addressed to itself. */
struct nvme_rdma_gpu_route {
	struct ibv_context	*ctx;
	uint8_t			sgid_index;
	uint8_t			hop_limit;
	uint8_t			sl;
	uint8_t			min_rnr_timer;
	uint8_t			timeout;
	uint8_t			retry_cnt;
	uint8_t			rnr_retry;
	/* ibv enum, 1-based. */
	int			path_mtu;
};

/* What the queues of one set share. Created when the first queue's route is resolved. */
struct nvme_rdma_gpu_set {
	uint32_t			nsid;
	uint32_t			num_qpairs;
	uint32_t			num_slots;
	uint32_t			num_rsps;
	uint32_t			slot_size;
	uint32_t			block_size;
	bool				ready;

	/* Whether NIC writes need nvme_gpu_flush() before data is read (see spdk/nvme_gpu.cuh). */
	bool				need_flush;

	struct ibv_pd			*pd;
	doca_gpu_t			*gpu;
	doca_dev_t			*net_dev;

	/* Queue pair memory, qmem_per_qpair bytes for each queue. */
	struct nvme_rdma_gpu_arena	qmem;
	size_t				qmem_per_qpair;

	/* Buffers, pool_per_qpair bytes for each queue: data, commands, responses,
	 * Connect capsule, flush scratch, slot WQE indices. */
	uint8_t				*pool;
	size_t				pool_per_qpair;
	size_t				pool_size;
	struct ibv_mr			*mr;

	/* Device-side view of every queue: host copies, and the array in GPU memory. */
	struct spdk_nvme_gpu_qpair	*h_qps;
	struct spdk_nvme_gpu_qpair	*d_qps;
};

struct nvme_rdma_gpu_qpair {
	struct nvme_rdma_gpu_set	*set;
	uint32_t			index;

	/* This queue's part of the set's queue pair memory. */
	struct nvme_rdma_gpu_arena	qmem;

	struct nvme_rdma_gpu_qp		qp;
	struct nvme_rdma_gpu_qp		flush_qp;
};

static inline uint32_t
nvme_rdma_gpu_align_up(uint32_t v, uint32_t a)
{
	return (v + a - 1) & ~(a - 1);
}

/*
 * DOCA requires a power of two >= 1; rdma_cm returns 0 because an initiator issues no
 * RDMA reads of its own.
 */
static inline uint8_t
nvme_rdma_gpu_legal_rd_atomic(uint8_t v)
{
	uint8_t p = 1;

	while ((uint16_t)(p << 1) <= v) {
		p = (uint8_t)(p << 1);
	}
	return p;
}

/* Register GPU memory with the NIC: dmabuf first, nvidia-peermem as a fallback. */
static doca_error_t
nvme_rdma_gpu_umem_create(doca_gpu_t *gpu, doca_dev_t *net_dev, void *ptr, size_t bytes,
			  doca_verbs_umem_t **umem)
{
	int fd = DOCA_VERBS_DMABUF_INVALID_FD;

	if (doca_gpu_get_dmabuf_fd(gpu, ptr, bytes, &fd) != DOCA_SUCCESS) {
		fd = DOCA_VERBS_DMABUF_INVALID_FD;
	}
	doca_error_t s = doca_verbs_umem_create(net_dev, gpu, ptr, bytes, IBV_ACCESS_LOCAL_WRITE, fd, 0,
						umem);
	if (s != DOCA_SUCCESS && fd > 0) {
		s = doca_verbs_umem_create(net_dev, gpu, ptr, bytes, IBV_ACCESS_LOCAL_WRITE,
					   DOCA_VERBS_DMABUF_INVALID_FD, 0, umem);
	}
	return s;
}

static doca_error_t
nvme_rdma_gpu_arena_take(struct nvme_rdma_gpu_arena *a, size_t bytes, void **ptr,
			 doca_verbs_umem_t **umem, uint64_t *off)
{
	if (a->used + bytes > a->size) {
		return DOCA_ERROR_NO_MEMORY;
	}
	*ptr = a->base + a->used;
	*umem = a->umem;
	*off = a->used;
	a->used += bytes;
	return DOCA_SUCCESS;
}

/* GPU memory one queue pair takes from the arena (see nvme_rdma_gpu_qp_create()). */
static size_t
nvme_rdma_gpu_qp_mem_bytes(uint32_t nwqe)
{
	const uint32_t page = (uint32_t)sysconf(_SC_PAGESIZE);
	const size_t cq = nvme_rdma_gpu_align_up(nwqe * DOCA_GPUNETIO_VERBS_CQE_SIZE, page) +
			  nvme_rdma_gpu_align_up(64, page);
	const size_t wq = nvme_rdma_gpu_align_up(nwqe * (uint32_t)(sizeof(struct
			  doca_gpunetio_ib_mlx5_wqe_data_seg) +
			  sizeof(struct doca_gpu_dev_verbs_wqe)), page);

	return 2 * cq + wq + nvme_rdma_gpu_align_up(64, page);
}

/*
 * Create one completion queue whose ring and consumer-index doorbell record are both
 * in GPU memory. The record must not stay in host memory (the default), or the NIC
 * would never see the GPU's updates. Overrun is allowed: GPUNetIO advances a send
 * completion queue's consumer index in GPU memory only, without updating its
 * doorbell record.
 */
static doca_error_t
nvme_rdma_gpu_cq_create(struct nvme_rdma_gpu_arena *arena, doca_dev_t *net_dev, uint32_t ncqes,
			void **ring_out, void **dbr_out, doca_verbs_cq_t **cq_out)
{
	doca_verbs_cq_attr_t *attr = NULL;
	doca_verbs_umem_t *ring_umem = NULL, *dbr_umem = NULL;
	uint64_t ring_off = 0, dbr_off = 0;
	if (doca_verbs_cq_attr_create(&attr) != DOCA_SUCCESS) {
		return DOCA_ERROR_DRIVER;
	}

	const uint32_t page = (uint32_t)sysconf(_SC_PAGESIZE);
	const uint32_t bytes = nvme_rdma_gpu_align_up(ncqes * DOCA_GPUNETIO_VERBS_CQE_SIZE, page);

	doca_error_t s = nvme_rdma_gpu_arena_take(arena, bytes, ring_out, &ring_umem, &ring_off);
	if (s != DOCA_SUCCESS) {
		return s;
	}
	/* Entries start with the owner bit meaning "not yet written", which is all ones. */
	void *seed = malloc(bytes);
	if (seed == NULL) {
		return DOCA_ERROR_NO_MEMORY;
	}
	memset(seed, 0xFF, bytes);
	cudaError_t cs = cudaMemcpy(*ring_out, seed, bytes, cudaMemcpyDefault);
	free(seed);
	if (cs != cudaSuccess) {
		return DOCA_ERROR_DRIVER;
	}

	s = doca_verbs_cq_attr_set_external_umem(attr, ring_umem, ring_off);
	if (s != DOCA_SUCCESS) {
		return s;
	}

	const uint32_t dbr_bytes = nvme_rdma_gpu_align_up(64, page);
	s = nvme_rdma_gpu_arena_take(arena, dbr_bytes, dbr_out, &dbr_umem, &dbr_off);
	if (s != DOCA_SUCCESS) {
		return s;
	}
	if (cudaMemset(*dbr_out, 0, dbr_bytes) != cudaSuccess) {
		return DOCA_ERROR_DRIVER;
	}
	s = doca_verbs_cq_attr_set_external_dbr_umem(attr, dbr_umem, dbr_off);
	if (s != DOCA_SUCCESS) {
		return s;
	}

	s = doca_verbs_cq_attr_set_cq_size(attr, ncqes);
	if (s != DOCA_SUCCESS) {
		return s;
	}
	s = doca_verbs_cq_attr_set_cq_overrun(attr, DOCA_VERBS_CQ_ENABLE_OVERRUN);
	if (s != DOCA_SUCCESS) {
		return s;
	}
	s = doca_verbs_cq_create(net_dev, attr, cq_out);
	doca_verbs_cq_attr_destroy(attr);
	return s;
}

static void
nvme_rdma_gpu_qp_destroy(struct nvme_rdma_gpu_set *set, struct nvme_rdma_gpu_qp *qp)
{
	if (qp->gverbs != NULL) {
		doca_gpu_verbs_unexport_qp(set->gpu, qp->gverbs);
	}
	if (qp->qp != NULL) {
		doca_verbs_qp_destroy(qp->qp);
	}
	/* Released after the queue pair that uses them. */
	if (qp->cq_sq != NULL) {
		doca_verbs_cq_destroy(qp->cq_sq);
	}
	if (qp->cq_rq != NULL) {
		doca_verbs_cq_destroy(qp->cq_rq);
	}
	if (qp->uar != NULL) {
		doca_verbs_uar_destroy(qp->uar);
	}
	memset(qp, 0, sizeof(*qp));
}

/*
 * Create a reliable-connected queue pair whose work rings, doorbell records and
 * completion queues are in GPU memory, and export its send side to the GPU. If rq_out
 * is not NULL, also fill in its receive side for spdk/nvme_gpu.cuh.
 */
static doca_error_t
nvme_rdma_gpu_qp_create(struct nvme_rdma_gpu_set *set, struct nvme_rdma_gpu_arena *arena,
			uint32_t nwqe, struct nvme_rdma_gpu_qp *out,
			struct doca_gpu_dev_verbs_qp **dev_out, struct spdk_nvme_gpu_rq *rq_out)
{
	const uint32_t page = (uint32_t)sysconf(_SC_PAGESIZE);

	doca_error_t s = doca_verbs_uar_create(set->net_dev, DOCA_VERBS_UAR_ALLOCATION_TYPE_NONCACHE,
					       &out->uar);
	if (s != DOCA_SUCCESS) {
		return s;
	}

	void *cq_sq_ring = NULL, *cq_sq_dbr = NULL, *cq_rq_ring = NULL, *cq_rq_dbr = NULL;
	s = nvme_rdma_gpu_cq_create(arena, set->net_dev, nwqe, &cq_sq_ring, &cq_sq_dbr, &out->cq_sq);
	if (s != DOCA_SUCCESS) {
		return s;
	}
	s = nvme_rdma_gpu_cq_create(arena, set->net_dev, nwqe, &cq_rq_ring, &cq_rq_dbr, &out->cq_rq);
	if (s != DOCA_SUCCESS) {
		return s;
	}

	/* Work-queue memory holds both rings: receives first, then sends. */
	const uint32_t wq_bytes = nvme_rdma_gpu_align_up(nwqe * (uint32_t)(sizeof(
					  struct doca_gpunetio_ib_mlx5_wqe_data_seg) +
				  sizeof(struct doca_gpu_dev_verbs_wqe)), page);
	void *wq = NULL;
	doca_verbs_umem_t *wq_umem = NULL;
	uint64_t wq_off = 0, dbr_off = 0;
	s = nvme_rdma_gpu_arena_take(arena, wq_bytes, &wq, &wq_umem, &wq_off);
	if (s != DOCA_SUCCESS) {
		return s;
	}
	if (cudaMemset(wq, 0, wq_bytes) != cudaSuccess) {
		return DOCA_ERROR_DRIVER;
	}

	const uint32_t dbr_bytes = nvme_rdma_gpu_align_up(64, page);
	void *dbr = NULL;
	doca_verbs_umem_t *dbr_umem = NULL;
	s = nvme_rdma_gpu_arena_take(arena, dbr_bytes, &dbr, &dbr_umem, &dbr_off);
	if (s != DOCA_SUCCESS) {
		return s;
	}
	if (cudaMemset(dbr, 0, dbr_bytes) != cudaSuccess) {
		return DOCA_ERROR_DRIVER;
	}

	doca_verbs_qp_init_attr_t *qi = NULL;
	if (doca_verbs_qp_init_attr_create(&qi) != DOCA_SUCCESS) {
		return DOCA_ERROR_DRIVER;
	}
	doca_verbs_qp_init_attr_set_external_uar(qi, out->uar);
	doca_verbs_qp_init_attr_set_external_umem(qi, wq_umem, wq_off);
	doca_verbs_qp_init_attr_set_external_umem_dbr(qi, dbr_umem, dbr_off);
	doca_verbs_qp_init_attr_set_pd(qi, set->net_dev);
	doca_verbs_qp_init_attr_set_qp_type(qi, DOCA_VERBS_QP_TYPE_RC);
	doca_verbs_qp_init_attr_set_sq_wr(qi, nwqe);
	doca_verbs_qp_init_attr_set_rq_wr(qi, nwqe);
	doca_verbs_qp_init_attr_set_send_cq(qi, out->cq_sq);
	doca_verbs_qp_init_attr_set_receive_cq(qi, out->cq_rq);
	doca_verbs_qp_init_attr_set_send_max_sges(qi, 2);
	doca_verbs_qp_init_attr_set_receive_max_sges(qi, 1);
	/* ordering_semantic is left at its default; some NICs (ConnectX-5) reject setting it. */
	s = doca_verbs_qp_create(set->net_dev, qi, &out->qp);
	doca_verbs_qp_init_attr_destroy(qi);
	if (s != DOCA_SUCCESS) {
		return s;
	}

	/* Send side, exported by the library. */
	s = doca_gpu_verbs_export_qp(set->gpu, out->qp, DOCA_GPUNETIO_VERBS_NIC_HANDLER_GPU_SM_DB, wq,
				     out->cq_sq, DOCA_GPUNETIO_VERBS_SEND_DBR_MODE_EXT_VALID_DBR,
				     DOCA_GPUNETIO_VERBS_CQ_64B, false, &out->gverbs);
	if (s != DOCA_SUCCESS) {
		return s;
	}
	s = doca_gpu_verbs_get_qp_dev(out->gverbs, dev_out);
	if (s != DOCA_SUCCESS) {
		return s;
	}
	if (rq_out == NULL) {
		/* Loopback queue pair: send side only. */
		return DOCA_SUCCESS;
	}

	/*
	 * Receive side, collected from the queue pair. Doorbell records come in pairs:
	 * [0] receive, [1] send.
	 */
	void *sq_buf = NULL, *rq_buf = NULL, *qp_dbr = NULL;
	uint32_t sq_n = 0, rq_n = 0, rwqe_size = 0;
	s = doca_verbs_qp_get_wq(out->qp, &sq_buf, &sq_n, &rq_buf, &rq_n, &rwqe_size);
	if (s != DOCA_SUCCESS) {
		return s;
	}
	s = doca_verbs_qp_get_dbr_addr(out->qp, &qp_dbr);
	if (s != DOCA_SUCCESS) {
		return s;
	}

	rq_out->wqe_daddr = (uint8_t *)rq_buf;
	rq_out->dbrec = (__be32 *)qp_dbr + DOCA_GPUNETIO_IB_MLX5_RCV_DBR;
	rq_out->wqe_num = rq_n;
	rq_out->wqe_mask = rq_n - 1;
	rq_out->wqe_stride = rwqe_size;
	rq_out->pi = 0;

	void *cq_buf = NULL;
	uint32_t cq_n = 0;
	uint8_t cqe_size = 0;
	s = doca_verbs_cq_get_wq(out->cq_rq, &cq_buf, &cq_n, &cqe_size);
	if (s != DOCA_SUCCESS) {
		return s;
	}
	/* The GPU pointer, not the host mapping doca_verbs_cq_get_wq() returns. */
	rq_out->cq.cqe_daddr = (uint8_t *)cq_rq_ring;
	s = doca_verbs_cq_get_cqn(out->cq_rq, &rq_out->cq.cq_num);
	if (s != DOCA_SUCCESS) {
		return s;
	}
	rq_out->cq.cqe_num = cq_n;
	rq_out->cq.cqe_mask = cq_n - 1;
	rq_out->cq.cqe_size = cqe_size;
	rq_out->cq.dbrec = (__be32 *)cq_rq_dbr;
	rq_out->cq.cqe_ci = 0;
	rq_out->cq.cqe_rsvd = 0;
	rq_out->cq.cq_type = DOCA_GPUNETIO_VERBS_CQ_64B;
	rq_out->cq.mem_type = DOCA_GPUNETIO_VERBS_MEM_TYPE_GPU;
	return DOCA_SUCCESS;
}

/*
 * Connect a queue pair to itself, so that every write on it is delivered back to the
 * same queue pair through the NIC. Used by nvme_gpu_flush().
 */
static int
nvme_rdma_gpu_loop_connect(struct nvme_rdma_gpu_qpair *gq, const struct nvme_rdma_gpu_route *r)
{
	doca_verbs_ah_attr_t *ah = NULL;
	doca_verbs_qp_attr_t *qa = NULL;
	struct doca_verbs_gid dgid;
	union ibv_gid gid;
	uint32_t qpn = 0;
	int rc = -EIO;

	if (doca_verbs_qp_get_qpn(gq->flush_qp.qp, &qpn) != DOCA_SUCCESS ||
	    ibv_query_gid(r->ctx, 1, r->sgid_index, &gid) != 0 ||
	    doca_verbs_ah_attr_create(gq->set->net_dev, &ah) != DOCA_SUCCESS ||
	    doca_verbs_qp_attr_create(&qa) != DOCA_SUCCESS) {
		goto out;
	}

	doca_verbs_qp_attr_set_next_state(qa, DOCA_VERBS_QP_STATE_INIT);
	doca_verbs_qp_attr_set_allow_remote_write(qa, 1);
	doca_verbs_qp_attr_set_allow_remote_read(qa, 1);
	doca_verbs_qp_attr_set_atomic_mode(qa, DOCA_VERBS_QP_ATOMIC_MODE_IB_SPEC);
	doca_verbs_qp_attr_set_pkey_index(qa, 0);
	doca_verbs_qp_attr_set_port_num(qa, 1);
	if (doca_verbs_qp_modify(gq->flush_qp.qp, qa, DOCA_VERBS_QP_ATTR_NEXT_STATE |
				 DOCA_VERBS_QP_ATTR_ALLOW_REMOTE_WRITE | DOCA_VERBS_QP_ATTR_ALLOW_REMOTE_READ |
				 DOCA_VERBS_QP_ATTR_ATOMIC_MODE | DOCA_VERBS_QP_ATTR_PKEY_INDEX |
				 DOCA_VERBS_QP_ATTR_PORT_NUM) != DOCA_SUCCESS) {
		goto out;
	}

	memcpy(dgid.raw, gid.raw, sizeof(dgid.raw));
	doca_verbs_ah_attr_set_addr_type(ah, DOCA_VERBS_ADDR_TYPE_IPv4);
	doca_verbs_ah_attr_set_gid(ah, dgid);
	doca_verbs_ah_attr_set_sgid_index(ah, r->sgid_index);
	doca_verbs_ah_attr_set_hop_limit(ah, r->hop_limit);
	doca_verbs_ah_attr_set_sl(ah, r->sl);
	doca_verbs_qp_attr_set_next_state(qa, DOCA_VERBS_QP_STATE_RTR);
	/* ibv's MTU enum is 1-based, DOCA's is 0-based. */
	doca_verbs_qp_attr_set_path_mtu(qa, (enum doca_verbs_mtu_size)(r->path_mtu - 1));
	doca_verbs_qp_attr_set_dest_qp_num(qa, qpn);
	doca_verbs_qp_attr_set_rq_psn(qa, 0);
	doca_verbs_qp_attr_set_min_rnr_timer(qa, r->min_rnr_timer);
	doca_verbs_qp_attr_set_max_dest_rd_atomic(qa, 1);
	doca_verbs_qp_attr_set_ah_attr(qa, ah);
	if (doca_verbs_qp_modify(gq->flush_qp.qp, qa, DOCA_VERBS_QP_ATTR_NEXT_STATE |
				 DOCA_VERBS_QP_ATTR_RQ_PSN | DOCA_VERBS_QP_ATTR_DEST_QP_NUM |
				 DOCA_VERBS_QP_ATTR_PATH_MTU | DOCA_VERBS_QP_ATTR_AH_ATTR |
				 DOCA_VERBS_QP_ATTR_MIN_RNR_TIMER |
				 DOCA_VERBS_QP_ATTR_MAX_DEST_RD_ATOMIC) != DOCA_SUCCESS) {
		goto out;
	}

	doca_verbs_qp_attr_set_next_state(qa, DOCA_VERBS_QP_STATE_RTS);
	doca_verbs_qp_attr_set_sq_psn(qa, 0);
	doca_verbs_qp_attr_set_ack_timeout(qa, r->timeout);
	doca_verbs_qp_attr_set_retry_cnt(qa, r->retry_cnt);
	doca_verbs_qp_attr_set_rnr_retry(qa, r->rnr_retry);
	doca_verbs_qp_attr_set_max_rd_atomic(qa, 1);
	if (doca_verbs_qp_modify(gq->flush_qp.qp, qa, DOCA_VERBS_QP_ATTR_NEXT_STATE |
				 DOCA_VERBS_QP_ATTR_SQ_PSN | DOCA_VERBS_QP_ATTR_ACK_TIMEOUT |
				 DOCA_VERBS_QP_ATTR_RETRY_CNT | DOCA_VERBS_QP_ATTR_RNR_RETRY |
				 DOCA_VERBS_QP_ATTR_MAX_QP_RD_ATOMIC) != DOCA_SUCCESS) {
		goto out;
	}
	rc = 0;
out:
	if (qa != NULL) {
		doca_verbs_qp_attr_destroy(qa);
	}
	if (ah != NULL) {
		doca_verbs_ah_attr_destroy(ah);
	}
	return rc;
}


/*
 * Create what the queues of a set share: the GPU and NIC handles, the queue pair
 * memory and the buffer pool, each registered with the NIC once, and the array of
 * device-side views. Done when the first queue's route is resolved, because the
 * NIC (and thus the protection domain) is known only then.
 */
static int
nvme_rdma_gpu_set_init(struct nvme_rdma_gpu_set *set, struct rdma_cm_id *cm_id)
{
	const size_t page = (size_t)sysconf(_SC_PAGESIZE);
	/*
	 * The work rings hold twice the response ring: posting num_rsps receives into a ring
	 * of exactly num_rsps entries would leave no free entry, which the NIC treats as full.
	 */
	const uint32_t nwqe = set->num_rsps * 2;
	char bus_id[32];
	int dev, order = 0, fd = 0;

	if (cudaGetDevice(&dev) != cudaSuccess ||
	    cudaDeviceGetPCIBusId(bus_id, sizeof(bus_id), dev) != cudaSuccess ||
	    cudaDeviceGetAttribute(&order, cudaDevAttrGPUDirectRDMAWritesOrdering, dev) != cudaSuccess) {
		SPDK_ERRLOG("Unable to query the current CUDA device\n");
		return -ENODEV;
	}
	/*
	 * From this level on, the GPU makes NIC writes visible in order by itself (the runtime
	 * counterpart of CU_FLUSH_GPU_DIRECT_RDMA_WRITES_TO_OWNER, which GPUNetIO checks).
	 * Below it the queues need nvme_gpu_flush().
	 */
	set->need_flush = order < cudaGPUDirectRDMAWritesOrderingOwner;

	if (doca_gpu_create(bus_id, &set->gpu) != DOCA_SUCCESS) {
		SPDK_ERRLOG("Unable to open GPU %s through GPUNetIO\n", bus_id);
		return -ENODEV;
	}

	/* All queues share one protection domain, so one registration of the pool is valid on all of them. */
	set->pd = spdk_rdma_utils_get_pd(cm_id->verbs);
	if (set->pd == NULL || doca_verbs_dev_open(set->pd, &set->net_dev) != DOCA_SUCCESS) {
		SPDK_ERRLOG("Unable to open the NIC through GPUNetIO\n");
		return -ENODEV;
	}

	/*
	 * Buffer pool, per queue: data buffers (first, so they stay page-aligned), then the
	 * commands, the responses, the Connect capsule, the flush scratch and the slot WQE
	 * indices. Rounded up to whole pages: a dmabuf export of a range that is not a whole
	 * number of pages is refused. The extra tail is never used.
	 */
	set->pool_per_qpair = (size_t)set->num_slots * (set->slot_size + sizeof(struct spdk_nvme_cmd)) +
			      (size_t)set->num_rsps * sizeof(struct spdk_nvme_cpl) +
			      NVME_RDMA_GPU_CONNECT_BYTES + 64 + (size_t)set->num_slots * sizeof(uint64_t);
	set->pool_size = (set->pool_per_qpair * set->num_qpairs + page - 1) / page * page;
	if (doca_gpu_mem_alloc(set->gpu, set->pool_size, page, DOCA_GPU_MEM_TYPE_GPU, (void **)&set->pool,
			       NULL) != DOCA_SUCCESS ||
	    cudaMemset(set->pool, 0, set->pool_size) != cudaSuccess) {
		SPDK_ERRLOG("Unable to allocate %zu bytes of GPU memory\n", set->pool_size);
		return -ENOMEM;
	}
	if (doca_gpu_get_dmabuf_fd(set->gpu, set->pool, set->pool_size, &fd) == DOCA_SUCCESS) {
		set->mr = ibv_reg_dmabuf_mr(set->pd, 0, set->pool_size, (uint64_t)set->pool, fd,
					    IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE |
					    IBV_ACCESS_REMOTE_READ);
	}
	if (set->mr == NULL) {
		/* Fall back to nvidia-peermem. */
		set->mr = ibv_reg_mr(set->pd, set->pool, set->pool_size,
				     IBV_ACCESS_LOCAL_WRITE | IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_REMOTE_READ);
	}
	if (set->mr == NULL) {
		SPDK_ERRLOG("Unable to register GPU memory with the NIC\n");
		return -EIO;
	}

	/* Per queue: its queue pair (nwqe entries) and the loopback queue pair for nvme_gpu_flush(). */
	set->qmem_per_qpair = nvme_rdma_gpu_qp_mem_bytes(nwqe) +
			      nvme_rdma_gpu_qp_mem_bytes(NVME_RDMA_GPU_FLUSH_WQES);
	set->qmem.size = set->qmem_per_qpair * set->num_qpairs;
	if (doca_gpu_mem_alloc(set->gpu, set->qmem.size, page, DOCA_GPU_MEM_TYPE_GPU,
			       (void **)&set->qmem.base, NULL) != DOCA_SUCCESS ||
	    nvme_rdma_gpu_umem_create(set->gpu, set->net_dev, set->qmem.base, set->qmem.size,
				      &set->qmem.umem) != DOCA_SUCCESS) {
		SPDK_ERRLOG("Unable to allocate and register GPU memory for the queue pairs\n");
		return -ENOMEM;
	}

	if (cudaMalloc((void **)&set->d_qps, sizeof(*set->d_qps) * set->num_qpairs) != cudaSuccess) {
		return -ENOMEM;
	}

	set->ready = true;
	return 0;
}

extern "C" struct nvme_rdma_gpu_set *
nvme_rdma_gpu_set_alloc(uint32_t nsid, uint32_t num_qpairs, uint32_t num_slots, uint32_t slot_size,
			uint32_t block_size)
{
	struct nvme_rdma_gpu_set *set = (struct nvme_rdma_gpu_set *)calloc(1, sizeof(*set));

	if (set == NULL) {
		return NULL;
	}
	set->h_qps = (struct spdk_nvme_gpu_qpair *)calloc(num_qpairs, sizeof(*set->h_qps));
	if (set->h_qps == NULL) {
		free(set);
		return NULL;
	}
	set->nsid = nsid;
	set->num_qpairs = num_qpairs;
	set->num_slots = num_slots;
	set->slot_size = slot_size;
	set->block_size = block_size;
	/*
	 * Response buffers form a ring indexed by completion count, so their number is a power
	 * of two, and at least NVME_RDMA_GPU_MIN_RSPS: with very few slots per queue a tiny
	 * ring would leave the send queue only a couple of entries.
	 */
	set->num_rsps = NVME_RDMA_GPU_MIN_RSPS;
	while (set->num_rsps < num_slots) {
		set->num_rsps <<= 1;
	}
	return set;
}

extern "C" void
nvme_rdma_gpu_set_free(struct nvme_rdma_gpu_set *set)
{
	if (set->d_qps != NULL) {
		cudaFree(set->d_qps);
	}
	if (set->mr != NULL) {
		ibv_dereg_mr(set->mr);
	}
	if (set->pool != NULL) {
		doca_gpu_mem_free(set->gpu, set->pool);
	}
	if (set->qmem.umem != NULL) {
		doca_verbs_umem_destroy(set->qmem.umem);
	}
	if (set->qmem.base != NULL) {
		doca_gpu_mem_free(set->gpu, set->qmem.base);
	}
	if (set->net_dev != NULL) {
		doca_verbs_dev_close(set->net_dev);
	}
	if (set->pd != NULL) {
		spdk_rdma_utils_put_pd(set->pd);
	}
	if (set->gpu != NULL) {
		doca_gpu_destroy(set->gpu);
	}
	free(set->h_qps);
	free(set);
}

extern "C" struct spdk_nvme_gpu_qpair *
nvme_rdma_gpu_set_get_device(struct nvme_rdma_gpu_set *set)
{
	return set->d_qps;
}

extern "C" struct nvme_rdma_gpu_qpair *
nvme_rdma_gpu_qpair_alloc(struct nvme_rdma_gpu_set *set, uint32_t index)
{
	struct nvme_rdma_gpu_qpair *gq = (struct nvme_rdma_gpu_qpair *)calloc(1, sizeof(*gq));

	if (gq == NULL) {
		return NULL;
	}
	gq->set = set;
	gq->index = index;
	return gq;
}

extern "C" void
nvme_rdma_gpu_qpair_free(struct nvme_rdma_gpu_qpair *gq)
{
	free(gq);
}

extern "C" int
nvme_rdma_gpu_qpair_create(struct nvme_rdma_gpu_qpair *gq, struct rdma_cm_id *cm_id)
{
	struct nvme_rdma_gpu_set *set = gq->set;
	struct spdk_nvme_gpu_qpair *h = &set->h_qps[gq->index];
	int rc;

	if (!set->ready) {
		rc = nvme_rdma_gpu_set_init(set, cm_id);
		if (rc != 0) {
			return rc;
		}
	}

	/* This queue's part of the queue pair memory. Taken again from its start on a reconnect. */
	gq->qmem.base = set->qmem.base + set->qmem_per_qpair * gq->index;
	gq->qmem.size = set->qmem_per_qpair;
	gq->qmem.used = 0;
	gq->qmem.umem = set->qmem.umem;

	if (nvme_rdma_gpu_qp_create(set, &gq->qmem, set->num_rsps * 2, &gq->qp, &h->qp,
				    &h->rq) != DOCA_SUCCESS) {
		SPDK_ERRLOG("Unable to create the queue pair in GPU memory\n");
		return -EIO;
	}
	return 0;
}

extern "C" uint32_t
nvme_rdma_gpu_qpair_get_qp_num(struct nvme_rdma_gpu_qpair *gq)
{
	uint32_t qpn = 0;

	doca_verbs_qp_get_qpn(gq->qp.qp, &qpn);
	return qpn;
}

/*
 * rdma_cm cannot move a queue pair it did not create, so the transitions are applied
 * here through DOCA, translating the values rdma_cm computes for this connection.
 */
extern "C" int
nvme_rdma_gpu_qpair_complete_connect(struct nvme_rdma_gpu_qpair *gq, struct rdma_cm_id *cm_id)
{
	struct nvme_rdma_gpu_route route = {};
	doca_verbs_ah_attr_t *ah = NULL;
	doca_verbs_qp_attr_t *qa = NULL;
	struct doca_verbs_gid dgid;
	struct ibv_qp_attr ib;
	int mask, rc = -EIO;

	if (doca_verbs_ah_attr_create(gq->set->net_dev, &ah) != DOCA_SUCCESS ||
	    doca_verbs_qp_attr_create(&qa) != DOCA_SUCCESS) {
		goto out;
	}

	memset(&ib, 0, sizeof(ib));
	ib.qp_state = IBV_QPS_INIT;
	if (spdk_rdma_cm_init_qp_attr(cm_id, &ib, &mask) != 0) {
		goto out;
	}
	doca_verbs_qp_attr_set_next_state(qa, DOCA_VERBS_QP_STATE_INIT);
	/* The target writes read data into GPU memory. */
	doca_verbs_qp_attr_set_allow_remote_write(qa, 1);
	doca_verbs_qp_attr_set_allow_remote_read(qa, 1);
	doca_verbs_qp_attr_set_atomic_mode(qa, DOCA_VERBS_QP_ATOMIC_MODE_IB_SPEC);
	doca_verbs_qp_attr_set_pkey_index(qa, 0);
	doca_verbs_qp_attr_set_port_num(qa, 1);
	if (doca_verbs_qp_modify(gq->qp.qp, qa, DOCA_VERBS_QP_ATTR_NEXT_STATE |
				 DOCA_VERBS_QP_ATTR_ALLOW_REMOTE_WRITE | DOCA_VERBS_QP_ATTR_ALLOW_REMOTE_READ |
				 DOCA_VERBS_QP_ATTR_ATOMIC_MODE | DOCA_VERBS_QP_ATTR_PKEY_INDEX |
				 DOCA_VERBS_QP_ATTR_PORT_NUM) != DOCA_SUCCESS) {
		goto out;
	}

	ib.qp_state = IBV_QPS_RTR;
	if (spdk_rdma_cm_init_qp_attr(cm_id, &ib, &mask) != 0) {
		goto out;
	}
	memcpy(dgid.raw, ib.ah_attr.grh.dgid.raw, sizeof(dgid.raw));
	doca_verbs_ah_attr_set_addr_type(ah, DOCA_VERBS_ADDR_TYPE_IPv4);
	doca_verbs_ah_attr_set_gid(ah, dgid);
	doca_verbs_ah_attr_set_sgid_index(ah, ib.ah_attr.grh.sgid_index);
	doca_verbs_ah_attr_set_hop_limit(ah, ib.ah_attr.grh.hop_limit);
	doca_verbs_ah_attr_set_sl(ah, ib.ah_attr.sl);
	doca_verbs_qp_attr_set_next_state(qa, DOCA_VERBS_QP_STATE_RTR);
	/* ibv's MTU enum is 1-based, DOCA's is 0-based. */
	doca_verbs_qp_attr_set_path_mtu(qa, (enum doca_verbs_mtu_size)((int)ib.path_mtu - 1));
	doca_verbs_qp_attr_set_dest_qp_num(qa, ib.dest_qp_num);
	doca_verbs_qp_attr_set_rq_psn(qa, ib.rq_psn);
	doca_verbs_qp_attr_set_min_rnr_timer(qa, ib.min_rnr_timer);
	doca_verbs_qp_attr_set_max_dest_rd_atomic(qa, nvme_rdma_gpu_legal_rd_atomic(ib.max_dest_rd_atomic));
	doca_verbs_qp_attr_set_ah_attr(qa, ah);
	if (doca_verbs_qp_modify(gq->qp.qp, qa, DOCA_VERBS_QP_ATTR_NEXT_STATE | DOCA_VERBS_QP_ATTR_RQ_PSN |
				 DOCA_VERBS_QP_ATTR_DEST_QP_NUM | DOCA_VERBS_QP_ATTR_PATH_MTU |
				 DOCA_VERBS_QP_ATTR_AH_ATTR | DOCA_VERBS_QP_ATTR_MIN_RNR_TIMER |
				 DOCA_VERBS_QP_ATTR_MAX_DEST_RD_ATOMIC) != DOCA_SUCCESS) {
		goto out;
	}
	route.ctx = cm_id->verbs;
	route.sgid_index = ib.ah_attr.grh.sgid_index;
	route.hop_limit = ib.ah_attr.grh.hop_limit;
	route.sl = ib.ah_attr.sl;
	route.min_rnr_timer = ib.min_rnr_timer;
	route.path_mtu = (int)ib.path_mtu;

	ib.qp_state = IBV_QPS_RTS;
	if (spdk_rdma_cm_init_qp_attr(cm_id, &ib, &mask) != 0) {
		goto out;
	}
	route.timeout = ib.timeout;
	route.retry_cnt = ib.retry_cnt;
	route.rnr_retry = ib.rnr_retry;
	doca_verbs_qp_attr_set_next_state(qa, DOCA_VERBS_QP_STATE_RTS);
	doca_verbs_qp_attr_set_sq_psn(qa, ib.sq_psn);
	doca_verbs_qp_attr_set_ack_timeout(qa, ib.timeout);
	doca_verbs_qp_attr_set_retry_cnt(qa, ib.retry_cnt);
	doca_verbs_qp_attr_set_rnr_retry(qa, ib.rnr_retry);
	doca_verbs_qp_attr_set_max_rd_atomic(qa, nvme_rdma_gpu_legal_rd_atomic(ib.max_rd_atomic));
	if (doca_verbs_qp_modify(gq->qp.qp, qa, DOCA_VERBS_QP_ATTR_NEXT_STATE | DOCA_VERBS_QP_ATTR_SQ_PSN |
				 DOCA_VERBS_QP_ATTR_ACK_TIMEOUT | DOCA_VERBS_QP_ATTR_RETRY_CNT |
				 DOCA_VERBS_QP_ATTR_RNR_RETRY |
				 DOCA_VERBS_QP_ATTR_MAX_QP_RD_ATOMIC) != DOCA_SUCCESS) {
		goto out;
	}

	/* The loopback queue pair for nvme_gpu_flush() uses the same port, GID and MTU. */
	if (gq->set->need_flush) {
		if (nvme_rdma_gpu_qp_create(gq->set, &gq->qmem, NVME_RDMA_GPU_FLUSH_WQES, &gq->flush_qp,
					    &gq->set->h_qps[gq->index].flush_qp, NULL) != DOCA_SUCCESS ||
		    nvme_rdma_gpu_loop_connect(gq, &route) != 0) {
			SPDK_ERRLOG("Unable to create the loopback queue pair\n");
			goto out;
		}
	}

	rc = spdk_rdma_cm_establish(cm_id);
out:
	if (qa != NULL) {
		doca_verbs_qp_attr_destroy(qa);
	}
	if (ah != NULL) {
		doca_verbs_ah_attr_destroy(ah);
	}
	return rc;
}


extern "C" int
nvme_rdma_gpu_qpair_prepare(struct nvme_rdma_gpu_qpair *gq,
			    const struct nvme_rdma_gpu_connect_info *info)
{
	struct nvme_rdma_gpu_set *set = gq->set;
	struct spdk_nvme_gpu_qpair *h = &set->h_qps[gq->index];
	uint8_t *base = set->pool + set->pool_per_qpair * gq->index;
	struct spdk_nvmf_fabric_connect_cmd cc;
	struct spdk_nvme_cmd *cmds, *connect;
	uint8_t *stage;
	uint32_t s;

	h->data = base;
	h->cmds = (struct spdk_nvme_cmd *)(h->data + (size_t)set->num_slots * set->slot_size);
	h->rsps = (struct spdk_nvme_cpl *)(h->cmds + set->num_slots);
	h->connect_capsule = (uint8_t *)(h->rsps + set->num_rsps);
	h->flush_buf = h->connect_capsule + NVME_RDMA_GPU_CONNECT_BYTES;
	h->slot_wqe = (uint64_t *)(h->flush_buf + 64);
	h->lkey = set->mr->lkey;
	h->rkey = set->mr->rkey;
	h->num_slots = set->num_slots;
	h->num_rsps = set->num_rsps;
	h->slot_size = set->slot_size;
	h->block_shift = (uint32_t)spdk_u32log2(set->block_size);

	stage = (uint8_t *)calloc(1, set->pool_per_qpair);
	if (stage == NULL) {
		return -ENOMEM;
	}

	/* Every read is the same except its block address, so all are prepared here. */
	cmds = (struct spdk_nvme_cmd *)(stage + ((uint8_t *)h->cmds - base));
	for (s = 0; s < set->num_slots; s++) {
		cmds[s].opc = SPDK_NVME_OPC_READ;
		cmds[s].psdt = SPDK_NVME_PSDT_SGL_MPTR_CONTIG;
		/* The command identifier is the slot number. */
		cmds[s].cid = (uint16_t)s;
		cmds[s].nsid = set->nsid;
		cmds[s].dptr.sgl1.keyed.type = SPDK_NVME_SGL_TYPE_KEYED_DATA_BLOCK;
		cmds[s].dptr.sgl1.keyed.subtype = SPDK_NVME_SGL_SUBTYPE_ADDRESS;
		cmds[s].dptr.sgl1.keyed.length = set->slot_size;
		cmds[s].dptr.sgl1.keyed.key = set->mr->rkey;
		cmds[s].dptr.sgl1.address = (uint64_t)(h->data + (size_t)s * set->slot_size);
		/* Number of blocks, 0-based. */
		cmds[s].cdw12 = set->slot_size / set->block_size - 1;
	}

	/*
	 * The queue is connected at the RDMA level but not yet attached to the controller;
	 * that takes a Fabrics Connect sent on the queue itself, with its data in the same
	 * capsule. Built as nvme_fabric_qpair_connect_async() does.
	 */
	memset(&cc, 0, sizeof(cc));
	cc.opcode = SPDK_NVME_OPC_FABRIC;
	cc.fctype = SPDK_NVMF_FABRIC_COMMAND_CONNECT;
	cc.qid = info->qid;
	cc.sqsize = info->sqsize;
	cc.kato = info->kato;
	cc.cattr.bits.dissqfc = info->disable_sq_flow_control;
	connect = (struct spdk_nvme_cmd *)(stage + (h->connect_capsule - base));
	memcpy(connect, &cc, sizeof(cc));
	connect->psdt = SPDK_NVME_PSDT_SGL_MPTR_CONTIG;
	connect->dptr.sgl1.unkeyed.type = SPDK_NVME_SGL_TYPE_DATA_BLOCK;
	connect->dptr.sgl1.unkeyed.subtype = SPDK_NVME_SGL_SUBTYPE_OFFSET;
	connect->dptr.sgl1.unkeyed.length = sizeof(info->data);
	connect->dptr.sgl1.address = 0;
	memcpy(connect + 1, &info->data, sizeof(info->data));

	if (cudaMemcpy(base, stage, set->pool_per_qpair, cudaMemcpyHostToDevice) != cudaSuccess ||
	    cudaMemcpy(&set->d_qps[gq->index], h, sizeof(*h), cudaMemcpyHostToDevice) != cudaSuccess) {
		free(stage);
		return -EIO;
	}
	free(stage);
	return 0;
}

/*
 * Post every receive buffer and send the Fabrics Connect of queue blockIdx.x. Both have
 * to be done by the GPU, because the receive ring and the doorbells are in GPU memory.
 * Receives go first, so that the response has somewhere to land.
 *
 * One block per queue, one thread each.
 */
__global__ static void
nvme_rdma_gpu_connect_kernel(struct spdk_nvme_gpu_qpair *qps, uint32_t connect_len, int *status)
{
	struct spdk_nvme_gpu_qpair *q = &qps[blockIdx.x];

	for (uint32_t s = 0; s < q->num_rsps; ++s) {
		nvme_gpu_post_recv(&q->rq, (uint64_t)&q->rsps[s], q->lkey, sizeof(struct spdk_nvme_cpl));
	}

	/* The Connect's command identifier is 0, so its send is tracked as slot 0's. */
	nvme_gpu_send(q->qp, (uint64_t)q->connect_capsule, q->lkey, connect_len, &q->slot_wqe[0]);

	uint32_t cid = 0;
	uint16_t st = 0;
	uint64_t spins = 0;
	for (;;) {
		int r = spdk_nvme_gpu_qpair_process_completions(q, &cid, &st, 1);
		if (r == 1) {
			status[blockIdx.x] = st;
			return;
		}
		if (r < 0) {
			/* The receive or the ordering step failed. */
			status[blockIdx.x] = -1;
			return;
		}
		if (++spins > NVME_RDMA_GPU_CONNECT_SPINS) {
			/* No response. */
			status[blockIdx.x] = -2;
			return;
		}
	}
}

extern "C" int
nvme_rdma_gpu_qpair_fabric_connect(struct nvme_rdma_gpu_qpair *gq)
{
	struct nvme_rdma_gpu_set *set = gq->set;
	int *d_st = NULL;
	int st = 0;

	if (cudaMalloc((void **)&d_st, sizeof(*d_st)) != cudaSuccess) {
		return -ENOMEM;
	}
	nvme_rdma_gpu_connect_kernel <<< 1, 1 >>> (&set->d_qps[gq->index],
			(uint32_t)NVME_RDMA_GPU_CONNECT_BYTES, d_st);
	if (cudaGetLastError() != cudaSuccess || cudaDeviceSynchronize() != cudaSuccess ||
	    cudaMemcpy(&st, d_st, sizeof(st), cudaMemcpyDeviceToHost) != cudaSuccess) {
		cudaFree(d_st);
		SPDK_ERRLOG("Fabrics Connect from the GPU could not run\n");
		return -EIO;
	}
	cudaFree(d_st);

	if (st == 0) {
		return 0;
	}
	if (st == -1) {
		SPDK_ERRLOG("Fabrics Connect from the GPU: receive failed\n");
	} else if (st == -2) {
		SPDK_ERRLOG("Fabrics Connect from the GPU: no reply\n");
		return -ETIMEDOUT;
	} else {
		SPDK_ERRLOG("Fabrics Connect from the GPU: status 0x%x\n", st);
	}
	return -EIO;
}

extern "C" void
nvme_rdma_gpu_qpair_destroy(struct nvme_rdma_gpu_qpair *gq)
{
	/* The loopback queue pair first, then the queue's own. */
	nvme_rdma_gpu_qp_destroy(gq->set, &gq->flush_qp);
	nvme_rdma_gpu_qp_destroy(gq->set, &gq->qp);
}
