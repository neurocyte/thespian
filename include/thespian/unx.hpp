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

} // namespace thespian::unx
