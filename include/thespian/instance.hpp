#pragma once

#include "context.hpp"
#include "env.hpp"
#include "handle.hpp"
#include "trace.hpp"

#include <functional>
#include <map>
#include <string>
#include <string_view>

namespace thespian {

using receiver = std::function<result(handle from, cbor::buffer)>;
using sync_receiver = std::function<cbor::buffer(handle from, cbor::buffer)>;

[[nodiscard]] auto send_raw(cbor::buffer) -> result;
template <typename... Ts> [[nodiscard]] auto send(Ts &&...parms) -> result {
  return send_raw(cbor::array(std::forward<Ts>(parms)...));
}
auto receive(receiver) -> void;
auto receive_sync(sync_receiver) -> void;

auto trap() -> bool;
auto trap(bool) -> bool;
auto link(const handle &) -> void;

auto self() -> handle;
auto self_ref() -> handle&;

[[nodiscard]] auto spawn(behaviour, std::string_view name)
    -> expected<handle, error>;
[[nodiscard]] auto spawn_link(behaviour, std::string_view name)
    -> expected<handle, error>;

[[nodiscard]] auto spawn(behaviour, std::string_view name, env_t)
    -> expected<handle, error>;
[[nodiscard]] auto spawn_link(behaviour, std::string_view name, env_t)
    -> expected<handle, error>;

[[nodiscard]] auto ok() -> result;
[[nodiscard]] auto exit() -> result;
[[nodiscard]] auto exit(std::string_view e) -> result;
[[nodiscard]] auto exit(std::string_view e, std::string_view m) -> result;
[[nodiscard]] auto exit(std::string_view e, int err) -> result;
[[nodiscard]] auto exit(std::string_view e, size_t n) -> result;

[[nodiscard]] auto unexpected(const cbor::buffer & /*b*/) -> result;

} // namespace thespian
