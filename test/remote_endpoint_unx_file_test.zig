const std = @import("std");
const builtin = @import("builtin");
const thespian = @import("thespian");
const cbor = @import("cbor");
const endpoint = @import("remote").endpoint.unx;

const Allocator = std.mem.Allocator;
const result = thespian.result;
const unexpected = thespian.unexpected;
const pid_ref = thespian.pid_ref;
const Receiver = thespian.Receiver;
const message = thespian.message;
const extract = thespian.extract;

fn socket_file_exists(path: [:0]const u8) bool {
    return std.c.access(path, 0) == 0;
}

fn create_stale_socket(path: [:0]const u8) !void {
    var addr: std.c.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = std.c.close(fd);
    if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.un)) != 0) return error.BindFailed;
}

const TestActor = struct {
    allocator: Allocator,
    listener: thespian.pid,
    second_listener: ?thespian.pid = null,
    connector: ?thespian.pid = null,
    conns: [2]?thespian.pid = .{ null, null },
    path: [:0]const u8,
    state: State = .waiting_for_path,
    receiver: Receiver(*@This()),

    const State = enum { waiting_for_path, waiting_for_connections, waiting_for_second_listener, waiting_for_close };

    const Args = struct { allocator: Allocator, path: [:0]const u8 };

    fn start(args: Args) result {
        return init(args) catch |e| return thespian.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        _ = thespian.set_trap(true);
        const listener = try endpoint.listen(args.allocator, args.path, .file, thespian.self_pid().clone());
        try listener.send(.{ "get", "path" });

        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .listener = listener,
            .path = args.path,
            .receiver = .init(receive_fn, deinit, self),
        };
        errdefer self.deinit();
        thespian.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        for (self.conns) |c| if (c) |p| p.deinit();
        if (self.connector) |p| p.deinit();
        if (self.second_listener) |p| p.deinit();
        self.listener.deinit();
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: pid_ref, m: message) result {
        return self.receive(from, m) catch |e| return thespian.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), from: pid_ref, m: message) !void {
        var conn_id: thespian.piid = .empty;
        var reason: []const u8 = "";

        if (try m.match(.{ "path", thespian.any })) {
            if (self.state != .waiting_for_path) return unexpected(m);
            self.connector = try endpoint.connect(self.allocator, self.path, .file, thespian.self_pid().clone());
            self.state = .waiting_for_connections;
        } else if (try m.match(.{ "connected", extract(&conn_id) })) {
            const conn = thespian.pid.from_id(conn_id) orelse return unexpected(m);
            if (self.state != .waiting_for_connections) {
                // the second listener's stale socket probe connects to us
                conn.deinit();
                return;
            }
            if (self.conns[0] == null) {
                self.conns[0] = conn;
            } else {
                self.conns[1] = conn;
                self.second_listener = try endpoint.listen(self.allocator, self.path, .file, thespian.self_pid().clone());
                self.state = .waiting_for_second_listener;
            }
        } else if (try m.match(.{ "exit", extract(&reason) }) or try m.match(.{ "exit", extract(&reason), thespian.more })) {
            if (self.second_listener) |p| if (from.instance_id() == p.instance_id()) {
                if (self.state != .waiting_for_second_listener) return unexpected(m);
                if (std.mem.eql(u8, reason, "normal")) return unexpected(m);
                if (!socket_file_exists(self.path)) return thespian.exit("second listener removed live socket");
                for (self.conns) |c| if (c) |cp| cp.send(.{ "exit", "done" }) catch {};
                try self.listener.send(.{"close"});
                self.state = .waiting_for_close;
                return;
            };
            if (from.instance_id() == self.listener.instance_id()) {
                if (self.state != .waiting_for_close) return unexpected(m);
                if (socket_file_exists(self.path)) return thespian.exit("socket file not removed on close");
                return thespian.exit("success");
            }
            if (std.mem.eql(u8, reason, "normal")) return;
            return unexpected(m);
        } else {
            return unexpected(m);
        }
    }
};

test "remote: unx file endpoint replaces stale socket, keeps live socket, removes on close" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var ctx = try thespian.context.init(allocator, .{});
    defer ctx.deinit();

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "/tmp/thespian_unx_file_test_{d}", .{std.c.getpid()}, 0);
    defer _ = std.c.unlink(path);

    try create_stale_socket(path);
    try std.testing.expect(socket_file_exists(path));

    var status: [64]u8 = undefined;
    var status_len: usize = 0;
    const Status = struct { buf: *[64]u8, len: *usize };
    var exit_handler = thespian.make_exit_handler(Status{ .buf = &status, .len = &status_len }, struct {
        fn handle(s: Status, msg: []const u8) void {
            const n = @min(msg.len, s.buf.len);
            @memcpy(s.buf[0..n], msg[0..n]);
            s.len.* = n;
        }
    }.handle);

    _ = try ctx.spawn_link(
        TestActor.Args{ .allocator = allocator, .path = path },
        TestActor.start,
        "test_actor",
        &exit_handler,
        null,
    );

    ctx.run();

    try std.testing.expectEqualStrings("success", status[0..status_len]);
}
