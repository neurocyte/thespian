#include "cbor/c/cbor.h"
#include "thespian/c/handle.h"
#include <thespian/c/instance.h>
#include <thespian/instance.hpp>

using std::string_view;

extern "C" {

void thespian_receive(thespian_receiver r, thespian_behaviour_state s) {
  thespian::receive([r, s](auto from, cbor::buffer msg) -> thespian::result {
    thespian_handle from_handle = reinterpret_cast<thespian_handle>( // NOLINT
        &from);
    auto *ret = r(s, from_handle, {msg.data(), msg.size()});
    if (ret) {
      auto err = cbor::buffer();
      const uint8_t *data = ret->base;
      std::copy(data, data + ret->len, back_inserter(err)); // NOLINT
      return thespian::to_error(err);
    }
    return thespian::ok();
  });
}

auto thespian_get_trap() -> bool { return thespian::trap(); }
auto thespian_set_trap(bool on) -> bool { return thespian::trap(on); }

void thespian_link(thespian_handle h) {
  thespian::handle *h_{
      reinterpret_cast<thespian::handle *>( // NOLINT(*-reinterpret-cast)
          h)};
  thespian::link(*h_);
}

auto thespian_self() -> thespian_handle {
  auto &self = thespian::self_ref();
  return reinterpret_cast<thespian_handle>(&self); // NOLINT(*-reinterpret-cast)
}

auto thespian_spawn_link(thespian_behaviour b, thespian_behaviour_state s,
                         const char *name, thespian_env env,
                         thespian_handle *handle) -> int {
  thespian::env_t empty_env_{};
  thespian::env_t env_ =
      env ? *reinterpret_cast<thespian::env_t *>(env) : empty_env_; // NOLINT

  auto ret = spawn_link(
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
      string_view(name), std::move(env_));
  if (!ret)
    return -1;
  *handle = reinterpret_cast<thespian_handle>( // NOLINT
      new thespian::handle{ret.value()});
  return 0;
}
}
