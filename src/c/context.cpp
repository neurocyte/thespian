#include "thespian/env.hpp"
#include <__type_traits/is_swappable.h>
#include <thespian/c/context.h>
#include <thespian/c/handle.h>
#include <thespian/context.hpp>
#include <thespian/handle.hpp>

using std::string_view;
using thespian::context;

thread_local const char *last_error{}; // NOLINT

extern "C" {

auto thespian_get_last_error() -> const char * { return last_error; }
void thespian_set_last_error(const char *msg) { last_error = msg; }

thespian_context
thespian_context_create(thespian_context_destroy *d) {        // NOLINT
  return reinterpret_cast<thespian_context>(                  // NOLINT
      context::create(reinterpret_cast<context::dtor *>(d))); // NOLINT
}

void thespian_context_run(thespian_context ctx) {
  reinterpret_cast<context *>(ctx)->run(); // NOLINT
}

void thespian_context_on_last_exit(thespian_context ctx,
                                   thespian_last_exit_handler h) {
  reinterpret_cast<context *>(ctx)->on_last_exit(h); // NOLINT
}

auto thespian_context_spawn_link(thespian_context ctx_, thespian_behaviour b,
                                 thespian_behaviour_state s,
                                 thespian_exit_handler eh,
                                 thespian_exit_handler_state es,
                                 const char *name, thespian_env env,
                                 thespian_handle *handle) -> int {
  auto *ctx = reinterpret_cast<context *>(ctx_); // NOLINT
  thespian::env_t empty_env_{};
  thespian::env_t &env_ =
      env ? *reinterpret_cast<thespian::env_t *>(env) : empty_env_; // NOLINT

  auto ret = ctx->spawn_link(
      [b, s]() -> thespian::result {
        auto *ret = b(s);
        if (ret) {
          auto err = cbor::buffer();
          const uint8_t *data = ret->base;                      // NOLINT
          std::copy(data, data + ret->len, back_inserter(err)); // NOLINT
          return thespian::to_error(err);
        }
        return thespian::ok();
      },
      [eh, es](auto e) {
        if (eh)
          eh(es, e.data(), e.size());
      },
      string_view(name), std::move(env_));
  if (!ret)
    return -1;
  *handle = reinterpret_cast<thespian_handle>( // NOLINT
      new thespian::handle{ret.value()});
  return 0;
}
}
