const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const protocol = @import("remote").protocol;
const endpoint = @import("remote").endpoint;

const lpiid = protocol.lpiid;
const rpiid = protocol.rpiid;
const piid = protocol.piid;

var trace_file: ?std.Io.File = null;
var trace_buf: [4096]u8 = undefined;
var trace_file_writer: std.Io.File.Writer = undefined;

fn trace_handler(buf: tp.message.c_buffer_type) callconv(.c) void {
    if (trace_file == null) return;
    cbor.toJsonWriter(buf.base[0..buf.len], &trace_file_writer.interface, .{}) catch return;
    trace_file_writer.interface.writeByte('\n') catch return;
    trace_file_writer.interface.flush() catch return;
}

const EchoActor = struct {
    allocator: std.mem.Allocator,
    receiver: tp.Receiver(*@This()),

    const Args = struct { allocator: std.mem.Allocator };

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .receiver = .init(receive_fn, deinit, self),
        };
        errdefer self.deinit();
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        _ = self;
        return from.send_raw(m);
    }
};

const EchoIdActor = struct {
    allocator: std.mem.Allocator,
    receiver: tp.Receiver(*@This()),
    state: enum { waiting_for_first, waiting_for_second } = .waiting_for_first,

    const Args = struct { allocator: std.mem.Allocator };

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .receiver = .init(receive_fn, deinit, self),
        };
        errdefer self.deinit();
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        switch (self.state) {
            .waiting_for_first => {
                const my_id = lpiid.fromInt(tp.self_pid().instance_id().toInt());
                try from.send(.{ "send", my_id, "test_receiver", cbor.Raw{ .bytes = m.buf } });
                self.state = .waiting_for_second;
            },
            .waiting_for_second => {
                try from.send(.{"done"});
            },
        }
    }
};

const DieTestActor = struct {
    allocator: std.mem.Allocator,
    receiver: tp.Receiver(*@This()),
    state: enum { waiting_for_first, waiting_for_die } = .waiting_for_first,

    const Args = struct { allocator: std.mem.Allocator };

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .receiver = .init(receive_fn, deinit, self),
        };
        errdefer self.deinit();
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        switch (self.state) {
            .waiting_for_first => {
                const my_id = lpiid.fromInt(tp.self_pid().instance_id().toInt());
                try from.send(.{ "send", my_id, "test_receiver", cbor.Raw{ .bytes = m.buf } });
                self.state = .waiting_for_die;
            },
            .waiting_for_die => {
                return tp.exit("die_test");
            },
        }
    }
};

const Control = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    receiver: tp.Receiver(*@This()),

    const Args = struct { allocator: std.mem.Allocator, io: std.Io };

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .io = args.io,
            .receiver = .init(receive_fn, deinit, self),
        };
        errdefer self.deinit();

        _ = tp.set_trap(true);

        const echo_pid = try tp.spawn_link(args.allocator, EchoActor.Args{
            .allocator = args.allocator,
        }, EchoActor.start, "echo");
        defer echo_pid.deinit();
        tp.env.get().proc_set("echo", echo_pid.ref());

        const echo_id_pid = try tp.spawn_link(args.allocator, EchoIdActor.Args{
            .allocator = args.allocator,
        }, EchoIdActor.start, "echo_id");
        defer echo_id_pid.deinit();
        tp.env.get().proc_set("echo_id", echo_id_pid.ref());

        const die_test_pid = try tp.spawn_link(args.allocator, DieTestActor.Args{
            .allocator = args.allocator,
        }, DieTestActor.start, "die_test");
        defer die_test_pid.deinit();
        tp.env.get().proc_set("die_test", die_test_pid.ref());

        _ = try endpoint.stdio.start(args.io, args.allocator);

        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        _ = self;
        _ = from;
        var reason: []const u8 = "";
        if (m.match(.{ "exit", tp.extract(&reason) }) catch false) {
            if (std.mem.eql(u8, reason, "die_test")) return;
            return tp.exit(reason);
        }
        return tp.unexpected(m);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var initial_env: ?tp.env = null;
    if (init.minimal.environ.getPosix("TRACE") != null) {
        const f = try std.Io.Dir.cwd().createFile(init.io, "remote_child_endpoint_trace.json", .{});
        trace_file = f;
        trace_file_writer = f.writer(init.io, &trace_buf);
        var e = tp.env.init();
        e.on_trace(&trace_handler);
        e.enable_all_channels();
        initial_env = e;
    }

    var ctx = try tp.context.init(allocator, .{});
    defer ctx.deinit();

    var exit_ok = true;
    var exit_handler = tp.make_exit_handler(&exit_ok, struct {
        fn handle(ok: *bool, status: []const u8) void {
            if (!std.mem.eql(u8, status, "stdin_closed") and
                !std.mem.eql(u8, status, "normal"))
                ok.* = false;
        }
    }.handle);

    _ = try ctx.spawn_link(
        Control.Args{ .allocator = allocator, .io = init.io },
        Control.start,
        "control",
        &exit_handler,
        initial_env,
    );

    ctx.run();

    if (initial_env) |e| {
        trace_file_writer.interface.flush() catch {};
        trace_file.?.close(init.io);
        trace_file = null;
        e.deinit();
    }

    std.process.exit(if (exit_ok) 0 else 1);
}
