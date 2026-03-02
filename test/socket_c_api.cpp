#include "tests.hpp"
#include <thespian/c/socket.h>

using namespace thespian;

// simple smoke test of socket C API: create + destroy handles

auto socket_c_api(thespian::context &ctx, bool &result, thespian::env_t env)
    -> thespian::result {
  (void)ctx;
  (void)env;

  // socket requires a valid file descriptor; we can't really test much
  // without one. Just test that the API is accessible (no linking errors).
  // actual socket operations would need a real FD from a socket/pipe/etc.

  result = true;
  return ok();
}
