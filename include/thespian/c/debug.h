#pragma once

#include <thespian/c/context.h>
#include <thespian/c/handle.h>
#include <thespian/c/unx.h>

// NOLINTBEGIN(modernize-*, hicpp-*)
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void thespian_debug_enable(thespian_context);
void thespian_debug_disable(thespian_context);
bool thespian_debug_isenabled(thespian_context);

// Start the debug tcp console on [::1]:port. Must be called from within an
// actor. On success stores the console actor handle in *handle (the caller
// owns it and must call thespian_handle_destroy) and returns 0.
int thespian_debug_tcp_create(thespian_context, uint16_t port,
                              const char *prompt, thespian_handle *handle);

// Start the debug console on a unix domain socket, see
// thespian::debug::unx::create. Same calling rules as
// thespian_debug_tcp_create.
int thespian_debug_unx_create(thespian_context, const char *path,
                              thespian_unx_mode mode, const char *prompt,
                              thespian_handle *handle);

#ifdef __cplusplus
}
#endif
// NOLINTEND(modernize-*, hicpp-*)
