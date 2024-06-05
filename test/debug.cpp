#include "tests.hpp"

#include "thespian/handle.hpp"
#include <thespian/debug.hpp>
#include <thespian/instance.hpp>
#include <thespian/socket.hpp>
#include <thespian/tcp.hpp>
#include <thespian/trace.hpp>

#include <cstring>
#include <memory>

#if defined(_WIN32)
#include <winsock2.h>
#include <in6addr.h>
#include <ws2ipdef.h>
#include <ws2tcpip.h>
#endif

using cbor::buffer;
using cbor::extract;
using std::make_shared;
using std::make_unique;
using std::move;
using std::string;
using std::string_view;
using std::stringstream;
using std::unique_ptr;
using thespian::context;
using thespian::env;
using thespian::env_t;
using thespian::error;
using thespian::exit;
using thespian::expected;
using thespian::handle;
using thespian::link;
using thespian::ok;
using thespian::receive;
using thespian::result;
using thespian::self;
using thespian::socket;
using thespian::spawn_link;
using thespian::trap;
using thespian::unexpected;
using thespian::tcp::connector;

namespace {

struct debuggee {
  auto receive(const handle &from, const buffer &m) {
    if (m("ping")) {
      return from.send("pong");
    }
    if (m("shutdown"))
      return exit("debuggee_shutdown");
    return unexpected(m);
    return ok();
  }

  static auto start() -> expected<handle, error> {
    return spawn_link(
        [=]() {
          ::receive([p{make_shared<debuggee>()}](auto from, auto m) {
            return p->receive(move(from), move(m));
          });
          return ok();
        },
        "debuggee");
  }
};

struct controller {
  static constexpr string_view tag{"debug_test_controller"};
  handle debug_tcp;
  handle debuggee_;
  connector c;
  unique_ptr<thespian::socket> s;
  size_t pong_count{};
  bool success_{false};
  string prev_buf;

  explicit controller(handle d, handle debuggee)
      : debug_tcp{std::move(d)}, debuggee_{std::move(debuggee)},
        c{connector::create(tag)} {
    trap(true);
  }

  auto receive(const handle & /*from*/, const buffer &m) {
    int fd{};
    string buf;
    int written{};
    int err{};
    string_view err_msg{};

    if (m("pong")) {
      pong_count++;
      if (pong_count == 2)
        c.connect(in6addr_loopback, 4242);
    } else if (m("connector", tag, "connected", extract(fd))) {
      s = make_unique<thespian::socket>(socket::create(tag, fd));
      s->read();
      s->write("\n");
      s->write("debuggee [\"ping\"]\n");
    } else if (m("socket", tag, "read_error", extract(err), extract(err_msg))) {
      return exit("read_error", err_msg);
    } else if (m("socket", tag, "read_complete", extract(buf))) {
      if (buf.empty()) {
        s->close();
        return ok();
      }
      s->read();
      buf.swap(prev_buf);
      buf.append(prev_buf);
      string::size_type pos{};
      while (not buf.empty() and pos != string::npos) {
        pos = buf.find_first_of('\n');
        if (pos != string::npos) {
          auto ret = self().send("dispatch", string(buf.data(), pos));
          if (not ret)
            return ret;
          buf.erase(0, pos + 1);
        }
      }
      prev_buf = buf;
    } else if (m("dispatch", extract(buf))) {
      if (buf == "debuggee [\"pong\"]") {
        s->write("debuggee [\"shutdown\"]\n");
      }
    } else if (m("socket", tag, "write_error", extract(err),
                 extract(err_msg))) {
      return exit("write_error", err_msg);
    } else if (m("socket", tag, "write_complete", extract(written))) {
      ;
    } else if (m("socket", tag, "closed")) {
      if (success_)
        return exit("success");
      auto ret = debuggee_.send("shutdown");
      if (not ret)
        return ret;
      return exit("closed");
    } else if (m("exit", "debuggee_shutdown")) {
      success_ = true;
      s->close();
    } else if (m("connector", tag, "cancelled"))
      return exit("cancelled");
    else if (m("connector", tag, "error", extract(buf)))
      return exit("connect_error", buf);

    else
      return unexpected(m);
    return ok();
  }
};

} // namespace

auto debug(context &ctx, bool &result, env_t env_) -> ::result {
  thespian::debug::enable(ctx);
  return to_result(ctx.spawn_link(
      [&ctx]() {
        link(env().proc("log"));
        auto ret = thespian::debug::tcp::create(ctx, 4242, "");
        if (not ret)
          return to_result(ret);
        auto debug_tcp = ret.value();
        ret = spawn_link(
            [&ctx, debug_tcp]() {
              trap(true);
              ::receive([&ctx, debug_tcp](auto, auto /*m*/) -> ::result {
                auto ret = debug_tcp.send("shutdown");
                if (not ret)
                  return ret;
                thespian::debug::disable(ctx);
                return exit();
              });
              return ok();
            },
            "controller_guard");
        if (not ret)
          return to_result(ret);
        auto ret2 = debug_tcp.send("ping");
        if (not ret2)
          return ret2;
        ret = debuggee::start();
        if (not ret)
          return to_result(ret);
        auto debuggee = ret.value();
        ret2 = debuggee.send("ping");
        if (not ret2)
          return ret2;
        receive([p{make_shared<controller>(debug_tcp, debuggee)}](auto from,
                                                                  auto m) {
          return p->receive(move(from), move(m));
        });
        return ok();
      },
      [&](auto s) {
        if (s == "success")
          result = true;
      },
      "debug", move(env_)));
}
