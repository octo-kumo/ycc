/* the largest file in the tree, so --largest has something to say */
#include <stdio.h>

int main(int argc, char **argv)
{
    int total = 0;
    for (int i = 1; i < argc; i++) {
        total += (int)argv[i][0];
    }
    printf("total=%d argc=%d\n", total, argc);
    return 0;
}
