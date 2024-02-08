#include "tests.hpp"

#include "thespian/env.hpp"
#include "thespian/handle.hpp"
#include <thespian/instance.hpp>

#include <chrono>
#include <string>

using cbor::A;
using cbor::array;
using cbor::buffer;
using cbor::extract;
using cbor::type;
using std::move;
using std::string_view;
using std::to_string;
using std::chrono::duration_cast;
using std::chrono::microseconds;
using thespian::context;
using thespian::env;
using thespian::env_t;
using thespian::link;
using thespian::ok;
using thespian::result;

using clk = std::chrono::system_clock;

namespace {

auto count{10000UL}; // NOLINT

auto time(const char *name, void (*f)()) -> void {
  auto start = clk::now();

  for (uint64_t i{0}; i < count; ++i)
    f();

  auto end = clk::now();
  auto us = duration_cast<microseconds>(end - start).count();

  auto _ = env().proc("log").send(to_string((count * 1.0L) / us), name, "/µs");
}

const auto ma = array("five", 5, "four", 4, array("three", 3));

auto test() -> result {
  link(env().proc("log"));
  auto _ = env().proc("log").send("buffer size:", ma.size());

  time("noop", []() {});

  time("encode_template", []() {
    buffer m{array("five", 5, "four", 4, array("three", 3))};
    check(m.size() == 21);
  });

  time("encode_chain", []() {
    buffer b;
    b.array_header(5)
        .push("five")
        .push(5)
        .push("four")
        .push(4)
        .array_header(2)
        .push("three")
        .push(3);
    check(b.size() == 21);
  });

  time("encode_chain_reserve", []() {
    buffer b;
    b.reserve(21);
    b.array_header(5)
        .push("five")
        .push(5)
        .push("four")
        .push(4)
        .array_header(2)
        .push("three")
        .push(3);
    check(b.size() == 21);
  });

  time("match", []() {
    check(ma(type::string, type::number, type::string, type::number,
             type::array));
  });

  time("match2", []() {
    check(ma(type::string, type::number, type::string, type::number,
             A(type::string, type::number)));
  });

  time("extract_int", []() {
    int64_t i{};
    check(ma(type::string, extract(i), type::more));
    check(i == 5);
  });

  time("extract_string", []() {
    string_view s;
    check(ma(extract(s), type::more));
  });

  time("extract_int2", []() {
    int64_t i{};
    check(ma(type::string, type::number, type::string, type::number,
             A(type::string, extract(i))));
    check(i == 3);
  });

  time("extract_string2", []() {
    string_view s;
    check(ma(type::string, type::number, type::string, type::number,
             A(extract(s), type::number)));
  });

  time("extract_array", []() {
    buffer::range r;
    check(
        ma(type::string, type::number, type::string, type::number, extract(r)));
    check(r(type::string, type::number));
  });
  return ok();
}

} // namespace

auto perf_cbor(context &ctx, bool &result, env_t env) -> ::result {
  if (env.is("long_run"))
    count = 10000000;
  return to_result(ctx.spawn_link(
      test,
      [&](auto s) {
        check(s == "noreceive");
        result = true;
      },
      "perf_cbor", move(env)));
}
