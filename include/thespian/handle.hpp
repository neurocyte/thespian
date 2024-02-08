#pragma once

#include <cbor/cbor.hpp>

#include "expected.hpp"
#include <memory>
#include <utility>

namespace thespian {

template <typename T, typename E>
using expected = std::experimental::expected<T, E>;
using error = cbor::buffer;

using result = expected<void, error>;
using to_error = std::experimental::unexpected<error>;

[[nodiscard]] inline auto ok() -> result { return result{}; }
template <typename T> [[nodiscard]] auto ok(T v) { return result{v}; }
template <typename T> [[nodiscard]] auto to_result(T ret) -> result {
  if (ret)
    return ok();
  return to_error(ret.error());
}

struct instance;
using ref = std::weak_ptr<instance>;

struct handle {
  [[nodiscard]] auto send_raw(cbor::buffer) const -> result;
  template <typename... Ts> [[nodiscard]] auto send(Ts &&...parms) const {
    return send_raw(cbor::array(std::forward<Ts>(parms)...));
  }
  template <typename... Ts>
  auto exit(const std::string &error, Ts &&...details) const {
    return send_raw(cbor::array("exit", error, std::forward<Ts>(details)...));
  }
  [[nodiscard]] inline auto expired() const { return ref_.expired(); }

private:
  ref ref_;
  friend auto handle_ref(handle &) -> ref &;
  friend auto handle_ref(const handle &) -> const ref &;
  friend auto operator==(const handle &, const handle &) -> bool;
};

auto operator==(const handle &, const handle &) -> bool;

} // namespace thespian
