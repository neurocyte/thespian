#pragma once

#include "handle.hpp"
#include <functional>
#include <memory>

namespace thespian {

struct hub : private handle {
  using filter = std::function<bool(const cbor::buffer &)>;

  hub() = default;
  auto expired() -> bool { return handle::expired(); }

  template <typename... Ts> auto broadcast(Ts &&...parms) const {
    return send("broadcast", cbor::array(std::forward<Ts>(parms)...));
  }
  [[nodiscard]] auto subscribe() const -> result;
  [[nodiscard]] auto subscribe(filter) const -> result;
  [[nodiscard]] auto listen(std::string_view unix_socket_descriptor) const
      -> result;
  [[nodiscard]] auto shutdown() const { return send("shutdown"); }

  [[nodiscard]] static auto create(std::string_view name)
      -> expected<hub, error>;

  struct pipe {
    pipe();
    pipe(const pipe &) = delete;
    pipe(pipe &&) = delete;
    auto operator=(const pipe &) -> pipe & = delete;
    auto operator=(pipe &&) -> pipe & = delete;
    virtual ~pipe();
  };

private:
  hub(const handle &, std::shared_ptr<pipe>);
  std::shared_ptr<pipe> pipe_;
  friend auto operator==(const handle &, const hub &) -> bool;
  friend auto operator==(const hub &, const handle &) -> bool;
};

auto operator==(const handle &, const hub &) -> bool;
auto operator==(const hub &, const handle &) -> bool;

} // namespace thespian
