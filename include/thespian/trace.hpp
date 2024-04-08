#pragma once

#include "thespian/handle.hpp"
#include <cbor/cbor.hpp>

#include <functional>
#include <limits>
#include <string>
#include <vector>

namespace thespian {

using channel_set = int;
enum class channel {
  send = 1,
  receive = 2,
  lifetime = 4,
  link = 8,
  execute = 16,
  udp = 32,
  tcp = 64,
  timer = 128,
  metronome = 256,
  endpoint = 512,
  signal = 1024,
  all = std::numeric_limits<channel_set>::max(),
};

using trace_handler = std::function<void(const cbor::buffer &)>;

auto on_trace(trace_handler) -> trace_handler;
auto trace_to_json_file(const std::string &file_name) -> void;
auto trace_to_cbor_file(const std::string &file_name) -> void;
auto trace_to_mermaid_file(const std::string &file_name) -> void;

} // namespace thespian
