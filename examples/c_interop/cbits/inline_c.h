#ifndef INLINE_C_H
#define INLINE_C_H

#include <stdint.h>

#ifndef INLINE_FACTOR
#define INLINE_FACTOR 1
#endif

#define INLINE_C_CONSTANT (10 * INLINE_FACTOR)

int32_t inline_c_scale(int32_t x);

#endif
