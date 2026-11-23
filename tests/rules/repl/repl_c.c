#include "repl_c.h"

int repl_c_scale(int x, int factor) {
    return x * factor + REPL_C_MAGIC;
}
