const std = @import("std");
const thespian = @import("thespian");

const Target = struct {
    receiver: thespian.Receiver(*@This()),
    allocator: std.mem.Allocator,

    fn start(allocator: std.mem.Allocator) thespian.result {
        const self = allocator.create(@This()) catch |e| return thespian.exit_error(e, @errorReturnTrace());
        self.* = .{ .allocator = allocator, .receiver = .init(receive, deinit, self) };
        thespian.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.allocator.destroy(self);
    }

    fn receive(_: *@This(), from: thespian.pid_ref, m: thespian.message) thespian.result {
        if (try m.match(.{"ping"})) return from.send(.{"pong"});
        if (try m.match(.{"shutdown"})) return thespian.exit("target_done");
        return thespian.unexpected(m);
    }
};

const Tapper = struct {
    receiver: thespian.Receiver(*@This()),
    allocator: std.mem.Allocator,
    target: thespian.pid,
    target_id: u64,
    self_id: u64,
    seen: struct { recv: bool = false, send: bool = false, pong: bool = false } = .{},

    fn start(allocator: std.mem.Allocator) thespian.result {
        return init(allocator) catch |e| return thespian.exit_error(e, @errorReturnTrace());
    }

    fn init(allocator: std.mem.Allocator) !void {
        _ = thespian.set_trap(true);
        const target = try thespian.spawn_link(allocator, allocator, Target.start, "tap_target");
        const self = try allocator.create(@This());
        self.* = .{
            .allocator = allocator,
            .receiver = .init(receive_fn, deinit, self),
            .target = target,
            .target_id = @backingInt(target.instance_id()),
            .self_id = @backingInt(thespian.self_pid().instance_id()),
        };
        thespian.tap_instance(target.instance_id());
        try target.send(.{"ping"});
        thespian.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.target.deinit();
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: thespian.pid_ref, m: thespian.message) thespian.result {
        return self.receive(from, m) catch |e| return thespian.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), _: thespian.pid_ref, m: thespian.message) !void {
        var id: u64 = 0;
        var peer_id: u64 = 0;
        var peer_name: []const u8 = "";
        var msg: []const u8 = "";
        var reason: []const u8 = "";
        if (try m.match(.{ "debug_tap_id", thespian.extract(&id), "recv", thespian.extract(&peer_id), thespian.extract(&peer_name), thespian.extract_cbor(&msg) })) {
            try std.testing.expectEqual(self.target_id, id);
            if (try thespian.message.match(.{ .buf = msg }, .{"ping"})) {
                try std.testing.expectEqual(self.self_id, peer_id);
                try std.testing.expectEqualStrings("tap_instance_test", peer_name);
                self.seen.recv = true;
            }
        } else if (try m.match(.{ "debug_tap_id", thespian.extract(&id), "send", thespian.extract(&peer_id), thespian.extract(&peer_name), thespian.extract_cbor(&msg) })) {
            try std.testing.expectEqual(self.target_id, id);
            try std.testing.expectEqual(self.self_id, peer_id);
            try std.testing.expectEqualStrings("tap_instance_test", peer_name);
            if (try thespian.message.match(.{ .buf = msg }, .{"pong"})) self.seen.send = true;
        } else if (try m.match(.{"pong"})) {
            self.seen.pong = true;
            try self.target.send(.{"shutdown"});
        } else if (try m.match(.{ "debug_tap_id", thespian.extract(&id), "exit", 0, "", thespian.extract_cbor(&msg) })) {
            try std.testing.expectEqual(self.target_id, id);
            try std.testing.expect(self.seen.recv and self.seen.send and self.seen.pong);
            try std.testing.expect(try thespian.message.match(.{ .buf = msg }, .{ "exit", "target_done" }));
            try std.testing.expect(thespian.untap_instance(self.target.instance_id()));
            try std.testing.expect(!thespian.untap_instance(self.target.instance_id()));
            return thespian.exit("success");
        } else if (try m.match(.{ "exit", thespian.extract(&reason) })) {
            // the link exit comes before the tap exit event
            if (!std.mem.eql(u8, reason, "target_done")) return thespian.exit(reason);
        }
    }
};

test "tap_instance streams the messages and exit of one actor" {
    const allocator = std.testing.allocator;
    var ctx = try thespian.context.init(allocator, .{});
    defer ctx.deinit();
    var success = false;
    var exit_handler = thespian.make_exit_handler(&success, struct {
        fn handle(ok: *bool, status: []const u8) void {
            if (std.mem.eql(u8, status, "success")) ok.* = true else std.log.err("EXITED: {s}", .{status});
        }
    }.handle);
    _ = try ctx.spawn_link(allocator, Tapper.start, "tap_instance_test", &exit_handler, null);
    ctx.run();
    try std.testing.expect(success);
}
