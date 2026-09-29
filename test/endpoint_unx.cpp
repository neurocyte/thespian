#include "tests.hpp"

#include <thespian/endpoint.hpp>
#include <thespian/instance.hpp>
#include <thespian/socket.hpp>
#include <thespian/timeout.hpp>
#include <thespian/unx.hpp>

#include <cstring>
#include <filesystem>
#include <sstream>
#include <utility>

#if !defined(_WIN32)
#include <unistd.h>
#else
#include <process.h>
#include <windows.h>
#endif

using cbor::array;
using cbor::buffer;
using cbor::extract;
using std::make_shared;
using std::move;
using std::string;
using std::string_view;
using std::stringstream;
using thespian::context;
using thespian::create_timeout;
using thespian::env;
using thespian::env_t;
using thespian::exit;
using thespian::handle;
using thespian::link;
using thespian::ok;
using thespian::receive;
using thespian::result;
using thespian::timeout;
using thespian::unexpected;
using thespian::endpoint::unx::connect;
using thespian::endpoint::unx::listen;
using thespian::unx::mode;

using namespace std::chrono_literals;

namespace {

// Linux supports abstract Unix sockets (null-byte prefix, no filesystem entry).
// Linux, FreeBSD, macOS and Windows support file-based Unix sockets.
#if defined(__linux__)
constexpr auto unx_socket_mode = mode::abstract;
#else
constexpr auto unx_socket_mode = mode::file;
#endif

// std::filesystem cannot stat or remove AF_UNIX socket files on windows
#if !defined(_WIN32)
auto socket_path() -> string {
  stringstream ss;
  ss << "/tmp/thespian_endpoint_t_" << getpid();
  return ss.str();
}
void remove_socket_file(const string &path) { ::unlink(path.c_str()); }
#else
auto socket_path() -> string {
  return (std::filesystem::temp_directory_path() /
          ("thespian_endpoint_t_" + std::to_string(::_getpid())))
      .string();
}
void remove_socket_file(const string &path) { ::DeleteFileA(path.c_str()); }
#endif

struct controller {
  handle ep_listen;
  handle ep_connect;
  size_t ping_count{};
  size_t pong_count{};
  bool success_{false};
  timeout t{create_timeout(100ms, array("connect"))};

  explicit controller(handle ep_l) : ep_listen{move(ep_l)} {}

  auto receive(const handle &from, const buffer &m) {
    string_view path;
    if (m("connect")) {
      auto ret = ep_listen.send("get", "path");
      if (not ret)
        return ret;
      return ok();
    }
    if (m("path", extract(path))) {
      ep_connect = connect(path, unx_socket_mode).value();
      return ok();
    }
    if (m("connected")) {
      ping_count++;
      return ep_connect.send("ping");
    }
    if (m("ping")) {
      pong_count++;
      return from.send("pong");
    }
    if (m("pong")) {
      if (ping_count > 10) {
        return exit(ping_count == pong_count ? "success" : "closed");
      }
      ping_count++;
      return ep_connect.send("ping");
    }
    return unexpected(m);
  }
}; // namespace

} // namespace

auto endpoint_unx(context &ctx, bool &result, env_t env_) -> ::result {
  const string path = socket_path();
  if (unx_socket_mode == mode::file)
    remove_socket_file(path);
  return to_result(ctx.spawn_link(
      [path]() {
        link(env().proc("log"));
        handle ep_listen = listen(path, unx_socket_mode).value();
        receive([p{make_shared<controller>(ep_listen)}](const auto &from,
                                                        const auto &m) {
          return p->receive(from, m);
        });
        return ok();
      },
      [&result, path](auto s) {
        if (unx_socket_mode == mode::file)
          remove_socket_file(path);
        if (s == "success")
          result = true;
      },
      "endpoint_unx", move(env_)));
}
