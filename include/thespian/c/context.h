#pragma once

#include <thespian/c/env.h>
#include <thespian/c/handle.h>

// NOLINTBEGIN(modernize-use-trailing-return-type, modernize-use-using)
#ifdef __cplusplus
extern "C" {
#endif

typedef void (*thespian_last_exit_handler)();
typedef void (*thespian_context_destroy)(void *);

typedef void *thespian_behaviour_state;
typedef void *thespian_exit_handler_state;
typedef thespian_result (*thespian_behaviour)(thespian_behaviour_state);
typedef void (*thespian_exit_handler)(thespian_exit_handler_state,
                                      const char *msg, size_t len);

struct thespian_context_t;
typedef struct thespian_context_t *thespian_context;

thespian_context thespian_context_create(thespian_context_destroy *);
void thespian_context_run(thespian_context);
void thespian_context_on_last_exit(thespian_context,
                                   thespian_last_exit_handler);

int thespian_context_spawn_link(thespian_context, thespian_behaviour,
                                thespian_behaviour_state, thespian_exit_handler,
                                thespian_exit_handler_state, const char *name,
                                thespian_env, thespian_handle *);

const char *thespian_get_last_error();
void thespian_set_last_error(const char *);

#ifdef __cplusplus
}
#endif
// NOLINTEND(modernize-use-trailing-return-type, modernize-use-using)
