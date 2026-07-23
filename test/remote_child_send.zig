const std = @import("std");
const cbor = @import("cbor");
const framing = @import("remote").framing;
const protocol = @import("remote").protocol;

pub fn main(init: std.process.Init) !void {
    var msg_buf: [256]u8 = undefined;
    const payload = try framing.write_frame(&msg_buf, .{ "send_named", protocol.lpiid.fromInt(1), "test_actor", .{ "hello", "from_child" } });

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(init.io, &stdout_buf);
    try stdout_w.interface.writeAll(payload);
    try stdout_w.interface.flush();
}
