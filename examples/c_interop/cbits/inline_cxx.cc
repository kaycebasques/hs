#include <algorithm>
#include <cstdint>

extern "C" int32_t inline_cxx_median3(int32_t a, int32_t b, int32_t c) {
    int32_t vals[3] = {a, b, c};
    std::sort(vals, vals + 3);
    return vals[1];
}
