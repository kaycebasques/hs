#ifndef TESTS_RULES_FFI_VEC_H
#define TESTS_RULES_FFI_VEC_H

#include <stdint.h>

#define VEC_MAGIC_VERSION 2026

typedef struct {
    int32_t x;
    int32_t y;
    double weight;
} Vec2;

extern const int32_t vec_global_bias;

void vec2_init(Vec2 *out, int32_t x, int32_t y, double weight);
void vec2_add(const Vec2 *a, const Vec2 *b, Vec2 *out);
int64_t vec2_dot(const Vec2 *a, const Vec2 *b);
double vec2_weighted_sum(const Vec2 *arr, int32_t len);

#endif
