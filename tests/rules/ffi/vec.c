#include "vec.h"

const int32_t vec_global_bias = 100;

void vec2_init(Vec2 *out, int32_t x, int32_t y, double weight) {
    out->x = x;
    out->y = y;
    out->weight = weight;
}

void vec2_add(const Vec2 *a, const Vec2 *b, Vec2 *out) {
    out->x = a->x + b->x;
    out->y = a->y + b->y;
    out->weight = a->weight + b->weight;
}

int64_t vec2_dot(const Vec2 *a, const Vec2 *b) {
    return (int64_t)a->x * (int64_t)b->x + (int64_t)a->y * (int64_t)b->y;
}

double vec2_weighted_sum(const Vec2 *arr, int32_t len) {
    double acc = 0.0;
    for (int32_t i = 0; i < len; ++i) {
        acc += (double)(arr[i].x + arr[i].y) * arr[i].weight;
    }
    return acc;
}
