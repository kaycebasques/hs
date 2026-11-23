#ifndef SYS_CC_H
#define SYS_CC_H

#include <stdint.h>

#if defined(__GNUC__) || defined(__clang__)
#define HAS_GNU_OR_CLANG_CC 1
#else
#define HAS_GNU_OR_CLANG_CC 0
#endif

int32_t sys_cc_mul_add(int32_t a, int32_t b, int32_t c);

#endif
