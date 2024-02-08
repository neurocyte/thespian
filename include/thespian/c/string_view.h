#pragma once

// NOLINTBEGIN(modernize-*, hicpp-*)
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct c_string_view_t {
  const char *base;
  size_t len;
};
typedef struct c_string_view_t c_string_view;

#ifdef __cplusplus
}
#endif
// NOLINTEND(modernize-*, hicpp-*)
