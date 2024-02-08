#pragma once

#include "handle.hpp"
#include "tcp.hpp"
#include "unx.hpp"
#include <chrono>
#include <string>

using port_t = unsigned short;

namespace thespian::endpoint {

using namespace std::chrono_literals;

namespace tcp {

auto listen(in6_addr, port_t) -> expected<handle, error>;
auto connect(in6_addr, port_t, std::chrono::milliseconds retry_time = 50ms,
             size_t retry_count = 5) -> expected<handle, error>;

} // namespace tcp

namespace unx {
using thespian::unx::mode;

auto listen(std::string_view, mode = mode::abstract) -> expected<handle, error>;
auto connect(std::string_view, mode = mode::abstract,
             std::chrono::milliseconds retry_time = 50ms,
             size_t retry_count = 5) -> expected<handle, error>;

} // namespace unx

} // namespace thespian::endpoint
