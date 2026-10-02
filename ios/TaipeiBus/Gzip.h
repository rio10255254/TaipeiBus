#ifndef TAIPEI_BUS_GZIP_H
#define TAIPEI_BUS_GZIP_H
#include <stddef.h>
#include <stdint.h>

// Caller owns *output on success. The 32 MiB cap bounds a malformed response.
int TaipeiBusInflateGzip(const uint8_t *input, size_t inputLength,
                        uint8_t **output, size_t *outputLength);
void TaipeiBusFreeBytes(void *bytes);
#endif
