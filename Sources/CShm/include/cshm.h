#ifndef CSHM_H
#define CSHM_H

#include <stddef.h>
#include <stdint.h>

/// Maps an existing POSIX shared memory region. Returns NULL on failure.
/// Swift cannot call shm_open() directly because it is a variadic function.
void *cshm_map(const char *name, size_t *out_size);

/// Unmaps a region from cshm_map().
void cshm_unmap(void *address, size_t size);

/// Reads a 32-bit value with acquire order, so the pixels written before it are visible.
uint32_t cshm_load_acquire_u32(const void *address);
/// Keeps earlier reads (the pixel copy) from moving after later reads.
void cshm_fence_acquire(void);

#endif
