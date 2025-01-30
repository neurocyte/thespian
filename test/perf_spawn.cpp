#include "tests.hpp"

#include "thespian/env.hpp"
#include <thespian/instance.hpp>

using cbor::extract;
using std::move;
using thespian::context;
using thespian::env;
using thespian::env_t;
using thespian::exit;
using thespian::link;
using thespian::ok;
using thespian::receive;
using thespian::result;
using thespian::spawn_link;
using thespian::unexpected;

namespace {

auto slave(const int slaves, int spawned) -> result {
  receive([slaves, spawned](const auto &, const auto &m) mutable {
    int n{0};
    if (!m(extract(n)))
      return unexpected(m);
    if (n) {
      ++spawned;
      return thespian::to_result(
          spawn_link([=]() { return slave(slaves, spawned); }, "slave")
              .value()
              .send(n - 1));
    }
    if (spawned != slaves) {
      auto _ = env().proc("log").send("spawned", spawned, "slaves !=", slaves);
      return exit("failed");
    }
    if (env().is("verbose"))
      auto _ = env().proc("log").send("spawned", slaves, "slaves");
    return exit("done");
  });
  return ok();
}

auto controller(const int slaves) -> result {
  auto ret = spawn_link([=]() { return slave(slaves, 1); }, "slave");
  if (not ret)
    return to_result(ret);
  auto ret2 = ret.value().send(slaves - 1);
  if (not ret2)
    return ret2;
  receive([](const auto &, const auto &) { return exit(); });
  return ok();
}
} // namespace

auto perf_spawn(context &ctx, bool &result, env_t env_) -> ::result {
  auto slaves{env_.is("long_run") ? 1000000 : 1000};
  return to_result((ctx.spawn_link(
      [=]() {
        link(env().proc("log"));
        return controller(slaves);
      },
      [&](auto s) {
        if (s == "done") {
          result = true;
        } else {
          auto _ = env_.proc("log").send(s);
        }
      },
      "perf_spawn", move(env_))));
}
