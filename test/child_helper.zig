const std = @import("std");
const builtin = @import("builtin");

pub const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    comptime name: []const u8,
    fallback: []const u8,
) ![]u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = std.process.executableDirPath(io, &dir_buf) catch
        return allocator.dupe(u8, fallback);
    const dir = dir_buf[0..dir_len];
    const sep: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";
    const sibling = try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ dir, sep, name, exe_suffix });
    errdefer allocator.free(sibling);
    std.Io.Dir.cwd().access(io, sibling, .{}) catch {
        allocator.free(sibling);
        return allocator.dupe(u8, fallback);
    };
    return sibling;
}
