#include "tests.hpp"

#include <thespian/instance.hpp>
#include <thespian/trace.hpp>

#include <string>

using cbor::A;
using cbor::array;
using cbor::buffer;
using cbor::extract;
using cbor::M;
using cbor::map;
using cbor::type;
using std::move;
using std::string;
using std::string_view;
using std::stringstream;
using thespian::context;
using thespian::env;
using thespian::env_t;
using thespian::link;
using thespian::ok;
using thespian::result;

namespace {

auto test() -> result {
  auto verbose = env().is("verbose");
  auto log = env().proc("log");
  result _;

  buffer m = array("five", 5, "four", 4, array("three", 3));

  if (verbose) {
    _ = log.send("message:", m.to_json());
    _ = log.send("buffer:", m.hexdump());
  }

  check(m.hexdump() ==
        "21: 85 64 66 69 76 65 05 64 66 6f 75 72 04 82 65 74 68 72 65 65 03");

  check(m.to_json() == R"(["five",5,"four",4,["three",3]])");

  check(m(type::string, type::number, type::string, type::number, type::array));
  check(!m(type::string, type::number, type::string, type::number));
  check(!m(type::number, type::string, type::number, type::array, type::any));
  check(m(type::any, type::number, type::string, type::number, type::any));

  check(m("five", type::number, type::string, 4, type::any));
  check(m("five", 5, "four", 4, type::array));
  check(m("five", 5, type::more));
  check(m("five", 5, "four", 4, type::array, type::more));
  check(!m("five", 5, "four", 4, type::array, type::any));

  check(array().is_null());
  check(!array(1).is_null());
  {
    buffer b;
    b.array_header(5)
        .push("five")
        .push(5)
        .push("four")
        .push(4)
        .array_header(2)
        .push("three")
        .push(3);
    check(m == b);
  }
  {
    buffer b = array(false, true, 5, "five");
    check(b == array(false, true, 5, "five"));
    check(b(false, true, 5, "five"));
    check(!b(true, false, 5, "five"));
    bool t = false;
    check(b(extract(t), true, 5, "five"));
    check(!t);
    check(b(false, extract(t), 5, "five"));
    check(t);
  }
  {
    buffer::range r;
    check(
        m(type::string, type::number, type::string, type::number, extract(r)));
    check(r(type::string, type::number));
    check(r("three", 3));
  }
  {
    int64_t i{};
    check(m(type::string, type::number, type::string, type::number,
            A(type::string, extract(i))));
    check(i == 3);
  }
  {
    buffer ref = array(array(124), array("blip"));
    check(ref(A(type::more), A(type::more)));
  }
  {
    int i{0};
    auto dump = [&](string_view val) {
      ++i;
      if (verbose)
        _ = log.send("value", i, ":", val);
    };
    buffer a = array("five", "four", "three", "two", "one");
    for (const auto val : a)
      dump(val);
    check(i == 5);
  }
  {
    int i{0};
    auto dump = [&](auto val) {
      ++i;
      if (verbose)
        _ = log.send("value", i, ":", val);
    };
    for (const auto val : m)
      val.visit(dump);
    check(i == 5);

    buffer::range r;
    check(m(type::any, type::any, type::any, type::any, extract(r)));
    for (const auto val : r)
      val.visit(dump);
    check(i == 7);
  }
  {
    buffer a = array(array(2, 3, 4, 5), array(6, 7, 8, 9));
    check(a(A(2, 3, 4, 5), A(6, 7, 8, 9)));

    buffer::range a1;
    buffer::range a2;
    check(a(extract(a1), extract(a2)));

    int i{0};
    auto dump = [&](uint32_t val) {
      ++i;
      if (verbose)
        _ = log.send("value", i, ":", val);
    };
    for (const auto val : a1)
      dump(val);
  }
  {
    buffer a = array(array(2, 3, 4, 5), array(6, 7, 8, 9));
    buffer::range a1;
    buffer::range a2;
    check(a(extract(a1), extract(a2)));

    buffer b = array(a1);
    check(b(A(2, 3, 4, 5)));

    buffer b2;
    b2.push(a2);
    check(b2(6, 7, 8, 9));
  }
  {
    buffer a = array(1, 2, map(3, array(3)));

    if (verbose) {
      _ = log.send("map buffer:", a.hexdump());
      _ = log.send("map json:", a.to_json());
    }
    check(a(1, 2, M(3, A(3))));
    buffer::range a1;
    check(a(1, 2, extract(a1)));
    if (verbose)
      _ = log.send("map range json:", a1.to_json());
    check(a1.to_json() == "{3:[3]}");
  }
  {
    buffer a;
    a.push_json(R"(["five", 5, "four", 4, ["three", 3]])");
    if (verbose) {
      _ = log.send("buffer:", a.hexdump());
      _ = log.send("message:", a.to_json());
    }
    check(a.hexdump() == "21: 85 64 66 69 76 65 05 64 66 6f 75 72 04 82 "
                         "65 74 68 72 65 65 03");
  }
  {
    buffer a;
    a.push_json(R"({"five": 5, "four": 4, "three": [{3:3}]})");
    string json = a.to_json();
    if (verbose) {
      _ = log.send("buffer:", a.hexdump());
      _ = log.send("json:", json);
    }
    check(a.hexdump() == "23: a3 64 66 69 76 65 05 64 66 6f 75 72 04 65 "
                         "74 68 72 65 65 81 a1 03 03");
    check(json == R"({"five":5,"four":4,"three":[{3:3}]})");
  }
  {
    buffer a = array("string\r\n", "\tstring\t", "\r\nstring");
    string json = a.to_json();
    if (verbose) {
      _ = log.send("escaped buffer:", a.hexdump());
      _ = log.send("escaped json:", json);
    }
    check(a.hexdump() == "28: 83 68 73 74 72 69 6e 67 0d 0a 68 09 73 74 "
                         "72 69 6e 67 09 68 0d 0a 73 74 72 69 6e 67");
    check(json == R"(["string\r\n","\tstring\t","\r\nstring"])");
  }
  {
    buffer a;
    a.push_json(R"(["string\r\n", "\tstring\t", "\r\nstring"])");
    string json = a.to_json();
    if (verbose) {
      _ = log.send("escaped2 buffer:", a.hexdump());
      _ = log.send("escaped2 json:", json);
    }
    check(a.hexdump() == "28: 83 68 73 74 72 69 6e 67 0d 0a 68 09 73 74 "
                         "72 69 6e 67 09 68 0d 0a 73 74 72 69 6e 67");
    check(json == R"(["string\r\n","\tstring\t","\r\nstring"])");
  }
  {
    buffer a = array(array());
    buffer::range r;
    check(a(extract(r)));
    int i{0};
    auto dump = [&](uint32_t /*val*/) { ++i; };
    for (const auto v1 : r)
      dump(v1);
    check(i == 0);
    check(r.is_null());
    check(r.to_json() == "null");
  }
  {
    int64_t i{-1};
    uint64_t sz{0};
    buffer a = array(i, sz);
    check(a(extract(i), extract(sz)));
    check(i == -1);
    check(sz == 0);
  }
  {
    int64_t i{-1};
    uint64_t sz{0};
    buffer a = array(i);
    check(a(extract(i)));
    check(not a(extract(sz)));
  }
  {
    int32_t i{-1};
    uint32_t sz{0};
    buffer a = array(i);
    check(a(extract(i)));
    check(not a(extract(sz)));
  }
  {
    int16_t i{-1};
    uint16_t sz{0};
    buffer a = array(i);
    check(a(extract(i)));
    check(not a(extract(sz)));
  }
  {
    int8_t i{-1};
    uint8_t sz{0};
    buffer a = array(i);
    check(a(extract(i)));
    check(not a(extract(sz)));
  }
  {
    uint16_t ui{1000};
    uint8_t sz{0};
    buffer a = array(ui);
    check(a(extract(ui)));
    check(not a(extract(sz)));
  }
  {
    uint64_t ui{18446744073709551615ULL};
    int64_t i{0};
    buffer a = array(ui);
    check(a(extract(ui)));
    check(not a(extract(i)));
  }
  {
    buffer a = array(array(1, 2));
    buffer b = array(array(1, 2));
    buffer::range ra;
    check(a(extract(ra)));
    buffer::range rb;
    check(b(extract(rb)));
    check(ra == rb);
  }
  {
    buffer a = array(array(1));
    buffer b = array(array(1, 2));
    buffer::range ra;
    check(a(extract(ra)));
    buffer::range rb;
    check(b(extract(rb)));
    check(not(ra == rb));
  }
  if (verbose)
    _ = log.send("done");
  return ok();
}

} // namespace

auto cbor_match(context &ctx, bool &result, env_t env_) -> ::result {
  return to_result(ctx.spawn_link(
      [=]() {
        link(env().proc("log"));
        return test();
      },
      [&](auto s) {
        check(s == "noreceive");
        result = true;
      },
      "cbor_match", move(env_)));
};
