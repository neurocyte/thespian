#include "tests.hpp"

#include <thespian/debug.hpp>
#include <thespian/instance.hpp>
#include <thespian/socket.hpp>
#include <thespian/tcp.hpp>

#include <cstdio>
#include <cstring>
#include <memory>
#include <vector>

#if defined(_WIN32)
#include <in6addr.h>
#include <winsock2.h>
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
using std::unique_ptr;
using std::vector;
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
using thespian::socket;
using thespian::spawn_link;
using thespian::trap;
using thespian::unexpected;
using thespian::tcp::connector;

namespace {

constexpr unsigned short port{4243};

struct debuggee {
  auto receive(const handle &from, const buffer &m) -> result {
    if (m("ping"))
      return from.send("pong");
    if (m("ignore"))
      return ok();
    if (m("shutdown"))
      return exit("debuggee_shutdown");
    return unexpected(m);
  }

  static auto start() -> expected<handle, error> {
    return spawn_link(
        [=]() {
          ::receive(
              [p{make_shared<debuggee>()}](const auto &from, const auto &m) {
                return p->receive(from, m);
              });
          return ok();
        },
        "debuggee");
  }
};

// Each step sends a command line and waits for the matching response line.
struct step {
  string command;
  string response;
  bool prefix_match{false};
};

const vector<step> steps{
    {R"({"id":1,"cmd":"list"})", R"({"id":1,"ok":true,"result":[)", true},
    {R"({"id":"two","cmd":"tap","name":"debuggee"})",
     R"({"id":"two","ok":true})"},
    {R"({"id":3,"cmd":"call","to":"debuggee","msg":["ping"]})",
     R"({"id":3,"ok":true,"from":"debuggee","result":["pong"]})"},
    {R"({"id":4,"cmd":"call","to":"debuggee","msg":["ignore"],"timeout_ms":50})",
     R"({"id":4,"ok":false,"error":"timeout"})"},
    {R"({"id":5,"cmd":"send","to":"nobody","msg":[]})",
     R"({"id":5,"ok":false,"error":"nobody not found"})"},
    {R"({"id":6,"cmd":"tap","name":"debug_tcp_connection"})",
     R"({"id":6,"ok":false,"error":"cannot tap debug interface actors"})"},
    {R"({"id":7,"cmd":"frobnicate"})",
     R"({"id":7,"ok":false,"error":"unknown cmd: frobnicate"})"},
    {"garbage", R"({"id":null,"ok":false,"error":"expected a JSON object"})"},
    {"{\"id\":8,\"cmd\":\"send\",\"to\":\"debuggee\",\"msg\":[\"shutdown\"]}\r",
     R"({"id":8,"ok":true})"},
    {R"({"id":9,"cmd":"bye"})", R"({"id":9,"ok":true})"},
};

struct controller {
  static constexpr string_view tag{"debug_json_test_controller"};
  handle debug_tcp_;
  handle debuggee_;
  connector c;
  unique_ptr<thespian::socket> s;
  string prev_buf;
  size_t step_{0};
  bool step_done_{false};
  bool tap_recv_{false};
  bool tap_send_{false};
  bool tap_exit_{false};

  controller(handle debug_tcp, handle debuggee)
      : debug_tcp_{move(debug_tcp)}, debuggee_{move(debuggee)},
        c{connector::create(tag)} {
    trap(true);
  }

  void send_step() {
    s->write(steps[step_].command);
    s->write("\n");
  }

  // the shutdown step also waits for the debuggee's exit tap event
  auto may_advance() -> bool {
    return step_done_ and (step_ != 8 or tap_exit_);
  }

  auto on_line(const string &line) -> result {
    if (line.starts_with(R"({"event":"tap","actor":"debuggee")")) {
      if (line.find(R"("dir":"recv","peer":"debug_call","msg":["ping"])") !=
          string::npos)
        tap_recv_ = true;
      if (line.find(R"("dir":"send","peer":"debug_call","msg":["pong"])") !=
          string::npos)
        tap_send_ = true;
      if (line.find(R"("dir":"exit","msg":["exit","debuggee_shutdown"])") !=
          string::npos)
        tap_exit_ = true;
    } else if (step_ < steps.size()) {
      const auto &st = steps[step_];
      const bool match = st.prefix_match ? line.starts_with(st.response)
                                         : line == st.response;
      if (not match)
        return exit("unexpected_line: " + line);
      if (step_ == 0 and line.find(R"("debuggee")") == string::npos)
        return exit("debuggee_not_listed", line);
      step_done_ = true;
    } else {
      return exit("unexpected_line: " + line);
    }
    if (may_advance()) {
      step_done_ = false;
      if (++step_ < steps.size())
        send_step();
    }
    return ok();
  }

  auto receive(const handle & /*from*/, const buffer &m) -> result {
    int fd{};
    string buf;
    int written{};
    int err{};
    string_view err_msg{};

    if (m("pong")) {
      // the console acceptor is listening once it answers
      c.connect(in6addr_loopback, port);
    } else if (m("connector", tag, "connected", extract(fd))) {
      s = make_unique<thespian::socket>(socket::create(tag, fd));
      s->read();
      send_step();
    } else if (m("socket", tag, "read_complete", extract(buf))) {
      if (buf.empty()) {
        s->close();
        return ok();
      }
      s->read();
      prev_buf.append(buf);
      string::size_type pos{};
      while ((pos = prev_buf.find('\n')) != string::npos) {
        auto ret = on_line(prev_buf.substr(0, pos));
        if (not ret)
          return ret;
        prev_buf.erase(0, pos + 1);
      }
    } else if (m("socket", tag, "write_complete", extract(written))) {
      ;
    } else if (m("socket", tag, "closed")) {
      if (step_ != steps.size())
        return exit("closed_early at step " + std::to_string(step_));
      if (not(tap_recv_ and tap_send_ and tap_exit_))
        return exit("missing_tap_events");
      return exit("success");
    } else if (m("socket", tag, "read_error", extract(err),
                 extract(err_msg))) {
      return exit("read_error", err_msg);
    } else if (m("socket", tag, "write_error", extract(err),
                 extract(err_msg))) {
      return exit("write_error", err_msg);
    } else if (m("exit", "debuggee_shutdown")) {
      ;
    } else if (m("connector", tag, "error", extract(buf))) {
      return exit("connect_error", buf);
    } else {
      return unexpected(m);
    }
    return ok();
  }
};

} // namespace

auto debug_json(context &ctx, bool &result, env_t env_) -> ::result {
  thespian::debug::enable(ctx);
  return to_result(ctx.spawn_link(
      [&ctx]() {
        link(env().proc("log"));
        auto ret = thespian::debug::tcp::create(ctx, port, "");
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
        ret = debuggee::start();
        if (not ret)
          return to_result(ret);
        auto p = make_shared<controller>(debug_tcp, ret.value());
        auto ret2 = debug_tcp.send("ping");
        if (not ret2)
          return ret2;
        receive([p](const auto &from, const auto &m) {
          return p->receive(from, m);
        });
        return ok();
      },
      [&](auto s) {
        if (s == "success")
          result = true;
        else
          fprintf(stderr, "debug_json: %.*s\n", static_cast<int>(s.size()),
                  s.data());
      },
      "debug_json", move(env_)));
}
