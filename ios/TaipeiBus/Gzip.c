#include "Gzip.h"
#include <limits.h>
#include <stdlib.h>
#include <zlib.h>

int TaipeiBusInflateGzip(const uint8_t *input, size_t inputLength,
                        uint8_t **output, size_t *outputLength) {
    if (!input || !output || !outputLength || inputLength > UINT_MAX) return -1;
    *output = NULL;
    *outputLength = 0;
    z_stream stream = {0};
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)inputLength;
    if (inflateInit2(&stream, 16 + MAX_WBITS) != Z_OK) return -2;
    const size_t limit = 32 * 1024 * 1024;
    size_t capacity = 64 * 1024;
    uint8_t *bytes = malloc(capacity);
    if (!bytes) { inflateEnd(&stream); return -3; }
    int result = Z_OK;
    while (result == Z_OK) {
        if (stream.total_out >= capacity) {
            if (capacity >= limit) { result = Z_MEM_ERROR; break; }
            capacity *= 2;
            uint8_t *grown = realloc(bytes, capacity);
            if (!grown) { result = Z_MEM_ERROR; break; }
            bytes = grown;
        }
        stream.next_out = bytes + stream.total_out;
        stream.avail_out = (uInt)(capacity - stream.total_out);
        result = inflate(&stream, Z_NO_FLUSH);
    }
    size_t length = stream.total_out;
    inflateEnd(&stream);
    if (result != Z_STREAM_END) { free(bytes); return -4; }
    *output = bytes;
    *outputLength = length;
    return 0;
}

void TaipeiBusFreeBytes(void *bytes) { free(bytes); }
