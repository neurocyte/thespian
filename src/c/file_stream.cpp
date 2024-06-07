#if defined(_WIN32)

#include <thespian/c/context.h>
#include <thespian/c/file_stream.h>
#include <thespian/file_stream.hpp>

using thespian::file_stream;
using thespian::file_stream_impl;
using thespian::file_stream_ref;

// NOLINTBEGIN(*-reinterpret-cast, *-use-trailing-*)
extern "C" {

auto thespian_file_stream_create(const char *tag, void *handle)
    -> thespian_file_stream_handle * {
  try {
    auto *p = file_stream::create(tag, handle).ref.release();
    return reinterpret_cast<thespian_file_stream_handle *>(p);
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return nullptr;
  } catch (...) {
    thespian_set_last_error("unknown thespian_file_stream_create error");
    return nullptr;
  }
}

int thespian_file_stream_start_read(thespian_file_stream_handle *p) {
  try {
    file_stream::start_read(reinterpret_cast<file_stream_impl *>(p));
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_file_stream_start_read error");
    return -1;
  }
}

int thespian_file_stream_start_write(thespian_file_stream_handle *p,
                                     const char *data, size_t size) {
  try {
    file_stream::start_write(reinterpret_cast<file_stream_impl *>(p),
                             std::string_view(data, size));
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_file_stream_start_write error");
    return -1;
  }
}

int thespian_file_stream_cancel(thespian_file_stream_handle *p) {
  try {
    file_stream::cancel(reinterpret_cast<file_stream_impl *>(p));
    return 0;
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
    return -1;
  } catch (...) {
    thespian_set_last_error("unknown thespian_file_stream_start_read error");
    return -1;
  }
}

void thespian_file_stream_destroy(thespian_file_stream_handle *p) {
  try {
    file_stream::destroy(reinterpret_cast<file_stream_impl *>(p));
  } catch (const std::exception &e) {
    thespian_set_last_error(e.what());
  } catch (...) {
    thespian_set_last_error("unknown thespian_file_stream_destroy error");
  }
}
}
// NOLINTEND(*-reinterpret-cast, *-use-trailing-*)

#endif
