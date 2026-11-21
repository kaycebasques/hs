#include "inline_helper.h"

#ifndef INLINE_SCALE
#define INLINE_SCALE 1
#endif

void accum_reset(Accum *a, int64_t initial) {
    a->acc = initial;
    a->count = 0;
    a->pad = 0;
}

void accum_push(Accum *a, int32_t value) {
    a->acc += (int64_t)value;
    a->count += 1;
}

int64_t accum_finish(const Accum *a) {
    return a->acc * (int64_t)INLINE_SCALE + (int64_t)a->count;
}
