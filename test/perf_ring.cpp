#include "tests.hpp"

#include "thespian/env.hpp"
#include <thespian/instance.hpp>

#include <string>

using cbor::extract;
using std::move;
using std::string;
using std::string_view;
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

namespace {

auto slave(const handle &last, int n) -> result {
  handle next;
  if (n)
    next = spawn_link([=]() { return slave(last, n - 1); }, "slave").value();

  receive([n, next, last](auto, auto m) {
    return n ? next.send_raw(move(m)) : last.send_raw(move(m));
  });
  return ok();
}

auto controller(const int slaves) -> result {
  auto verbose = env().is("long_run");
  int loop = 10;
  handle last = self();
  auto ret = spawn_link([=]() { return slave(last, slaves); }, "slave");
  if (not ret)
    return to_result(ret);
  handle first = ret.value();
  auto ret2 = first.send("forward");
  if (not ret2)
    return ret2;
  receive([loop, first, verbose](auto, auto m) mutable {
    if (loop) {
      if (verbose)
        auto _ = env().proc("log").send(loop);
      --loop;
      return first.send_raw(move(m));
    }
    string_view s;
    check(m(extract(s)));
    return exit(s);
  });
  return ok();
}
} // namespace

auto perf_ring(context &ctx, bool &result, env_t env_) -> ::result {
  auto long_run = env_.is("long_run");
  auto slaves{long_run ? 100000 : 1000};
  return to_result(ctx.spawn_link(
      [=]() {
        link(env().proc("log"));
        return controller(slaves);
      },
      [&](auto s) {
        if (s == "forward") {
          result = true;
        } else {
          auto _ = env_.proc("log").send("failed:", s);
        }
      },
      "perf_ring", move(env_)));
}
