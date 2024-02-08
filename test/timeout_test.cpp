#include "tests.hpp"

#include "thespian/env.hpp"
#include "thespian/handle.hpp"
#include <thespian/instance.hpp>
#include <thespian/timeout.hpp>

#include <chrono>
#include <memory>
#include <string>

using cbor::array;
using cbor::buffer;
using std::move;
using std::shared_ptr;
using std::chrono::microseconds;
using std::chrono::system_clock;
using thespian::context;
using thespian::create_timeout;
using thespian::env_t;
using thespian::exit;
using thespian::exit_handler;
using thespian::ok;
using thespian::receive;
using thespian::result;
using thespian::timeout;
using thespian::unexpected;

using clk = std::chrono::system_clock;

using namespace std::chrono_literals;

namespace {

auto initA() -> result {
  thespian::link(thespian::env().proc("log"));
  struct state_t {
    system_clock::time_point start{clk::now()};
    timeout t{create_timeout(200ms, array("timeout"))};

    auto receive(const buffer &m) {
      if (!m("timeout"))
        return unexpected(m);
      auto end = clk::now();
      auto us = duration_cast<microseconds>(end - start);
      return exit(us > 200ms ? "done" : "failed");
    }
  };
  shared_ptr<state_t> state{new state_t};
  receive([state](auto, auto m) mutable { return state->receive(m); });
  return ok();
}

} // namespace

auto timeout_test(context &ctx, bool &result, env_t env) -> ::result {
  return to_result(ctx.spawn_link(
      initA,
      [&](auto s) {
        if (s == "done")
          result = true;
      },
      "timeout", move(env)));
}
