#ifndef CHECKSUM_H
#define CHECKSUM_H

#include <stddef.h>
#include <stdint.h>

#define CHECKSUM_SEED 0x1234U

static inline uint32_t checksum_mix(uint32_t a, uint32_t b) {
    return (a << 3) ^ b;
}

uint32_t checksum_bytes(const uint8_t *buf, size_t len);

#endif
