#ifndef LLVM_CHECK_H
#define LLVM_CHECK_H

#include <stdint.h>

#ifdef __clang__
#define IS_CLANG_COMPILER 1
#else
#define IS_CLANG_COMPILER 0
#endif

int32_t llvm_c_add(int32_t a, int32_t b);

#endif
