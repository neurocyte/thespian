const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");
const protocol = @import("remote.zig").protocol;

const rpiid = protocol.rpiid;
const lpiid = protocol.lpiid;
const piid = protocol.piid;

pub const Args = struct {
    allocator: std.mem.Allocator,
    endpoint: tp.pid,
    remote_id: rpiid,
};

pub const start = Proxy.start;

const Proxy = struct {
    allocator: std.mem.Allocator,
    endpoint: tp.pid,
    remote_id: rpiid,
    receiver: tp.Receiver(*@This()),

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .endpoint = args.endpoint,
            .remote_id = args.remote_id,
            .receiver = .init(receive, deinit, self),
        };
        errdefer self.deinit();
        _ = tp.set_trap(true);
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.endpoint.deinit();
        self.allocator.destroy(self);
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive_safe(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive_safe(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        var reason: []const u8 = "";
        var to_name: []const u8 = "";
        var target_id: lpiid = .empty;
        var payload: cbor.Raw = .empty;

        if (try m.match(.{ "endpoint_exit", tp.extract(&reason) })) {
            return tp.exit(reason);
        } else if (try m.match(.{ "exit", tp.extract(&reason) })) {
            if (from.instance_id() != self.endpoint.instance_id()) {
                self.endpoint.send(.{
                    "local_link_exit",
                    lpiid.fromInt(from.instance_id().toInt()),
                    reason,
                }) catch {};
                return;
            }
            self.endpoint.send(.{ "proxy_exit", self.remote_id, reason }) catch {};
            return tp.exit(reason);
        } else if (try m.match(.{"establish_wire_link"})) {
            try from.link();
            try self.endpoint.send(.{
                "link_wire",
                lpiid.fromInt(from.instance_id().toInt()),
                self.remote_id,
            });
        } else if (try m.match(.{ "set_notify", tp.extract(&target_id) })) {
            if (tp.pid.from_id(.fromInt(target_id.toInt()))) |actor| {
                defer actor.deinit();
                try actor.link();
            }
        } else if (try m.match(.{ "deliver_named", tp.extract(&to_name), tp.extract(&payload) })) {
            const actor = tp.env.get().proc(to_name);
            try actor.send_raw(tp.message{ .buf = payload.bytes });
        } else if (try m.match(.{ "deliver_pid", tp.extract(&target_id), tp.extract(&payload) })) {
            if (tp.pid.from_id(.fromInt(target_id.toInt()))) |actor| {
                defer actor.deinit();
                try actor.send_raw(tp.message{ .buf = payload.bytes });
            }
        } else {
            try self.endpoint.send(.{
                "send",
                lpiid.fromInt(from.instance_id().toInt()),
                self.remote_id,
                cbor.Raw{ .bytes = m.buf },
            });
        }
    }
};
