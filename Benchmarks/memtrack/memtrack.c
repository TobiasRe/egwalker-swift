// LD_PRELOAD heap tracker: counts *requested* bytes (like a Rust counting
// GlobalAlloc), so Swift and Rust numbers are comparable.
// Exposes memtrack_current(), memtrack_peak(), memtrack_reset_peak().
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>
#include <stdatomic.h>
#include <malloc.h>
#include <string.h>

static void *(*real_malloc)(size_t);
static void (*real_free)(void *);
static void *(*real_realloc)(void *, size_t);
static void *(*real_calloc)(size_t, size_t);
static int (*real_posix_memalign)(void **, size_t, size_t);
static void *(*real_aligned_alloc)(size_t, size_t);
static _Atomic long cur, peak;
static char boot[65536]; static size_t boot_used;

static void bump(long d) { long c = atomic_fetch_add(&cur, d) + d; long p = atomic_load(&peak); while (c > p && !atomic_compare_exchange_weak(&peak, &p, c)) {} }
static void init(void) {
  real_malloc = dlsym(RTLD_NEXT, "malloc"); real_free = dlsym(RTLD_NEXT, "free");
  real_realloc = dlsym(RTLD_NEXT, "realloc"); real_calloc = dlsym(RTLD_NEXT, "calloc");
  real_posix_memalign = dlsym(RTLD_NEXT, "posix_memalign"); real_aligned_alloc = dlsym(RTLD_NEXT, "aligned_alloc");
}
static int is_boot(void *p) { return (char *)p >= boot && (char *)p < boot + sizeof boot; }
void *malloc(size_t n) { if (!real_malloc) { if (boot_used + n > sizeof boot) return NULL; void *p = boot + boot_used; boot_used += (n + 15) & ~15; return p; } void *p = real_malloc(n); if (p) bump((long)malloc_usable_size(p)); return p; }
void free(void *p) { if (!p || is_boot(p)) return; bump(-(long)malloc_usable_size(p)); real_free(p); }
void *calloc(size_t a, size_t b) { if (!real_calloc) { void *p = malloc(a * b); if (p) memset(p, 0, a * b); return p; } void *p = real_calloc(a, b); if (p) bump((long)malloc_usable_size(p)); return p; }
void *realloc(void *p, size_t n) { if (!real_realloc) init(); if (p && is_boot(p)) { void *q = real_malloc(n); memcpy(q, p, n); bump((long)malloc_usable_size(q)); return q; } long old = p ? (long)malloc_usable_size(p) : 0; void *q = real_realloc(p, n); if (q) bump((long)malloc_usable_size(q) - old); else if (n == 0) bump(-old); return q; }
int posix_memalign(void **out, size_t al, size_t n) { if (!real_posix_memalign) init(); int r = real_posix_memalign(out, al, n); if (!r) bump((long)malloc_usable_size(*out)); return r; }
void *aligned_alloc(size_t al, size_t n) { if (!real_aligned_alloc) init(); void *p = real_aligned_alloc(al, n); if (p) bump((long)malloc_usable_size(p)); return p; }
__attribute__((constructor)) static void ctor(void) { init(); }
long memtrack_current(void) { return atomic_load(&cur); }
long memtrack_peak(void) { return atomic_load(&peak); }
void memtrack_reset_peak(void) { atomic_store(&peak, atomic_load(&cur)); }
