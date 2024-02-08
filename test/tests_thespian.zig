const std = @import("std");
const thespian = @import("thespian");
const cbor = @import("cbor");

pub const unexpected = thespian.unexpected;
const message = thespian.message;
const error_message = thespian.error_message;

test "thespian.unexpected" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(error.Exit, unexpected(message.fmt(.{"TEST"})));
    const json = try cbor.toJson(error_message(), &buf);
    try std.testing.expectEqualStrings("[\"exit\",\"UNEXPECTED_MESSAGE: [\\\"TEST\\\"]\"]", json);
}
