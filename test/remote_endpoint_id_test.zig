const std = @import("std");
const thespian = @import("thespian");
const cbor = @import("cbor");
const protocol = @import("remote").protocol;
const endpoint = @import("remote").endpoint.subprocess;
const build_options = @import("build_options");

var trace_file: ?std.Io.File = null;
var trace_buf: [4096]u8 = undefined;
var trace_file_writer: std.Io.File.Writer = undefined;

fn trace_handler(buf: thespian.message.c_buffer_type) callconv(.c) void {
    if (trace_file == null) return;
    cbor.toJsonWriter(buf.base[0..buf.len], &trace_file_writer.interface, .{}) catch return;
    trace_file_writer.interface.writeByte('\n') catch return;
}

const Allocator = std.mem.Allocator;
const result = thespian.result;
const unexpected = thespian.unexpected;
const pid_ref = thespian.pid_ref;
const Receiver = thespian.Receiver;
const message = thespian.message;

const TestActor = struct {
    allocator: Allocator,
    ep: thespian.pid,
    receiver: Receiver(*@This()),
    state: enum { waiting_for_hello, waiting_for_done },

    const Args = struct { allocator: Allocator };

    fn start(args: Args) result {
        return init(args) catch |e| return thespian.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        thespian.env.get().proc_set("test_receiver", thespian.self_pid().ref());

        const argv: cbor.Raw = .{ .bytes = message.fmt(.{build_options.remote_child_endpoint_path}).buf };
        const ep = try endpoint.start(std.testing.io, args.allocator, argv);

        try ep.send(.{ "send", protocol.lpiid.empty, "echo_id", .{"hello"} });

        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .ep = ep,
            .receiver = .init(receive_fn, deinit, self),
            .state = .waiting_for_hello,
        };
        errdefer self.deinit();
        thespian.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.ep.deinit();
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: pid_ref, m: message) result {
        return self.receive(from, m) catch |e| return thespian.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), from: pid_ref, m: message) !void {
        switch (self.state) {
            .waiting_for_hello => {
                if (try m.match(.{"hello"})) {
                    try from.send(.{"hello"});
                    self.state = .waiting_for_done;
                } else return unexpected(m);
            },
            .waiting_for_done => {
                if (try m.match(.{"done"})) {
                    return thespian.exit("success");
                } else return unexpected(m);
            },
        }
    }
};

test "remote: inbound proxy table, from-substitution, outbound ID table, and send-by-ID routing" {
    const allocator = std.testing.allocator;

    var initial_env: ?thespian.env = null;
    if (std.testing.environ.getPosix("TRACE") != null) {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, "remote_endpoint_id_trace.json", .{});
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
