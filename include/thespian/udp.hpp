#pragma once

#include <cbor/cbor_in.hpp>

#include <cstddef>
#include <functional>
#include <memory>

using port_t = unsigned short;

namespace thespian {

struct udp_impl;
using udp_dtor = void (*)(udp_impl *);
using udp_ref = std::unique_ptr<udp_impl, udp_dtor>;

struct udp {
  static auto create(std::string tag) -> udp;

  auto open(const in6_addr &, port_t port) -> port_t;
  [[nodiscard]] auto sendto(std::string_view, in6_addr ip, port_t port)
      -> size_t;
  auto close() -> void;

  //->("udp", tag, "open_error", int err, string message);
  //->("udp", tag, "read_error", int err, string message);
  //->("udp", tag, "receive", string data, in6_addr remote_ip, int port);
  //->("udp", tag, "closed");

  udp_ref ref;
};

} // namespace thespian
