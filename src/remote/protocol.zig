const std = @import("std");
const cbor = @import("cbor");
const TypedInt = @import("TypedInt");
const tp = @import("thespian");
const framing = @import("framing.zig");

pub const ProtocolMessage = union(enum) {
    send: struct {
        from_id: lpiid,
        to_id: rpiid,
        payload: cbor.Raw,
    },

    send_named: struct {
        from_id: lpiid,
        to_name: []const u8,
        payload: cbor.Raw,
    },

    link: struct {
        local_id: lpiid,
        remote_id: rpiid,
    },

    exit: struct {
        local_id: lpiid,
        reason: []const u8,
    },

    transport_error: struct {
        reason: []const u8,
    },

    pub const rpiid = TypedInt.Tagged(usize, "RPID"); // remote piid
    pub const lpiid = TypedInt.Tagged(usize, "LPID"); // local piid
    pub const piid = tp.piid;

    pub const max_frame_size = 8 * 4096; // max_message_size

    pub fn encode(self: @This(), buf: []u8) ![]u8 {
        return switch (self) {
            .send => |v| framing.write_frame(buf, .{ "send", v.from_id, v.to_id, v.payload }),
            .send_named => |v| framing.write_frame(buf, .{ "send_named", v.from_id, v.to_name, v.payload }),
            .link => |v| framing.write_frame(buf, .{ "link", v.local_id, v.remote_id }),
            .exit => |v| framing.write_frame(buf, .{ "exit", v.local_id, v.reason }),
            .transport_error => |v| framing.write_frame(buf, .{ "transport_error", v.reason }),
        };
    }

    pub fn decode(frame: cbor.Raw) !@This() {
        var local_id: lpiid = .empty;
        var remote_id: rpiid = .empty;
        var name: []const u8 = "";
        var payload: cbor.Raw = .empty;
        var reason: []const u8 = "";

        if (try cbor.match(frame.bytes, .{ "send", cbor.extract(&local_id), cbor.extract(&remote_id), cbor.extract(&payload) }))
            return .{ .send = .{ .from_id = local_id, .to_id = remote_id, .payload = payload } };

        if (try cbor.match(frame.bytes, .{ "send_named", cbor.extract(&local_id), cbor.extract(&name), cbor.extract(&payload) }))
            return .{ .send_named = .{ .from_id = local_id, .to_name = name, .payload = payload } };

        if (try cbor.match(frame.bytes, .{ "link", cbor.extract(&local_id), cbor.extract(&remote_id) }))
            return .{ .link = .{ .local_id = local_id, .remote_id = remote_id } };

        if (try cbor.match(frame.bytes, .{ "exit", cbor.extract(&local_id), cbor.extract(&reason) }))
            return .{ .exit = .{ .local_id = local_id, .reason = reason } };

        if (try cbor.match(frame.bytes, .{ "transport_error", cbor.extract(&reason) }))
            return .{ .transport_error = .{ .reason = reason } };

        return error.UnknownMessageType;
    }
};
