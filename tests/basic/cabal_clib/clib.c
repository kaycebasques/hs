#include "clib.h"
#include "clib_impl.c"

int clib_scale(int x) {
    return clib_internal_mult(x) + CLIB_MAGIC;
}
