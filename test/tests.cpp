#include "tests.hpp"

#include <cstring>
#include <thespian/backtrace.h>
#include <thespian/context.hpp>
#include <thespian/debug.hpp>
#include <thespian/env.hpp>
#include <thespian/instance.hpp>
#include <thespian/timeout.hpp>
#include <thespian/trace.hpp>

#include <csignal>
#include <cstdlib>
#include <iostream>
#include <map>
#include <mutex>
#include <string>
#include <utility>

using cbor::buffer;
using std::cerr;
using std::cout;
using std::lock_guard;
using std::map;
using std::move;
using std::mutex;
using std::ostream;
using std::string;
using thespian::env_t;
using thespian::handle;
using thespian::ok;

namespace {

using namespace std::chrono_literals;

auto operator<<(ostream &s, const cbor::buffer::value_accessor::unvisitable_type
                                & /*unused*/) -> ostream & {
  return s << "unvisitable_type";
}

struct logger {
  thespian::timeout t{thespian::create_timeout(60s, cbor::array("timeout"))};
  const char *name;
  mutex &trace_m;
  bool verbose;

  explicit logger(const char *name, mutex &trace_m, bool verbose)
      : name(name), trace_m(trace_m), verbose(verbose) {}

  auto receive(const buffer &m) {
    if (verbose) {
      std::lock_guard<mutex> lock(trace_m);
      cout << name << ": ";
      auto dump = [&](auto val) { cout << val << " "; };
      for (const auto val : m)
        val.visit(dump);
      cout << '\n';
    }
    return ok();
  }

  static auto start(thespian::context &ctx, const char *name, mutex &trace_m,
                    bool verbose, env_t env) -> handle {
    return ctx
        .spawn(
            [name, &trace_m, verbose]() {
              thespian::receive(
                  [p{make_shared<logger>(name, trace_m, verbose)}](
                      auto, auto m) { return p->receive(move(m)); });
              return ok();
            },
            string("logger_") + name, move(env))
        .value();
  }
}; // namespace

} // namespace

extern "C" auto runtestcase(const char *name) -> int {
  mutex trace_m;

#if !defined(_WIN32)
  if (signal(SIGPIPE, SIG_IGN) == SIG_ERR) // NOLINT
    abort();
#endif

  auto gdb = getenv("JITDEBUG"); // NOLINT

  if (gdb) {
    if (strcmp(gdb, "on") != 0)
      install_debugger();
    else if (strcmp(gdb, "backtrace") != 0)
      install_backtrace();
  }

  auto ctx = thespian::context::create();

  map<string, testcase *> tests;
  tests["cbor_match"] = cbor_match;
  tests["debug"] = debug;
  tests["endpoint_unx"] = endpoint_unx;
  tests["endpoint_tcp"] = endpoint_tcp;
  tests["hub_filter"] = hub_filter;
  tests["ip_tcp_client_server"] = ip_tcp_client_server;
  tests["ip_udp_echo"] = ip_udp_echo;
  tests["metronome_test"] = metronome_test;
  tests["perf_cbor"] = perf_cbor;
  tests["perf_hub"] = perf_hub;
  tests["perf_ring"] = perf_ring;
  tests["perf_spawn"] = perf_spawn;
  tests["spawn_exit"] = spawn_exit;
  tests["timeout_test"] = timeout_test;

  env_t env{};
  env_t log_env{};
  auto trace = [&](const buffer &buf) {
    lock_guard<mutex> lock(trace_m);
    cout << buf.to_json() << '\n';
  };
  log_env.on_trace(trace);
  env.on_trace(trace);
  if (getenv("TRACE")) { // NOLINT
    thespian::debug::enable(*ctx);
    env.enable_all_channels();
    log_env.enable_all_channels();
  }
  if (getenv("TRACE_LIFETIME")) { // NOLINT
    thespian::debug::enable(*ctx);
    env.enable(thespian::channel::lifetime);
    log_env.enable(thespian::channel::lifetime);
  }
  if (getenv("TRACE_EXECUTE")) { // NOLINT
    env.enable(thespian::channel::execute);
  }
  if (getenv("TRACE_SEND")) { // NOLINT
    env.enable(thespian::channel::send);
  }
  if (getenv("TRACE_RECEIVE")) { // NOLINT
    env.enable(thespian::channel::receive);
  }

  bool long_run = getenv("LONGRUN"); // NOLINT
  bool verbose = getenv("VERBOSE");  // NOLINT
  env.is("long_run") = long_run;
  env.is("verbose") = verbose;

  if (verbose)
    cout << '\n';

  env.proc("log") = logger::start(*ctx, name, trace_m, verbose, move(log_env));

  auto test = tests.find(name);
  if (test == tests.end()) {
    cerr << "invalid testcase: " << name << '\n';
    return 1;
  }
  bool result{false};
  test->second(*ctx, result, move(env));
  ctx->run();
  return result ? 0 : 1;
}
