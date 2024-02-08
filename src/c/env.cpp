#include <cbor/cbor.hpp>
#include <thespian/c/env.h>
#include <thespian/c/handle.h>
#include <thespian/env.hpp>
#include <thespian/trace.hpp>

#include <cassert>

namespace {

auto to_env(thespian_env e) -> thespian::env_t & {
  assert(e);
  return *reinterpret_cast<thespian::env_t *>(e); // NOLINT
}

auto destroy(thespian_env e) -> void {
  delete reinterpret_cast<thespian::env_t *>(e); // NOLINT
}

} // namespace

extern "C" {

void thespian_env_enable_all_channels(thespian_env e) {
  to_env(e).enable_all_channels();
}

void thespian_env_disable_all_channels(thespian_env e) {
  to_env(e).disable_all_channels();
}
void thespian_env_enable(thespian_env e, thespian_trace_channel c) {
  to_env(e).enable(static_cast<thespian::channel>(c));
}
void thespian_env_disable(thespian_env e, thespian_trace_channel c) {
  to_env(e).disable(static_cast<thespian::channel>(c));
}
auto thespian_env_enabled(thespian_env e, thespian_trace_channel c) -> bool {
  return to_env(e).enabled(static_cast<thespian::channel>(c));
}
void thespian_env_on_trace(thespian_env e, thespian_trace_handler h) {
  to_env(e).on_trace([h](const cbor::buffer &m) { h({m.data(), m.size()}); });
}
void thespian_env_trace(thespian_env e, cbor_buffer m) {
  cbor::buffer buf;
  const uint8_t *data = m.base;
  std::copy(data, data + m.len, back_inserter(buf)); // NOLINT
  to_env(e).trace(buf);
}

auto thespian_env_is(thespian_env e, c_string_view key) -> bool {
  return to_env(e).is({key.base, key.len});
}
void thespian_env_set(thespian_env e, c_string_view key, bool value) {
  to_env(e).is({key.base, key.len}) = value;
}
auto thespian_env_num(thespian_env e, c_string_view key) -> int64_t {
  return to_env(e).num({key.base, key.len});
}
void thespian_env_num_set(thespian_env e, c_string_view key, int64_t value) {
  to_env(e).num({key.base, key.len}) = value;
}
auto thespian_env_str(thespian_env e, c_string_view key) -> c_string_view {
  auto &ret = to_env(e).str({key.base, key.len});
  return {ret.data(), ret.size()};
}
void thespian_env_str_set(thespian_env e, c_string_view key,
                          c_string_view value) {
  to_env(e).str({key.base, key.len}) = std::string_view{value.base, value.len};
}
auto thespian_env_proc(thespian_env e, c_string_view key) -> thespian_handle {
  auto &ret = to_env(e).proc({key.base, key.len});
  return reinterpret_cast<thespian_handle>(&ret); // NOLINT
}
void thespian_env_proc_set(thespian_env e, c_string_view key,
                           thespian_handle value) {
  thespian::handle *h{reinterpret_cast<thespian::handle *>( // NOLINT
      value)};
  to_env(e).proc({key.base, key.len}) = *h;
}
auto thespian_env_clone(thespian_env e) -> thespian_env {
  return reinterpret_cast<thespian_env>( // NOLINT
      new thespian::env_t{to_env(e)});
}
void thespian_env_destroy(thespian_env e) { destroy(e); }

auto thespian_env_get() -> thespian_env {
  return reinterpret_cast<thespian_env>(&thespian::env()); // NOLINT
}
auto thespian_env_new() -> thespian_env {
  return reinterpret_cast<thespian_env>(new thespian::env_t); // NOLINT
}
}
