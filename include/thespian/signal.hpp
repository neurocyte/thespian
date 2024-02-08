#pragma once

#include <cbor/cbor.hpp>

#include <chrono>
#include <functional>
#include <memory>

namespace thespian {

struct signal_impl;
using signal_dtor = void (*)(signal_impl *);
using signal_ref = std::unique_ptr<signal_impl, signal_dtor>;

struct signal {
  auto cancel() -> void;

  signal_ref ref;
};

[[nodiscard]] auto create_signal(int signum, cbor::buffer m) -> signal;
void cancel_signal(signal_impl *);
void destroy_signal(signal_impl *);

} // namespace thespian
