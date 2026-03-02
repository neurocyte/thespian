#include <thespian/c/context.h>
#include <thespian/c/unx.h>
#include <thespian/unx.hpp>

using thespian::unx::acceptor_impl;
using thespian::unx::connector_impl;
using thespian::unx::mode;

extern "C" {

namespace {
static auto to_cpp_mode(thespian_unx_mode m) -> mode {
  return m == THESPIAN_UNX_MODE_ABSTRACT ? mode::abstract : mode::file;
}
} // namespace

auto thespian_unx_acceptor_create(const char *tag)
    -> struct thespian_unx_acceptor_handle * {
  try {
    auto *h = thespian::unx::acceptor::create(tag).ref.release();
    return reinterpret_cast<struct thespian_unx_acceptor_handle *>(h); // NOLINT
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return nullptr;
  } catch (...) {
    thespian_set_last_error("unknown thespian_unx_acceptor_create error");
    return nullptr;
  }
}

auto thespian_unx_acceptor_listen(struct thespian_unx_acceptor_handle *handle,
                                  const char *path, thespian_unx_mode m)
    -> int {
  try {
    thespian::unx::acceptor_listen(
        reinterpret_cast<acceptor_impl *>(handle), // NOLINT
        path, to_cpp_mode(m));
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_unx_acceptor_listen error");
    return -1;
  }
}

auto thespian_unx_acceptor_close(struct thespian_unx_acceptor_handle *handle)
    -> int {
  try {
    thespian::unx::acceptor_close(
        reinterpret_cast<acceptor_impl *>(handle)); // NOLINT
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_unx_acceptor_close error");
    return -1;
  }
}

void thespian_unx_acceptor_destroy(
    struct thespian_unx_acceptor_handle *handle) {
  try {
    thespian::unx::destroy_acceptor(
        reinterpret_cast<acceptor_impl *>(handle)); // NOLINT
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
  } catch (...) {
    thespian_set_last_error("unknown thespian_unx_acceptor_destroy error");
  }
}

auto thespian_unx_connector_create(const char *tag)
    -> struct thespian_unx_connector_handle * {
  try {
    auto *h = thespian::unx::connector::create(tag).ref.release();
    return reinterpret_cast<struct thespian_unx_connector_handle *>( // NOLINT
        h);
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return nullptr;
  } catch (...) {
    thespian_set_last_error("unknown thespian_unx_connector_create error");
    return nullptr;
  }
}

auto thespian_unx_connector_connect(
    struct thespian_unx_connector_handle *handle, const char *path,
    thespian_unx_mode m) -> int {
  try {
    thespian::unx::connector_connect(
        reinterpret_cast<connector_impl *>(handle), // NOLINT
        path, to_cpp_mode(m));
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_unx_connector_connect error");
    return -1;
  }
}

auto thespian_unx_connector_cancel(struct thespian_unx_connector_handle *handle)
    -> int {
  try {
    thespian::unx::connector_cancel(
        reinterpret_cast<connector_impl *>(handle)); // NOLINT
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_unx_connector_cancel error");
    return -1;
  }
}

void thespian_unx_connector_destroy(
    struct thespian_unx_connector_handle *handle) {
  try {
    thespian::unx::destroy_connector(
        reinterpret_cast<connector_impl *>(handle)); // NOLINT
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
  } catch (...) {
    thespian_set_last_error("unknown thespian_unx_connector_destroy error");
  }
}

} // extern "C"
