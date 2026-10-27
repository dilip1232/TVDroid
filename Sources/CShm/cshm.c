#include "cshm.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

void *cshm_map(const char *name, size_t *out_size) {
    int fd = shm_open(name, O_RDWR, 0);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        close(fd);
        return NULL;
    }
    void *address = mmap(NULL, (size_t)st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (address == MAP_FAILED) return NULL;
    *out_size = (size_t)st.st_size;
    return address;
}

void cshm_unmap(void *address, size_t size) {
    if (address) munmap(address, size);
}

void cshm_fence_acquire(void) { __atomic_thread_fence(__ATOMIC_ACQUIRE); }

uint32_t cshm_load_acquire_u32(const void *address) {
    return __atomic_load_n((const uint32_t *)address, __ATOMIC_ACQUIRE);
}
