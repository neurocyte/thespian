const std = @import("std");
const cbor = @import("cbor");

pub fn write_frame(buf: []u8, value: anytype) ![]u8 {
    if (buf.len < 5) return error.TooShort;

    const payload = buf[5..];
    var writer = std.Io.Writer.fixed(payload);

    try cbor.writeValue(&writer, value);

    const written = writer.end;

    // fixed 32-bit length header
    buf[0] = 0x5a; // cbor.bytes
    std.mem.writeInt(u32, buf[1..5], @as(u32, @intCast(written)), .big);

    return buf[0 .. 5 + written];
}

pub const Accumulator = struct {
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }

    pub fn feed(self: *@This(), allocator: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}!?[]const u8 {
        var iter: []const u8 = self.buf.items;
        var result: []const u8 = undefined;
        if (cbor.matchString(&iter, &result) catch false)
            self.buf.replaceRangeAssumeCapacity(0, @intFromPtr(iter.ptr) - @intFromPtr(self.buf.items.ptr), &.{});
        try self.buf.appendSlice(allocator, bytes);
        iter = self.buf.items;
        return if (cbor.matchString(&iter, &result) catch false) result else null;
    }
};
