#include <algorithm>
#include <cstdint>
#include <numeric>
#include <vector>

#ifndef CXX_BONUS
#define CXX_BONUS 0
#endif

extern "C" int32_t cxx_sorted_weighted_sum(int32_t a, int32_t b, int32_t c) {
    std::vector<int32_t> vals = {a, b, c};
    std::sort(vals.begin(), vals.end());
    return vals[0] * 1 + vals[1] * 2 + vals[2] * 3 + CXX_BONUS;
}
