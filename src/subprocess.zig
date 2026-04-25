const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian.zig");

io: std.Io,
pid: ?tp.pid,
stdin_behavior: StdIo,
write_buf: [max_chunk_size]u8 = undefined,

const Self = @This();
pub const max_chunk_size = 4096 - 32;
pub const StdIo = std.process.SpawnOptions.StdIo;

pub fn init(io: std.Io, a: std.mem.Allocator, argv: tp.message, tag: [:0]const u8, stdin_behavior: StdIo) !Self {
    return .{
        .io = io,
        .pid = try Proc.create(io, a, argv, tag, stdin_behavior),
        .stdin_behavior = stdin_behavior,
    };
}

pub fn deinit(self: *Self) void {
    if (self.pid) |pid| {
        pid.deinit();
        self.pid = null;
    }
}

pub fn write(self: *Self, bytes: []const u8) error{WriteFailed}!usize {
    self.send(bytes) catch return error.WriteFailed;
    return bytes.len;
}

pub const Writer = struct {
    subprocess: *Self,
    interface: std.Io.Writer,
};

pub fn writer(self: *Self, buffer: []u8) Writer {
    return .{
        .subprocess = self,
        .interface = .{
            .vtable = &.{
                .drain = drain,
            },
            .buffer = buffer,
        },
    };
}

fn drain(w: *std.Io.Writer, data_: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const writer_: *Self.Writer = @alignCast(@fieldParentPtr("interface", w));
    var written: usize = 0;
    const buffered = w.buffered();
    if (buffered.len != 0) {
        const n = try writer_.subprocess.write(buffered);
        written += w.consume(n);
    }
    if (data_.len == 0) return written;
    for (data_[0 .. data_.len - 1]) |bytes| {
        written += try writer_.subprocess.write(bytes);
    }
    const pattern_ = data_[data_.len - 1];
    switch (pattern_.len) {
        0 => return written,
        else => for (0..splat) |_| {
            written += try writer_.subprocess.write(pattern_);
        },
    }
    return written;
}

pub fn send(self: *const Self, bytes_: []const u8) tp.result {
    if (self.stdin_behavior != .pipe) return tp.exit("cannot send to closed stdin");
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
    if (self.stdin_behavior == .pipe)
        if (self.pid) |pid| if (!pid.expired()) try pid.send(.{"stdin_close"});
}

pub fn term(self: *Self) tp.result {
    defer self.deinit();
    if (self.pid) |pid| if (!pid.expired()) try pid.send(.{"term"});
}

const Proc = struct {
    a: std.mem.Allocator,
    io: std.Io,
    receiver: Receiver,
    args: std.heap.ArenaAllocator,
    argv: []const []const u8,
    stdin_behavior: StdIo,
    parent: tp.pid,
    child: std.process.Child,
    tag: [:0]const u8,
    stdin_buffer: std.ArrayList(u8),
    fd_stdin: ?tp.file_descriptor = null,
    fd_stdout: ?tp.file_descriptor = null,
    fd_stderr: ?tp.file_descriptor = null,
    write_pending: bool = false,
    stdin_close_pending: bool = false,

    const Receiver = tp.Receiver(*Proc);

    fn create(io: std.Io, a: std.mem.Allocator, argv: tp.message, tag: [:0]const u8, stdin_behavior: StdIo) !tp.pid {
        var args = std.heap.ArenaAllocator.init(a);
        const args_a = args.allocator();
        errdefer args.deinit();

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

        const self: *Proc = try a.create(Proc);
        errdefer a.destroy(self);
        self.* = .{
            .a = a,
            .io = io,
            .receiver = Receiver.init(receive, Proc.deinit, self),
            .args = args,
            .argv = argv_,
            .stdin_behavior = stdin_behavior,
            .parent = tp.self_pid().clone(),
            .child = undefined,
            .tag = try a.dupeZ(u8, tag),
            .stdin_buffer = .empty,
        };
        return tp.spawn_link(a, self, Proc.start, tag);
    }

    fn deinit(self: *Proc) void {
        if (self.fd_stdin) |fd| fd.deinit();
        if (self.fd_stdout) |fd| fd.deinit();
        if (self.fd_stderr) |fd| fd.deinit();
        self.stdin_buffer.deinit(self.a);
        self.parent.deinit();
        self.args.deinit();
        self.a.free(self.tag);
        self.a.destroy(self);
    }

    fn start(self: *Proc) tp.result {
        errdefer self.deinit();

        self.child = std.process.spawn(self.io, .{
            .argv = self.argv,
            .stdin = self.stdin_behavior,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |e| return self.handle_error(e);
        _ = self.args.reset(.free_all);

        if (self.stdin_behavior == .pipe)
            self.fd_stdin = tp.file_descriptor.init("stdin", self.child.stdin.?.handle) catch |e| return self.handle_error(e);
        self.fd_stdout = tp.file_descriptor.init("stdout", self.child.stdout.?.handle) catch |e| return self.handle_error(e);
        self.fd_stderr = tp.file_descriptor.init("stderr", self.child.stderr.?.handle) catch |e| return self.handle_error(e);
        if (self.fd_stdout) |fd_stdout| fd_stdout.wait_read() catch |e| return self.handle_error(e);
        if (self.fd_stderr) |fd_stderr| fd_stderr.wait_read() catch |e| return self.handle_error(e);

        tp.receive(&self.receiver);
    }

    fn receive(self: *Proc, _: tp.pid_ref, m: tp.message) tp.result {
        var bytes: []const u8 = "";
        var err: i64 = 0;
        var err_msg: []const u8 = "";
        if (try m.match(.{ "fd", "stdout", "read_ready" })) {
            try self.dispatch_stdout();
            if (self.fd_stdout) |fd_stdout| fd_stdout.wait_read() catch |e| return self.handle_error(e);
        } else if (try m.match(.{ "fd", "stderr", "read_ready" })) {
            try self.dispatch_stderr();
            if (self.fd_stderr) |fd_stderr| fd_stderr.wait_read() catch |e| return self.handle_error(e);
        } else if (try m.match(.{ "fd", "stdin", "write_ready" })) {
            if (self.stdin_buffer.items.len > 0) {
                if (self.child.stdin) |stdin| {
                    const written = stdin.writeStreaming(self.io, "", &.{self.stdin_buffer.items}, 1) catch |e| switch (e) {
                        error.WouldBlock => {
                            if (self.fd_stdin) |fd_stdin| {
                                fd_stdin.wait_write() catch |e_| return self.handle_error(e_);
                                self.write_pending = true;
                                return;
                            } else return self.handle_error(error.WouldBlock);
                        },
                        else => return self.handle_error(e),
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
                            fd_stdin.wait_write() catch |e| return self.handle_error(e);
                            self.write_pending = true;
                        }
                    }
                }
            }
        } else if (try m.match(.{ "stdin", tp.extract(&bytes) })) {
            if (self.fd_stdin) |fd_stdin| {
                self.stdin_buffer.appendSlice(self.a, bytes) catch |e| return self.handle_error(e);
                fd_stdin.wait_write() catch |e| return self.handle_error(e);
                self.write_pending = true;
            }
        } else if (try m.match(.{"stdin_close"})) {
            if (self.write_pending) {
                self.stdin_close_pending = true;
            } else {
                self.stdin_close();
            }
        } else if (try m.match(.{"stdout_close"})) {
            if (self.child.stdout) |stdout| {
                stdout.close(self.io);
                self.child.stdout = null;
            }
        } else if (try m.match(.{"stderr_close"})) {
            if (self.child.stderr) |stderr| {
                stderr.close(self.io);
                self.child.stderr = null;
            }
        } else if (try m.match(.{"term"})) {
            self.child_sig_term() catch |e| std.debug.panic("child_sig_term: {t}", .{e});
            return self.handle_terminate();
        } else if (try m.match(.{ "fd", tp.any, "read_error", tp.extract(&err), tp.extract(&err_msg) })) {
            try self.parent.send(.{ self.tag, "term", err_msg, 1 });
            return tp.exit_normal();
        }
    }

    fn stdin_close(self: *Proc) void {
        if (self.child.stdin) |stdin| {
            stdin.close(self.io);
            self.child.stdin = null;
            tp.env.get().trace(tp.message.fmt(.{ self.tag, "stdin", "closed" }).to(tp.message.c_buffer_type));
        }
    }

    fn dispatch_stdout(self: *Proc) tp.result {
        var buffer: [max_chunk_size]u8 = undefined;
        const stdout = self.child.stdout orelse return self.handle_error(error.ReadNoStdout);
        const bytes = std.posix.read(stdout.handle, &buffer) catch |e| switch (e) {
            error.WouldBlock => return,
            else => return self.handle_error(e),
        };
        if (bytes == 0)
            return self.handle_terminate();
        try self.parent.send(.{ self.tag, "stdout", buffer[0..bytes] });
    }

    fn dispatch_stderr(self: *Proc) tp.result {
        var buffer: [max_chunk_size]u8 = undefined;
        const stderr = self.child.stderr orelse return self.handle_error(error.ReadNoStderr);
        const bytes = std.posix.read(stderr.handle, &buffer) catch |e| switch (e) {
            error.WouldBlock => return,
            else => return self.handle_error(e),
        };
        if (bytes == 0)
            return;
        try self.parent.send(.{ self.tag, "stderr", buffer[0..bytes] });
    }

    fn handle_terminate(self: *Proc) error{Exit} {
        return self.handle_term(self.child_wait() catch |e| return self.handle_error(e));
    }

    fn handle_term(self: *Proc, term_: std.process.Child.Term) error{Exit} {
        (switch (term_) {
            .exited => |val| self.parent.send(.{ self.tag, "term", "exited", val }),
            .signal => |val| self.parent.send(.{ self.tag, "term", "signal", @intFromEnum(val) }),
            .stopped => |val| self.parent.send(.{ self.tag, "term", "stop", @intFromEnum(val) }),
            .unknown => |val| self.parent.send(.{ self.tag, "term", "unknown", val }),
        }) catch {};
        return tp.exit_normal();
    }

    fn handle_error(self: *Proc, e: anyerror) error{Exit} {
        try self.parent.send(.{ self.tag, "term", e, 1 });
        return tp.exit_normal();
    }

    fn child_sig_term(self: *Proc) !void {
        const pid = self.child.id.?;
        while (true) switch (std.c.errno(std.c.kill(pid, .TERM))) {
            .SUCCESS => return,
            .INTR => {},
            .PERM => return error.PermissionDenied,
            else => |e| std.debug.panic("child_sig_term: ERROR: {t}", .{e}),
        };
    }

    fn child_wait(self: *Proc) error{ WaitChild, Unexpected }!std.process.Child.Term {
        defer self.child_wait_cleanup();
        const pid = self.child.id.?;
        var status: c_int = undefined;
        while (true) switch (std.c.errno(std.c.wait4(pid, &status, 0, null))) {
            .SUCCESS => return std.Io.Threaded.statusToTerm(@bitCast(status)),
            .INTR => {},
            .CHILD => return error.WaitChild,
            else => return error.Unexpected,
        };
    }

    fn child_wait_cleanup(self: *Proc) void {
        if (self.child.stdin) |stdout| {
            stdout.close(self.io);
            self.child.stdout = null;
        }
        if (self.child.stdout) |stdout| {
            stdout.close(self.io);
            self.child.stdout = null;
        }
        if (self.child.stderr) |stdout| {
            stdout.close(self.io);
            self.child.stdout = null;
        }
        self.child.id = null;
    }
};
