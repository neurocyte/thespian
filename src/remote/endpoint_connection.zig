const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");

const tag = "EPCON";

/// Spawns an unlinked connection endpoint actor around `fd`. Unlinked
/// so a connection's exit does not kill the listener/connector that
/// spawned it; the owning actor is expected to manage the connection's
/// lifecycle via `.send(.{"exit", reason})` or transport events.
pub fn start(allocator: std.mem.Allocator, fd: i32) error{ OutOfMemory, ThespianSpawnFailed }!tp.pid {
    return tp.spawn(
        allocator,
        Connection.Args{
            .allocator = allocator,
            .fd = fd,
        },
        Connection.start,
        @typeName(@This()),
    );
}

const Connection = struct {
    sock: tp.socket,
    endpoint: @import("endpoint_common.zig").create(@This()),
    receiver: tp.Receiver(*@This()),

    const Args = struct {
        allocator: std.mem.Allocator,
        fd: i32,
    };

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        const sock = try tp.socket.init(tag, args.fd);
        const self = try args.allocator.create(@This());
        self.* = .{
            .sock = sock,
            .endpoint = .init(args.allocator),
            .receiver = .init(receive, deinit, self),
        };
        errdefer self.deinit();

        _ = tp.set_trap(true);
        try self.sock.read();
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        const allocator = self.endpoint.allocator;
        self.endpoint.deinit();
        self.sock.deinit();
        allocator.destroy(self);
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive_safe(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive_safe(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        var bytes: []const u8 = "";
        var reason: []const u8 = "";

        if (try m.match(.{ "socket", tag, "read_complete", tp.extract(&bytes) })) {
            if (bytes.len == 0) {
                try self.endpoint.send_transport_error("peer_closed");
                return tp.exit("peer_closed");
            }
            try self.endpoint.feed(bytes);
            try self.sock.read();
        } else if (try m.match(.{ "socket", tag, "write_complete", tp.any })) {
            return;
        } else if (try m.match(.{ "socket", tag, "read_error", tp.any, tp.extract(&reason) })) {
            try self.endpoint.send_transport_error(reason);
            return tp.exit(reason);
        } else if (try m.match(.{ "socket", tag, "write_error", tp.any, tp.extract(&reason) })) {
            try self.endpoint.send_transport_error(reason);
            return tp.exit(reason);
        } else if (try m.match(.{ "socket", tag, "closed" })) {
            return tp.exit("transport_closed");
        } else if (try m.match(.{ "exit", tp.extract(&reason) })) {
            self.sock.close() catch {};
            return tp.exit(reason);
        } else {
            return self.endpoint.receive(from, m);
        }
    }

    pub fn send_frame(self: *@This(), frame: []const u8) !void {
        try self.sock.write_binary(frame);
    }
};
