#ifndef C_MAP_H
#define C_MAP_H

#include <stdlib.h>
#include <string.h>

typedef struct {
    char *key;
    void *value;
} map_entry;

typedef struct {
    map_entry *items;
    size_t len;
    size_t cap;
} map_t;

void map_init(map_t *m);
void *map_get(map_t *m, const char *key);
void map_set(map_t *m, const char *key, void *value);
void map_free(map_t *m);

#endif