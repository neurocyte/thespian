const std = @import("std");
const thespian = @import("thespian");
const cbor = @import("cbor");
const framing = @import("remote").framing;
const protocol = @import("remote").protocol;
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
    frame_received: bool = false,

    const Args = struct { allocator: Allocator, io: std.Io };

    fn start(args: Args) result {
        return init(args) catch |e| return thespian.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        const proc = try subprocess.init(
            args.io,
            args.allocator,
            message.fmt(.{build_options.remote_child_path}),
            tag,
            .ignore,
        );
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
                const msg = try protocol.decode(.{ .bytes = frame });
                switch (msg) {
                    .send_named => |s| {
                        try std.testing.expectEqual(protocol.lpiid.fromInt(1), s.from_id);
                        try std.testing.expectEqualStrings("test_actor", s.to_name);
                        try std.testing.expect(try cbor.match(s.payload.bytes, .{ "hello", "from_child" }));
                    },
                    else => return unexpected(thespian.message{ .buf = frame }),
                }
                self.frame_received = true;
            }
        } else if (try m.match(.{ tag, "term", "exited", extract(&exit_code) })) {
            try std.testing.expect(self.frame_received);
            try std.testing.expectEqual(@as(i64, 0), exit_code);
            return thespian.exit("success");
        } else if (try m.match(.{ tag, "stderr", extract(&bytes) })) {
            // ignore stderr from child
        } else {
            return unexpected(m);
        }
    }
};

test "remote: child process sends a message to parent" {
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
        "remote_poc",
        &exit_handler,
        null,
    );

    ctx.run();

    if (!success) return error.TestFailed;
}
