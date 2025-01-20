#include "tests.hpp"

#include "thespian/env.hpp"
#include "thespian/handle.hpp"
#include <thespian/hub.hpp>
#include <thespian/instance.hpp>
#include <thespian/trace.hpp>

#include <chrono>
#include <set>
#include <sstream>

using cbor::extract;
using std::move;
using std::set;
using std::string;
using std::stringstream;
using std::underlying_type_t;
using std::chrono::duration_cast;
using std::chrono::milliseconds;
using thespian::context;
using thespian::env;
using thespian::env_t;
using thespian::handle;
using thespian::hub;
using thespian::link;
using thespian::ok;
using thespian::receive;
using thespian::result;
using thespian::self;
using thespian::spawn_link;
using thespian::unexpected;

using clk = std::chrono::system_clock;

namespace {

enum class tag : uint8_t {
  ready = 1,
  done = 2,
};

auto tag_to_int(tag e) noexcept -> int {
  return static_cast<underlying_type_t<tag>>(e);
}
auto tag_from_int(int i) -> tag {
  return static_cast<tag>(static_cast<int>(i));
}

auto subscriber(const hub &h, const handle &controller, const int num,
                const int messages) -> result {
  auto ret = h.subscribe();
  if (not ret)
    return ret;
  ret = controller.send(tag_to_int(tag::ready), num);
  if (not ret)
    return ret;
  int count{1};
  receive([=](auto /*from*/, auto m) mutable {
    if (!m("parmA", "parmB", "parmC", count))
      std::abort();
    if (count == messages) {
      auto ret = controller.send(tag_to_int(tag::done), num);
      if (not ret)
        return ret;
    }
    ++count;
    return ok();
  });
  return ok();
}

auto controller(const int subscriptions, const int messages) -> result {
  const auto log = env().proc("log");
  const auto verbose = env().is("verbose");
  auto ret = hub::create("hub");
  if (not ret)
    return to_result(ret);
  auto h = ret.value();
  handle c = self();

  auto _ = log.send("subscribing", subscriptions);

  set<int> subs;
  for (auto i{0}; i < subscriptions; ++i) {
    auto ret =
        spawn_link([=]() -> result { return subscriber(h, c, i, messages); },
                   "subscriber");
    if (not ret)
      return to_result(ret);
    subs.insert(i);
  }
  _ = log.send("all", "spawned");
  set<int> not_ready = subs;
  set<int> done = subs;
  clk::time_point start;

  receive([=](auto, auto m) mutable {
    int tag_{}, num{};
    if (!m(extract(tag_), extract(num)))
      return unexpected(m);
    tag tag = tag_from_int(tag_);
    switch (tag) {
    case tag::ready:
      not_ready.erase(num);
      if (not_ready.empty()) {
        if (verbose)
          _ = log.send("all", "ready");
        for (int i = 1; i <= messages; ++i)
          h.broadcast("parmA", "parmB", "parmC", i);
        start = clk::now();
        if (verbose)
          _ = log.send("broadcasting", messages);
      }
      break;

    case tag::done:
      done.erase(num);
      if (done.empty()) {
        if (verbose) {
          clk::time_point end = clk::now();
          auto ms = duration_cast<milliseconds>(end - start).count();
          double msgs = subscriptions * messages + subscriptions;
          _ = log.send("all", "done");
          _ = log.send("time:", ms, "ms");
          _ = log.send(
              static_cast<int>((msgs / static_cast<double>(ms)) * 1000),
              "msg/s");
        }
        return h.shutdown();
      }
    }
    return ok();
  });
  return ok();
}
} // namespace

auto perf_hub(context &ctx, bool &result, env_t env_) -> ::result {
  const auto long_run = env_.is("long_run");
  const auto subscriptions = long_run ? 1000 : 100;
  const auto messages = long_run ? 10000 : 100;
  return to_result(ctx.spawn_link(
      [=]() {
        link(env().proc("log"));
        return controller(subscriptions, messages);
      },
      [&](auto s) {
        if (s == "shutdown")
          result = true;
      },
      "controller", move(env_)));
}
