#include "tests.hpp"

#include <thespian/endpoint.hpp>
#include <thespian/instance.hpp>
#include <thespian/socket.hpp>
#include <thespian/timeout.hpp>
#include <thespian/unx.hpp>

#include <cstring>
#include <map>
#include <sstream>
#include <unistd.h>
#include <utility>

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
      ep_connect = connect(path).value();
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
  stringstream ss;
  ss << "/net/vdbonline/thespian/endpoint_t_" << getpid();
  string path = ss.str();
  return to_result(ctx.spawn_link(
      [path]() {
        link(env().proc("log"));
        handle ep_listen = listen(path).value();
        receive([p{make_shared<controller>(ep_listen)}](auto from, auto m) {
          return p->receive(move(from), move(m));
        });
        return ok();
      },
      [&](auto s) {
        if (s == "success")
          result = true;
      },
      "endpoint_unx", move(env_)));
}
