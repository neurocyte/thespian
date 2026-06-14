pub fn Tagged(T: type, tag: []const u8) type {
    return enum(T) {
        _,

        pub const TAG = tag;

        pub const empty: @This() = @enumFromInt(0);

        pub fn cborEncode(self: @This(), writer: *Writer) Writer.Error!void {
            const value: T = @intFromEnum(self);
            try cbor.writeValue(writer, .{ TAG, value });
        }

        pub fn cborExtract(self: *@This(), iter: *[]const u8) cbor.Error!bool {
            var value: T = 0;
            if (try cbor.matchValue(iter, .{ TAG, cbor.extract(&value) })) {
                self.* = @enumFromInt(value);
                return true;
            }
            return false;
        }

        pub fn format(self: @This(), writer: *Writer) !void {
            return writer.print("{s}:{d}", .{ TAG, @intFromEnum(self) });
        }

        pub fn fromInt(v: T) @This() {
            return @enumFromInt(v);
        }

        pub fn toInt(v: @This()) T {
            return @intFromEnum(v);
        }
    };
}

pub fn TaggedPtr(tag: []const u8) type {
    return enum(usize) {
        _,

        pub const T = usize;
        pub const TAG = tag;

        pub const empty: @This() = @enumFromInt(0);

        pub fn cborEncode(self: @This(), writer: *Writer) Writer.Error!void {
            const value: T = @intFromEnum(self);
            try cbor.writeValue(writer, .{ TAG, value });
        }

        pub fn cborExtract(self: *@This(), iter: *[]const u8) cbor.Error!bool {
            var value: T = 0;
            if (try cbor.matchValue(iter, .{ TAG, cbor.extract(&value) })) {
                self.* = @enumFromInt(value);
                return true;
            }
            return false;
        }

        pub fn format(self: @This(), writer: *Writer) !void {
            return writer.print("{s}:0x{x}", .{ TAG, @intFromEnum(self) });
        }

        pub fn fromPtr(p: anytype) @This() {
            return @enumFromInt(@intFromPtr(p));
        }

        pub fn toInt(v: @This()) T {
            return @intFromEnum(v);
        }
    };
}

const Writer = @import("std").Io.Writer;
const cbor = @import("cbor");
