const std = @import("std");
const thespian = @import("thespian");
const cbor = @import("cbor");
const framing = @import("remote").framing;
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const result = thespian.result;
const unexpected = thespian.unexpected;
const pid_ref = thespian.pid_ref;
const Receiver = thespian.Receiver;
const message = thespian.message;
const extract = thespian.extract;
const subprocess = thespian.subprocess;

const tag = "subprocess";

const Parent = struct {
    allocator: Allocator,
    proc: subprocess,
    accumulator: framing.Accumulator,
    receiver: Receiver(*@This()),
    pong_received: bool = false,

    const Args = struct { allocator: Allocator, io: std.Io };

    fn start(args: Args) result {
        return init(args) catch |e| return thespian.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        var proc = try subprocess.init(
            args.io,
            args.allocator,
            message.fmt(.{build_options.remote_child_roundtrip_path}),
            tag,
            .pipe,
        );

        var frame_buf: [68]u8 = undefined;
        const frame = try framing.write_frame(&frame_buf, .{"ping"});
        try proc.send(frame);
        try proc.close();

        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .proc = proc,
            .accumulator = .{},
            .receiver = .init(receive_fn, deinit, self),
        };
        errdefer self.deinit();
        thespian.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.accumulator.deinit(self.allocator);
        self.proc.deinit();
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: pid_ref, m: message) result {
        return self.receive(from, m) catch |e| return thespian.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), _: pid_ref, m: message) !void {
        var bytes: []const u8 = "";
        var exit_code: i64 = 0;

        if (try m.match(.{ tag, "stdout", extract(&bytes) })) {
            if (self.accumulator.feed(self.allocator, bytes)) |frame| {
                try std.testing.expect(try cbor.match(frame, .{"pong"}));
                self.pong_received = true;
            }
        } else if (try m.match(.{ tag, "term", "exited", extract(&exit_code) })) {
            try std.testing.expect(self.pong_received);
            try std.testing.expectEqual(@as(i64, 0), exit_code);
            return thespian.exit("success");
        } else if (try m.match(.{ tag, "stderr", extract(&bytes) })) {
            // ignore stderr from child
        } else {
            return unexpected(m);
        }
    }
};

test "remote: round-trip ping/pong between parent and child" {
    const allocator = std.testing.allocator;
    var ctx = try thespian.context.init(allocator, .{});
    defer ctx.deinit();

    var success = false;
    var exit_handler = thespian.make_exit_handler(&success, struct {
        fn handle(ok: *bool, status: []const u8) void {
            ok.* = std.mem.eql(u8, status, "success");
        }
    }.handle);

    _ = try ctx.spawn_link(
        Parent.Args{ .allocator = allocator, .io = std.testing.io },
        Parent.start,
        "remote_roundtrip",
        &exit_handler,
        null,
    );

    ctx.run();

    if (!success) return error.TestFailed;
}
