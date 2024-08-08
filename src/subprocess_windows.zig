const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian.zig");

pid: ?tp.pid,
stdin_behavior: std.process.Child.StdIo,

const Self = @This();
pub const max_chunk_size = 4096 - 32;
pub const Writer = std.io.Writer(*Self, error{Exit}, write);
pub const BufferedWriter = std.io.BufferedWriter(max_chunk_size, Writer);

pub fn init(a: std.mem.Allocator, argv: tp.message, tag: [:0]const u8, stdin_behavior: std.process.Child.StdIo) !Self {
    return .{
        .pid = try Proc.create(a, argv, tag, stdin_behavior),
        .stdin_behavior = stdin_behavior,
    };
}

pub fn deinit(self: *Self) void {
    if (self.pid) |pid| {
        pid.deinit();
        self.pid = null;
    }
}

pub fn write(self: *Self, bytes: []const u8) error{Exit}!usize {
    try self.send(bytes);
    return bytes.len;
}

pub fn send(self: *const Self, bytes_: []const u8) tp.result {
    if (self.stdin_behavior != .Pipe) return tp.exit("cannot send to closed stdin");
    const pid = if (self.pid) |pid| pid else return tp.exit_error(error.Closed, null);
    var bytes = bytes_;
    while (bytes.len > 0)
        bytes = loop: {
            if (bytes.len > max_chunk_size) {
                try pid.send(.{ "stdin", bytes[0..max_chunk_size] });
                break :loop bytes[max_chunk_size..];
            } else {
                try pid.send(.{ "stdin", bytes });
                break :loop &[_]u8{};
            }
        };
}

pub fn close(self: *Self) tp.result {
    defer self.deinit();
    if (self.stdin_behavior == .Pipe)
        if (self.pid) |pid| if (!pid.expired()) try pid.send(.{"stdin_close"});
}

pub fn term(self: *Self) tp.result {
    defer self.deinit();
    if (self.pid) |pid| if (!pid.expired()) try pid.send(.{"term"});
}

pub fn writer(self: *Self) Writer {
    return .{ .context = self };
}

pub fn bufferedWriter(self: *Self) BufferedWriter {
    return .{ .unbuffered_writer = self.writer() };
}

const Proc = struct {
    a: std.mem.Allocator,
    receiver: Receiver,
    args: std.heap.ArenaAllocator,
    parent: tp.pid,
    child: std.process.Child,
    tag: [:0]const u8,
    stdin_buffer: std.ArrayList(u8),
    stream_stdout: ?tp.file_stream = null,
    stream_stderr: ?tp.file_stream = null,

    const Receiver = tp.Receiver(*Proc);

    fn create(a: std.mem.Allocator, argv: tp.message, tag: [:0]const u8, stdin_behavior: std.process.Child.StdIo) !tp.pid {
        const self: *Proc = try a.create(Proc);

        var args = std.heap.ArenaAllocator.init(a);
        const args_a = args.allocator();
        var iter = argv.buf;
        var len = cbor.decodeArrayHeader(&iter) catch return error.InvalidArgument;
        var argv_ = try args_a.alloc([]const u8, len);
        var arg: []const u8 = undefined;
        var i: usize = 0;
        while (len > 0) : (len -= 1) {
            if (!(cbor.matchString(&iter, &arg) catch return error.InvalidArgument))
                return error.InvalidArgument;
            argv_[i] = try args_a.dupe(u8, arg);
            i += 1;
        }

        var child = std.process.Child.init(argv_, a);
        child.stdin_behavior = stdin_behavior;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        self.* = .{
            .a = a,
            .receiver = Receiver.init(receive, self),
            .args = args,
            .parent = tp.self_pid().clone(),
            .child = child,
            .tag = try a.dupeZ(u8, tag),
            .stdin_buffer = std.ArrayList(u8).init(a),
        };
        return tp.spawn_link(a, self, Proc.start, tag);
    }

    fn deinit(self: *Proc) void {
        self.args.deinit();
        if (self.stream_stdout) |stream| stream.deinit();
        if (self.stream_stderr) |stream| stream.deinit();
        self.stdin_buffer.deinit();
        self.parent.deinit();
        self.a.free(self.tag);
    }

    fn start(self: *Proc) tp.result {
        errdefer self.deinit();

        self.child.spawn() catch |e| {
            try self.parent.send(.{ self.tag, "term", e, 1 });
            return tp.exit_normal();
        };
        _ = self.args.reset(.free_all);

        self.stream_stdout = tp.file_stream.init("stdout", self.child.stdout.?.handle) catch |e| return tp.exit_error(e, @errorReturnTrace());
        self.stream_stderr = tp.file_stream.init("stderr", self.child.stderr.?.handle) catch |e| return tp.exit_error(e, @errorReturnTrace());
        if (self.stream_stdout) |stream| stream.start_read() catch |e| return tp.exit_error(e, @errorReturnTrace());
        if (self.stream_stderr) |stream| stream.start_read() catch |e| return tp.exit_error(e, @errorReturnTrace());

        tp.receive(&self.receiver);
    }

    fn receive(self: *Proc, _: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();
        var bytes: []u8 = "";
        var stream_name: []u8 = "";
        var err: i64 = 0;
        var err_msg: []u8 = "";
        if (try m.match(.{ "stream", "stdout", "read_complete", tp.extract(&bytes) })) {
            try self.dispatch_stdout(bytes);
            if (self.stream_stdout) |stream| stream.start_read() catch |e| return tp.exit_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "stream", "stderr", "read_complete", tp.extract(&bytes) })) {
            try self.dispatch_stderr(bytes);
            if (self.stream_stderr) |stream| stream.start_read() catch |e| return tp.exit_error(e, @errorReturnTrace());
        } else if (try m.match(.{ "stdin", tp.extract(&bytes) })) {
            try self.start_write(bytes);
        } else if (try m.match(.{"stdin_close"})) {
            self.stdin_close();
        } else if (try m.match(.{"stdout_close"})) {
            if (self.child.stdout) |*fd| {
                fd.close();
                self.child.stdout = null;
            }
        } else if (try m.match(.{"stderr_close"})) {
            if (self.child.stderr) |*fd| {
                fd.close();
                self.child.stderr = null;
            }
        } else if (try m.match(.{"term"})) {
            const term_ = self.child.kill() catch |e| return tp.exit_error(e, @errorReturnTrace());
            return self.handle_term(term_);
        } else if (try m.match(.{ "stream", "stdout", "read_error", 109, tp.extract(&err_msg) })) {
            // stdout closed
            self.child.stdout = null;
            return self.handle_terminate();
        } else if (try m.match(.{ "stream", "stderr", "read_error", 109, tp.extract(&err_msg) })) {
            // stderr closed
            self.child.stderr = null;
        } else if (try m.match(.{ "stream", tp.extract(&stream_name), "read_error", tp.extract(&err), tp.extract(&err_msg) })) {
            return tp.exit_fmt("{s} read_error: {s}", .{ stream_name, err_msg });
        }
    }

    fn start_write(self: *Proc, bytes: []const u8) tp.result {
        if (self.child.stdin) |stdin|
            stdin.writeAll(bytes) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn stdin_close(self: *Proc) void {
        if (self.child.stdin) |*fd| {
            fd.close();
            self.child.stdin = null;
            tp.env.get().trace(tp.message.fmt(.{ self.tag, "stdin", "closed" }).to(tp.message.c_buffer_type));
        }
    }

    fn dispatch_stdout(self: *Proc, bytes: []const u8) tp.result {
        if (bytes.len == 0)
            return self.handle_terminate();
        try self.parent.send(.{ self.tag, "stdout", bytes });
    }

    fn dispatch_stderr(self: *Proc, bytes: []const u8) tp.result {
        if (bytes.len == 0)
            return;
        try self.parent.send(.{ self.tag, "stderr", bytes });
    }

    fn handle_terminate(self: *Proc) tp.result {
        return self.handle_term(self.child.wait() catch |e| return tp.exit_error(e, @errorReturnTrace()));
    }

    fn handle_term(self: *Proc, term_: std.process.Child.Term) tp.result {
        (switch (term_) {
            .Exited => |val| self.parent.send(.{ self.tag, "term", "exited", val }),
            .Signal => |val| self.parent.send(.{ self.tag, "term", "signal", val }),
            .Stopped => |val| self.parent.send(.{ self.tag, "term", "stop", val }),
            .Unknown => |val| self.parent.send(.{ self.tag, "term", "unknown", val }),
        }) catch {};
        return tp.exit_normal();
    }
};
