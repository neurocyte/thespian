#include "tests.hpp"

#include <thespian/instance.hpp>
#include <thespian/socket.hpp>
#include <thespian/tcp.hpp>

#include <memory>
#include <string>

#if defined(_WIN32)
#include <in6addr.h>
#include <winsock2.h>
#include <ws2ipdef.h>
#include <ws2tcpip.h>
#else
#include <netinet/in.h>
#endif

using cbor::buffer;
using cbor::extract;
using std::make_shared;
using std::make_unique;
using std::move;
using std::string;
using std::string_view;
using std::unique_ptr;
using thespian::context;
using thespian::env;
using thespian::env_t;
using thespian::exit;
using thespian::handle;
using thespian::link;
using thespian::ok;
using thespian::receive;
using thespian::result;
using thespian::self;
using thespian::spawn_link;
using thespian::trap;
using thespian::unexpected;
using thespian::tcp::acceptor;
using thespian::tcp::connector;

// Owners of sockets and acceptors may exit from inside the handler of a
// message that the socket/acceptor delivered synchronously. That destroys
// the socket/acceptor while its completion handler is still running, which
// must not touch it afterwards.

namespace {

struct listener {
  acceptor a;
  handle parent;

  explicit listener(handle parent_)
      : a{acceptor::create("listener")}, parent{move(parent_)} {
    auto port = a.listen(in6addr_loopback, 0);
    auto _ = parent.send("port", port);
  }

  auto receive(const buffer &m) -> result {
    int fd{};
    if (m("acceptor", "listener", "accept", extract(fd))) {
      auto ret = parent.send("accepted", fd);
      if (not ret)
        return ret;
      return exit("listener_done");
    }
    return unexpected(m);
  }
};

struct writer {
  connector c;
  unique_ptr<thespian::socket> s;
  string chunk = string(65536, 'x');

  explicit writer(port_t port) : c{connector::create("writer")} {
    c.connect(in6addr_loopback, port);
  }

  auto receive(const buffer &m) -> result {
    int fd{};
    int written{};
    int err{};
    string_view msg;
    if (m("connector", "writer", "connected", extract(fd))) {
      s = make_unique<thespian::socket>(thespian::socket::create("writer", fd));
      s->write(chunk);
    } else if (m("socket", "writer", "write_complete", extract(written))) {
      s->write(chunk);
    } else if (m("socket", "writer", "write_error", extract(err),
                 extract(msg))) {
      return exit("writer_done");
    } else {
      return unexpected(m);
    }
    return ok();
  }
};

template <typename T, typename... Args>
auto start(string_view name, Args... args) {
  return spawn_link(
      [=]() {
        receive([p{make_shared<T>(args...)}](const auto & /*from*/,
                                            const auto &m) {
          return p->receive(m);
        });
        return ok();
      },
      name);
}

struct controller {
  unique_ptr<thespian::socket> server_side;
  bool listener_done{false};
  bool writer_done{false};

  auto receive(const buffer &m) -> result {
    port_t port{};
    int fd{};
    if (m("port", extract(port))) {
      return to_result(start<writer>("writer", port));
    }
    if (m("accepted", extract(fd))) {
      server_side = make_unique<thespian::socket>(thespian::socket::create("server_side", fd));
      server_side->close();
    } else if (m("socket", "server_side", "closed")) {
      ;
    } else if (m("exit", "listener_done")) {
      listener_done = true;
    } else if (m("exit", "writer_done")) {
      writer_done = true;
    } else {
      return unexpected(m);
    }
    if (listener_done and writer_done)
      return exit("success");
    return ok();
  }
};

} // namespace

auto socket_owner_exit(context &ctx, bool &result, env_t env_) -> ::result {
  return to_result(ctx.spawn_link(
      []() {
        trap(true);
        link(env().proc("log"));
        auto ret = start<listener>("listener", self());
        if (not ret)
          return to_result(ret);
        receive([p{make_shared<controller>()}](const auto & /*from*/,
                                                const auto &m) {
          return p->receive(m);
        });
        return ok();
      },
      [&](auto s) {
        if (s == "success")
          result = true;
      },
      "socket_owner_exit", move(env_)));
}
