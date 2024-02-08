#pragma once

#include <cbor/cbor.hpp>

#include <chrono>
#include <functional>
#include <memory>

namespace thespian {

struct timeout_impl;
using timeout_dtor = void (*)(timeout_impl *);
using timeout_ref = std::unique_ptr<timeout_impl, timeout_dtor>;

struct timeout {
  auto cancel() -> void;

  timeout_ref ref;
};

[[nodiscard]] auto create_timeout(std::chrono::microseconds us, cbor::buffer m)
    -> timeout;

[[nodiscard]] auto never() -> timeout;
void cancel_timeout(timeout_impl *);
void destroy_timeout(timeout_impl *);

} // namespace thespian
