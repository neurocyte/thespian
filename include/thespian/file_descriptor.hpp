#pragma once

#if !defined(_WIN32)

#include <memory>
#include <string_view>

namespace thespian {

struct file_descriptor_impl;
using file_descriptor_dtor = void (*)(file_descriptor_impl *);
using file_descriptor_ref =
    std::unique_ptr<file_descriptor_impl, file_descriptor_dtor>;

struct file_descriptor {
  static auto create(std::string_view tag, int fd) -> file_descriptor;
  auto wait_write() -> void;
  auto wait_read() -> void;
  auto cancel() -> void;
  static void wait_write(file_descriptor_impl *);
  static void wait_read(file_descriptor_impl *);
  static void cancel(file_descriptor_impl *);
  static void destroy(file_descriptor_impl *);

  //->("fd", tag, "write_ready")
  //->("fd", tag, "write_error", int err, string message)
  //->("fd", tag, "read_ready")
  //->("fd", tag, "read_error", int err, string message)

  file_descriptor_ref ref;
};

} // namespace thespian

#endif
