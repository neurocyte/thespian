const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");

const endpoint_connection = @import("endpoint_connection.zig");

const acceptor_tag = "EPTCP_L";
const connector_tag = "EPTCP_c";

pub fn listen(
    allocator: std.mem.Allocator,
    ip: tp.in6_addr,
    port: u16,
    owner: tp.pid,
) error{ OutOfMemory, ThespianSpawnFailed }!tp.pid {
    errdefer owner.deinit();
    return tp.spawn_link(
        allocator,
        Listener.Args{
            .allocator = allocator,
            .ip = ip,
            .port = port,
            .owner = owner,
        },
        Listener.start,
        @typeName(@This()) ++ ".listen",
    );
}

pub fn connect(
    allocator: std.mem.Allocator,
    ip: tp.in6_addr,
    port: u16,
    owner: tp.pid,
) error{ OutOfMemory, ThespianSpawnFailed }!tp.pid {
    errdefer owner.deinit();
    return tp.spawn_link(
        allocator,
        Connector.Args{
            .allocator = allocator,
            .ip = ip,
            .port = port,
            .owner = owner,
        },
        Connector.start,
        @typeName(@This()) ++ ".connect",
    );
}

const Listener = struct {
    allocator: std.mem.Allocator,
    acceptor: tp.tcp_acceptor,
    owner: tp.pid,
    port: u16 = 0,
    receiver: tp.Receiver(*@This()),

    const Args = struct {
        allocator: std.mem.Allocator,
        ip: tp.in6_addr,
        port: u16,
        owner: tp.pid,
    };

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        const acceptor = try tp.tcp_acceptor.init(acceptor_tag);
        var acceptor_owned = true;
        errdefer if (acceptor_owned) acceptor.deinit();
        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .acceptor = acceptor,
            .owner = args.owner,
            .receiver = .init(receive, deinit, self),
        };
        acceptor_owned = false;
        errdefer self.deinit();

        _ = tp.set_trap(true);
        self.port = try self.acceptor.listen(args.ip, args.port);
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.owner.deinit();
        self.acceptor.deinit();
        self.allocator.destroy(self);
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive_safe(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive_safe(self: *@This(), _: tp.pid_ref, m: tp.message) !void {
        var fd: i32 = 0;
        var reason: []const u8 = "";

        if (try m.match(.{ "acceptor", acceptor_tag, "accept", tp.extract(&fd) })) {
            const conn = try endpoint_connection.start(self.allocator, fd);
            defer conn.deinit();
            try self.owner.send(.{ "connected", conn.instance_id() });
        } else if (try m.match(.{ "acceptor", acceptor_tag, "error", tp.any, tp.extract(&reason) })) {
            return tp.exit(reason);
        } else if (try m.match(.{ "acceptor", acceptor_tag, "closed" })) {
            return tp.exit_normal();
        } else if (try m.match(.{ "get", "port" })) {
            try self.owner.send(.{ "port", self.port });
        } else if (try m.match(.{"close"})) {
            try self.acceptor.close();
        } else if (try m.match(.{ "exit", tp.extract(&reason) })) {
            self.acceptor.close() catch {};
            return tp.exit(reason);
        } else {
            return tp.unexpected(m);
        }
    }
};

const Connector = struct {
    allocator: std.mem.Allocator,
    connector: tp.tcp_connector,
    owner: tp.pid,
    connected: bool = false,
    receiver: tp.Receiver(*@This()),

    const Args = struct {
        allocator: std.mem.Allocator,
        ip: tp.in6_addr,
        port: u16,
        owner: tp.pid,
    };

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        const connector = try tp.tcp_connector.init(connector_tag);
        var connector_owned = true;
        errdefer if (connector_owned) connector.deinit();
        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .connector = connector,
            .owner = args.owner,
            .receiver = .init(receive, deinit, self),
        };
        connector_owned = false;
        errdefer self.deinit();

        _ = tp.set_trap(true);
        try self.connector.connect(args.ip, args.port);
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.owner.deinit();
        self.connector.deinit();
        self.allocator.destroy(self);
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive_safe(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive_safe(self: *@This(), _: tp.pid_ref, m: tp.message) !void {
        var fd: i32 = 0;
        var reason: []const u8 = "";

        if (try m.match(.{ "connector", connector_tag, "connected", tp.extract(&fd) })) {
            self.connected = true;
            const conn = try endpoint_connection.start(self.allocator, fd);
            defer conn.deinit();
            try self.owner.send(.{ "connected", conn.instance_id() });
            return tp.exit_normal();
        } else if (try m.match(.{ "connector", connector_tag, "error", tp.any, tp.extract(&reason) })) {
            return tp.exit(reason);
        } else if (try m.match(.{ "connector", connector_tag, "cancelled" })) {
            return tp.exit_normal();
        } else if (try m.match(.{"cancel"})) {
            self.connector.cancel() catch {};
        } else if (try m.match(.{ "exit", tp.extract(&reason) })) {
            if (!self.connected) self.connector.cancel() catch {};
            return tp.exit(reason);
        } else {
            return tp.unexpected(m);
        }
    }
};
