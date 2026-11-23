#include "checksum.h"

uint32_t checksum_bytes(const uint8_t *buf, size_t len) {
    uint32_t acc = CHECKSUM_SEED;
    for (size_t i = 0; i < len; ++i) {
        acc = checksum_mix(acc, buf[i]);
    }
    return acc;
}
