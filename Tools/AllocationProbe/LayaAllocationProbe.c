#include <errno.h>
#include <malloc/malloc.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

static _Thread_local bool laya_probe_armed;
static _Thread_local uint64_t laya_probe_allocation_count;

__attribute__((visibility("default")))
void laya_allocation_probe_arm(void) {
    laya_probe_allocation_count = 0;
    laya_probe_armed = true;
}

__attribute__((visibility("default")))
uint64_t laya_allocation_probe_disarm(void) {
    laya_probe_armed = false;
    return laya_probe_allocation_count;
}

static inline void laya_record_allocation(void) {
    if (laya_probe_armed) {
        laya_probe_allocation_count += 1;
    }
}

static inline malloc_zone_t *laya_zone_for_pointer(void *pointer) {
    if (pointer == NULL) {
        return malloc_default_zone();
    }
    malloc_zone_t *zone = malloc_zone_from_ptr(pointer);
    return zone == NULL ? malloc_default_zone() : zone;
}

static void *laya_malloc(size_t size) {
    laya_record_allocation();
    return malloc_zone_malloc(malloc_default_zone(), size);
}

static void *laya_calloc(size_t count, size_t size) {
    laya_record_allocation();
    return malloc_zone_calloc(malloc_default_zone(), count, size);
}

static void *laya_realloc(void *pointer, size_t size) {
    laya_record_allocation();
    return malloc_zone_realloc(laya_zone_for_pointer(pointer), pointer, size);
}

static void *laya_valloc(size_t size) {
    laya_record_allocation();
    return malloc_zone_valloc(malloc_default_zone(), size);
}

static void *laya_aligned_alloc(size_t alignment, size_t size) {
    laya_record_allocation();
    return malloc_zone_memalign(malloc_default_zone(), alignment, size);
}

static int laya_posix_memalign(
    void **result,
    size_t alignment,
    size_t size
) {
    if (alignment < sizeof(void *)
        || (alignment & (alignment - 1)) != 0) {
        return EINVAL;
    }
    laya_record_allocation();
    void *pointer = malloc_zone_memalign(
        malloc_default_zone(),
        alignment,
        size
    );
    if (pointer == NULL) {
        return ENOMEM;
    }
    *result = pointer;
    return 0;
}

#define LAYA_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } laya_interpose_##replacee \
    __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(uintptr_t)&replacement, \
        (const void *)(uintptr_t)&replacee \
    }

LAYA_INTERPOSE(laya_malloc, malloc);
LAYA_INTERPOSE(laya_calloc, calloc);
LAYA_INTERPOSE(laya_realloc, realloc);
LAYA_INTERPOSE(laya_valloc, valloc);
LAYA_INTERPOSE(laya_aligned_alloc, aligned_alloc);
LAYA_INTERPOSE(laya_posix_memalign, posix_memalign);
