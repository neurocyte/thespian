#include "tests.hpp"
#include <netinet/in.h>
#include <thespian/c/tcp.h>

using namespace thespian;

// simple smoke test of tcp C API: create + destroy handles and listen on any
// port

auto tcp_c_api(thespian::context &ctx, bool &result, thespian::env_t env)
    -> thespian::result {
  (void)ctx;
  (void)env;

  struct thespian_tcp_acceptor_handle *a = thespian_tcp_acceptor_create("tag");
  check(a != nullptr);
  uint16_t port = thespian_tcp_acceptor_listen(a, in6addr_any, 0);
  // port may be zero if something went wrong; ignore for smoke.
  (void)port;
  thespian_tcp_acceptor_close(a);
  thespian_tcp_acceptor_destroy(a);

  struct thespian_tcp_connector_handle *c =
      thespian_tcp_connector_create("tag");
  check(c != nullptr);
  // don't attempt to connect, simply exercise create/destroy
  thespian_tcp_connector_destroy(c);

  result = true;
  return ok();
}
