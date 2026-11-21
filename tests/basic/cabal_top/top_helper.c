/* Tests transitive install-includes header propagation (depends on cabal_mid, NOT cabal_c_only directly). */
#include <clib.h>

int top_helper_fn(int x) {
    return clib_scale(x) + CLIB_MAGIC;
}
