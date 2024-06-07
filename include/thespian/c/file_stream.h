#pragma once

#include <stdint.h> // NOLINT

#if defined(_WIN32)

// NOLINTBEGIN(modernize-use-trailing-return-type)
#ifdef __cplusplus
extern "C" {
#endif

struct thespian_file_stream_handle;
struct thespian_file_stream_handle *thespian_file_stream_create(const char *tag,
                                                                void *handle);
int thespian_file_stream_start_read(struct thespian_file_stream_handle *);
int thespian_file_stream_start_write(struct thespian_file_stream_handle *,
                                     const char *, size_t);
int thespian_file_stream_cancel(struct thespian_file_stream_handle *);
void thespian_file_stream_destroy(struct thespian_file_stream_handle *);

#ifdef __cplusplus
}
#endif
// NOLINTEND(modernize-use-trailing-return-type)

#endif
