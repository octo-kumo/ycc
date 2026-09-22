#include "parser_debug.h"
#include "parser.h"
#include "stdio.h"

char *digit_list_to_str(list_t *list) {
    size_t len = 0;
    list_t *current = list;
    while (current) {
        len += 1;
        current = current->next;
    }
    char *str = malloc(len + 1);
    str[len] = '\0';
    current = list;
    size_t index = 0;
    while (current) {
        str[index++] = (char)(uintptr_t)current->value + '0';
        current = current->next;
    }
    return str;
}

char *long_list_to_str(list_t *list) {
    size_t len = 0;
    list_t *current = list;
    while (current) {
        len += 20; // enough for long
        current = current->next;
    }
    char *str = malloc(len + 3);
    str[0] = '[';
    str[len + 2] = '\0';
    current = list;
    size_t index = 1;
    while (current) {
        index += sprintf(str + index, "%ld, ", (long)(uintptr_t)current->value);
        current = current->next;
    }
    if (index > 1) {
        str[index - 2] = ']';
        str[index - 1] = '\0';
    } else {
        str[1] = ']';
        str[2] = '\0';
    }
    return str;
}
