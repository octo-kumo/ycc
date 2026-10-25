#ifndef Y_BOOTSTRAP_GC_H
#define Y_BOOTSTRAP_GC_H
/* Optional Boehm GC allocator for the hosted bootstrap. The ABI is the small
 * allocator interface exported by libgc.so.1; no compiler logic lives here. */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
extern void GC_init(void);
extern void GC_set_warn_proc(void (*)(const char *, uintptr_t));
static void cg_gc_warning(const char *message, uintptr_t argument) {
    (void)message;(void)argument; /* allocation failure has one deterministic report below */
}
extern void GC_set_max_heap_size(size_t);
extern void *GC_malloc(size_t);
extern void *GC_malloc_atomic(size_t);
extern void *GC_realloc(void *, size_t);
extern void GC_free(void *);
static void cg_gc_init(void) {
    static int initialized;
    if(!initialized){GC_init();GC_set_warn_proc(cg_gc_warning);GC_set_max_heap_size((size_t)2600*1024*1024);initialized=1;}
}
static void *cg_gc_check(void *p) {
    if(!p){fputs("runtime error: out of memory\n",stdout);exit(1);}return p;
}
static void *cg_gc_malloc(size_t n) { cg_gc_init();return cg_gc_check(GC_malloc(n?n:1)); }
static void *cg_gc_calloc(size_t n,size_t size) {
    if(size && n>SIZE_MAX/size)return NULL;
    return cg_gc_malloc(n*size);
}
static void *cg_gc_realloc(void *p,size_t n) { cg_gc_init();return cg_gc_check(GC_realloc(p,n?n:1)); }
#define malloc cg_gc_malloc
#define calloc cg_gc_calloc
#define realloc cg_gc_realloc
#define free GC_free
#endif
