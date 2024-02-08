#include <thespian/c/context.h>
#include <thespian/c/file_descriptor.h>
#include <thespian/file_descriptor.hpp>

using thespian::file_descriptor;
using thespian::file_descriptor_impl;
using thespian::file_descriptor_ref;

// NOLINTBEGIN(*-reinterpret-cast, *-use-trailing-*)
extern "C" {

auto thespian_file_descriptor_create(const char *tag, int fd)
    -> thespian_file_descriptor_handle * {
  try {
    auto *p = file_descriptor::create(tag, fd).ref.release();
    return reinterpret_cast<thespian_file_descriptor_handle *>(p);
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return nullptr;
  } catch (...) {
    thespian_set_last_error("unknown thespian_file_descriptor_create error");
    return nullptr;
  }
}

int thespian_file_descriptor_wait_write(thespian_file_descriptor_handle *p) {
  try {
    file_descriptor::wait_write(reinterpret_cast<file_descriptor_impl *>(p));
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error(
        "unknown thespian_file_descriptor_wait_write error");
    return -1;
  }
}

int thespian_file_descriptor_wait_read(thespian_file_descriptor_handle *p) {
  try {
    file_descriptor::wait_read(reinterpret_cast<file_descriptor_impl *>(p));
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_file_descriptor_wait_read error");
    return -1;
  }
}

int thespian_file_descriptor_cancel(thespian_file_descriptor_handle *p) {
  try {
    file_descriptor::cancel(reinterpret_cast<file_descriptor_impl *>(p));
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_file_descriptor_wait_read error");
    return -1;
  }
}

void thespian_file_descriptor_destroy(thespian_file_descriptor_handle *p) {
  try {
    file_descriptor::destroy(reinterpret_cast<file_descriptor_impl *>(p));
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
  } catch (...) {
    thespian_set_last_error("unknown thespian_file_descriptor_destroy error");
  }
}
}
// NOLINTEND(*-reinterpret-cast, *-use-trailing-*)
