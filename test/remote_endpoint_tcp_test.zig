const std = @import("std");
const thespian = @import("thespian");
const cbor = @import("cbor");
const protocol = @import("remote").protocol;
const endpoint = @import("remote").endpoint.tcp;

var trace_file: ?std.Io.File = null;
var trace_buf: [4096]u8 = undefined;
var trace_file_writer: std.Io.File.Writer = undefined;

fn trace_handler(buf: thespian.message.c_buffer_type) callconv(.c) void {
    if (trace_file == null) return;
    cbor.toJsonWriter(buf.base[0..buf.len], &trace_file_writer.interface, .{}) catch return;
    trace_file_writer.interface.writeByte('\n') catch return;
    trace_file_writer.interface.flush() catch return;
}

const Allocator = std.mem.Allocator;
const result = thespian.result;
const unexpected = thespian.unexpected;
const pid_ref = thespian.pid_ref;
const Receiver = thespian.Receiver;
const message = thespian.message;
const extract = thespian.extract;

const TestActor = struct {
    allocator: Allocator,
    listener: thespian.pid,
    connector: ?thespian.pid = null,
    server_conn: ?thespian.pid = null,
    client_conn: ?thespian.pid = null,
    state: State = .waiting_for_port,
    receiver: Receiver(*@This()),

    const State = enum { waiting_for_port, waiting_for_connections, waiting_for_ping };

    const Args = struct { allocator: Allocator };

    fn start(args: Args) result {
        return init(args) catch |e| return thespian.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        _ = thespian.set_trap(true);
        thespian.env.get().proc_set("test_receiver", thespian.self_pid().ref());

        const listener = try endpoint.listen(args.allocator, thespian.in6addr_loopback, 0, thespian.self_pid().clone());
        try listener.send(.{ "get", "port" });

        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .listener = listener,
            .receiver = .init(receive_fn, deinit, self),
        };
        errdefer self.deinit();
        thespian.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        if (self.client_conn) |*p| p.deinit();
        if (self.server_conn) |*p| p.deinit();
        if (self.connector) |*p| p.deinit();
        self.listener.deinit();
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: pid_ref, m: message) result {
        return self.receive(from, m) catch |e| return thespian.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), _: pid_ref, m: message) !void {
        var port: u16 = 0;
        var conn_id: thespian.piid = .empty;
        var reason: []const u8 = "";

        if (try m.match(.{ "port", extract(&port) })) {
            if (self.state != .waiting_for_port) return unexpected(m);
            self.connector = try endpoint.connect(self.allocator, thespian.in6addr_loopback, port, thespian.self_pid().clone());
            self.state = .waiting_for_connections;
        } else if (try m.match(.{ "connected", extract(&conn_id) })) {
            if (self.state != .waiting_for_connections) return unexpected(m);
            const conn = thespian.pid.from_id(conn_id) orelse return unexpected(m);
            if (self.server_conn == null) {
                self.server_conn = conn;
            } else {
                self.client_conn = conn;
                const my_id = protocol.lpiid.fromInt(thespian.self_pid().instance_id().toInt());
                try self.client_conn.?.send(.{ "send", my_id, "test_receiver", .{"ping"} });
                self.state = .waiting_for_ping;
            }
        } else if (try m.match(.{"ping"})) {
            if (self.state != .waiting_for_ping) return unexpected(m);
            if (self.server_conn) |p| p.send(.{ "exit", "done" }) catch {};
            if (self.client_conn) |p| p.send(.{ "exit", "done" }) catch {};
            try self.listener.send(.{"close"});
            return thespian.exit("success");
        } else if (try m.match(.{ "exit", extract(&reason) })) {
            // Spawn-linked children (connector, listener) propagate their
            // exits to us; ignore normal shutdowns.
            if (std.mem.eql(u8, reason, "normal")) return;
            return unexpected(m);
        } else {
            return unexpected(m);
        }
    }
};

test "remote: tcp endpoint round-trip via listen/connect" {
    const allocator = std.testing.allocator;

    var initial_env: ?thespian.env = null;
    if (std.testing.environ.containsConstant("TRACE")) {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, "remote_endpoint_tcp_trace.json", .{});
        trace_file = f;
        trace_file_writer = f.writer(std.testing.io, &trace_buf);
        var e = thespian.env.init();
        e.on_trace(&trace_handler);
        e.enable_all_channels();
        initial_env = e;
    }
    defer if (initial_env) |e| {
        trace_file_writer.interface.flush() catch {};
        trace_file.?.close(std.testing.io);
        trace_file = null;
        e.deinit();
    };

    var ctx = try thespian.context.init(allocator, .{});
    defer ctx.deinit();

    var success = false;
    var exit_handler = thespian.make_exit_handler(&success, struct {
        fn handle(ok: *bool, status: []const u8) void {
            ok.* = std.mem.eql(u8, status, "success");
        }
    }.handle);

    _ = try ctx.spawn_link(
        TestActor.Args{ .allocator = allocator },
        TestActor.start,
        "test_actor",
        &exit_handler,
        initial_env,
    );

    ctx.run();

    if (!success) return error.TestFailed;
}
