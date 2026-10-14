/*   SPDX-License-Identifier: BSD-3-Clause
 *   Copyright (C) 2026 Hyungsun Yoo.
 *   All rights reserved.
 */

/*
 * Public API of GPU I/O queues (spdk/nvme_gpu.h).
 *
 * Each GPU queue is an ordinary RDMA I/O queue that is marked as a GPU queue before
 * it connects. The RDMA transport then connects it through its usual steps and calls
 * nvme_rdma_gpu.cu where a GPU queue differs. The queues created together share
 * their GPU resources (struct nvme_rdma_gpu_set).
 */

#include "spdk/nvme_gpu.h"

#include "nvme_internal.h"
#include "nvme_rdma_gpu.h"

struct spdk_nvme_gpu_qpairs {
	struct nvme_rdma_gpu_set	*set;
	uint32_t			num_qpairs;
	struct spdk_nvme_qpair		*qpairs[];
};

void
spdk_nvme_gpu_qpair_get_default_opts(struct spdk_nvme_ctrlr *ctrlr,
				     struct spdk_nvme_gpu_qpair_opts *opts, size_t opts_size)
{
	assert(ctrlr);

	assert(opts);

	memset(opts, 0, opts_size);
	opts->opts_size = opts_size;

#define FIELD_OK(field) \
	offsetof(struct spdk_nvme_gpu_qpair_opts, field) + sizeof(opts->field) <= opts_size

#define SET_FIELD(field, value) \
        if (FIELD_OK(field)) { \
                opts->field = value; \
        } \

	SET_FIELD(nsid, 1);
	/* A queue of N entries holds at most N - 1 commands. */
	SET_FIELD(num_slots, ctrlr->opts.io_queue_size - 1);
	SET_FIELD(slot_size, 4096);

#undef FIELD_OK
#undef SET_FIELD
}

static void
nvme_gpu_qpair_opts_copy(struct spdk_nvme_gpu_qpair_opts *dst,
			 const struct spdk_nvme_gpu_qpair_opts *src, size_t opts_size_src)
{
	if (!opts_size_src) {
		SPDK_ERRLOG("opts_size_src should not be zero value\n");
		assert(false);
	}

#define FIELD_OK(field) \
        offsetof(struct spdk_nvme_gpu_qpair_opts, field) + sizeof(src->field) <= opts_size_src

#define SET_FIELD(field) \
        if (FIELD_OK(field)) { \
                dst->field = src->field; \
        } \

	SET_FIELD(nsid);
	SET_FIELD(num_slots);
	SET_FIELD(slot_size);

	dst->opts_size = opts_size_src;

#undef FIELD_OK
#undef SET_FIELD
}

void
spdk_nvme_ctrlr_free_gpu_io_qpairs(struct spdk_nvme_gpu_qpairs *qpairs)
{
	uint32_t i;

	for (i = 0; i < qpairs->num_qpairs; i++) {
		if (qpairs->qpairs[i] != NULL) {
			spdk_nvme_ctrlr_free_io_qpair(qpairs->qpairs[i]);
		}
	}
	nvme_rdma_gpu_set_free(qpairs->set);
	free(qpairs);
}

struct spdk_nvme_gpu_qpairs *
spdk_nvme_ctrlr_alloc_gpu_io_qpairs(struct spdk_nvme_ctrlr *ctrlr, uint32_t num_qpairs,
				    const struct spdk_nvme_gpu_qpair_opts *user_opts, size_t opts_size)
{
	struct spdk_nvme_gpu_qpair_opts opts;
	struct spdk_nvme_io_qpair_opts qopts;
	struct spdk_nvme_gpu_qpairs *qpairs;
	struct nvme_rdma_gpu_qpair *gq;
	struct spdk_nvme_qpair *qpair;
	struct spdk_nvme_ns *ns;
	uint32_t block_size, i;

	if (ctrlr->trid.trtype != SPDK_NVME_TRANSPORT_RDMA) {
		NVME_CTRLR_ERRLOG(ctrlr, "GPU I/O queues need the RDMA transport\n");
		return NULL;
	}
	if (num_qpairs == 0) {
		return NULL;
	}

	/*
	 * Get the default options, then overwrite them with the user-provided options
	 * up to opts_size.
	 *
	 * This allows for extensions of the opts structure without breaking
	 * ABI compatibility.
	 */
	spdk_nvme_gpu_qpair_get_default_opts(ctrlr, &opts, sizeof(opts));
	if (user_opts) {
		nvme_gpu_qpair_opts_copy(&opts, user_opts, spdk_min(opts.opts_size, opts_size));
	}

	ns = spdk_nvme_ctrlr_get_ns(ctrlr, opts.nsid);
	if (ns == NULL || !spdk_nvme_ns_is_active(ns)) {
		NVME_CTRLR_ERRLOG(ctrlr, "Namespace %u is not active\n", opts.nsid);
		return NULL;
	}
	block_size = spdk_nvme_ns_get_sector_size(ns);
	if (opts.num_slots == 0 || opts.slot_size == 0 || opts.slot_size % block_size != 0) {
		NVME_CTRLR_ERRLOG(ctrlr, "Invalid GPU queue options: %u slots of %u bytes, block size %u\n",
				  opts.num_slots, opts.slot_size, block_size);
		return NULL;
	}

	qpairs = calloc(1, sizeof(*qpairs) + num_qpairs * sizeof(qpairs->qpairs[0]));
	if (qpairs == NULL) {
		return NULL;
	}
	qpairs->num_qpairs = num_qpairs;
	qpairs->set = nvme_rdma_gpu_set_alloc(opts.nsid, num_qpairs, opts.num_slots, opts.slot_size,
					      block_size);
	if (qpairs->set == NULL) {
		free(qpairs);
		return NULL;
	}

	spdk_nvme_ctrlr_get_default_io_qpair_opts(ctrlr, &qopts, sizeof(qopts));
	/* A queue of N entries holds at most N - 1 commands. */
	qopts.io_queue_size = opts.num_slots + 1;
	qopts.create_only = true;

	for (i = 0; i < num_qpairs; i++) {
		gq = nvme_rdma_gpu_qpair_alloc(qpairs->set, i);
		if (gq == NULL) {
			goto err;
		}
		qpair = spdk_nvme_ctrlr_alloc_io_qpair(ctrlr, &qopts, sizeof(qopts));
		if (qpair == NULL) {
			nvme_rdma_gpu_qpair_free(gq);
			goto err;
		}
		qpairs->qpairs[i] = qpair;
		if (nvme_rdma_qpair_set_gpu(qpair, gq, opts.num_slots) != 0) {
			nvme_rdma_gpu_qpair_free(gq);
			goto err;
		}
		if (spdk_nvme_ctrlr_connect_io_qpair(ctrlr, qpair) != 0) {
			goto err;
		}
	}

	return qpairs;

err:
	spdk_nvme_ctrlr_free_gpu_io_qpairs(qpairs);
	return NULL;
}

struct spdk_nvme_gpu_qpair *
spdk_nvme_gpu_qpairs_get_device(struct spdk_nvme_gpu_qpairs *qpairs)
{
	return nvme_rdma_gpu_set_get_device(qpairs->set);
}
