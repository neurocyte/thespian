#include "tests.hpp"

#include "thespian/env.hpp"
#include "thespian/handle.hpp"
#include <thespian/instance.hpp>
#include <thespian/timeout.hpp>
#include <thespian/udp.hpp>

#if !defined(_WIN32)
#include <netinet/in.h>
#else
#include <winsock2.h>
#include <in6addr.h>
#include <ws2ipdef.h>
#include <ws2tcpip.h>
#endif

using cbor::array;
using cbor::buffer;
using cbor::extract;
using cbor::more;
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
using thespian::link;
using thespian::ok;
using thespian::receive;
using thespian::result;
using thespian::udp;
using thespian::unexpected;

using namespace std::chrono_literals;

namespace {

struct controller {
  port_t server_port{0};
  port_t client_port{0};
  udp client;
  udp server;
  size_t ping_count{};
  size_t pong_count{};
  bool success_{false};
  thespian::timeout server_receive_timeout{
      create_timeout(500s, array("udp", "server", "timeout"))};

  explicit controller()
      : client{udp::create("client")}, server{udp::create("server")} {
    server_port = server.open(in6addr_loopback, server_port);
    client.open(in6addr_loopback, client_port);
    auto sent = client.sendto("ping", in6addr_loopback, server_port);
    if (sent != 4)
      abort();
  }
  controller(controller &&) = delete;
  controller(const controller &) = delete;

  ~controller() { server_receive_timeout.cancel(); }

  auto operator=(controller &&) -> controller & = delete;
  auto operator=(const controller &) -> controller & = delete;

  auto client_receive(const buffer &m) {
    in6_addr remote_ip{};
    port_t remote_port{};
    if (m("udp", "client", "receive", "pong", extract(remote_ip),
          extract(remote_port))) {
      check(remote_port == server_port);
      client.close();
    } else if (m("udp", "client", "closed")) {
      return exit("success");
    } else {
      return unexpected(m);
    }
    return ok();
  }

  auto server_receive(const buffer &m) {
    in6_addr remote_ip{};
    port_t remote_port{};
    if (m("udp", "server", "receive", "ping", extract(remote_ip),
          extract(remote_port))) {
      auto sent = server.sendto("pong", remote_ip, remote_port);
      if (sent != 4)
        return exit("unexpected_sendto_size", sent);
      server.close();
    } else if (m("udp", "server", "timeout")) {
      return exit("timeout");
    } else if (m("udp", "server", "closed")) {
      ;
    } else {
      return unexpected(m);
    }
    return ok();
  }

  auto receive(const buffer &m) {
    if (m("udp", "client", more))
      return client_receive(m);
    if (m("udp", "server", more))
      return server_receive(m);
    return unexpected(m);
  }
};

} // namespace

auto ip_udp_echo(context &ctx, bool &result, env_t env_) -> ::result {
  return to_result(ctx.spawn_link(
      [=]() {
        link(env().proc("log"));
        receive([p{make_shared<controller>()}](auto /*from*/, auto m) {
          return p->receive(move(m));
        });
        return ok();
      },
      [&](auto s) {
        if (s == "success")
          result = true;
      },
      "ip_udp_echo", move(env_)));
}
