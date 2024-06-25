const std = @import("std");
const cbor_mod = @import("cbor");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectError = std.testing.expectError;

const fmt = cbor_mod.fmt;
const toJson = cbor_mod.toJson;
const toJsonPretty = cbor_mod.toJsonPretty;
const fromJson = cbor_mod.fromJson;
const fromJsonAlloc = cbor_mod.fromJsonAlloc;
const toJsonAlloc = cbor_mod.toJsonAlloc;
const toJsonPrettyAlloc = cbor_mod.toJsonPrettyAlloc;
const decodeType = cbor_mod.decodeType;
const matchInt = cbor_mod.matchInt;
const matchIntValue = cbor_mod.matchIntValue;
const matchValue = cbor_mod.matchValue;
const match = cbor_mod.match;
const isNull = cbor_mod.isNull;
const writeArrayHeader = cbor_mod.writeArrayHeader;
const writeMapHeader = cbor_mod.writeMapHeader;
const writeValue = cbor_mod.writeValue;
const extract = cbor_mod.extract;
const extract_cbor = cbor_mod.extract_cbor;

const more = cbor_mod.more;
const any = cbor_mod.any;
const string = cbor_mod.string;
const number = cbor_mod.number;
const array = cbor_mod.array;
const map = cbor_mod.map;

test "cbor simple" {
    var buf: [128]u8 = undefined;
    try expectEqualDeep(
        fmt(&buf, .{ "five", 5, "four", 4, .{ "three", 3 } }),
        &[_]u8{ 0x85, 0x64, 0x66, 0x69, 0x76, 0x65, 0x05, 0x64, 0x66, 0x6f, 0x75, 0x72, 0x04, 0x82, 0x65, 0x74, 0x68, 0x72, 0x65, 0x65, 0x03 },
    );
}

test "cbor exit message" {
    var buf: [128]u8 = undefined;
    try expectEqualDeep(
        fmt(&buf, .{ "exit", "normal" }),
        &[_]u8{ 0x82, 0x64, 0x65, 0x78, 0x69, 0x74, 0x66, 0x6E, 0x6F, 0x72, 0x6D, 0x61, 0x6C },
    );
}

test "cbor error.OutOfMemory" {
    var buf: [128]u8 = undefined;
    try expectEqualDeep(
        fmt(&buf, .{ "exit", error.OutOfMemory }),
        &[_]u8{ 0x82, 0x64, 0x65, 0x78, 0x69, 0x74, 0x71, 0x65, 0x72, 0x72, 0x6F, 0x72, 0x2E, 0x4F, 0x75, 0x74, 0x4F, 0x66, 0x4D, 0x65, 0x6D, 0x6F, 0x72, 0x79 },
    );
}

test "cbor error.OutOfMemory json" {
    var buf: [128]u8 = undefined;
    var json_buf: [128]u8 = undefined;
    const cbor = fmt(&buf, .{ "exit", error.OutOfMemory });
    try expectEqualDeep(toJson(cbor, &json_buf),
        \\["exit","error.OutOfMemory"]
    );
}

test "cbor.decodeType2" {
    var buf = [_]u8{ 0x20, 0xDF };
    var iter: []const u8 = &buf;
    const t = try decodeType(&iter);
    try expectEqual(t.major, 1);
    try expectEqual(t.minor, 0);
    try expectEqual(iter[0], 0xDF);
}

test "cbor.decodeType3" {
    var buf = [_]u8{ 0x03, 0xDF };
    var iter: []const u8 = &buf;
    const t = try decodeType(&iter);
    try expectEqual(t.major, 0);
    try expectEqual(t.minor, 3);
    try expectEqual(iter[0], 0xDF);
}

test "cbor.matchI64 small" {
    var buf = [_]u8{ 1, 0xDF };
    var iter: []const u8 = &buf;
    var val: i64 = 0;
    try expect(try matchInt(i64, &iter, &val));
    try expectEqual(val, 1);
    try expectEqual(iter[0], 0xDF);
}

test "cbor.matchI64 1byte" {
    var buf = [_]u8{ 0x18, 0x1A, 0xDF };
    var iter: []const u8 = &buf;
    var val: i64 = 0;
    try expect(try matchInt(i64, &iter, &val));
    try expectEqual(val, 26);
    try expectEqual(iter[0], 0xDF);
}

test "cbor.matchI64 2byte" {
    var buf = [_]u8{ 0x19, 0x01, 0x07, 0xDF };
    var iter: []const u8 = &buf;
    var val: i64 = 0;
    try expect(try matchInt(i64, &iter, &val));
    try expectEqual(val, 263);
    try expectEqual(iter[0], 0xDF);
}

test "cbor.matchI64 8byte" {
    var buf = [_]u8{ 0x1B, 0x00, 0x00, 0xEF, 0x6F, 0xC1, 0x4A, 0x0A, 0x1F, 0xDF };
    var iter: []const u8 = &buf;
    var val: i64 = 0;
    try expect(try matchInt(i64, &iter, &val));
    try expectEqual(val, 263263263263263);
    try expectEqual(iter[0], 0xDF);
}

test "cbor.matchI64 error.CborIntegerTooLarge" {
    var buf = [_]u8{ 0x1B, 0xA9, 0x0A, 0xDE, 0x0D, 0x4E, 0x2B, 0x8A, 0x1F, 0xDF };
    var iter: []const u8 = &buf;
    var val: i64 = 0;
    const result = matchInt(i64, &iter, &val);
    try expectError(error.CborIntegerTooLarge, result);
}

test "cbor.matchI64 error.CborTooShort" {
    var buf = [_]u8{ 0x19, 0x01 };
    var iter: []const u8 = &buf;
    var val: i64 = 0;
    const result = matchInt(i64, &iter, &val);
    try expectError(error.CborTooShort, result);
}

test "cbor.matchI64Value" {
    var buf = [_]u8{ 7, 0xDF };
    var iter: []const u8 = &buf;
    try expect(try matchIntValue(i64, &iter, 7));
}

test "cbor.matchValue(i64)" {
    var buf: [128]u8 = undefined;
    var iter = fmt(&buf, 7);
    try expect(try matchValue(&iter, 7));
}

test "cbor.matchValue(i64) multi" {
    var buf: [128]u8 = undefined;
    const iter = fmt(&buf, 7);
    const iter2 = fmt(buf[iter.len..], 8);
    var iter3 = buf[0 .. iter.len + iter2.len];
    try expect(try matchValue(&iter3, 7));
    try expect(try matchValue(&iter3, 8));
}

test "cbor.match(.{i64...})" {
    var buf: [128]u8 = undefined;
    const v = .{ 5, 4, 3, 123456, 234567890 };
    const m = fmt(&buf, v);
    try expect(try match(m, v));
}

test "cbor.match(.{i64... more})" {
    var buf: [128]u8 = undefined;
    const v = .{ 5, 4, 3, 123456, 234567890, 6, 5, 4, 3, 2, 1 };
    const m = fmt(&buf, v);
    try expect(try match(m, .{ 5, 4, 3, more }));
}

test "cbor.match(.{any, i64... more})" {
    var buf: [128]u8 = undefined;
    const v = .{ "cbor", 4, 3, 123456, 234567890, 6, 5, 4, 3, 2, 1 };
    const m = fmt(&buf, v);
    try expect(try match(m, .{ any, 4, 3, more }));
}

test "cbor.match(.{types...})" {
    var buf: [128]u8 = undefined;
    const v = .{ "five", 5, "four", 4, .{ "three", 3 } };
    const m = fmt(&buf, v);
    try expect(try match(m, .{ string, number, string, number, array }));

    try expect(!try match(m, .{ string, number, string, number }));
    try expect(!try match(m, .{ number, string, number, array, any }));
    try expect(try match(m, .{ any, number, string, number, any }));

    try expect(try match(m, .{ "five", number, string, 4, any }));
    try expect(try match(m, .{ "five", 5, "four", 4, array }));
    try expect(try match(m, .{ "five", 5, more }));
    try expect(try match(m, .{ "five", 5, "four", 4, array, more }));
    try expect(!try match(m, .{ "five", 5, "four", 4, array, any }));
    try expect(!try match(m, .{ "four", 5, "five", 4, array, any }));
    try expect(try match(m, .{ "five", 5, "four", 4, .{ "three", 3 } }));
}

test "cbor.nulls" {
    var buf: [128]u8 = undefined;
    try expect(isNull(fmt(&buf, .{})));
    try expect(!isNull(fmt(&buf, .{1})));
}

test "cbor.stream_writer" {
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    try writeArrayHeader(writer, 5);
    try writeValue(writer, "five");
    try writeValue(writer, 5);
    try writeValue(writer, "four");
    try writeValue(writer, 4);
    try writeArrayHeader(writer, 2);
    try writeValue(writer, "three");
    try writeValue(writer, 3);
    try expect(try match(stream.getWritten(), .{ "five", 5, "four", 4, .{ "three", 3 } }));
}

test "cbor.stream_object_writer" {
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    try writeMapHeader(writer, 3);
    try writeValue(writer, "five");
    try writeValue(writer, 5);
    try writeValue(writer, "four");
    try writeValue(writer, 4);
    try writeValue(writer, "three");
    try writeValue(writer, 3);
    const obj = stream.getWritten();
    var json_buf: [128]u8 = undefined;
    const json = try toJson(obj, &json_buf);
    try expectEqualDeep(json,
        \\{"five":5,"four":4,"three":3}
    );
}

test "cbor.match_bool" {
    var buf: [128]u8 = undefined;
    const m = fmt(&buf, .{ false, true, 5, "five" });
    try expect(try match(m, .{ false, true, 5, "five" }));
    try expect(!try match(m, .{ true, false, 5, "five" }));
}

test "cbor.extract_match" {
    var buf: [128]u8 = undefined;
    var t: bool = false;
    const extractor = extract(&t);
    var iter = fmt(&buf, true);
    try expect(try extractor.extract(&iter));
    try expect(t);
    iter = fmt(&buf, false);
    try expect(try extractor.extract(&iter));
    try expect(!t);

    const m = fmt(&buf, .{ false, true, 5, "five" });
    try expect(try match(m, .{ extract(&t), true, 5, "five" }));
    try expect(!t);
    try expect(try match(m, .{ false, extract(&t), 5, "five" }));
    try expect(t);

    var i: i64 = undefined;
    try expect(try match(m, .{ false, true, extract(&i), "five" }));
    try expect(i == 5);

    var u: u64 = undefined;
    try expect(try match(m, .{ false, true, extract(&u), "five" }));
    try expect(u == 5);

    var s: []const u8 = undefined;
    try expect(try match(m, .{ false, true, 5, extract(&s) }));
    try expect(std.mem.eql(u8, "five", s));
}

test "cbor.extract_cbor" {
    var buf: [128]u8 = undefined;
    const v = .{ "five", 5, "four", 4, .{ "three", 3 } };
    const m = fmt(&buf, v);

    try expect(try match(m, .{ "five", 5, "four", 4, .{ "three", 3 } }));

    var sub: []const u8 = undefined;
    try expect(try match(m, .{ "five", 5, "four", 4, extract_cbor(&sub) }));
    try expect(try match(sub, .{ "three", 3 }));
}

test "cbor.extract_nested" {
    var buf: [128]u8 = undefined;
    const v = .{ "five", 5, "four", 4, .{ "three", 3 } };
    const m = fmt(&buf, v);

    var u: u64 = undefined;
    try expect(try match(m, .{ "five", 5, "four", 4, .{ "three", extract(&u) } }));
    try expect(u == 3);
}

test "cbor.match_map" {
    var buf: [128]u8 = undefined;
    const v = .{ "five", 5, "four", 4, .{ .three = 3 } };
    const m = fmt(&buf, v);
    try expect(try match(m, .{ "five", 5, "four", 4, map }));
}

test "cbor.extract_map_cbor" {
    var buf: [128]u8 = undefined;
    const v = .{ "five", 5, "four", 4, .{ .three = 3 } };
    const m = fmt(&buf, v);
    var map_cbor: []const u8 = undefined;
    try expect(try match(m, .{ "five", 5, "four", 4, extract_cbor(&map_cbor) }));
    var json_buf: [256]u8 = undefined;
    const json = try toJson(map_cbor, &json_buf);
    try expectEqualDeep(json,
        \\{"three":3}
    );
}

test "cbor.extract_map" {
    var buf: [128]u8 = undefined;
    const v = .{ "five", 5, "four", 4, .{ .three = 3 } };
    const m = fmt(&buf, v);
    var obj = std.json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();
    try expect(try match(m, .{ "five", 5, "four", 4, extract(&obj) }));
    try expect(obj.contains("three"));
    try expectEqual(obj.get("three").?, std.json.Value{ .integer = 3 });
}

test "cbor.extract_map_map" {
    var buf: [128]u8 = undefined;
    const v = .{ "five", 5, "four", 4, .{ .three = 3, .child = .{ .two = 2, .one = .{ 1, 2, 3, true, false, null } } } };
    const m = fmt(&buf, v);
    var a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a.deinit();
    var obj = std.json.ObjectMap.init(a.allocator());
    defer obj.deinit();
    try expect(try match(m, .{ "five", 5, "four", 4, extract(&obj) }));
    try expect(obj.contains("three"));
    try expectEqual(obj.get("three").?, std.json.Value{ .integer = 3 });
    var child = obj.get("child").?.object;
    try expectEqual(child.get("two"), std.json.Value{ .integer = 2 });

    var json_buf: [256]u8 = undefined;
    const json = try toJson(m, &json_buf);
    try expectEqualDeep(json,
        \\["five",5,"four",4,{"three":3,"child":{"two":2,"one":[1,2,3,true,false,null]}}]
    );
}

test "cbor.extract_value" {
    var buf: [128]u8 = undefined;
    const v = .{ "five", 5, "four", 4, .{ .three = 3 } };
    const m = fmt(&buf, v);
    var value = std.json.Value{ .null = {} };
    var value_int = std.json.Value{ .null = {} };
    try expect(try match(m, .{ "five", 5, extract(&value), extract(&value_int), any }));
    try expectEqualDeep(value.string, "four");
    try expectEqualDeep(value_int.integer, 4);
}

test "cbor.match_more_nested" {
    var buf: [128]u8 = undefined;
    const v = .{ .{124}, .{ "three", 3 } };
    const m = fmt(&buf, v);
    try expect(try match(m, .{ .{more}, .{more} }));
}

test "cbor.extract_number_limits" {
    var buf: [128]u8 = undefined;
    const bigint: u64 = 18446744073709551615;
    var u: u64 = undefined;
    var i: i64 = undefined;
    const m = fmt(&buf, bigint);
    try expect(try match(m, extract(&u)));
    try expectError(error.CborIntegerTooLarge, match(m, extract(&i)));
}

test "cbor.toJson" {
    var buf: [128]u8 = undefined;
    var json_buf: [128]u8 = undefined;
    const a = fmt(&buf, .{ "string\r\n", "\tstring\t", "\r\nstring" });
    const json = try toJson(a, &json_buf);
    try expect(try match(a, .{ "string\r\n", "\tstring\t", "\r\nstring" }));
    try expectEqualDeep(json,
        \\["string\r\n","\tstring\t","\r\nstring"]
    );
}

test "cbor.toJson_object" {
    var buf: [128]u8 = undefined;
    var json_buf: [128]u8 = undefined;
    const a = fmt(&buf, .{ .five = 5, .four = 4, .three = 3 });
    const json = try toJson(a, &json_buf);
    try expectEqualDeep(json,
        \\{"five":5,"four":4,"three":3}
    );
}

test "cbor.toJsonPretty_object" {
    var buf: [128]u8 = undefined;
    var json_buf: [128]u8 = undefined;
    const a = fmt(&buf, .{ .five = 5, .four = 4, .three = 3 });
    const json = try toJsonPretty(a, &json_buf);
    try expectEqualDeep(json,
        \\{
        \\ "five": 5,
        \\ "four": 4,
        \\ "three": 3
        \\}
    );
}

test "cbor.fromJson_small" {
    var cbor_buf: [128]u8 = undefined;
    const json_buf: []const u8 =
        \\[12345]
    ;
    const cbor = try fromJson(json_buf, &cbor_buf);
    try expect(try match(cbor, .{12345}));
}

test "cbor.fromJson" {
    var cbor_buf: [128]u8 = undefined;
    const json_buf: []const u8 =
        \\["string\r\n","\tstring\t","\r\nstring",12345]
    ;
    const cbor = try fromJson(json_buf, &cbor_buf);
    try expect(try match(cbor, .{ "string\r\n", "\tstring\t", "\r\nstring", 12345 }));
}

test "cbor.fromJson_object" {
    var cbor_buf: [128]u8 = undefined;
    const json_buf: []const u8 =
        \\{"five":5,"four":4,"three":3}
    ;
    const cbor = try fromJson(json_buf, &cbor_buf);
    try expect(try match(cbor, map));
}

test "cbor f32" {
    var buf: [128]u8 = undefined;
    try expectEqualDeep(
        fmt(&buf, .{ "float", @as(f32, 0.96891385316848755) }),
        &[_]u8{
            0x82, // 82               # array(2)
            0x65, //    65            # text(5)
            0x66, //       666C6F6174 # "float"
            0x6C,
            0x6F,
            0x61,
            0x74,
            0xfa, //    FA 3F780ABD   # primitive(1064831677)
            0x3F,
            0x78,
            0x0A,
            0xBD,
        },
    );
}

test "cbor.fromJson_object f32" {
    var buf: [128]u8 = undefined;
    const json_buf: []const u8 =
        \\["float",0.96891385316848755]
    ;
    const cbor = try fromJson(json_buf, &buf);
    try expect(try match(cbor, array));

    try expectEqualDeep(
        &[_]u8{
            0x82, // 82                     # array(2)
            0x65, //    65                  # text(5)
            0x66, //       666C6F6174       # "float"
            0x6C,
            0x6F,
            0x61,
            0x74,
            0xfb, //    FB 3FEF0157A0000000 # primitive(4606902419681443840)
            0x3f,
            0xef,
            0x01,
            0x57,
            0xa0,
            0x00,
            0x00,
            0x00,
        },
        cbor,
    );
}

test "cbor.extract_match_f32" {
    var buf: [128]u8 = undefined;
    const json_buf: []const u8 =
        \\["float",0.96891385316848755]
    ;
    const m = try fromJson(json_buf, &buf);

    try expect(try match(m, .{ "float", @as(f64, 0.96891385316848755) }));

    var f: f64 = undefined;
    try expect(try match(m, .{ "float", extract(&f) }));
    try expectEqual(0.96891385316848755, f);
}

test "cbor.extract_cbor f64" {
    var buf: [128]u8 = undefined;
    const json_buf: []const u8 =
        \\["float",[0.96891385316848755],"check"]
    ;
    const m = try fromJson(json_buf, &buf);

    var sub: []const u8 = undefined;
    try expect(try match(m, .{ "float", extract_cbor(&sub), "check" }));

    const json = try toJsonPrettyAlloc(std.testing.allocator, sub);
    defer std.testing.allocator.free(json);

    const json2 = try toJsonAlloc(std.testing.allocator, sub);
    defer std.testing.allocator.free(json2);

    try expectEqualDeep("[9.689138531684875e-1]", json2);
}
