const std = @import("std");
const cbor = @import("cbor");
const framing = @import("remote").framing;
const protocol = @import("remote").protocol;

pub fn main(init: std.process.Init) !void {
    var msg_buf: [256]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&msg_buf);
    try cbor.writeValue(&stream, .{ "send_named", protocol.lpiid.fromInt(1), "test_actor", .{ "hello", "from_child" } });
    const payload = stream.buffered();

    var stdout_buf: [framing.max_frame_size + 4]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(init.io, &stdout_buf);
    try framing.write_frame(&stdout_w.interface, payload);
    try stdout_w.interface.flush();
}
