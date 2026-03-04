const std = @import("std");
const thespian = @import("thespian");

const Allocator = std.mem.Allocator;

const exit = thespian.exit;
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

const ClientConnection = struct {
    allocator: Allocator,
    sock: socket,
    client_pid: pid,
    receiver: Receiver(*@This()),

    const Args = struct { allocator: Allocator, fd: i32, client_pid: pid };

    fn start(args: Args) result {
        std.log.err("ClientConnection.start entered fd={d}", .{args.fd});
        const sock = socket.init("client_connection", args.fd) catch |e| {
            std.log.err("ClientConnection.start socket.init FAILED: {any}", .{e});
            return exit_error(e, @errorReturnTrace());
        };
        std.log.err("ClientConnection.start socket created", .{});
        var self = args.allocator.create(@This()) catch |e| return exit_error(e, @errorReturnTrace());
        self.* = .{
            .allocator = args.allocator,
            .sock = sock,
            .client_pid = args.client_pid,
            .receiver = .init(receive_safe, self),
        };
        errdefer self.deinit();
        self.sock.read() catch |e| {
            std.log.err("ClientConnection.start sock.read FAILED: {any}", .{e});
            return exit_error(e, @errorReturnTrace());
        };
        std.log.err("ClientConnection.start calling receive()", .{});
        thespian.receive(&self.receiver);
        std.log.err("ClientConnection.start returning", .{});
    }

    fn deinit(self: *@This()) void {
        self.sock.deinit();
        self.client_pid.deinit();
        self.allocator.destroy(self);
        std.log.err("ClientConnection.deinit: client connection destroyed", .{});
    }

    fn receive_safe(self: *@This(), from: pid_ref, m: message) result {
        errdefer self.deinit();
        self.receive(from, m) catch |e| return exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), _: pid_ref, m: message) !void {
        std.log.err("ClientConnection.receive msg={f}", .{m});
        var buf: []const u8 = "";
        var written: i64 = 0;
        if (try m.match(.{ "socket", "client_connection", "read_complete", extract(&buf) })) {
            std.log.err("ClientConnection.receive: read_complete buf={s}", .{buf});
            try std.testing.expectEqualSlices(u8, "ping", buf);
            try self.sock.write("pong");
            // try self.sock.read();
        } else if (try m.match(.{ "socket", "client_connection", "write_complete", extract(&written) })) {
            std.log.err("ClientConnection.receive: write_complete written={d}", .{written});
            try std.testing.expectEqual(4, written);
            // wait for server to close - must keep a read pending to detect it
            // try self.sock.read();
        } else if (try m.match(.{ "socket", "client_connection", "closed" })) {
            std.log.err("ClientConnection.receive: closed, sending done", .{});
            _ = self.client_pid.send(.{ "client_connection", "done" }) catch {};
            return exit("success");
        } else {
            std.log.err("ClientConnection.receive: UNEXPECTED msg={f}", .{m});
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
        std.log.err("Client.init entered port={d}", .{args.port});
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
        std.log.err("Client.init connect() called, calling receive()", .{});
        thespian.receive(&self.receiver);
        std.log.err("Client.init returning", .{});
    }

    fn deinit(self: *@This()) void {
        self.server_pid.deinit();
        self.allocator.destroy(self);
        std.log.err("Client.deinit: client destroyed", .{});
    }

    fn receive_safe(self: *@This(), from: pid_ref, m: message) result {
        errdefer self.deinit();
        self.receive(from, m) catch |e| return exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), _: pid_ref, m: message) !void {
        std.log.err("Client.receive msg={f}", .{m});
        var fd: i32 = 0;
        if (try m.match(.{ "connector", "client", "connected", extract(&fd) })) {
            std.log.err("Client.receive: connected fd={d}, spawning ClientConnection", .{fd});
            _ = try spawn_link(self.allocator, ClientConnection.Args{
                .allocator = self.allocator,
                .fd = fd,
                .client_pid = self_pid().clone(),
            }, ClientConnection.start, "client_connection");
            std.log.err("Client.receive: ClientConnection spawned", .{});
        } else if (try m.match(.{ "client_connection", "done" })) {
            std.log.err("Client.receive: client_connection done, exiting", .{});
            _ = try self.server_pid.send(.{ "client", "done" });
            return exit_normal();
        } else {
            std.log.err("Client.receive: UNEXPECTED msg={f}", .{m});
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
        std.log.err("ServerConnection.init entered fd={d}", .{args.fd});
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
        std.log.err("ServerConnection.init write(ping) called, calling receive()", .{});
        thespian.receive(&self.receiver);
        std.log.err("ServerConnection.init returning", .{});
    }

    fn deinit(self: *@This()) void {
        self.sock.deinit();
        self.server_pid.deinit();
        self.allocator.destroy(self);
        std.log.err("ServerConnection.deinit: server connection destroyed", .{});
    }

    fn receive_safe(self: *@This(), from: pid_ref, m: message) result {
        errdefer self.deinit();
        self.receive(from, m) catch |e| return exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), _: pid_ref, m: message) !void {
        std.log.err("ServerConnection.receive msg={f}", .{m});
        var buf: []const u8 = "";
        var written: i64 = 0;

        if (try m.match(.{ "socket", "server_connection", "write_complete", extract(&written) })) {
            std.log.err("ServerConnection.receive: write_complete written={d}", .{written});
            try std.testing.expectEqual(4, written);
            // ping sent, start reading
            try self.sock.read();
        } else if (try m.match(.{ "socket", "server_connection", "read_complete", extract(&buf) })) {
            std.log.err("ServerConnection.receive: read_complete buf={s}", .{buf});
            try std.testing.expectEqualSlices(u8, "pong", buf);
            // received pong, close socket
            try self.sock.close();
        } else if (try m.match(.{ "socket", "server_connection", "closed" })) {
            std.log.err("ServerConnection.receive: closed, sending done", .{});
            self.server_pid.send(.{ "server_connection", "done" }) catch |e| return exit_error(e, @errorReturnTrace());
            return exit("success");
        } else {
            std.log.err("ServerConnection.receive: UNEXPECTED msg={f}", .{m});
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
        std.log.err("Server.init entered", .{});
        const acceptor: tcp_acceptor = try .init("server");
        var self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .acceptor = acceptor,
            .receiver = .init(receive_safe, self),
        };
        errdefer self.deinit();

        const port = try self.acceptor.listen(in6addr_loopback, 0);
        std.log.err("Server.init listening on port={d}", .{port});

        _ = try spawn_link(args.allocator, Client.Args{
            .allocator = args.allocator,
            .server_pid = self_pid().clone(),
            .port = port,
        }, Client.start, "client");
        std.log.err("Server.init Client spawned, calling receive()", .{});

        thespian.receive(&self.receiver);
        std.log.err("Server.init returning", .{});
    }

    fn deinit(self: *@This()) void {
        self.acceptor.deinit();
        self.allocator.destroy(self);
        std.log.err("Server.deinit: server destroyed", .{});
    }

    fn receive_safe(self: *@This(), from: pid_ref, m: message) result {
        errdefer self.deinit();
        self.receive(from, m) catch |e| return exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), _: pid_ref, m: message) !void {
        std.log.err("Server.receive msg={f}", .{m});
        var fd: i32 = 0;
        if (try m.match(.{ "acceptor", "server", "accept", extract(&fd) })) {
            std.log.err("Server.receive: accept fd={d}, spawning ServerConnection", .{fd});
            _ = try spawn_link(self.allocator, ServerConnection.Args{
                .allocator = self.allocator,
                .fd = fd,
                .server_pid = self_pid().clone(),
            }, ServerConnection.start, "server_connection");
            std.log.err("Server.receive: ServerConnection spawned, closing acceptor", .{});
            try self.acceptor.close();
        } else if (try m.match(.{ "acceptor", "server", "closed" })) {
            std.log.err("Server.receive: acceptor closed (flags: client={} conn={})", .{ self.client_done, self.server_conn_done });
            self.acceptor_closed = true;
        } else if (try m.match(.{ "client", "done" })) {
            std.log.err("Server.receive: client done (flags: acceptor={} conn={})", .{ self.acceptor_closed, self.server_conn_done });
            self.client_done = true;
        } else if (try m.match(.{ "server_connection", "done" })) {
            std.log.err("Server.receive: server_connection done (flags: acceptor={} client={})", .{ self.acceptor_closed, self.client_done });
            self.server_conn_done = true;
        } else {
            std.log.err("Server.receive: UNEXPECTED msg={f}", .{m});
            return unexpected(m);
        }
        if (self.acceptor_closed and self.client_done and self.server_conn_done) {
            std.log.err("Server.receive: all done, exiting with 'success'", .{});
            return exit("success");
        }
    }
};

test "ip_tcp_client_server test" {
    const allocator = std.testing.allocator;
    var ctx = try thespian.context.init(allocator);
    defer ctx.deinit();

    var success = false;

    var exit_handler = thespian.make_exit_handler(&success, struct {
        fn handle(ok: *bool, status: []const u8) void {
            if (std.mem.eql(u8, status, "success")) {
                ok.* = true;
                std.log.err("EXITED: {s}", .{status});
            } else {
                std.log.err("EXITED: {s}", .{status});
            }
        }
    }.handle);

    _ = try ctx.spawn_link(Server.Args{ .allocator = allocator }, Server.start, "ip_tcp_client_server", &exit_handler, null);

    ctx.run();

    if (!success) return error.TestFailed;
}
