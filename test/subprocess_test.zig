const std = @import("std");
const builtin = @import("builtin");
const thespian = @import("thespian");

const Allocator = std.mem.Allocator;
const result = thespian.result;
const exit_error = thespian.exit_error;
const unexpected = thespian.unexpected;
const pid_ref = thespian.pid_ref;
const Receiver = thespian.Receiver;
const message = thespian.message;
const extract = thespian.extract;

const subprocess = thespian.subprocess;

const Runner = struct {
    allocator: Allocator,
    io: std.Io,
    proc: subprocess,
    output: std.ArrayList(u8),
    receiver: Receiver(*@This()),

    const Args = struct { allocator: Allocator, io: std.Io };

    fn start(args: Args) result {
        return init(args) catch |e| exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        const argv = if (builtin.os.tag == .windows)
            message.fmt(.{ "cmd", "/c", "echo hello" })
        else
            message.fmt(.{ "echo", "hello" });

        const proc = try subprocess.init(args.io, args.allocator, argv, "echo", .ignore);
        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .io = args.io,
            .proc = proc,
            .output = .empty,
            .receiver = .init(receive_fn, deinit, self),
        };
        thespian.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.proc.deinit();
        self.output.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: pid_ref, m: message) result {
        return self.receive(from, m) catch |e| exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), _: pid_ref, m: message) !void {
        var buf: []const u8 = "";
        var exit_code: i64 = 0;
        if (try m.match(.{ "echo", "stdout", extract(&buf) })) {
            try self.output.appendSlice(self.allocator, buf);
        } else if (try m.match(.{ "echo", "term", "exited", extract(&exit_code) })) {
            const trimmed = std.mem.trimEnd(u8, self.output.items, "\r\n");
            try std.testing.expectEqualStrings("hello", trimmed);
            try std.testing.expectEqual(@as(i64, 0), exit_code);
            return thespian.exit("success");
        } else if (try m.match(.{ "echo", "term", extract(&buf), extract(&exit_code) })) {
            std.log.err("subprocess terminated unexpectedly: {s} ({})", .{ buf, exit_code });
            return error.SubprocessFailed;
        } else {
            return unexpected(m);
        }
    }
};

const WriterRunner = struct {
    allocator: Allocator,
    io: std.Io,
    proc: subprocess,
    output: std.ArrayList(u8),
    receiver: Receiver(*@This()),

    const tag = "writer_test";
    const input = "hello from writer";

    const Args = struct { allocator: Allocator, io: std.Io };

    fn start(args: Args) result {
        return init(args) catch |e| exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        // Use a process that echoes stdin to stdout:
        //   Unix: cat
        //   Windows: cmd /c sort (reads all stdin, outputs sorted; single line = identity)
        const argv = if (builtin.os.tag == .windows)
            message.fmt(.{ "cmd", "/c", "sort" })
        else
            message.fmt(.{"cat"});

        const proc = try subprocess.init(args.io, args.allocator, argv, tag, .pipe);
        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .io = args.io,
            .proc = proc,
            .output = .empty,
            .receiver = .init(receive_fn, deinit, self),
        };

        var write_buf: [subprocess.max_chunk_size]u8 = undefined;
        var w = self.proc.writer(&write_buf);
        try w.interface.writeAll(input ++ "\n");
        try w.interface.flush();
        try self.proc.close();

        thespian.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.proc.deinit();
        self.output.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: pid_ref, m: message) result {
        return self.receive(from, m) catch |e| exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), _: pid_ref, m: message) !void {
        var buf: []const u8 = "";
        var exit_code: i64 = 0;
        if (try m.match(.{ tag, "stdout", extract(&buf) })) {
            try self.output.appendSlice(self.allocator, buf);
        } else if (try m.match(.{ tag, "term", "exited", extract(&exit_code) })) {
            const trimmed = std.mem.trimEnd(u8, self.output.items, "\r\n");
            try std.testing.expectEqualStrings(input, trimmed);
            try std.testing.expectEqual(@as(i64, 0), exit_code);
            return thespian.exit("success");
        } else if (try m.match(.{ tag, "term", extract(&buf), extract(&exit_code) })) {
            std.log.err("subprocess terminated unexpectedly: {s} ({})", .{ buf, exit_code });
            return error.SubprocessFailed;
        } else {
            return unexpected(m);
        }
    }
};

test "subprocess writer" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var ctx = try thespian.context.init(allocator);
    defer ctx.deinit();

    var success = false;

    var exit_handler = thespian.make_exit_handler(&success, struct {
        fn handle(ok: *bool, status: []const u8) void {
            if (std.mem.eql(u8, status, "success")) ok.* = true;
        }
    }.handle);

    _ = try ctx.spawn_link(
        WriterRunner.Args{ .allocator = allocator, .io = io },
        WriterRunner.start,
        "subprocess_writer",
        &exit_handler,
        null,
    );

    ctx.run();

    if (!success) return error.TestFailed;
}

test "subprocess echo" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var ctx = try thespian.context.init(allocator);
    defer ctx.deinit();

    var success = false;

    var exit_handler = thespian.make_exit_handler(&success, struct {
        fn handle(ok: *bool, status: []const u8) void {
            if (std.mem.eql(u8, status, "success")) ok.* = true;
        }
    }.handle);

    _ = try ctx.spawn_link(
        Runner.Args{ .allocator = allocator, .io = io },
        Runner.start,
        "subprocess_echo",
        &exit_handler,
        null,
    );

    ctx.run();

    if (!success) return error.TestFailed;
}
