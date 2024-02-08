#pragma once

#include <memory>
#include <string_view>
#include <vector>

namespace thespian {

struct socket_impl;
using socket_dtor = void (*)(socket_impl *);
using socket_ref = std::unique_ptr<socket_impl, socket_dtor>;

struct socket {
  static auto create(std::string_view tag, int fd) -> socket;
  auto write(std::string_view) -> void;
  auto write(const std::vector<uint8_t> &) -> void;
  auto read() -> void;
  auto close() -> void;

  //->("socket", tag, "write_complete", int written)
  //->("socket", tag, "write_error", int err, string message)
  //->("socket", tag, "read_complete", string buf)
  //->("socket", tag, "read_error", int err, string message)
  //->("socket", tag, "closed")

  socket_ref ref;
};

} // namespace thespian
