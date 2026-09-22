#include "map.h"
#include <stdlib.h>
#include <string.h>

void map_init(map_t *m) {
    m->items = NULL;
    m->len = 0;
    m->cap = 0;
}

void *map_get(map_t *m, const char *key) {
    for (size_t i = 0; i < m->len; i++) {
        if (strcmp(m->items[i].key, key) == 0) return m->items[i].value;
    }
    return NULL;
}

void map_set(map_t *m, const char *key, void *value) {
    for (size_t i = 0; i < m->len; i++) {
        if (strcmp(m->items[i].key, key) == 0) {
            if (value == NULL) { // remove
                free(m->items[i].key);
                m->items[i] = m->items[m->len - 1];
                m->len--;
            } else {
                m->items[i].value = value;
            }
            return;
        }
    }

    if (value == NULL) return; // removing non-existent key

    if (m->len == m->cap) {
        m->cap = m->cap ? m->cap * 2 : 4;
        m->items = realloc(m->items, m->cap * sizeof(map_entry));
    }

    m->items[m->len].key = strdup(key);
    m->items[m->len].value = value;
    m->len++;
}

void map_free(map_t *m) {
    for (size_t i = 0; i < m->len; i++) free(m->items[i].key);

    free(m->items);
    m->items = NULL;
    m->len = 0;
    m->cap = 0;
}
