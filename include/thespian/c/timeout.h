#pragma once

#include <cbor/c/cbor.h>

// NOLINTBEGIN(modernize-use-trailing-return-type)
#ifdef __cplusplus
extern "C" {
#endif

struct thespian_timeout_handle;
struct thespian_timeout_handle *
thespian_timeout_create_ms(unsigned long ms, cbor_buffer m);
struct thespian_timeout_handle *
thespian_timeout_create_us(unsigned long us, cbor_buffer m);
int thespian_timeout_cancel(struct thespian_timeout_handle *);
void thespian_timeout_destroy(struct thespian_timeout_handle *);

#ifdef __cplusplus
}
#endif
// NOLINTEND(modernize-use-trailing-return-type)
