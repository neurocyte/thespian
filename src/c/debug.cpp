#include <thespian/c/debug.h>
#include <thespian/debug.hpp>

#include <string>

using thespian::context;

namespace {
thread_local std::string last_error_msg; // NOLINT

void set_error(std::string msg) {
  last_error_msg = std::move(msg);
  thespian_set_last_error(last_error_msg.c_str());
}
} // namespace

extern "C" {

void thespian_debug_enable(thespian_context ctx) {
  thespian::debug::enable(*reinterpret_cast<context *>(ctx)); // NOLINT
}

void thespian_debug_disable(thespian_context ctx) {
  thespian::debug::disable(*reinterpret_cast<context *>(ctx)); // NOLINT
}

auto thespian_debug_isenabled(thespian_context ctx) -> bool {
  return thespian::debug::isenabled(
      *reinterpret_cast<context *>(ctx)); // NOLINT
}

auto thespian_debug_tcp_create(thespian_context ctx, uint16_t port,
                               const char *prompt, thespian_handle *handle)
    -> int {
  try {
    auto ret = thespian::debug::tcp::create(
        *reinterpret_cast<context *>(ctx), port, prompt ? prompt : ""); // NOLINT
    if (not ret) {
      set_error(ret.error().to_json());
      return -1;
    }
    *handle = reinterpret_cast<thespian_handle>( // NOLINT
        new thespian::handle{ret.value()});
    return 0;
  } catch (const std::exception &e) {
    set_error(e.what());
    return -1;
  } catch (...) {
    set_error("unknown thespian_debug_tcp_create error");
    return -1;
  }
}
}
