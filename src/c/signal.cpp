#include <thespian/c/context.h>
#include <thespian/c/signal.h>
#include <thespian/signal.hpp>

using thespian::cancel_signal;
using thespian::destroy_signal;
using thespian::signal_impl;
using thespian::signal_ref;

extern "C" {

auto thespian_signal_create(int signum, cbor_buffer m)
    -> thespian_signal_handle * {
  try {
    cbor::buffer buf;
    const uint8_t *data = m.base;
    std::copy(data, data + m.len, // NOLINT(*-pointer-arithmetic)
              back_inserter(buf));
    auto *handle = thespian::create_signal(signum, move(buf)).ref.release();
    return reinterpret_cast<thespian_signal_handle *>(handle); // NOLINT
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return nullptr;
  } catch (...) {
    thespian_set_last_error("unknown thespian_signal_create error");
    return nullptr;
  }
}
auto thespian_signal_cancel(thespian_signal_handle *handle) -> int {
  try {
    cancel_signal(reinterpret_cast<signal_impl *>(handle)); // NOLINT
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_signal_start error");
    return -1;
  }
}
void thespian_signal_destroy(thespian_signal_handle *handle) {
  try {
    destroy_signal(reinterpret_cast<signal_impl *>(handle)); // NOLINT
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
  } catch (...) {
    thespian_set_last_error("unknown thespian_signal_destroy error");
  }
}
}
