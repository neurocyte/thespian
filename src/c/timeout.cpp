#include <thespian/c/context.h>
#include <thespian/c/timeout.h>
#include <thespian/timeout.hpp>

#include <chrono>

using std::chrono::microseconds;
using std::chrono::milliseconds;
using thespian::cancel_timeout;
using thespian::destroy_timeout;
using thespian::timeout_impl;
using thespian::timeout_ref;

extern "C" {

auto thespian_timeout_create_ms(unsigned long ms, cbor_buffer m)
    -> thespian_timeout_handle * {
  try {
    cbor::buffer buf;
    const uint8_t *data = m.base;
    std::copy(data, data + m.len, // NOLINT(*-pointer-arithmetic)
              back_inserter(buf));
    auto *handle =
        thespian::create_timeout(milliseconds(ms), move(buf)).ref.release();
    return reinterpret_cast<thespian_timeout_handle *>(handle); // NOLINT
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return nullptr;
  } catch (...) {
    thespian_set_last_error("unknown thespian_timeout_create_ms error");
    return nullptr;
  }
}
auto thespian_timeout_create_us(unsigned long us, cbor_buffer m)
    -> thespian_timeout_handle * {
  try {
    cbor::buffer buf;
    const uint8_t *data = m.base;
    std::copy(data, data + m.len, // NOLINT(*-pointer-arithmetic)
              back_inserter(buf));
    auto *handle =
        thespian::create_timeout(microseconds(us), move(buf)).ref.release();
    return reinterpret_cast<thespian_timeout_handle *>(handle); // NOLINT
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return nullptr;
  } catch (...) {
    thespian_set_last_error("unknown thespian_timeout_create_us error");
    return nullptr;
  }
}
auto thespian_timeout_cancel(thespian_timeout_handle *handle) -> int {
  try {
    cancel_timeout(reinterpret_cast<timeout_impl *>(handle)); // NOLINT
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_timeout_start error");
    return -1;
  }
}
void thespian_timeout_destroy(thespian_timeout_handle *handle) {
  try {
    destroy_timeout(reinterpret_cast<timeout_impl *>(handle)); // NOLINT
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
  } catch (...) {
    thespian_set_last_error("unknown thespian_timeout_destroy error");
  }
}
}
