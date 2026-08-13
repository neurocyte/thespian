const std = @import("std");
const builtin = @import("builtin");

pub const start = if (builtin.os.tag == .windows)
    @import("endpoint_stdio_windows.zig").start
else
    @import("endpoint_stdio_posix.zig").start;
