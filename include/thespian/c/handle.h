#pragma once

#include "thespian/c/string_view.h"
#include <cbor/c/cbor.h>

// NOLINTBEGIN(modernize-*, hicpp-*)
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef cbor_buffer thespian_error;
typedef thespian_error *thespian_result;

struct thespian_handle_t;
typedef struct thespian_handle_t *thespian_handle;

thespian_handle thespian_handle_clone(thespian_handle);
void thespian_handle_destroy(thespian_handle);

thespian_result thespian_handle_send_raw(thespian_handle, cbor_buffer);
thespian_result thespian_handle_send_exit(thespian_handle, c_string_view);
bool thespian_handle_is_expired(thespian_handle);

#ifdef __cplusplus
}
#endif
// NOLINTEND(modernize-*, hicpp-*)
