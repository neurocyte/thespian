const std = @import("std");
const tp = @import("thespian");

pub fn start(io: std.Io, allocator: std.mem.Allocator) error{ OutOfMemory, ThespianSpawnFailed }!tp.pid {
    return tp.spawn_link(
        allocator,
        Process.Args{
            .io = io,
            .allocator = allocator,
        },
        Process.start,
        @typeName(@This()),
    );
}

const Process = struct {
    io: std.Io,
    fd_stdin: tp.file_descriptor,
    read_buf: [4096]u8 = undefined,
    endpoint: @import("endpoint_common.zig").create(@This()),
    receiver: tp.Receiver(*@This()),

    const Args = struct {
        io: std.Io,
        allocator: std.mem.Allocator,
    };

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        const fd_stdin = try tp.file_descriptor.init("stdin", 0);
        var fd_owned = true;
        errdefer if (fd_owned) fd_stdin.deinit();
        const self = try args.allocator.create(@This());
        self.* = .{
            .io = args.io,
            .fd_stdin = fd_stdin,
            .endpoint = .init(args.allocator),
            .receiver = .init(receive, deinit, self),
        };
        fd_owned = false;
        errdefer self.deinit();

        _ = tp.set_trap(true);
        try self.fd_stdin.wait_read();
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        const allocator = self.endpoint.allocator;
        self.endpoint.deinit();
        self.fd_stdin.deinit();
        allocator.destroy(self);
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive_safe(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive_safe(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        if (try m.match(.{ "fd", "stdin", "read_ready" })) {
            try self.dispatch_stdin();
            try self.fd_stdin.wait_read();
        } else if (try m.match(.{ "fd", "stdin", "read_error", tp.any, tp.any })) {
            try self.endpoint.send_transport_error("stdin_closed");
            return tp.exit("stdin_closed");
        } else {
            return self.endpoint.receive(from, m);
        }
    }

    fn dispatch_stdin(self: *@This()) !void {
        const n = std.Io.File.stdin().readStreaming(self.io, &.{&self.read_buf}) catch |e| switch (e) {
            error.WouldBlock => return,
            error.EndOfStream => 0,
            else => return tp.exit_error(e, @errorReturnTrace()),
        };
        if (n == 0) {
            try self.endpoint.send_transport_error("stdin_closed");
            return tp.exit("stdin_closed");
        }
        try self.endpoint.feed(self.read_buf[0..n]);
    }

    pub fn send_frame(self: *@This(), frame: []const u8) !void {
        try std.Io.File.stdout().writeStreamingAll(self.io, frame);
    }
};
