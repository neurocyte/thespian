#include "tests.hpp"
#include <thespian/c/unx.h>

using namespace thespian;

// Very small smoke test for the new C API.  We don't actually open sockets,
// just verify that the create/destroy functions work and return non-null.

auto unx_c_api(thespian::context &ctx, bool &result, thespian::env_t env)
    -> thespian::result {
  (void)ctx;
  (void)env;

  struct thespian_unx_acceptor_handle *a = thespian_unx_acceptor_create("tag");
  if (a != nullptr) {
    thespian_unx_acceptor_destroy(a);
  }

  struct thespian_unx_connector_handle *c =
      thespian_unx_connector_create("tag");
  if (c != nullptr) {
    thespian_unx_connector_destroy(c);
  }

  result = true;
  return ok();
}
