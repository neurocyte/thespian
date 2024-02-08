#pragma once

#include <thespian/c/handle.h>
#include <thespian/c/string_view.h>
#include <thespian/c/trace.h>

// NOLINTBEGIN(modernize-use-trailing-return-type, modernize-use-using)
#ifdef __cplusplus
extern "C" {
#endif

struct thespian_env_t;
typedef struct
    thespian_env_t *thespian_env;

void thespian_env_enable_all_channels(thespian_env);
void thespian_env_disable_all_channels(thespian_env);
void thespian_env_enable(thespian_env, thespian_trace_channel);
void thespian_env_disable(thespian_env, thespian_trace_channel);
bool thespian_env_enabled(thespian_env, thespian_trace_channel);
void thespian_env_on_trace(thespian_env, thespian_trace_handler);
void thespian_env_trace(thespian_env, cbor_buffer);

bool thespian_env_is(thespian_env, c_string_view key);              
void thespian_env_set(thespian_env, c_string_view key, bool);       
int64_t thespian_env_num(thespian_env, c_string_view key);          
void thespian_env_num_set(thespian_env, c_string_view key, int64_t);
c_string_view thespian_env_str(thespian_env, c_string_view key);    
void thespian_env_str_set(thespian_env, c_string_view key,
                          c_string_view);                          
thespian_handle thespian_env_proc(thespian_env, c_string_view key);
void thespian_env_proc_set(thespian_env, c_string_view key,
                           thespian_handle);

thespian_env thespian_env_get();              
thespian_env thespian_env_new();              
thespian_env thespian_env_clone(thespian_env);
void thespian_env_destroy(thespian_env);      

#ifdef __cplusplus
}
#endif
// NOLINTEND(modernize-use-trailing-return-type, modernize-use-using)
