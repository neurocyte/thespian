const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian.zig");

pid: ?tp.pid,
stdin_behavior: std.ChildProcess.StdIo,

const Self = @This();
pub const max_chunk_size = 4096 - 32;
pub const Writer = std.io.Writer(*Self, error{Exit}, write);
pub const BufferedWriter = std.io.BufferedWriter(max_chunk_size, Writer);

pub fn init(a: std.mem.Allocator, argv: tp.message, tag: [:0]const u8, stdin_behavior: std.ChildProcess.StdIo) !Self {
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
    const pid = if (self.pid) |pid| pid else return tp.exit_error(error.Closed);
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
    child: std.ChildProcess,
    tag: [:0]const u8,
    stdin_buffer: std.ArrayList(u8),
    fd_stdin: ?tp.file_descriptor = null,
    fd_stdout: ?tp.file_descriptor = null,
    fd_stderr: ?tp.file_descriptor = null,
    write_pending: bool = false,
    stdin_close_pending: bool = false,

    const Receiver = tp.Receiver(*Proc);

    fn create(a: std.mem.Allocator, argv: tp.message, tag: [:0]const u8, stdin_behavior: std.ChildProcess.StdIo) !tp.pid {
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

        var child = std.ChildProcess.init(argv_, a);
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
        if (self.fd_stdin) |fd| fd.deinit();
        if (self.fd_stdout) |fd| fd.deinit();
        if (self.fd_stderr) |fd| fd.deinit();
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

        if (self.child.stdin_behavior == .Pipe)
            self.fd_stdin = tp.file_descriptor.init("stdin", self.child.stdin.?.handle) catch |e| return tp.exit_error(e);
        self.fd_stdout = tp.file_descriptor.init("stdout", self.child.stdout.?.handle) catch |e| return tp.exit_error(e);
        self.fd_stderr = tp.file_descriptor.init("stderr", self.child.stderr.?.handle) catch |e| return tp.exit_error(e);
        if (self.fd_stdout) |fd_stdout| fd_stdout.wait_read() catch |e| return tp.exit_error(e);
        if (self.fd_stderr) |fd_stderr| fd_stderr.wait_read() catch |e| return tp.exit_error(e);

        tp.receive(&self.receiver);
    }

    fn receive(self: *Proc, _: tp.pid_ref, m: tp.message) tp.result {
        errdefer self.deinit();
        var bytes: []u8 = "";
        var err: i64 = 0;
        var err_msg: []u8 = "";
        if (try m.match(.{ "fd", "stdout", "read_ready" })) {
            try self.dispatch_stdout();
            if (self.fd_stdout) |fd_stdout| fd_stdout.wait_read() catch |e| return tp.exit_error(e);
        } else if (try m.match(.{ "fd", "stderr", "read_ready" })) {
            try self.dispatch_stderr();
            if (self.fd_stderr) |fd_stderr| fd_stderr.wait_read() catch |e| return tp.exit_error(e);
        } else if (try m.match(.{ "fd", "stdin", "write_ready" })) {
            if (self.stdin_buffer.items.len > 0) {
                if (self.child.stdin) |stdin| {
                    const written = stdin.write(self.stdin_buffer.items) catch |e| switch (e) {
                        error.WouldBlock => {
                            if (self.fd_stdin) |fd_stdin| {
                                fd_stdin.wait_write() catch |e_| return tp.exit_error(e_);
                                self.write_pending = true;
                                return;
                            } else return tp.exit_error(error.WouldBlock);
                        },
                        else => return tp.exit_error(e),
                    };
                    self.write_pending = false;
                    defer {
                        if (self.stdin_close_pending and !self.write_pending)
                            self.stdin_close();
                    }
                    if (written == self.stdin_buffer.items.len) {
                        self.stdin_buffer.clearRetainingCapacity();
                    } else {
                        std.mem.copyForwards(u8, self.stdin_buffer.items, self.stdin_buffer.items[written..]);
                        self.stdin_buffer.items.len = self.stdin_buffer.items.len - written;
                        if (self.fd_stdin) |fd_stdin| {
                            fd_stdin.wait_write() catch |e| return tp.exit_error(e);
                            self.write_pending = true;
                        }
                    }
                }
            }
        } else if (try m.match(.{ "stdin", tp.extract(&bytes) })) {
            if (self.fd_stdin) |fd_stdin| {
                self.stdin_buffer.appendSlice(bytes) catch |e| return tp.exit_error(e);
                fd_stdin.wait_write() catch |e| return tp.exit_error(e);
                self.write_pending = true;
            }
        } else if (try m.match(.{"stdin_close"})) {
            if (self.write_pending) {
                self.stdin_close_pending = true;
            } else {
                self.stdin_close();
            }
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
        } else if (try m.match(.{ "fd", tp.any, "read_error", tp.extract(&err), tp.extract(&err_msg) })) {
            return tp.exit(err_msg);
        }
    }

    fn stdin_close(self: *Proc) void {
        if (self.child.stdin) |*fd| {
            fd.close();
            self.child.stdin = null;
            tp.env.get().trace(tp.message.fmt(.{ self.tag, "stdin", "closed" }).to(tp.message.c_buffer_type));
        }
    }

    fn dispatch_stdout(self: *Proc) tp.result {
        var buffer: [max_chunk_size]u8 = undefined;
        const stdout = self.child.stdout orelse return tp.exit("cannot read closed stdout");
        const bytes = stdout.read(&buffer) catch |e| switch (e) {
            error.WouldBlock => return,
            else => return tp.exit_error(e),
        };
        if (bytes == 0)
            return self.handle_terminate();
        try self.parent.send(.{ self.tag, "stdout", buffer[0..bytes] });
    }

    fn dispatch_stderr(self: *Proc) tp.result {
        var buffer: [max_chunk_size]u8 = undefined;
        const stderr = self.child.stderr orelse return tp.exit("cannot read closed stderr");
        const bytes = stderr.read(&buffer) catch |e| switch (e) {
            error.WouldBlock => return,
            else => return tp.exit_error(e),
        };
        if (bytes == 0)
            return;
        try self.parent.send(.{ self.tag, "stderr", buffer[0..bytes] });
    }

    fn handle_terminate(self: *Proc) tp.result {
        const term = self.child.wait() catch |e| return tp.exit_error(e);
        (switch (term) {
            .Exited => |val| self.parent.send(.{ self.tag, "term", "exited", val }),
            .Signal => |val| self.parent.send(.{ self.tag, "term", "signal", val }),
            .Stopped => |val| self.parent.send(.{ self.tag, "term", "stop", val }),
            .Unknown => |val| self.parent.send(.{ self.tag, "term", "unknown", val }),
        }) catch {};
        return tp.exit_normal();
    }
};
