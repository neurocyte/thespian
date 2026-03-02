#pragma once

// NOLINTBEGIN(modernize-use-trailing-return-type)
#ifdef __cplusplus
extern "C" {
#endif

#include <inttypes.h>
#include <stdbool.h>

// UNIX-domain socket utilities (acceptors/connectors)

// mode indicates whether the path is a filesystem entry or an abstract socket.
typedef enum thespian_unx_mode {
  THESPIAN_UNX_MODE_FILE = 0,
  THESPIAN_UNX_MODE_ABSTRACT = 1,
} thespian_unx_mode;

struct thespian_unx_acceptor_handle;
struct thespian_unx_acceptor_handle *
thespian_unx_acceptor_create(const char *tag);
int thespian_unx_acceptor_listen(struct thespian_unx_acceptor_handle *,
                                 const char *path, thespian_unx_mode mode);
int thespian_unx_acceptor_close(struct thespian_unx_acceptor_handle *);
void thespian_unx_acceptor_destroy(struct thespian_unx_acceptor_handle *);

struct thespian_unx_connector_handle;
struct thespian_unx_connector_handle *
thespian_unx_connector_create(const char *tag);
int thespian_unx_connector_connect(struct thespian_unx_connector_handle *,
                                   const char *path, thespian_unx_mode mode);
int thespian_unx_connector_cancel(struct thespian_unx_connector_handle *);
void thespian_unx_connector_destroy(struct thespian_unx_connector_handle *);

#ifdef __cplusplus
}
#endif
// NOLINTEND(modernize-use-trailing-return-type)
