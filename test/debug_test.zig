const std = @import("std");
const thespian = @import("thespian");

const Allocator = std.mem.Allocator;

const exit = thespian.exit;
const exit_error = thespian.exit_error;
const result = thespian.result;
const unexpected = thespian.unexpected;

const pid = thespian.pid;
const pid_ref = thespian.pid_ref;

const Receiver = thespian.Receiver;
const spawn_link = thespian.spawn_link;

const message = thespian.message;
const extract = thespian.extract;

const socket = thespian.socket;
const tcp_connector = thespian.tcp_connector;
const in6addr_loopback = thespian.in6addr_loopback;

const port = 4244;
const call_request = "{\"id\":1,\"cmd\":\"call\",\"to\":\"zig_debuggee\",\"msg\":[\"ping\"]}\n";
const call_response = "{\"id\":1,\"ok\":true,\"from\":\"zig_debuggee\",\"result\":[\"pong\"]}";
const bye_request = "{\"id\":2,\"cmd\":\"bye\"}\n";
const bye_response = "{\"id\":2,\"ok\":true}";

const Debuggee = struct {
    receiver: Receiver(*@This()),
    allocator: Allocator,

    fn start(allocator: Allocator) result {
        const self = allocator.create(@This()) catch |e| return exit_error(e, @errorReturnTrace());
        self.* = .{ .allocator = allocator, .receiver = .init(receive, deinit, self) };
        thespian.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.allocator.destroy(self);
    }

    fn receive(_: *@This(), from: pid_ref, m: message) result {
        if (try m.match(.{"ping"}))
            return from.send(.{"pong"});
        if (try m.match(.{"shutdown"}))
            return exit("debuggee_shutdown");
        return unexpected(m);
    }
};

const Controller = struct {
    allocator: Allocator,
    ctx: *const thespian.context,
    console: pid,
    debuggee: pid,
    connector: tcp_connector,
    sock: ?socket = null,
    lines: std.ArrayList(u8) = .empty,
    got_bye: bool = false,
    receiver: Receiver(*@This()),

    const Args = struct { allocator: Allocator, ctx: *const thespian.context };

    fn start(args: Args) result {
        return init(args) catch |e| return exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        _ = thespian.set_trap(true);
        const console = try thespian.debug.tcp_create(args.ctx, port, "");
        errdefer console.deinit();
        const debuggee = try spawn_link(args.allocator, args.allocator, Debuggee.start, "zig_debuggee");
        errdefer debuggee.deinit();
        const connector: tcp_connector = try .init("zig_debug_client");
        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .ctx = args.ctx,
            .console = console,
            .debuggee = debuggee,
            .connector = connector,
            .receiver = .init(receive_fn, deinit, self),
        };
        // the console answers ping once it is listening
        try self.console.send(.{"ping"});
        thespian.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        if (self.sock) |s| s.deinit();
        self.connector.deinit();
        self.lines.deinit(self.allocator);
        self.console.deinit();
        self.debuggee.deinit();
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: pid_ref, m: message) result {
        return self.receive(from, m) catch |e| return exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), _: pid_ref, m: message) !void {
        var fd: i32 = 0;
        var buf: []const u8 = "";
        var written: i64 = 0;
        if (try m.match(.{"pong"})) {
            try self.connector.connect(in6addr_loopback, port);
        } else if (try m.match(.{ "connector", "zig_debug_client", "connected", extract(&fd) })) {
            self.sock = try socket.init("zig_debug_client", fd);
            try self.sock.?.read();
            try self.sock.?.write(call_request);
        } else if (try m.match(.{ "socket", "zig_debug_client", "read_complete", extract(&buf) })) {
            if (buf.len == 0) return self.sock.?.close();
            try self.lines.appendSlice(self.allocator, buf);
            while (std.mem.indexOfScalar(u8, self.lines.items, '\n')) |pos| {
                try self.on_line(self.lines.items[0..pos]);
                self.lines.replaceRangeAssumeCapacity(0, pos + 1, "");
            }
            try self.sock.?.read();
        } else if (try m.match(.{ "socket", "zig_debug_client", "write_complete", extract(&written) })) {
            // nothing to do
        } else if (try m.match(.{ "socket", "zig_debug_client", "closed" })) {
            if (!self.got_bye) return exit("closed_early");
            try self.console.send(.{"shutdown"});
            try self.debuggee.send(.{"shutdown"});
        } else if (try m.match(.{ "exit", "debuggee_shutdown" })) {
            thespian.debug.disable(self.ctx);
            return exit("success");
        } else {
            return unexpected(m);
        }
    }

    fn on_line(self: *@This(), line: []const u8) !void {
        if (std.mem.eql(u8, line, call_response)) {
            try self.sock.?.write(bye_request);
        } else if (std.mem.eql(u8, line, bye_response)) {
            self.got_bye = true;
        } else {
            std.log.err("unexpected debug console line: {s}", .{line});
            return error.UnexpectedLine;
        }
    }
};

test "debug console via zig bindings" {
    const allocator = std.testing.allocator;
    var ctx = try thespian.context.init(allocator, .{});
    defer ctx.deinit();

    thespian.debug.enable(&ctx);
    try std.testing.expect(thespian.debug.isenabled(&ctx));

    var success = false;
    var exit_handler = thespian.make_exit_handler(&success, struct {
        fn handle(ok: *bool, status: []const u8) void {
            if (std.mem.eql(u8, status, "success")) {
                ok.* = true;
            } else {
                std.log.err("EXITED: {s}", .{status});
            }
        }
    }.handle);

    _ = try ctx.spawn_link(Controller.Args{ .allocator = allocator, .ctx = &ctx }, Controller.start, "debug_zig_test", &exit_handler, null);

    ctx.run();

    try std.testing.expect(success);
    try std.testing.expect(!thespian.debug.isenabled(&ctx));
}
