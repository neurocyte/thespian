#pragma once

#include <cbor/c/cbor.h>

// NOLINTBEGIN(modernize-use-trailing-return-type)
#ifdef __cplusplus
extern "C" {
#endif

struct thespian_signal_handle;
struct thespian_signal_handle *
thespian_signal_create(int signum, cbor_buffer m);
int thespian_signal_cancel(struct thespian_signal_handle *);
void thespian_signal_destroy(struct thespian_signal_handle *);

#ifdef __cplusplus
}
#endif
// NOLINTEND(modernize-use-trailing-return-type)
