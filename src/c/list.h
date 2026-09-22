#ifndef LIST_H
#define LIST_H
#include <stdio.h>
#include <stdlib.h>

#define INIT_CAPACITY 4

#define LIST(T) T *
typedef struct {
    size_t count;
    size_t cap;
} ListHdr;

#define list_hdr(ptr) ((ListHdr *)(ptr) - 1)
#define list_init(T, ptr)                                                      \
    do {                                                                       \
        ListHdr *hdr = malloc(sizeof(ListHdr) + sizeof(T) * INIT_CAPACITY);    \
        if (!hdr) {                                                            \
            fprintf(stderr, "out of memory\n");                                \
            exit(1);                                                           \
        }                                                                      \
        hdr->count = 0;                                                        \
        hdr->cap = INIT_CAPACITY;                                              \
        (ptr) = (T *)((char *)hdr + sizeof(ListHdr));                          \
    } while (0)

#define list_push(T, ptr, val)                                                 \
    do {                                                                       \
        ListHdr *hdr = list_hdr(ptr);                                          \
        if (hdr->count >= hdr->cap) {                                          \
            size_t new_cap = hdr->cap * 2;                                     \
            void *new_mem =                                                    \
                realloc(hdr, sizeof(ListHdr) + sizeof(T) * new_cap);           \
            if (!new_mem) {                                                    \
                fprintf(stderr, "out of memory\n");                            \
                exit(1);                                                       \
            }                                                                  \
            hdr = new_mem;                                                     \
            hdr->cap = new_cap;                                                \
            (ptr) = (T *)((char *)hdr + sizeof(ListHdr));                      \
        }                                                                      \
        (ptr)[hdr->count] = (val);                                             \
        hdr->count++;                                                          \
    } while (0)

#define list_count(ptr) (list_hdr(ptr)->count)
#define list_free(ptr)                                                         \
    do {                                                                       \
        ListHdr *hdr = list_hdr(ptr);                                          \
        if (hdr) free(hdr);                                                    \
        (ptr) = NULL;                                                          \
    } while (0)

#define list_get(ptr, i) ((ptr)[i])
#endif