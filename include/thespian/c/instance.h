#pragma once

#include "context.h"
#include "env.h"
#include "handle.h"

// NOLINTBEGIN(modernize-use-trailing-return-type, modernize-use-using)
#ifdef __cplusplus
extern "C" {
#endif

typedef thespian_result (*thespian_receiver)(thespian_behaviour_state,
                                             thespian_handle from, cbor_buffer);

void thespian_receive(thespian_receiver, thespian_behaviour_state);

bool thespian_get_trap();
bool thespian_set_trap(bool);
void thespian_link(thespian_handle);

thespian_handle thespian_self();

int thespian_spawn_link(thespian_behaviour, thespian_behaviour_state,
                        const char *name, thespian_env, thespian_handle *);

#ifdef __cplusplus
}
#endif
// NOLINTEND(modernize-use-trailing-return-type, modernize-use-using)
