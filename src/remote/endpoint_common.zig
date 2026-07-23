const std = @import("std");
const tp = @import("thespian");
const cbor = @import("cbor");

const framing = @import("framing.zig");
const protocol = @import("remote.zig").protocol;
const proxy = @import("proxy.zig");

const rpiid = protocol.rpiid;
const lpiid = protocol.lpiid;

pub fn create(EndpointT: type) type {
    return struct {
        allocator: std.mem.Allocator,
        accumulator: framing.Accumulator = .{},
        remote_proxies: std.AutoHashMapUnmanaged(rpiid, tp.pid) = .empty,
        frame_buf: [protocol.max_frame_size]u8 = undefined,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            var proxy_it = self.remote_proxies.valueIterator();
            while (proxy_it.next()) |p| {
                p.send(.{ "endpoint_exit", "transport_closed" }) catch {};
                p.deinit();
            }
            self.remote_proxies.deinit(self.allocator);
            self.accumulator.deinit(self.allocator);
        }

        pub fn receive(self: *@This(), _: tp.pid_ref, m: tp.message) !void {
            var from_id: lpiid = .empty;
            var to_id: rpiid = .empty;
            var to_name: []const u8 = "";
            var payload: cbor.Raw = .empty;
            var reason: []const u8 = "";

            if (try m.match(.{ "send", tp.extract(&from_id), tp.extract(&to_id), cbor.extract(&payload) })) {
                try self.send_wire_by_id(from_id, to_id, payload);
            } else if (try m.match(.{ "send", tp.extract(&from_id), tp.extract(&to_name), cbor.extract(&payload) })) {
                try self.send_wire_named(from_id, to_name, payload);
            } else if (try m.match(.{ "link_wire", tp.extract(&from_id), tp.extract(&to_id) })) {
                try self.send_wire_link(from_id, to_id);
            } else if (try m.match(.{ "local_link_exit", tp.extract(&from_id), tp.extract(&reason) })) {
                try self.send_wire_exit(from_id, reason);
            } else if (try m.match(.{ "proxy_exit", tp.extract(&to_id), tp.any })) {
                if (self.remote_proxies.fetchRemove(to_id)) |entry| entry.value.deinit();
            } else {
                return tp.unexpected(m);
            }
        }

        pub fn feed(self: *@This(), bytes: []const u8) !void {
            var maybe_frame = self.accumulator.feed(self.allocator, bytes);
            while (maybe_frame) |frame| {
                try self.dispatch_inbound(.{ .bytes = frame });
                maybe_frame = self.accumulator.feed(self.allocator, &.{});
            }
        }

        fn get_or_create_proxy(self: *@This(), remote_id: rpiid) !tp.pid_ref {
            if (self.remote_proxies.getPtr(remote_id)) |p| return p.ref();
            const p = try tp.spawn(self.allocator, proxy.Args{
                .allocator = self.allocator,
                .endpoint = tp.self_pid().clone(),
                .remote_id = remote_id,
            }, proxy.start, "proxy");
            try self.remote_proxies.put(self.allocator, remote_id, p);
            return self.remote_proxies.getPtr(remote_id).?.ref();
        }

        fn dispatch_inbound(self: *@This(), frame: cbor.Raw) !void {
            const msg = try protocol.decode(frame);
            switch (msg) {
                .send => |s| {
                    const from_rpiid: rpiid = .fromInt(s.from_id.toInt());
                    const to_lpiid: lpiid = .fromInt(s.to_id.toInt());
                    const prx = try self.get_or_create_proxy(from_rpiid);
                    try prx.send(.{ "deliver_pid", to_lpiid, s.payload });
                },
                .send_named => |s| {
                    if (s.from_id != lpiid.empty) {
                        const from_rpiid: rpiid = .fromInt(s.from_id.toInt());
                        const prx = try self.get_or_create_proxy(from_rpiid);
                        try prx.send(.{ "deliver_named", s.to_name, s.payload });
                    } else {
                        const actor = tp.env.get().proc(s.to_name);
                        try actor.send_raw(tp.message{ .buf = s.payload.bytes });
                    }
                },
                .exit => |e| {
                    const from_rpiid: rpiid = .fromInt(e.local_id.toInt());
                    if (self.remote_proxies.get(from_rpiid)) |p|
                        p.send(.{ "exit", e.reason }) catch {};
                },
                .link => |lnk| {
                    const from_rpiid: rpiid = .fromInt(lnk.local_id.toInt());
                    const target_lpiid: lpiid = .fromInt(lnk.remote_id.toInt());
                    const prx = try self.get_or_create_proxy(from_rpiid);
                    try prx.send(.{ "set_notify", target_lpiid });
                },
                .transport_error => |te| return tp.exit(te.reason),
            }
        }

        fn send_wire_by_id(self: *@This(), from_id: lpiid, to_id: rpiid, payload: cbor.Raw) !void {
            try self.send_wire(.{ .send = .{ .from_id = from_id, .to_id = to_id, .payload = payload } });
        }

        fn send_wire_named(self: *@This(), from_id: lpiid, to_name: []const u8, payload: cbor.Raw) !void {
            try self.send_wire(.{ .send_named = .{ .from_id = from_id, .to_name = to_name, .payload = payload } });
        }

        fn send_wire_link(self: *@This(), local_id: lpiid, remote_id: rpiid) !void {
            try self.send_wire(.{ .link = .{ .local_id = local_id, .remote_id = remote_id } });
        }

        fn send_wire_exit(self: *@This(), local_id: lpiid, reason: []const u8) !void {
            try self.send_wire(.{ .exit = .{ .local_id = local_id, .reason = reason } });
        }

        pub fn send_transport_error(self: *@This(), reason: []const u8) !void {
            try self.send_wire(.{ .transport_error = .{ .reason = reason } });
        }

        fn send_wire(self: *@This(), msg: protocol) !void {
            const frame = try msg.encode(&self.frame_buf);
            try self.send_frame(frame);
        }

        fn send_frame(self: *@This(), frame: []const u8) !void {
            const endpoint: *EndpointT = @alignCast(@fieldParentPtr("endpoint", self));
            try endpoint.send_frame(frame);
        }
    };
}
