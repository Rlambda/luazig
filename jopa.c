#include <stdio.h>
#include <errno.h>
#include <string.h>

int main(void) {
    FILE *ret = fopen("jopa", "r");
    printf("Jopa is %i\n", *ret);
    printf("errno is %i\n", errno);
    printf("errno is %s\n", strerror(errno));


    return 0;
}
