const std = @import("std");
const thespian = @import("thespian");
const cbor = @import("cbor");
const protocol = @import("remote").protocol;
const endpoint = @import("remote").endpoint.subprocess;
const build_options = @import("build_options");
const child_helper = @import("child_helper.zig");

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
    ep: thespian.pid,
    receiver: Receiver(*@This()),

    const Args = struct { allocator: Allocator };

    fn start(args: Args) result {
        return init(args) catch |e| return thespian.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        thespian.env.get().proc_set("test_receiver", thespian.self_pid().ref());

        const child_path = try child_helper.resolve(args.allocator, std.testing.io, "remote_child_endpoint", build_options.remote_child_endpoint_path);
        defer args.allocator.free(child_path);
        const argv: cbor.Raw = .{ .bytes = message.fmt(.{child_path}).buf };
        const ep = try endpoint.start(std.testing.io, args.allocator, argv);

        const my_id = protocol.lpiid.fromInt(thespian.self_pid().instance_id().toInt());
        try ep.send(.{ "send", my_id, "echo", .{"hello"} });

        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .ep = ep,
            .receiver = .init(receive_fn, deinit, self),
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

    fn receive(_: *@This(), _: pid_ref, m: message) !void {
        if (try m.match(.{"hello"})) {
            return thespian.exit("success");
        } else {
            return unexpected(m);
        }
    }
};

test "remote: endpoint delivers message cross-process and receives reply" {
    const allocator = std.testing.allocator;

    var initial_env: ?thespian.env = null;
    if (std.testing.environ.containsConstant("TRACE")) {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, "remote_endpoint_trace.json", .{});
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
