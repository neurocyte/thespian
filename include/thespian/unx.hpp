#pragma once

#include <memory>
#include <string_view>

namespace thespian::unx {

enum class mode : uint8_t { file, abstract };

struct acceptor_impl;
using acceptor_dtor = void (*)(acceptor_impl *);
using acceptor_ref = std::unique_ptr<acceptor_impl, acceptor_dtor>;

struct acceptor {
  static auto create(std::string_view tag) -> acceptor;
  auto listen(std::string_view, mode) -> void;
  auto close() -> void;

  //->("acceptor", tag, "accept", int fd)
  //->("acceptor", tag, "error", int err, string message)
  //->("acceptor",tag, "closed")

  acceptor_ref ref;
};

// C++ helpers used by the C binding layer
void acceptor_listen(acceptor_impl *h, std::string_view path, mode m);
void acceptor_close(acceptor_impl *h);
void destroy_acceptor(acceptor_impl *h);

struct connector_impl;
using connector_dtor = void (*)(connector_impl *);
using connector_ref = std::unique_ptr<connector_impl, connector_dtor>;

struct connector {
  static auto create(std::string_view tag) -> connector;
  auto connect(std::string_view, mode) -> void;
  auto cancel() -> void;

  //->("connector", tag, "connected", int fd)
  //->("connector", tag, "error", int err, string message)
  //->("connector", tag, "cancelled")

  connector_ref ref;
};

// C++ helpers for C API
void connector_connect(connector_impl *h, std::string_view path, mode m);
void connector_cancel(connector_impl *h);
void destroy_connector(connector_impl *h);

} // namespace thespian::unx
