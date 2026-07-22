const std = @import("std");
pub const cpp = @import("tests_cpp.zig");
pub const thespian = @import("tests_thespian.zig");
pub const ip_tcp_client_server = @import("ip_tcp_client_server.zig");
pub const subprocess_test = @import("subprocess_test.zig");
pub const remote_poc = @import("remote_poc_test.zig");
pub const remote_roundtrip = @import("remote_roundtrip_test.zig");
pub const remote_endpoint = @import("remote_endpoint_test.zig");
pub const remote_endpoint_id = @import("remote_endpoint_id_test.zig");
pub const remote_lifetime = @import("remote_lifetime_test.zig");

test {
    std.testing.refAllDecls(@This());
}
