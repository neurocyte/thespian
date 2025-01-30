#include <thespian/c/handle.h>
#include <thespian/handle.hpp>
#include <thespian/instance.hpp>

namespace {

static thread_local cbor::buffer
    message_buffer; // NOLINT(*-avoid-non-const-global-variables)
static thread_local thespian_error
    error_buffer; // NOLINT(*-avoid-non-const-global-variables)

auto to_thespian_result(thespian::result r) -> thespian_result {
  if (r) {
    return nullptr;
  }
  message_buffer = r.error();
  error_buffer.base = message_buffer.data();
  error_buffer.len = message_buffer.size();
  return &error_buffer;
}

} // namespace

extern "C" {

auto thespian_handle_clone(thespian_handle h) -> thespian_handle {
  thespian::handle *h_{
      reinterpret_cast<thespian::handle *>( // NOLINT(*-reinterpret-cast)
          h)};
  if (!h_)
    return nullptr;
  return reinterpret_cast<thespian_handle>( // NOLINT(*-reinterpret-cast)
      new thespian::handle{*h_});
}

void thespian_handle_destroy(thespian_handle h) {
  thespian::handle *h_{
      reinterpret_cast<thespian::handle *>( // NOLINT(*-reinterpret-cast)
          h)};
  delete h_;
}

auto thespian_handle_send_raw(thespian_handle h, cbor_buffer m)
    -> thespian_result {
  thespian::handle *h_{
      reinterpret_cast<thespian::handle *>( // NOLINT(*-reinterpret-cast)
          h)};
  cbor::buffer buf;
  const uint8_t *data = m.base;
  std::copy(data, data + m.len, // NOLINT(*-pointer-arithmetic)
            back_inserter(buf));
  return to_thespian_result(h_->send_raw(move(buf)));
}

auto thespian_handle_send_exit(thespian_handle h, c_string_view err)
    -> thespian_result {
  thespian::handle *h_{
      reinterpret_cast<thespian::handle *>( // NOLINT(*-reinterpret-cast)
          h)};
  return to_thespian_result(h_->exit(std::string(err.base, err.len)));
}

auto thespian_handle_is_expired(thespian_handle h) -> bool {
  thespian::handle *h_{
      reinterpret_cast<thespian::handle *>( // NOLINT(*-reinterpret-cast)
          h)};
  return h_->expired();
}
}
