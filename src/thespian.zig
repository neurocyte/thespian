const std = @import("std");
const c = @cImport({
    @cInclude("thespian/c/file_descriptor.h");
    @cInclude("thespian/c/instance.h");
    @cInclude("thespian/c/metronome.h");
    @cInclude("thespian/c/timeout.h");
    @cInclude("thespian/c/signal.h");
    @cInclude("thespian/backtrace.h");
});
const cbor = @import("cbor");
pub const subprocess = @import("subprocess.zig");

pub const install_debugger = c.install_debugger;
pub const max_message_size = 8 * 4096;
threadlocal var message_buffer: [max_message_size]u8 = undefined;
threadlocal var error_message_buffer: [256]u8 = undefined;
threadlocal var error_buffer_tl: c.thespian_error = .{
    .base = null,
    .len = 0,
};

pub const result = error{Exit}!void;
pub const extract = cbor.extract;
pub const extract_cbor = cbor.extract_cbor;

pub const number = cbor.number;
pub const bytes = cbor.bytes;
pub const string = cbor.string;
pub const array = cbor.array;
pub const map = cbor.map;
pub const tag = cbor.tag;
pub const boolean = cbor.boolean;
pub const null_ = cbor.null_;
pub const any = cbor.any;
pub const more = cbor.more;

pub const Ownership = enum {
    Wrapped,
    Owned,
};

fn Pid(comptime own: Ownership) type {
    return struct {
        h: c.thespian_handle,

        const ownership = own;
        const Self = @This();

        pub fn clone(self: Self) Pid(.Owned) {
            return .{ .h = c.thespian_handle_clone(self.h) };
        }

        pub fn ref(self: Self) Pid(.Wrapped) {
            return .{ .h = self.h };
        }

        pub fn deinit(self: *const Self) void {
            comptime if (ownership == Ownership.Wrapped)
                @compileError("cannot call deinit on Pid(.Wrapped)");
            c.thespian_handle_destroy(self.h);
        }

        pub fn send_raw(self: Self, m: message) result {
            const ret = c.thespian_handle_send_raw(self.h, m.to(c.cbor_buffer));
            if (ret) |err|
                return set_error(err.*);
        }

        pub fn send(self: Self, m: anytype) result {
            return self.send_raw(message.fmt(m));
        }

        pub fn call(self: Self, a: std.mem.Allocator, request: anytype) error{ OutOfMemory, ThespianSpawnFailed }!message {
            return CallContext.call(a, self.ref(), message.fmt(request));
        }

        pub fn link(self: Self) result {
            return c.thespian_link(self.h);
        }

        pub fn expired(self: Self) bool {
            return c.thespian_handle_is_expired(self.h);
        }

        pub fn wait_expired(self: Self, timeout_ns: isize) !void {
            var max_sleep: isize = timeout_ns;
            while (!self.expired()) {
                if (max_sleep <= 0) return error.Timeout;
                std.time.sleep(100);
                max_sleep -= 100;
            }
        }
    };
}
pub const pid = Pid(.Owned);
pub const pid_ref = Pid(.Wrapped);
fn wrap_handle(h: c.thespian_handle) pid_ref {
    return .{ .h = h };
}
fn wrap_pid(h: c.thespian_handle) pid {
    return .{ .h = h };
}

pub const message = struct {
    buf: buffer_type = "",

    const Self = @This();
    pub const buffer_type: type = []const u8;
    pub const c_buffer_type = c.cbor_buffer;

    pub fn fmt(value: anytype) Self {
        return fmtbuf(&message_buffer, value) catch unreachable;
    }

    pub fn fmtbuf(buf: []u8, value: anytype) !Self {
        const f = comptime switch (@typeInfo(@TypeOf(value))) {
            .Struct => |info| if (info.is_tuple)
                fmtbufInternal
            else
                @compileError("thespian.message template should be a tuple: " ++ @typeName(@TypeOf(value))),
            else => fmtbufInternalScalar,
        };
        return f(buf, value);
    }

    fn fmtbufInternalScalar(buf: []u8, value: anytype) !Self {
        return fmtbufInternal(buf, .{value});
    }

    fn fmtbufInternal(buf: []u8, value: anytype) !Self {
        var stream = std.io.fixedBufferStream(buf);
        try cbor.writeValue(stream.writer(), value);
        return .{ .buf = stream.getWritten() };
    }

    pub fn len(self: Self) usize {
        return self.buf.len;
    }

    pub fn from(span: anytype) Self {
        return .{ .buf = span.base[0..span.len] };
    }

    pub fn to(self: *const Self, comptime T: type) T {
        return T{ .base = self.buf.ptr, .len = self.buf.len };
    }

    pub fn clone(self: *const Self, a: std.mem.Allocator) !Self {
        return .{ .buf = try a.dupe(u8, self.buf) };
    }

    pub fn to_json(self: *const Self, buffer: []u8) cbor.CborJsonError![]const u8 {
        return cbor.toJson(self.buf, buffer);
    }

    pub const json_string_view = c.c_string_view;
    const json_callback = *const fn (json_string_view) callconv(.C) void;

    pub fn to_json_cb(self: *const Self, callback: json_callback) void {
        c.cbor_to_json(self.to(c_buffer_type), callback);
    }
    pub fn match(self: Self, m: anytype) error{Exit}!bool {
        return if (cbor.match(self.buf, m)) |ret| ret else |e| exit_error(e);
    }
};

pub fn exit_message(e: anytype) message {
    return message.fmtbuf(&error_message_buffer, .{ "exit", e }) catch unreachable;
}

pub fn exit_normal() result {
    return set_error_msg(exit_message("normal"));
}

pub fn exit(e: []const u8) error{Exit} {
    return set_error_msg(exit_message(e));
}

pub fn exit_fmt(comptime fmt: anytype, args: anytype) result {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "FMTERROR";
    return set_error_msg(exit_message(msg));
}

pub fn exit_error(e: anyerror) error{Exit} {
    return switch (e) {
        error.Exit => error.Exit,
        else => set_error_msg(exit_message(e)),
    };
}

pub fn unexpected(b: message) error{Exit} {
    const txt = "UNEXPECTED_MESSAGE: ";
    var buf: [max_message_size]u8 = undefined;
    @memcpy(buf[0..txt.len], txt);
    const json = b.to_json(buf[txt.len..]) catch |e| return exit_error(e);
    return set_error_msg(message.fmt(.{ "exit", buf[0..(txt.len + json.len)] }));
}

pub fn error_message() []const u8 {
    if (error_buffer_tl.base) |base|
        return base[0..error_buffer_tl.len];
    set_error_msg(exit_message("NOERROR")) catch {};
    return error_message();
}

pub fn error_text() []const u8 {
    const msg_: message = .{ .buf = error_message() };
    var msg__: []const u8 = undefined;
    return if (msg_.match(.{ "exit", extract(&msg__) }) catch false)
        msg__
    else
        &[_]u8{};
}

pub fn self_pid() pid_ref {
    return wrap_handle(c.thespian_self());
}

pub const trace_channel = c.thespian_trace_channel;
pub const channel = struct {
    pub const send = c.thespian_trace_channel_send;
    pub const receive = c.thespian_trace_channel_receive;
    pub const lifetime = c.thespian_trace_channel_lifetime;
    pub const link = c.thespian_trace_channel_link;
    pub const execute = c.thespian_trace_channel_execute;
    pub const udp = c.thespian_trace_channel_udp;
    pub const tcp = c.thespian_trace_channel_tcp;
    pub const timer = c.thespian_trace_channel_timer;
    pub const metronome = c.thespian_trace_channel_metronome;
    pub const endpoint = c.thespian_trace_channel_endpoint;
    pub const signal = c.thespian_trace_channel_signal;
    pub const event: c.thespian_trace_channel = 2048;
    pub const widget: c.thespian_trace_channel = 4096;
    pub const input: c.thespian_trace_channel = 8192;
    pub const all = c.thespian_trace_channel_all;
};

pub const env = struct {
    env: *c.thespian_env_t,
    owned: bool = false,

    const Self = @This();

    pub fn get() Self {
        return .{ .env = c.thespian_env_get() orelse unreachable, .owned = false };
    }

    pub fn init() Self {
        return .{ .env = c.thespian_env_new() orelse unreachable, .owned = true };
    }

    pub fn clone(self: *const Self) Self {
        return .{ .env = c.thespian_env_clone(self.env) orelse unreachable, .owned = true };
    }

    pub fn deinit(self: Self) void {
        if (self.owned) c.thespian_env_destroy(self.env);
    }

    pub fn enable_all_channels(self: *const Self) void {
        c.thespian_env_enable_all_channels(self.env);
    }

    pub fn disable_all_channels(self: *const Self) void {
        c.thespian_env_disable_all_channels(self.env);
    }

    pub fn enable(self: *const Self, chan: c.thespian_trace_channel) void {
        c.thespian_env_enable(self.env, chan);
    }

    pub fn disable(self: *const Self, chan: c.thespian_trace_channel) void {
        c.thespian_env_disable(self.env, chan);
    }

    pub fn enabled(self: *const Self, chan: c.thespian_trace_channel) bool {
        return c.thespian_env_enabled(self.env, chan);
    }

    pub const trace_handler = *const fn (c.cbor_buffer) callconv(.C) void;

    pub fn on_trace(self: *const Self, h: trace_handler) void {
        c.thespian_env_on_trace(self.env, h);
    }

    pub fn trace(self: *const Self, m: c.cbor_buffer) void {
        c.thespian_env_trace(self.env, m);
    }

    pub fn is(self: *const Self, key: []const u8) bool {
        return c.thespian_env_is(self.env, .{ .base = key.ptr, .len = key.len });
    }
    pub fn set(self: *const Self, key: []const u8, value: bool) void {
        c.thespian_env_set(self.env, .{ .base = key.ptr, .len = key.len }, value);
    }

    pub fn num(self: *const Self, key: []const u8) i64 {
        return c.thespian_env_num(self.env, .{ .base = key.ptr, .len = key.len });
    }
    pub fn num_set(self: *const Self, key: []const u8, value: i64) void {
        c.thespian_env_num_set(self.env, .{ .base = key.ptr, .len = key.len }, value);
    }

    pub fn str(self: *const Self, key: []const u8) []const u8 {
        const ret = c.thespian_env_str(self.env, .{ .base = key.ptr, .len = key.len });
        return ret.base[0..ret.len];
    }
    pub fn str_set(self: *const Self, key: []const u8, value: []const u8) void {
        c.thespian_env_str_set(self.env, .{ .base = key.ptr, .len = key.len }, .{ .base = value.ptr, .len = value.len });
    }

    pub fn proc(self: *const Self, key: []const u8) pid_ref {
        return wrap_handle(c.thespian_env_proc(self.env, .{ .base = key.ptr, .len = key.len }));
    }
    pub fn proc_set(self: *const Self, key: []const u8, value: pid_ref) void {
        c.thespian_env_proc_set(self.env, .{ .base = key.ptr, .len = key.len }, value.h);
    }
};

pub fn trace(chan: trace_channel, value: anytype) void {
    if (env.get().enabled(chan)) {
        if (@TypeOf(value) == message) {
            env.get().trace(value.to(message.c_buffer_type));
        } else {
            var trace_buffer: [512]u8 = undefined;
            const m = message.fmtbuf(&trace_buffer, value);
            env.get().trace(m.to(message.c_buffer_type));
        }
    }
}

pub const context = struct {
    a: std.mem.Allocator,
    context: c.thespian_context,
    context_destroy: *const fn (?*anyopaque) callconv(.C) void,

    const Self = @This();

    pub fn init(a: std.mem.Allocator) !Self {
        var ctx_destroy: c.thespian_context_destroy = null;
        const ctx = c.thespian_context_create(&ctx_destroy) orelse return error.ThespianContextCreateFailed;
        return .{
            .a = a,
            .context = ctx,
            .context_destroy = ctx_destroy orelse return error.ThespianContextCreateFailed,
        };
    }

    pub fn run(self: *Self) void {
        c.thespian_context_run(self.context);
    }

    pub fn spawn_link(
        self: *const Self,
        data: anytype,
        f: Behaviour(@TypeOf(data)).FunT,
        name: [:0]const u8,
        eh: anytype,
        env_: ?*const env,
    ) !pid {
        const Tclosure = Behaviour(@TypeOf(data));
        var handle_: c.thespian_handle = null;
        try neg_to_error(c.thespian_context_spawn_link(
            self.context,
            Tclosure.run,
            try Tclosure.create(self.a, f, data),
            exitHandlerRun(@TypeOf(eh)),
            eh,
            name,
            if (env_) |env__| env__.env else null,
            &handle_,
        ), error.ThespianSpawnFailed);
        return .{ .h = handle_ };
    }

    pub fn deinit(self: *Self) void {
        self.context_destroy(self.context);
    }
};

fn exitHandlerRun(comptime T: type) c.thespian_exit_handler {
    if (T == @TypeOf(null)) return null;
    return switch (@typeInfo(T)) {
        .Optional => |info| switch (@typeInfo(info.child)) {
            .Pointer => |ptr_info| switch (ptr_info.size) {
                .One => ptr_info.child.run,
                else => @compileError("expected single item pointer, found: '" ++ @typeName(T) ++ "'"),
            },
        },
        .Pointer => |ptr_info| switch (ptr_info.size) {
            .One => ptr_info.child.run,
            else => @compileError("expected single item pointer, found: '" ++ @typeName(T) ++ "'"),
        },
        else => @compileError("expected optional pointer or pointer type, found: '" ++ @typeName(T) ++ "'"),
    };
}

pub fn receive(r: anytype) void {
    const T = switch (@typeInfo(@TypeOf(r))) {
        .Pointer => |ptr_info| switch (ptr_info.size) {
            .One => ptr_info.child,
            else => @compileError("invalid receiver type"),
        },
        else => @compileError("invalid receiver type"),
    };
    c.thespian_receive(T.run, r);
}

pub fn Receiver(comptime T: type) type {
    return struct {
        f: FunT,
        data: T,
        const FunT: type = *const fn (T, from: pid_ref, m: message) result;
        const Self = @This();
        pub fn init(f: FunT, data: T) Self {
            return .{ .f = f, .data = data };
        }
        pub fn run(ostate: c.thespian_behaviour_state, from: c.thespian_handle, m: c.cbor_buffer) callconv(.C) c.thespian_result {
            const state: *Self = @ptrCast(@alignCast(ostate orelse unreachable));
            reset_error();
            return to_result(state.f(state.data, wrap_handle(from), message.from(m)));
        }
    };
}

pub fn get_trap() bool {
    return c.thespian_get_trap();
}

pub fn set_trap(on: bool) bool {
    return c.thespian_set_trap(on);
}

pub fn spawn_link(
    a: std.mem.Allocator,
    data: anytype,
    f: Behaviour(@TypeOf(data)).FunT,
    name: [:0]const u8,
) error{ OutOfMemory, ThespianSpawnFailed }!pid {
    return spawn_link_env(a, data, f, name, env.get());
}

pub fn spawn_link_env(
    a: std.mem.Allocator,
    data: anytype,
    f: Behaviour(@TypeOf(data)).FunT,
    name: [:0]const u8,
    env_: ?env,
) error{ OutOfMemory, ThespianSpawnFailed }!pid {
    const Tclosure = Behaviour(@TypeOf(data));
    var handle_: c.thespian_handle = null;
    try neg_to_error(c.thespian_spawn_link(
        Tclosure.run,
        try Tclosure.create(a, f, data),
        name,
        if (env_) |env__| env__.env else null,
        &handle_,
    ), error.ThespianSpawnFailed);
    return wrap_pid(handle_);
}

pub fn neg_to_error(errcode: c_int, errortype: anytype) @TypeOf(errortype)!void {
    if (errcode < 0) return errortype;
}

pub fn nonzero_to_error(errcode: c_int, errortype: anytype) @TypeOf(errortype)!void {
    if (errcode != 0) return errortype;
}

pub fn wrap(comptime f: anytype, errortype: anyerror) fn (std.meta.ArgsTuple(@TypeOf(f))) @TypeOf(errortype)!void {
    const Local = struct {
        pub fn wrapped(args: std.meta.ArgsTuple(@TypeOf(f))) @TypeOf(errortype)!void {
            return nonzero_to_error(@call(.auto, f, args), errortype);
        }
    };
    return Local.wrapped;
}

fn Behaviour(comptime T: type) type {
    return struct {
        a: std.mem.Allocator,
        f: FunT,
        data: T,
        const FunT: type = *const fn (T) result;
        const Self = @This();

        pub fn create(a: std.mem.Allocator, f: FunT, data: T) error{OutOfMemory}!*Self {
            const self: *Self = try a.create(Self);
            self.* = .{ .a = a, .f = f, .data = data };
            return self;
        }

        pub fn destroy(self: *Self) void {
            self.a.destroy(self);
        }

        pub fn run(state: c.thespian_behaviour_state) callconv(.C) c.thespian_result {
            const self: *Self = @ptrCast(@alignCast(state orelse unreachable));
            defer self.destroy();
            reset_error();
            return to_result(self.f(self.data));
        }
    };
}

fn to_result(ret: result) c.thespian_result {
    if (ret) |_| {
        return null;
    } else |_| {
        const msg = error_message();
        if (!(cbor.match(msg, .{ "exit", "normal" }) catch false)) {
            if (env.get().is("dump-stack-trace")) {
                const trace_ = @errorReturnTrace();
                if (trace_) |t| std.debug.dumpStackTrace(t.*);
            }
        }
        return &error_buffer_tl;
    }
}

fn set_error_msg(m: message) error{Exit} {
    return set_error(m.to(c.thespian_error));
}

fn set_error(e: c.thespian_error) error{Exit} {
    error_buffer_tl = e;
    return error.Exit;
}

pub fn reset_error() void {
    error_buffer_tl = .{ .base = null, .len = 0 };
}

pub fn make_exit_handler(data: anytype, f: ExitHandler(@TypeOf(data)).FunT) ExitHandler(@TypeOf(data)) {
    return ExitHandler(@TypeOf(data)).init(f, data);
}

fn ExitHandler(comptime T: type) type {
    return struct {
        a: ?std.mem.Allocator = null,
        f: FunT,
        data: T,
        const FunT: type = *const fn (T, []const u8) void;
        const Self = @This();

        pub fn init(f: FunT, data: T) Self {
            return .{ .f = f, .data = data };
        }

        pub fn create(a: std.mem.Allocator, f: FunT, data: T) !*Self {
            const self: *Self = try a.create(Self);
            self.* = .{ .a = a, .f = f, .data = data };
            return self;
        }

        pub fn destroy(self: *Self) void {
            if (self.a) |a_| a_.destroy(self);
        }

        pub fn run(state: c.thespian_exit_handler_state, msg: [*c]const u8, len: usize) callconv(.C) void {
            const self: *Self = @ptrCast(@alignCast(state orelse unreachable));
            defer self.destroy();
            self.f(self.data, msg[0..len]);
        }
    };
}

pub const signal = struct {
    handle: *c.struct_thespian_signal_handle,

    const Self = @This();

    pub fn init(signum: c_int, m: message) !Self {
        return .{ .handle = c.thespian_signal_create(signum, m.to(c.cbor_buffer)) orelse return error.ThespianSignalInitFailed };
    }

    pub fn cancel(self: *const Self) !void {
        return neg_to_error(c.thespian_signal_cancel(self.handle), error.ThespianSignalCancelFailed);
    }

    pub fn deinit(self: *const Self) void {
        c.thespian_signal_destroy(self.handle);
    }
};

pub const metronome = struct {
    handle: *c.struct_thespian_metronome_handle,

    const Self = @This();

    pub fn init(tick_time_us: u64) !Self {
        return .{ .handle = c.thespian_metronome_create_us(tick_time_us) orelse return error.ThespianMetronomeInitFailed };
    }

    pub fn init_ms(tick_time_us: u64) !Self {
        return .{ .handle = c.thespian_metronome_create_ms(tick_time_us) orelse return error.ThespianMetronomeInitFailed };
    }

    pub fn start(self: *const Self) !void {
        return neg_to_error(c.thespian_metronome_start(self.handle), error.ThespianMetronomeStartFailed);
    }

    pub fn stop(self: *const Self) !void {
        return neg_to_error(c.thespian_metronome_stop(self.handle), error.ThespianMetronomeStopFailed);
    }

    pub fn deinit(self: *const Self) void {
        c.thespian_metronome_destroy(self.handle);
    }
};

pub const timeout = struct {
    handle: ?*c.struct_thespian_timeout_handle,

    const Self = @This();

    pub fn init(tick_time_us: u64, m: message) !Self {
        return .{ .handle = c.thespian_timeout_create_us(tick_time_us, m.to(c.cbor_buffer)) orelse return error.ThespianTimeoutInitFailed };
    }

    pub fn init_ms(tick_time_us: u64, m: message) !Self {
        return .{ .handle = c.thespian_timeout_create_ms(tick_time_us, m.to(c.cbor_buffer)) orelse return error.ThespianTimeoutInitFailed };
    }

    pub fn cancel(self: *const Self) !void {
        return neg_to_error(c.thespian_timeout_cancel(self.handle), error.ThespianTimeoutCancelFailed);
    }

    pub fn deinit(self: *Self) void {
        c.thespian_timeout_destroy(self.handle);
        self.handle = null;
    }
};

pub const file_descriptor = struct {
    handle: *c.struct_thespian_file_descriptor_handle,

    const Self = @This();

    pub fn init(tag_: []const u8, fd: i32) !Self {
        return .{ .handle = c.thespian_file_descriptor_create(tag_.ptr, fd) orelse return error.ThespianFileDescriptorInitFailed };
    }

    pub fn wait_write(self: *const Self) !void {
        return neg_to_error(c.thespian_file_descriptor_wait_write(self.handle), error.ThespianFileDescriptorWaitWriteFailed);
    }

    pub fn wait_read(self: *const Self) !void {
        return neg_to_error(c.thespian_file_descriptor_wait_read(self.handle), error.ThespianFileDescriptorWaitReadFailed);
    }

    pub fn cancel(self: *const Self) !void {
        return neg_to_error(c.thespian_file_descriptor_cancel(self.handle), error.ThespianFileDescriptorCancelFailed);
    }

    pub fn deinit(self: *const Self) void {
        c.thespian_file_descriptor_destroy(self.handle);
    }
};

const CallContext = struct {
    receiver: ReceiverT,
    to: pid_ref,
    request: message,
    response: ?message,
    a: std.mem.Allocator,
    mut: std.Thread.Mutex = std.Thread.Mutex{},
    cond: std.Thread.Condition = std.Thread.Condition{},

    const Self = @This();
    const ReceiverT = Receiver(*Self);

    pub fn call(a: std.mem.Allocator, to: pid_ref, request: message) error{ OutOfMemory, ThespianSpawnFailed }!message {
        var self: Self = undefined;
        const rec = ReceiverT.init(receive_, &self);

        self = .{
            .receiver = rec,
            .to = to,
            .request = request,
            .response = null,
            .a = a,
        };

        self.mut.lock();
        errdefer self.mut.unlock();

        const proc = try spawn_link(a, &self, start, @typeName(Self));
        defer proc.deinit();

        self.cond.wait(&self.mut);

        return self.response orelse .{};
    }

    fn start(self: *Self) result {
        errdefer self.cond.signal();
        _ = set_trap(true);
        try self.to.link();
        try self.to.send_raw(self.request);
        receive(&self.receiver);
    }

    fn receive_(self: *Self, from: pid_ref, m: message) result {
        defer self.cond.signal();
        _ = from;
        self.response = m.clone(self.a) catch |e| return exit_error(e);
        try exit_normal();
    }
};
