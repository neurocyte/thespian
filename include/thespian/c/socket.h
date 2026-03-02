#pragma once

// NOLINTBEGIN(modernize-use-trailing-return-type)
#ifdef __cplusplus
extern "C" {
#endif

#include <inttypes.h>
#include <stdint.h>
#include <string.h>

struct thespian_socket_handle;
struct thespian_socket_handle *thespian_socket_create(const char *tag, int fd);
int thespian_socket_write(struct thespian_socket_handle *, const char *data,
                          size_t len);
int thespian_socket_write_binary(struct thespian_socket_handle *,
                                 const uint8_t *data, size_t len);
int thespian_socket_read(struct thespian_socket_handle *);
int thespian_socket_close(struct thespian_socket_handle *);
void thespian_socket_destroy(struct thespian_socket_handle *);

#ifdef __cplusplus
}
#endif
// NOLINTEND(modernize-use-trailing-return-type)
