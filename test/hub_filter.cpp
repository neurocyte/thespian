#include "tests.hpp"

#include "thespian/env.hpp"
#include "thespian/handle.hpp"
#include <thespian/hub.hpp>
#include <thespian/instance.hpp>

#include <map>

using cbor::extract;
using cbor::type;
using std::map;
using std::move;
using std::string;
using std::string_view;
using std::stringstream;
using thespian::context;
using thespian::env_t;
using thespian::handle;
using thespian::hub;
using thespian::ok;
using thespian::receive;
using thespian::result;
using thespian::self;
using thespian::spawn_link;

namespace {

auto sub_plain(const hub &h, const handle &controller, string name) -> result {
  auto ret = h.subscribe();
  if (not ret)
    return ret;
  ret = controller.send("ready", name);
  if (not ret)
    return ret;
  receive([=](const auto & /*from*/, const auto &m) {
    string_view cmd;
    check(m("parmA", "parmB", "parmC", extract(cmd)));
    check(cmd == "continue" || cmd == "done");
    if (cmd == "done") {
      auto ret = controller.send(cmd, name);
      if (not ret)
        return ret;
    }
    return ok();
  });
  return ok();
}

auto sub_filtered(const hub &h, const handle &controller, string name)
    -> result {
  auto ret = h.subscribe(
      [](const auto &m) { return m(type::any, type::any, type::any, "done"); });
  if (not ret)
    return ret;
  ret = controller.send("ready", name);
  if (not ret)
    return ret;
  receive([=](const auto & /*from*/, const auto &m) {
    check(m("parmA", "parmB", "parmC", "done"));
    auto ret = controller.send("done", name);
    if (not ret)
      return ret;
    return ok();
  });
  return ok();
}

map<string, auto (*)(const hub &, const handle &, string)->result>
    subscription_defs // NOLINT
    = {
        {"sub_plain", sub_plain},
        {"sub_filtered", sub_filtered},
};
using submap = map<string, handle>;

auto controller() -> result {
  thespian::link(thespian::env().proc("log"));
  auto h = hub::create("hub").value();
  handle c = self();
  auto ret = h.subscribe();
  if (not ret)
    return ret;

  submap subs;
  for (const auto &s : subscription_defs) {
    subs.insert({s.first, spawn_link(
                              [=]() {
                                s.second(h, c, s.first);
                                return ok();
                              },
                              s.first)
                              .value()});
  }
  submap not_ready = subs;
  submap done = subs;

  receive([=](const auto &, const auto &m) mutable {
    string name;
    if (m("ready", extract(name))) {
      not_ready.erase(name);
      if (not_ready.empty()) {
        h.broadcast("parmA", "parmB", "parmC", "continue");
        h.broadcast("parmA", "parmB", "parmC", "continue");
        h.broadcast("parmA", "parmB", "parmC", "done");
      }
    } else if (m("done", extract(name))) {
      done.erase(name);
      if (done.empty())
        return h.shutdown();
    }
    return ok();
  });
  return ok();
}

} // namespace

auto hub_filter(context &ctx, bool &result, env_t env) -> ::result {
  return to_result(ctx.spawn_link(
      controller,
      [&](auto s) {
        if (s == "shutdown")
          result = true;
      },
      "hub_filter", move(env)));
}
