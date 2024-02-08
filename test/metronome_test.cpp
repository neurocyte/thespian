#include "tests.hpp"

#include "thespian/env.hpp"
#include <thespian/instance.hpp>
#include <thespian/metronome.hpp>

#include <chrono>
#include <memory>
#include <string>

using cbor::buffer;
using std::move;
using std::shared_ptr;
using std::chrono::microseconds;
using std::chrono::system_clock;
using thespian::context;
using thespian::create_metronome;
using thespian::env;
using thespian::env_t;
using thespian::exit;
using thespian::exit_handler;
using thespian::handle;
using thespian::link;
using thespian::metronome;
using thespian::ok;
using thespian::receive;
using thespian::result;
using thespian::unexpected;

using clk = std::chrono::system_clock;

using namespace std::chrono_literals;

namespace {

auto initA() {
  link(env().proc("log"));
  struct state_t {
    int i{0};
    system_clock::time_point start{clk::now()};
    metronome met{create_metronome(10ms)};
    state_t() { met.start(); }
    handle log{env().proc("log")};

    auto receive(const buffer &m) {
      if (m("tick", i))
        ++i;
      else
        return unexpected(m);
      {
        auto end = clk::now();
        auto us = duration_cast<microseconds>(end - start).count();
        auto ret = log.send("tick@", us, "µs");
        if (not ret)
          return ret;
      }
      if (i == 5) {
        auto end = clk::now();
        auto us = duration_cast<microseconds>(end - start);
        met.stop();
        return exit(us > 50000us ? "done" : "failed");
      }
      return ok();
    }
  };
  shared_ptr<state_t> state{new state_t};
  receive([state](auto, auto m) mutable { return state->receive(m); });
  return ok();
}

} // namespace

auto metronome_test(context &ctx, bool &result, env_t env) -> ::result {
  return to_result(ctx.spawn_link(
      initA,
      [&](auto s) {
        if (s == "done")
          result = true;
      },
      "metronome", move(env)));
}
