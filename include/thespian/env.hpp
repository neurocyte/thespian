#pragma once

#include "handle.hpp"
#include "trace.hpp"

#include <any>
#include <cstddef>
#include <map>

namespace thespian {

struct env_t {
  void enable_all_channels() {
    trace_channels = static_cast<channel_set>(channel::all);
  }
  void disable_all_channels() { trace_channels = 0; }
  void enable(channel c) { trace_channels |= static_cast<channel_set>(c); }
  void disable(channel c) { trace_channels ^= static_cast<channel_set>(c); }
  auto enabled(channel c) -> bool {
    return trace_channels & static_cast<channel_set>(c);
  }

  auto on_trace(trace_handler h) {
    std::swap(h, trace_handler);
    return h;
  }

  auto trace(const cbor::buffer &msg) const {
    if (trace_handler)
      trace_handler(msg);
  }

  auto is(std::string_view k) -> bool & { return b[std::string(k)]; }
  auto num(std::string_view k) -> int64_t & { return i[std::string(k)]; }
  auto str(std::string_view k) -> std::string & { return s[std::string(k)]; }
  auto proc(std::string_view k) -> handle & { return h[std::string(k)]; }
  [[nodiscard]] auto proc(std::string_view k) const -> const handle & {
    return h.at(std::string(k));
  }

private:
  std::map<std::string, std::string> s;
  std::map<std::string, bool> b;
  std::map<std::string, int64_t> i;
  std::map<std::string, handle> h;
  channel_set trace_channels{0};
  trace_handler trace_handler;
};
auto env() -> env_t &;

} // namespace thespian
