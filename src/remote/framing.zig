const std = @import("std");
const cbor = @import("cbor");

pub const max_frame_size = 16 * 1024;

pub fn write_frame(writer: *std.Io.Writer, payload: []const u8) !void {
    try cbor.writeValue(writer, payload);
}

pub const Accumulator = struct {
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }

    pub fn feed(self: *@This(), allocator: std.mem.Allocator, bytes: []const u8) ?[]const u8 {
        var iter: []const u8 = self.buf.items;
        var result: []const u8 = undefined;
        if (cbor.matchString(&iter, &result) catch false)
            self.buf.replaceRangeAssumeCapacity(0, @intFromPtr(iter.ptr) - @intFromPtr(self.buf.items.ptr), &.{});
        self.buf.appendSlice(allocator, bytes) catch return null;
        iter = self.buf.items;
        return if (cbor.matchString(&iter, &result) catch false) result else null;
    }
};
