const std = @import("std");
const thespian = @import("thespian");

const Allocator = std.mem.Allocator;

const exit_normal = thespian.exit_normal;
const exit_error = thespian.exit_error;
const result = thespian.result;
const unexpected = thespian.unexpected;

const pid = thespian.pid;
const pid_ref = thespian.pid_ref;
const self_pid = thespian.self_pid;

const Receiver = thespian.Receiver;
const spawn_link = thespian.spawn_link;

const message = thespian.message;
const extract = thespian.extract;

const socket = thespian.socket;
const tcp_acceptor = thespian.tcp_acceptor;
const tcp_connector = thespian.tcp_connector;
const in6addr_loopback = thespian.in6addr_loopback;

pub const std_options = .{
    .log_level = .err,
};

const ClientConnection = struct {
    allocator: Allocator,
    sock: socket,
    client_pid: pid,
    receiver: Receiver(*@This()),

    const Args = struct { allocator: Allocator, fd: i32, client_pid: pid };

    fn start(args: Args) result {
        const sock = socket.init("client_connection", args.fd) catch |e| return exit_error(e, @errorReturnTrace());
        var self = args.allocator.create(@This()) catch |e| return exit_error(e, @errorReturnTrace());
        self.* = .{
            .allocator = args.allocator,
            .sock = sock,
            .client_pid = args.client_pid,
            .receiver = .init(receive_safe, self),
        };
        errdefer self.deinit();
        self.sock.read() catch |e| return exit_error(e, @errorReturnTrace());
        thespian.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.client_pid.deinit();
        self.allocator.destroy(self);
    }

    fn receive_safe(self: *@This(), from: pid_ref, m: message) result {
        errdefer self.deinit();
        self.receive(from, m) catch |e| return exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), _: pid_ref, m: message) !void {
        var buf: []const u8 = "";
        var written: i64 = 0;
        if (try m.match(.{ "socket", "client_connection", "read_complete", extract(&buf) })) {
            if (std.mem.eql(u8, buf, "ping"))
                try self.sock.write("pong");
        } else if (try m.match(.{ "socket", "client_connection", "write_complete", extract(&written) })) {
            // just wait for server to close
        } else if (try m.match(.{ "socket", "client_connection", "closed" })) {
            // connection done
            _ = self.client_pid.send(.{ "client_connection", "done" }) catch {};
            return exit_normal();
        } else {
            return unexpected(m);
        }
    }
};

const Client = struct {
    allocator: Allocator,
    connector: tcp_connector,
    server_pid: pid,
    receiver: Receiver(*@This()),

    const Args = struct { allocator: Allocator, server_pid: pid, port: u16 };

    fn start(args: Args) result {
        return init(args) catch |e| return exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        const connector: tcp_connector = try .init("client");
        var self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .connector = connector,
            .server_pid = args.server_pid,
            .receiver = .init(receive_safe, self),
        };
        errdefer self.deinit();
        try self.connector.connect(in6addr_loopback, args.port);
        thespian.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.server_pid.deinit();
        self.allocator.destroy(self);
    }

    fn receive_safe(self: *@This(), from: pid_ref, m: message) result {
        errdefer self.deinit();
        self.receive(from, m) catch |e| return exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), _: pid_ref, m: message) !void {
        var fd: i32 = 0;
        if (try m.match(.{ "connector", "client", "connected", extract(&fd) })) {
            _ = try spawn_link(self.allocator, ClientConnection.Args{
                .allocator = self.allocator,
                .fd = fd,
                .client_pid = self_pid().clone(),
            }, ClientConnection.start, "client_connection");
        } else if (try m.match(.{ "client_connection", "done" })) {
            _ = try self.server_pid.send(.{ "client", "done" });
            return exit_normal();
        } else {
            return unexpected(m);
        }
    }
};

const ServerConnection = struct {
    allocator: Allocator,
    sock: socket,
    server_pid: pid,
    receiver: Receiver(*@This()),

    const Args = struct { allocator: Allocator, fd: i32, server_pid: pid };

    fn start(args: Args) result {
        return init(args) catch |e| return exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        const sock = try socket.init("server_connection", args.fd);
        var self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .sock = sock,
            .server_pid = args.server_pid,
            .receiver = .init(receive_safe, self),
        };
        errdefer self.deinit();
        try self.sock.write("ping");
        thespian.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.server_pid.deinit();
        self.allocator.destroy(self);
    }

    fn receive_safe(self: *@This(), from: pid_ref, m: message) result {
        errdefer self.deinit();
        self.receive(from, m) catch |e| return exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), _: pid_ref, m: message) !void {
        var buf: []const u8 = "";
        var written: i64 = 0;

        if (try m.match(.{ "socket", "server_connection", "write_complete", extract(&written) })) {
            // ping sent, start reading
            try self.sock.read();
        } else if (try m.match(.{ "socket", "server_connection", "read_complete", extract(&buf) })) {
            // received pong, close socket
            if (std.mem.eql(u8, buf, "pong"))
                try self.sock.close();
        } else if (try m.match(.{ "socket", "server_connection", "closed" })) {
            // connection done, notify server
            _ = self.server_pid.send(.{ "server_connection", "done" }) catch {};
            return exit_normal();
        } else {
            return unexpected(m);
        }
    }
};

const Server = struct {
    allocator: Allocator,
    acceptor: tcp_acceptor,
    client_done: bool = false,
    server_conn_done: bool = false,
    acceptor_closed: bool = false,
    receiver: Receiver(*@This()),

    const Args = struct { allocator: Allocator };

    fn start(args: Args) result {
        return init(args) catch |e| exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        const acceptor: tcp_acceptor = try .init("server");
        var self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .acceptor = acceptor,
            .receiver = .init(receive_safe, self),
        };
        errdefer self.deinit();

        const port = try self.acceptor.listen(in6addr_loopback, 0);

        _ = try spawn_link(args.allocator, Client.Args{
            .allocator = args.allocator,
            .server_pid = self_pid().clone(),
            .port = port,
        }, Client.start, "client");

        thespian.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.acceptor.deinit();
        self.allocator.destroy(self);
    }

    fn receive_safe(self: *@This(), from: pid_ref, m: message) result {
        errdefer self.deinit();
        self.receive(from, m) catch |e| return exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), _: pid_ref, m: message) !void {
        var fd: i32 = 0;
        if (try m.match(.{ "acceptor", "server", "accept", extract(&fd) })) {
            _ = try spawn_link(self.allocator, ServerConnection.Args{
                .allocator = self.allocator,
                .fd = fd,
                .server_pid = self_pid().clone(),
            }, ServerConnection.start, "server_connection");
            // just one connection for this test
            try self.acceptor.close();
        } else if (try m.match(.{ "acceptor", "server", "closed" })) {
            self.acceptor_closed = true;
        } else if (try m.match(.{ "client", "done" })) {
            self.client_done = true;
        } else if (try m.match(.{ "server_connection", "done" })) {
            self.server_conn_done = true;
        } else {
            return unexpected(m);
        }
        if (self.acceptor_closed and self.client_done and self.server_conn_done)
            return exit_normal();
    }
};

test "ip_tcp_client_server test" {
    const allocator = std.testing.allocator;
    var ctx = try thespian.context.init(allocator);
    defer ctx.deinit();

    var success = false;

    var exit_handler = thespian.make_exit_handler(&success, struct {
        fn handle(ok: *bool, status: []const u8) void {
            if (std.mem.eql(u8, status, "normal")) {
                ok.* = true;
            } else {
                std.log.err("EXITED: {s}", .{status});
            }
        }
    }.handle);

    _ = try ctx.spawn_link(Server.Args{ .allocator = allocator }, Server.start, "ip_tcp_client_server", &exit_handler, null);

    ctx.run();

    if (!success) return error.TestFailed;
}
