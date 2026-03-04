#pragma once

#include <thespian/context.hpp>
#include <thespian/env.hpp>

#include <cstdlib>

constexpr auto check(bool expression) -> void {
  if (!expression)
    std::abort();
}

using testcase = auto(thespian::context &ctx, bool &result, thespian::env_t env)
    -> thespian::result;

testcase cbor_match;
testcase debug;
testcase endpoint_tcp;
testcase endpoint_unx;
testcase hub_filter;
testcase ip_tcp_client_server;
testcase ip_udp_echo;
testcase metronome_test;
testcase perf_cbor;
testcase perf_hub;
testcase perf_ring;
testcase perf_spawn;
testcase spawn_exit;
testcase timeout_test;
