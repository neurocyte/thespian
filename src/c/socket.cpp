#include <thespian/c/context.h>
#include <thespian/c/socket.h>
#include <thespian/socket.hpp>

#include <cassert>

#define ASSERT_HANDLE(h, fn) \
    assert((h) != nullptr && "null handle passed to " fn ": was it created outside an actor?")


using socket_impl = thespian::socket_impl;

extern "C" {

auto thespian_socket_create(const char *tag, int fd)
    -> struct thespian_socket_handle * {
  try {
    auto *h = thespian::socket::create(tag, fd).ref.release();
    return reinterpret_cast<struct thespian_socket_handle *>(h); // NOLINT
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return nullptr;
  } catch (...) {
    thespian_set_last_error("unknown thespian_socket_create error");
    return nullptr;
  }
}

auto thespian_socket_write(struct thespian_socket_handle *handle,
                           const char *data, size_t len) -> int {
  ASSERT_HANDLE(handle, "thespian_socket_write");
  try {
    thespian::socket_write(reinterpret_cast<socket_impl *>(handle), // NOLINT
                           std::string_view(data, len));
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_socket_write error");
    return -1;
  }
}

auto thespian_socket_write_binary(struct thespian_socket_handle *handle,
                                  const uint8_t *data, size_t len) -> int {
  ASSERT_HANDLE(handle, "thespian_socket_write_binary");
  try {
    std::vector<uint8_t> buf(data, data + len); // NOLINT
    thespian::socket_write_binary(
        reinterpret_cast<socket_impl *>(handle), // NOLINT
        buf);
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_socket_write_binary error");
    return -1;
  }
}

auto thespian_socket_read(struct thespian_socket_handle *handle) -> int {
  ASSERT_HANDLE(handle, "thespian_socket_read");
  try {
    thespian::socket_read(reinterpret_cast<socket_impl *>(handle)); // NOLINT
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_socket_read error");
    return -1;
  }
}

auto thespian_socket_close(struct thespian_socket_handle *handle) -> int {
  ASSERT_HANDLE(handle, "thespian_socket_close");
  try {
    thespian::socket_close(reinterpret_cast<socket_impl *>(handle)); // NOLINT
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_socket_close error");
    return -1;
  }
}

void thespian_socket_destroy(struct thespian_socket_handle *handle) {
  ASSERT_HANDLE(handle, "thespian_socket_destroy");
  try {
    thespian::destroy_socket(reinterpret_cast<socket_impl *>(handle)); // NOLINT
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
  } catch (...) {
    thespian_set_last_error("unknown thespian_socket_destroy error");
  }
}

} // extern "C"
