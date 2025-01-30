#include "tests.hpp"

#include "thespian/env.hpp"
#include "thespian/handle.hpp"

#include <thespian/instance.hpp>

using std::move;
using thespian::behaviour;
using thespian::context;
using thespian::env;
using thespian::env_t;
using thespian::exit;
using thespian::exit_handler;
using thespian::ok;
using thespian::receive;
using thespian::result;
using thespian::self;
using thespian::spawn;
using thespian::spawn_link;
using thespian::to_result;
using thespian::trap;
using thespian::unexpected;

namespace {

auto initE() {
  check(env().str("initAsays") == "yes");
  check(env().str("initBsays") == "");
  check(env().str("initCsays") == "no");
  check(env().num("intval") == 42);
  check(!env().proc("A").expired());
  link(env().proc("A"));
  auto ret = env().proc("A").send("shutdown");
  if (not ret)
    return ret;
  receive([](const auto &, const auto &) { return ok(); });
  return ok();
}

auto initD() {
  auto ret = spawn(initE, "E");
  if (not ret)
    return to_result(ret);
  receive([](const auto &, const auto &m) {
    if (m("die"))
      return exit("died");
    return unexpected(m);
  });
  return ok();
}

auto initC() {
  env().str("initCsays") = "no";
  auto ret = spawn_link(initD, "D").value().send("die");
  if (not ret)
    return to_result(ret);
  trap(true);
  receive([](const auto & /*from*/, const auto &m) {
    if (m("exit", "died"))
      return exit();
    return unexpected(m);
  });
  return ok();
}

auto initB() {
  env().str("initBsays") = "noyoudont";
  receive([](const auto &from, const auto &m) {
    if (m("shutdown")) {
      auto ret = from.send("done");
      if (not ret)
        return ret;
      return exit();
    }
    return unexpected(m);
  });
  return ok();
}

auto initA() {
  link(env().proc("log"));
  env().str("initAsays") = "yes";
  env().num("intval") = 42;
  env().proc("A") = self();
  auto ret = spawn_link(initB, "B").value().send("shutdown");
  if (not ret)
    return ret;
  spawn_link(initC, "C").value();
  receive([i{0}](const auto &, const auto &m) mutable {
    if (m("shutdown") || m("done"))
      ++i;
    else
      return unexpected(m);
    if (i == 2)
      return exit("done");
    return ok();
  });
  return ok();
}

} // namespace

auto spawn_exit(context &ctx, bool &result, env_t env) -> ::result {

  behaviour b;
  check(!b);
  b = []() { return ok(); };
  check(!!b);
  b = behaviour{};
  check(!b);

  return to_result(ctx.spawn_link(
      initA,
      [&](auto s) {
        if (s == "done")
          result = true;
      },
      "spawn_exit", move(env)));
}
