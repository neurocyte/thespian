const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");

const framing = @import("framing.zig");
const protocol = @import("remote.zig").protocol;
const proxy = @import("proxy.zig");

const rpiid = protocol.rpiid;
const lpiid = protocol.lpiid;
const piid = protocol.piid;

pub fn start(io: std.Io, allocator: std.mem.Allocator, argv: cbor.Raw) error{ OutOfMemory, ThespianSpawnFailed }!tp.pid {
    const argv_dup = try allocator.dupe(u8, argv.bytes);
    errdefer allocator.free(argv_dup);
    return tp.spawn_link(
        allocator,
        Process.Args{
            .io = io,
            .allocator = allocator,
            .argv = .{ .bytes = argv_dup },
        },
        Process.start,
        @typeName(@This()),
    );
}

const Process = struct {
    proc: tp.subprocess,
    endpoint: @import("endpoint_common.zig").create(@This()),
    receiver: tp.Receiver(*@This()),

    const tag = "EPPRC";

    const Args = struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        argv: cbor.Raw,

        fn deinit(self: *const @This()) void {
            self.allocator.free(self.argv.bytes);
        }
    };

    fn start(args: Args) tp.result {
        defer args.deinit();
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        var proc = try tp.subprocess.init_overlapped(args.io, args.allocator, tp.message{ .buf = args.argv.bytes }, tag, .pipe);
        var proc_owned = true;
        errdefer if (proc_owned) proc.deinit();
        const self = try args.allocator.create(@This());
        self.* = .{
            .proc = proc,
            .endpoint = .init(args.allocator),
            .receiver = .init(receive, deinit, self),
        };
        proc_owned = false;
        errdefer self.deinit();

        _ = tp.set_trap(true);
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        const allocator = self.endpoint.allocator;
        self.endpoint.deinit();
        self.proc.deinit();
        allocator.destroy(self);
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive_safe(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive_safe(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        var bytes: []const u8 = "";
        var reason: []const u8 = "";

        if (try m.match(.{ tag, "stdout", tp.extract(&bytes) })) {
            try self.endpoint.feed(bytes);
        } else if (try m.match(.{ tag, "stderr", tp.extract(&bytes) })) {
            std.log.err("endpoint-child-error: {s}", .{bytes});
        } else if (try m.match(.{ tag, "term", tp.any, tp.any })) {
            return tp.exit("transport_closed");
        } else if (try m.match(.{ "exit", tp.extract(&reason) })) {
            self.proc.close() catch {};
            return tp.exit(reason);
        } else {
            return self.endpoint.receive(from, m);
        }
    }

    pub fn send_frame(self: *@This(), frame: []const u8) !void {
        try self.proc.send(frame);
    }
};
