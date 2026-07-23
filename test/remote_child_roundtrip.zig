const std = @import("std");
const cbor = @import("cbor");
const framing = @import("remote").framing;

pub fn main(init: std.process.Init) !void {
    var acc: framing.Accumulator = .{};
    defer acc.deinit(init.gpa);

    var stdin_reader_buf: [4096]u8 = undefined;
    var stdin_r = std.Io.File.stdin().reader(init.io, &stdin_reader_buf);
    var read_buf: [4096]u8 = undefined;

    const frame = while (true) {
        const n = try stdin_r.interface.readSliceShort(&read_buf);
        if (n == 0) return error.UnexpectedEof;
        if (acc.feed(init.gpa, read_buf[0..n])) |f| break f;
    };

    if (!try cbor.match(frame, .{"ping"})) return error.UnexpectedMessage;

    var msg_buf: [64]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(init.io, &stdout_buf);
    try stdout_w.interface.writeAll(try framing.write_frame(&msg_buf, .{"pong"}));
    try stdout_w.interface.flush();
}
