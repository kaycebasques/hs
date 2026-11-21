#ifndef TESTS_RULES_FFI_INLINE_HELPER_H
#define TESTS_RULES_FFI_INLINE_HELPER_H

#include <stdint.h>

#define INLINE_HELPER_TAG 77
#define CAPI_SCALED_TAG (INLINE_SCALE * 11)

typedef struct {
    int64_t acc;
    int32_t count;
    int32_t pad;
} Accum;

void accum_reset(Accum *a, int64_t initial);
void accum_push(Accum *a, int32_t value);
int64_t accum_finish(const Accum *a);

#endif
