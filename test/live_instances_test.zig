const std = @import("std");
const thespian = @import("thespian");

const Idle = struct {
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

    fn receive(_: *@This(), _: thespian.pid_ref, m: thespian.message) thespian.result {
        if (try m.match(.{"shutdown"})) return thespian.exit_normal();
        return thespian.unexpected(m);
    }
};

fn find(instances: []const thespian.Instance, id: thespian.piid) ?thespian.Instance {
    for (instances) |instance| if (instance.id == id) return instance;
    return null;
}

test "live_instances lists named and unnamed actors in id order" {
    const allocator = std.testing.allocator;
    var ctx = try thespian.context.init(allocator, .{});
    defer ctx.deinit();
    var exit_handler = thespian.make_exit_handler({}, struct {
        fn handle(_: void, _: []const u8) void {}
    }.handle);

    const named = try ctx.spawn_link(allocator, Idle.start, "live_instances_named", &exit_handler, null);
    defer named.deinit();
    const unnamed = try ctx.spawn_link(allocator, Idle.start, "", &exit_handler, null);
    defer unnamed.deinit();

    const instances = try thespian.live_instances(allocator);
    defer thespian.free_instances(allocator, instances);

    const n = find(instances, named.instance_id()) orelse return error.NamedActorMissing;
    try std.testing.expectEqualStrings("live_instances_named", n.name);
    const u = find(instances, unnamed.instance_id()) orelse return error.UnnamedActorMissing;
    try std.testing.expectEqualStrings("", u.name);
    for (instances[1..], instances[0 .. instances.len - 1]) |b, a|
        try std.testing.expect(@backingInt(a.id) < @backingInt(b.id));

    try named.send(.{"shutdown"});
    try unnamed.send(.{"shutdown"});
    ctx.run();

    const after = try thespian.live_instances(allocator);
    defer thespian.free_instances(allocator, after);
    try std.testing.expect(find(after, named.instance_id()) == null);
    try std.testing.expect(find(after, unnamed.instance_id()) == null);
}
