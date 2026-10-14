/*   SPDX-License-Identifier: BSD-3-Clause
 *   Copyright (C) 2026 Hyungsun Yoo.
 *   All rights reserved.
 */

/** \file
 * GPU-initiated NVMe-oF I/O queues (RDMA transport)
 *
 * I/O queues created with spdk_nvme_ctrlr_alloc_gpu_io_qpairs() are driven by GPU
 * code instead of the CPU: GPU threads submit reads and reap completions with the
 * functions in spdk/nvme_gpu.cuh, and each queue's queue pair, completion queues
 * and buffers live in GPU memory. The CPU only creates, connects and frees the
 * queues.
 *
 * Each queue has a fixed number of slots. A slot is one outstanding read: its
 * NVMe command and its data buffer are fixed when the queue is created, and the
 * command identifier is the slot number.
 */

#ifndef SPDK_NVME_GPU_H
#define SPDK_NVME_GPU_H

#include "spdk/stdinc.h"
#include "spdk/nvme.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Device-side view of a GPU I/O queue, passed to the functions in
 * spdk/nvme_gpu.cuh. Its layout is defined there.
 */
struct spdk_nvme_gpu_qpair;

/** GPU I/O queues created together by spdk_nvme_ctrlr_alloc_gpu_io_qpairs(). */
struct spdk_nvme_gpu_qpairs;

/** Options for spdk_nvme_ctrlr_alloc_gpu_io_qpairs(). */
struct spdk_nvme_gpu_qpair_opts {
	/**
	 * The size of spdk_nvme_gpu_qpair_opts according to the caller of this library is used for
	 * ABI compatibility. The library uses this field to know how many fields in this structure
	 * are valid. And the library will populate any remaining fields with default values.
	 */
	size_t opts_size;

	/** Namespace the queues read from. */
	uint32_t nsid;

	/** Number of slots of each queue: how many reads can be outstanding on it at once. */
	uint32_t num_slots;

	/**
	 * Size of each slot's data buffer in bytes, i.e. the largest read. Must be a
	 * multiple of the namespace's block size.
	 */
	uint32_t slot_size;
};

/**
 * Get the default options for GPU I/O queues.
 *
 * \param ctrlr Controller the queues will be created on.
 * \param opts Options to fill.
 * \param opts_size Must be set to sizeof(struct spdk_nvme_gpu_qpair_opts).
 */
void spdk_nvme_gpu_qpair_get_default_opts(struct spdk_nvme_ctrlr *ctrlr,
		struct spdk_nvme_gpu_qpair_opts *opts, size_t opts_size);

/**
 * Allocate and connect I/O queues driven by the GPU.
 *
 * The controller must use the RDMA transport. The queues are created on the current
 * CUDA device and share its GPU memory and its registration with the NIC. They are
 * not added to a poll group, and spdk_nvme_qpair_process_completions() does not reap
 * their completions; GPU code does (see spdk/nvme_gpu.cuh).
 *
 * \param ctrlr Controller to create the queues on.
 * \param num_qpairs Number of queues.
 * \param opts Queue options, or NULL for the defaults.
 * \param opts_size Must be set to sizeof(struct spdk_nvme_gpu_qpair_opts), or 0 if opts is NULL.
 *
 * \return the queues, or NULL on failure.
 */
struct spdk_nvme_gpu_qpairs *spdk_nvme_ctrlr_alloc_gpu_io_qpairs(struct spdk_nvme_ctrlr *ctrlr,
		uint32_t num_qpairs, const struct spdk_nvme_gpu_qpair_opts *opts, size_t opts_size);

/**
 * Free GPU I/O queues. No GPU code may use them any more.
 *
 * \param qpairs Queues returned by spdk_nvme_ctrlr_alloc_gpu_io_qpairs().
 */
void spdk_nvme_ctrlr_free_gpu_io_qpairs(struct spdk_nvme_gpu_qpairs *qpairs);

/**
 * Get the device-side views of GPU I/O queues.
 *
 * \param qpairs Queues returned by spdk_nvme_ctrlr_alloc_gpu_io_qpairs().
 *
 * \return an array of num_qpairs queues in GPU memory, to pass to GPU code.
 */
struct spdk_nvme_gpu_qpair *spdk_nvme_gpu_qpairs_get_device(struct spdk_nvme_gpu_qpairs *qpairs);

#ifdef __cplusplus
}
#endif

#endif /* SPDK_NVME_GPU_H */
