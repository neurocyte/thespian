const std = @import("std");
pub const cpp = @import("tests_cpp.zig");
pub const thespian = @import("tests_thespian.zig");
pub const ip_tcp_client_server = @import("ip_tcp_client_server.zig");
pub const subprocess_test = @import("subprocess_test.zig");

test {
    std.testing.refAllDecls(@This());
}
