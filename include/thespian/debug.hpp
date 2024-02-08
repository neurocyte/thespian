#pragma once

#include "context.hpp"
#include "handle.hpp"

#include <string>

using port_t = unsigned short;

namespace thespian::debug {

auto enable(context &) -> void;
auto disable(context &) -> void;
auto isenabled(context &) -> bool;

namespace tcp {

auto create(context &, port_t port, const std::string &prompt)
    -> expected<handle, error>;

} // namespace tcp
} // namespace thespian::debug
