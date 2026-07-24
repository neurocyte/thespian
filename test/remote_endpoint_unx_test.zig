const std = @import("std");
const builtin = @import("builtin");
const thespian = @import("thespian");
const cbor = @import("cbor");
const protocol = @import("remote").protocol;
const endpoint = @import("remote").endpoint.unx;

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
    path: [:0]const u8,
    mode: thespian.unx_mode,
    state: State = .waiting_for_path,
    receiver: Receiver(*@This()),

    const State = enum { waiting_for_path, waiting_for_connections, waiting_for_ping };

    const Args = struct { allocator: Allocator, path: [:0]const u8, mode: thespian.unx_mode };

    fn start(args: Args) result {
        return init(args) catch |e| return thespian.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        _ = thespian.set_trap(true);
        thespian.env.get().proc_set("test_receiver", thespian.self_pid().ref());

        const listener = try endpoint.listen(args.allocator, args.path, args.mode, thespian.self_pid().clone());
        // round-trip serves as a sync barrier
        try listener.send(.{ "get", "path" });

        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .listener = listener,
            .path = args.path,
            .mode = args.mode,
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
        var conn_id: thespian.piid = .empty;
        var reason: []const u8 = "";
        var path_out: []const u8 = "";

        if (try m.match(.{ "path", extract(&path_out) })) {
            if (self.state != .waiting_for_path) return unexpected(m);
            self.connector = try endpoint.connect(self.allocator, self.path, self.mode, thespian.self_pid().clone());
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
            if (std.mem.eql(u8, reason, "normal")) return;
            return unexpected(m);
        } else {
            return unexpected(m);
        }
    }
};

test "remote: unx endpoint round-trip via listen/connect" {
    const allocator = std.testing.allocator;

    var initial_env: ?thespian.env = null;
    if (std.testing.environ.getPosix("TRACE") != null) {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, "remote_endpoint_unx_trace.json", .{});
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

    var path_buf: [128]u8 = undefined;
    const path_slice = try std.fmt.bufPrintZ(&path_buf, "thespian_endpoint_unx_test_{d}", .{std.os.linux.getpid()});
    const mode: thespian.unx_mode = if (builtin.os.tag == .linux) .abstract else .file;

    var success = false;
    var exit_handler = thespian.make_exit_handler(&success, struct {
        fn handle(ok: *bool, status: []const u8) void {
            ok.* = std.mem.eql(u8, status, "success");
        }
    }.handle);

    _ = try ctx.spawn_link(
        TestActor.Args{ .allocator = allocator, .path = path_slice, .mode = mode },
        TestActor.start,
        "test_actor",
        &exit_handler,
        initial_env,
    );

    ctx.run();

    if (!success) return error.TestFailed;
}
