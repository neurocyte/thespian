const std = @import("std");
const c = @import("c");

fn testcase(name: [*c]const u8) !void {
    const result = c.runtestcase(name);
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "cbor_match" {
    try testcase("cbor_match");
}

test "debug" {
    try testcase("debug");
}

test "debug_json" {
    try testcase("debug_json");
}

test "debug_unx" {
    try testcase("debug_unx");
}

test "endpoint_unx" {
    try testcase("endpoint_unx");
}

test "endpoint_tcp" {
    try testcase("endpoint_tcp");
}

test "hub_filter" {
    try testcase("hub_filter");
}

test "ip_tcp_client_server" {
    try testcase("ip_tcp_client_server");
}

test "ip_tcp_client_server_c" {
    try testcase("ip_tcp_client_server_c");
}

test "ip_udp_echo" {
    try testcase("ip_udp_echo");
}

test "metronome_test" {
    try testcase("metronome_test");
}

test "perf_cbor" {
    try testcase("perf_cbor");
}

test "perf_hub" {
    try testcase("perf_hub");
}

test "perf_ring" {
    try testcase("perf_ring");
}

test "perf_spawn" {
    try testcase("perf_spawn");
}

test "socket_owner_exit" {
    try testcase("socket_owner_exit");
}

test "spawn_exit" {
    try testcase("spawn_exit");
}

test "timeout_test" {
    try testcase("timeout_test");
}

