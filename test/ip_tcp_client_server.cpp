#include "tests.hpp"

#include "thespian/handle.hpp"
#include <cbor/cbor_in.hpp>
#include <thespian/debug.hpp>
#include <thespian/instance.hpp>
#include <thespian/socket.hpp>
#include <thespian/tcp.hpp>

#if !defined(_WIN32)
#include <netinet/in.h>
#else
#include <winsock2.h>
#include <in6addr.h>
#include <ws2ipdef.h>
#include <ws2tcpip.h>
#endif

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
using thespian::result;
using thespian::self;
using thespian::socket;
using thespian::spawn_link;
using thespian::unexpected;
using thespian::tcp::acceptor;
using thespian::tcp::connector;

namespace {

struct client_connection {
  thespian::socket socket;
  handle connector;

  explicit client_connection(int fd, handle connector)
      : socket{socket::create("client_connection", fd)},
        connector(move(connector)) {
    socket.read();
  }

  auto receive(const buffer &m) {
    int written{};
    int err{};
    string_view buf{};

    if (m("socket", "client_connection", "read_complete", extract(buf))) {
      check(buf == "ping");
      check(err == 0);
      socket.write("pong");
    } else if (m("socket", "client_connection", "write_complete",
                 extract(written))) {
      check(written == 4);
      check(err == 0);
      // socket.close(); // let server close
    } else if (m("socket", "client_connection", "closed")) {
      auto ret = connector.send("client_connection", "done");
      if (not ret)
        return ret;
      return exit("success");
    } else {
      return unexpected(m);
    }
    return ok();
  }

  [[nodiscard]] static auto init(int fd, const handle &connector) {
    return spawn_link(
        [fd, connector]() {
          ::thespian::receive(
              [p{make_shared<client_connection>(fd, connector)}](
                  auto /*from*/, auto m) { return p->receive(move(m)); });
          return ok();
        },
        "client_connection");
  }
};

struct client {
  connector connector;
  handle server;
  port_t server_port;

  explicit client(handle server, port_t server_port)
      : connector{connector::create("client")}, server(move(server)),
        server_port(server_port) {
    connector.connect(in6addr_loopback, server_port);
  }

  auto receive(const buffer &m) -> thespian::result {
    int fd{};
    if (m("connector", "client", "connected", extract(fd))) {
      return to_result(client_connection::init(fd, self()));
    }
    if (m("connector_connection", "done")) {
      return server.send("client", "done");
    }
    return unexpected(m);
  }

  static auto init(handle server, port_t server_port) -> result {
    ::thespian::receive(
        [p{make_shared<client>(server, server_port)}](auto /*from*/, auto m) {
          return p->receive(move(m));
        });
    return ok();
  }
};

struct server_connection {
  thespian::socket socket;
  handle server;

  explicit server_connection(int fd, handle server)
      : socket{socket::create("server_connection", fd)}, server(move(server)) {
    socket.write("ping");
  }

  auto receive(const buffer &m) {
    int written{};
    int err{};
    string_view buf{};

    if (m("socket", "server_connection", "write_complete", extract(written))) {
      check(written == 4);
      check(err == 0);
      socket.read();
    } else if (m("socket", "server_connection", "read_complete",
                 extract(buf))) {
      check(buf == "pong");
      check(err == 0);
      socket.close();
    } else if (m("socket", "server_connection", "closed")) {
      auto ret = server.send("server_connection", "done");
      if (not ret)
        return ret;
      return exit("success");
    } else {
      return unexpected(m);
    }
    return ok();
  }

  [[nodiscard]] static auto init(int fd, const handle &server) {
    return spawn_link(
        [fd, server]() {
          ::thespian::receive(
              [p{make_shared<server_connection>(fd, server)}](
                  auto /*from*/, auto m) { return p->receive(move(m)); });
          return ok();
        },
        "server_connection");
  }
};

struct server {
  acceptor acceptor;
  bool client_done{false};
  bool server_connection_done{false};
  bool acceptor_closed{false};
  port_t server_port;

  explicit server()
      : acceptor{acceptor::create("server")},
        server_port(acceptor.listen(in6addr_loopback, 0)) {}

  auto receive(const buffer &m) {
    int fd{};
    if (m("acceptor", "server", "accept", extract(fd))) {
      auto ret = server_connection::init(fd, self());
      if (not ret)
        return to_result(ret);
      acceptor.close();
    } else if (m("acceptor", "server", "closed")) {
      acceptor_closed = true;
    } else if (m("client", "done")) {
      client_done = true;
    } else if (m("server_connection", "done")) {
      server_connection_done = true;
    } else {
      return unexpected(m);
    }
    if (acceptor_closed and client_done and server_connection_done)
      return exit("success");
    return ok();
  }

  [[nodiscard]] static auto init() {
    link(env().proc("log"));
    auto log = env().proc("log");
    auto _ = log.send("server starting");
    auto p{make_shared<server>()};
    _ = log.send("server listening on port", p->server_port);
    auto ret = spawn_link(
        [server{self()}, server_port{p->server_port}]() {
          return client::init(server, server_port);
        },
        "ip_tcp_client");
    if (not ret)
      return to_result(ret);
    thespian::receive(
        [p](auto /*from*/, auto m) { return p->receive(move(m)); });
    return ok();
  }
};

} // namespace

auto ip_tcp_client_server(context &ctx, bool &result, env_t env) -> ::result {
  thespian::debug::enable(ctx);
  return to_result(ctx.spawn_link(
      server::init,
      [&](auto s) {
        if (s == "success") {
          result = true;
        } else {
          auto _ = env.proc("log").send("failed:", s);
        }
      },
      "ip_tcp_client_server", move(env)));
}
