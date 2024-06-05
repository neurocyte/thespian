#pragma once

#include <memory>
#include <string_view>
#include <vector>

#if !defined(_WIN32)
#include <netinet/in.h>
#else
#include <in6addr.h>
#endif

using port_t = unsigned short;

namespace thespian::tcp {

struct acceptor_impl;
using acceptor_dtor = void (*)(acceptor_impl *);
using acceptor_ref = std::unique_ptr<acceptor_impl, acceptor_dtor>;

struct acceptor {
  static auto create(std::string_view tag) -> acceptor;
  auto listen(in6_addr ip, port_t port) -> port_t;
  auto close() -> void;

  //->("acceptor", tag, "accept", int fd, in6_addr ip, port_t port)
  //->("acceptor", tag, "error", int err, string message)
  //->("acceptor", tag, "closed")

  acceptor_ref ref;
};

struct connector_impl;
using connector_dtor = void (*)(connector_impl *);
using connector_ref = std::unique_ptr<connector_impl, connector_dtor>;

struct connector {
  static auto create(std::string_view tag) -> connector;
  auto connect(in6_addr ip, port_t port) -> void;
  auto connect(in6_addr ip, port_t port, in6_addr lip) -> void;
  auto connect(in6_addr ip, port_t port, port_t lport) -> void;
  auto connect(in6_addr ip, port_t port, in6_addr lip, port_t lport) -> void;
  auto cancel() -> void;

  //->("connector", tag, "connected", int fd)
  //->("connector", tag, "error", int err, string message)
  //->("connector", tag, "cancelled")

  connector_ref ref;
};

} // namespace thespian::tcp
