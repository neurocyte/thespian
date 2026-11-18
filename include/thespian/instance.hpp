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
auto observe_links() -> bool;
auto observe_links(bool) -> bool;
auto link(const handle &) -> void;

// Receive the messages sent to and by the actor with instance id, and its
// exit, as messages to the calling actor:
//   ["debug_tap_id", id, "recv", from_id, from_name, msg]
//   ["debug_tap_id", id, "send", to_id, to_name, msg]
//   ["debug_tap_id", id, "exit", 0, "", msg]
// A tap ends when the calling actor exits or calls untap_instance.
auto tap_instance(uintptr_t id) -> void;
// Stop tapping id, or all taps of the calling actor with an id of 0.
// Returns false if there was no such tap.
auto untap_instance(uintptr_t id) -> bool;

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
