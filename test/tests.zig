const std = @import("std");
pub const cpp = @import("tests_cpp.zig");
pub const thespian = @import("tests_thespian.zig");

test {
    std.testing.refAllDecls(@This());
}
