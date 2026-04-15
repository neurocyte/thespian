#pragma once

// NOLINTBEGIN(modernize-use-trailing-return-type)
#ifdef __cplusplus
extern "C" {
#endif

#include <inttypes.h>
#if defined(_WIN32)
#include <ws2tcpip.h>
#else
#include <netinet/in.h>
#endif
#include <stdint.h>

struct thespian_tcp_acceptor_handle;
struct thespian_tcp_acceptor_handle *
thespian_tcp_acceptor_create(const char *tag);
uint16_t thespian_tcp_acceptor_listen(struct thespian_tcp_acceptor_handle *,
                                      struct in6_addr ip, uint16_t port);
int thespian_tcp_acceptor_close(struct thespian_tcp_acceptor_handle *);
void thespian_tcp_acceptor_destroy(struct thespian_tcp_acceptor_handle *);

struct thespian_tcp_connector_handle;
struct thespian_tcp_connector_handle *
thespian_tcp_connector_create(const char *tag);
int thespian_tcp_connector_connect(struct thespian_tcp_connector_handle *,
                                   struct in6_addr ip, uint16_t port);
int thespian_tcp_connector_cancel(struct thespian_tcp_connector_handle *);
void thespian_tcp_connector_destroy(struct thespian_tcp_connector_handle *);

#ifdef __cplusplus
}
#endif
// NOLINTEND(modernize-use-trailing-return-type)
