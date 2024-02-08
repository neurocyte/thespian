#pragma once

#include <thespian/c/string_view.h>

#include <stddef.h> // NOLINT
#include <stdint.h> // NOLINT

#ifdef __cplusplus
extern "C" {
#endif

struct cbor_buffer_t {
  const uint8_t *base;
  size_t len;
};
typedef struct // NOLINT
    cbor_buffer_t cbor_buffer;

typedef // NOLINT
    void (*cbor_to_json_callback)(c_string_view);

void cbor_to_json(cbor_buffer, cbor_to_json_callback);

#ifdef __cplusplus
}
#endif
