#include <thespian/c/context.h>
#include <thespian/c/tcp.h>
#include <thespian/tcp.hpp>

using ::port_t;
using thespian::tcp::acceptor_impl;
using thespian::tcp::connector_impl;

extern "C" {

auto thespian_tcp_acceptor_create(const char *tag)
    -> struct thespian_tcp_acceptor_handle * {
  try {
    auto *h = thespian::tcp::acceptor::create(tag).ref.release();
    return reinterpret_cast<struct thespian_tcp_acceptor_handle *>(h); // NOLINT
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return nullptr;
  } catch (...) {
    thespian_set_last_error("unknown thespian_tcp_acceptor_create error");
    return nullptr;
  }
}

auto thespian_tcp_acceptor_listen(struct thespian_tcp_acceptor_handle *handle,
                                  in6_addr ip, uint16_t port) -> uint16_t {
  try {
    port_t p = thespian::tcp::acceptor_listen(
        reinterpret_cast<acceptor_impl *>(handle), ip, port); // NOLINT
    return static_cast<uint16_t>(p);
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return 0;
  } catch (...) {
    thespian_set_last_error("unknown thespian_tcp_acceptor_listen error");
    return 0;
  }
}

auto thespian_tcp_acceptor_close(struct thespian_tcp_acceptor_handle *handle)
    -> int {
  try {
    thespian::tcp::acceptor_close(
        reinterpret_cast<acceptor_impl *>(handle)); // NOLINT
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_tcp_acceptor_close error");
    return -1;
  }
}

void thespian_tcp_acceptor_destroy(
    struct thespian_tcp_acceptor_handle *handle) {
  try {
    thespian::tcp::destroy_acceptor(
        reinterpret_cast<acceptor_impl *>(handle)); // NOLINT
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
  } catch (...) {
    thespian_set_last_error("unknown thespian_tcp_acceptor_destroy error");
  }
}

auto thespian_tcp_connector_create(const char *tag)
    -> struct thespian_tcp_connector_handle * {
  try {
    auto *h = thespian::tcp::connector::create(tag).ref.release();
    return reinterpret_cast<struct thespian_tcp_connector_handle *>( // NOLINT
        h);
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return nullptr;
  } catch (...) {
    thespian_set_last_error("unknown thespian_tcp_connector_create error");
    return nullptr;
  }
}

auto thespian_tcp_connector_connect(
    struct thespian_tcp_connector_handle *handle, in6_addr ip, uint16_t port)
    -> int {
  try {
    thespian::tcp::connector_connect(
        reinterpret_cast<connector_impl *>(handle), // NOLINT
        ip, port);
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_tcp_connector_connect error");
    return -1;
  }
}

auto thespian_tcp_connector_cancel(struct thespian_tcp_connector_handle *handle)
    -> int {
  try {
    thespian::tcp::connector_cancel(
        reinterpret_cast<connector_impl *>(handle)); // NOLINT
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_tcp_connector_cancel error");
    return -1;
  }
}

void thespian_tcp_connector_destroy(
    struct thespian_tcp_connector_handle *handle) {
  try {
    thespian::tcp::destroy_connector(
        reinterpret_cast<connector_impl *>(handle)); // NOLINT
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
  } catch (...) {
    thespian_set_last_error("unknown thespian_tcp_connector_destroy error");
  }
}

} // extern "C"
