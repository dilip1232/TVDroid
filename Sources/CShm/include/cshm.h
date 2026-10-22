#ifndef CSHM_H
#define CSHM_H

#include <stddef.h>

/// Maps an existing POSIX shared memory region. Returns NULL on failure.
/// Swift cannot call shm_open() directly because it is a variadic function.
void *cshm_map(const char *name, size_t *out_size);

/// Unmaps a region from cshm_map().
void cshm_unmap(void *address, size_t size);

#endif
