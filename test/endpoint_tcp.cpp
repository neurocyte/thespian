#include "tests.hpp"

#include "cbor/cbor.hpp"
#include "thespian/env.hpp"
#include "thespian/handle.hpp"
#include <thespian/endpoint.hpp>
#include <thespian/instance.hpp>
#include <thespian/socket.hpp>
#include <thespian/tcp.hpp>

#include <cstring>
#include <utility>

#if defined(_WIN32)
#include <in6addr.h>
#include <winsock2.h>
#include <ws2ipdef.h>
#include <ws2tcpip.h>
#endif

using cbor::any;
using cbor::buffer;
using cbor::extract;
using std::make_shared;
using std::move;
using std::string;
using std::string_view;
using std::stringstream;
using thespian::context;
using thespian::env;
using thespian::env_t;
using thespian::exit;
using thespian::handle;
using thespian::link;
using thespian::ok;
using thespian::receive;
using thespian::result;
using thespian::unexpected;
using thespian::endpoint::tcp::listen;

namespace {

struct controller {
  handle ep_listen;
  handle ep_connect;
  size_t ping_count{};
  size_t pong_count{};
  bool success_{false};

  explicit controller(handle ep_l) : ep_listen{move(ep_l)} {}

  auto receive(const handle &from, const buffer &m) {
    port_t port{0};
    if (m("port", extract(port))) {
      ep_connect =
          thespian::endpoint::tcp::connect(in6addr_loopback, port).value();
      return ok();
    }
    if (m("connected")) {
      ping_count++;
      return ep_connect.send("ping", ping_count);
    }
    if (m("ping", any)) {
      pong_count++;
      return from.send("pong", pong_count);
    }
    if (m("pong", any)) {
      if (ping_count > 10) {
        return exit(ping_count == pong_count ? "success" : "closed");
      }
      ping_count++;
      return from.send("ping", ping_count);
    }
    return unexpected(m);
  }
}; // namespace

} // namespace

auto endpoint_tcp(context &ctx, bool &result, env_t env_) -> ::result {
  return to_result(ctx.spawn_link(
      [=]() {
        link(env().proc("log"));
        handle ep_listen = listen(in6addr_loopback, 0).value();
        auto ret = ep_listen.send("get", "port");
        if (not ret)
          return ret;

        receive([p{make_shared<controller>(ep_listen)}](const auto &from,
                                                        const auto &m) {
          return p->receive(from, m);
        });
        return ok();
      },
      [&](auto s) {
        if (s == "success")
          result = true;
      },
      "endpoint_tcp", move(env_)));
}
