#pragma once

#include "cbor.hpp"

#include <cstring>

#if !defined(_WIN32)
#include <netinet/in.h>
#else
#include <in6addr.h>
#endif

namespace cbor {

template <> inline auto buffer::push<in6_addr>(const in6_addr &a) -> buffer & {
  push(std::string_view(reinterpret_cast<const char *>(&a), // NOLINT
                        sizeof(a)));
  return *this;
}

inline auto extract(in6_addr &a) -> cbor::buffer::extractor {
  return [&a](auto &b, const auto &e) {
    std::string_view s;
    auto ret = cbor::extract(s)(b, e);
    if (ret && s.size() == sizeof(in6_addr)) {
      std::memcpy(&a, s.data(), sizeof(in6_addr));
      return true;
    }
    return false;
  };
}

} // namespace cbor
