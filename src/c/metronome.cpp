#include <thespian/c/context.h>
#include <thespian/c/metronome.h>
#include <thespian/metronome.hpp>

#include <chrono>

using std::chrono::microseconds;
using std::chrono::milliseconds;
using thespian::destroy_metronome;
using thespian::metronome_impl;
using thespian::metronome_ref;
using thespian::start_metronome;
using thespian::stop_metronome;

extern "C" {

auto thespian_metronome_create_ms(uint64_t ms)
    -> thespian_metronome_handle * {
  try {
    auto *handle = thespian::create_metronome(milliseconds(ms)).ref.release();
    return reinterpret_cast<thespian_metronome_handle *>(handle); // NOLINT
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return nullptr;
  } catch (...) {
    thespian_set_last_error("unknown thespian_metronome_create_ms error");
    return nullptr;
  }
}
auto thespian_metronome_create_us(uint64_t us)
    -> thespian_metronome_handle * {
  try {
    auto *handle = thespian::create_metronome(microseconds(us)).ref.release();
    return reinterpret_cast<thespian_metronome_handle *>(handle); // NOLINT
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return nullptr;
  } catch (...) {
    thespian_set_last_error("unknown thespian_metronome_create_us error");
    return nullptr;
  }
}
auto thespian_metronome_start(thespian_metronome_handle *handle) -> int {
  try {
    start_metronome(reinterpret_cast<metronome_impl *>(handle)); // NOLINT
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_metronome_start error");
    return -1;
  }
}
auto thespian_metronome_stop(thespian_metronome_handle *handle) -> int {
  try {
    stop_metronome(reinterpret_cast<metronome_impl *>(handle)); // NOLINT
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_metronome_stop error");
    return -1;
  }
}
void thespian_metronome_destroy(thespian_metronome_handle *handle) {
  try {
    destroy_metronome(reinterpret_cast<metronome_impl *>(handle)); // NOLINT
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
  } catch (...) {
    thespian_set_last_error("unknown thespian_metronome_destroy error");
  }
}
}
