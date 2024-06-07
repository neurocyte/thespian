#pragma once

#if defined(_WIN32)

#include <memory>
#include <string_view>

namespace thespian {

struct file_stream_impl;
using file_stream_dtor = void (*)(file_stream_impl *);
using file_stream_ref = std::unique_ptr<file_stream_impl, file_stream_dtor>;

struct file_stream {
  static auto create(std::string_view tag, void *handle) -> file_stream;
  auto start_read() -> void;
  auto start_write(std::string_view data) -> void;
  auto cancel() -> void;
  static void start_read(file_stream_impl *);
  static void start_write(file_stream_impl *, std::string_view data);
  static void cancel(file_stream_impl *);
  static void destroy(file_stream_impl *);

  //->("stream", tag, "read_complete")
  //->("stream", tag, "read_error", int err, string message)
  //->("stream", tag, "write_complete", int bytes_written)
  //->("stream", tag, "write_error", int err, string message)

  file_stream_ref ref;
};

} // namespace thespian

#endif
