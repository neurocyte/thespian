const std = @import("std");
const c = @cImport({
    @cInclude("thespian/c/file_descriptor.h");
    @cInclude("thespian/c/file_stream.h");
    @cInclude("thespian/c/instance.h");
    @cInclude("thespian/c/metronome.h");
    @cInclude("thespian/c/timeout.h");
    @cInclude("thespian/c/signal.h");
});
const c_posix = if (builtin.os.tag != .windows) @cImport({
    @cInclude("thespian/backtrace.h");
}) else {};
const cbor = @import("cbor");
const builtin = @import("builtin");

const log = std.log.scoped(.thespian);

pub var stack_trace_on_errors: bool = false;

pub const subprocess = if (builtin.os.tag == .windows) @import("subprocess_windows.zig") else @import("subprocess.zig");

pub const install_debugger = c.install_debugger;
pub const install_remote_debugger = c.install_remote_debugger;
pub const install_backtrace = c.install_backtrace;
pub const install_jitdebugger = c.install_jitdebugger;

pub const sighdl_debugger = if (builtin.os.tag != .windows) c_posix.sighdl_debugger else {};
pub const sighdl_remote_debugger = if (builtin.os.tag != .windows) c_posix.sighdl_remote_debugger else {};
pub const sighdl_backtrace = if (builtin.os.tag != .windows) c_posix.sighdl_backtrace else {};

pub const max_message_size = 8 * 4096;
const message_buf_allocator = std.heap.c_allocator;
threadlocal var message_buffer: std.ArrayList(u8) = std.ArrayList(u8).init(message_buf_allocator);
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

pub const CallError = error{ OutOfMemory, ThespianSpawnFailed, Timeout };

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

        pub fn call(self: Self, a: std.mem.Allocator, timeout_ns: u64, request: anytype) CallError!message {
            return CallContext.call(a, self.ref(), timeout_ns, message.fmt(request));
        }

        pub fn delay_send(self: Self, a: std.mem.Allocator, delay_us: u64, m: anytype) result {
            var h = self.delay_send_cancellable(a, delay_us, m) catch |e| return exit_error(e, @errorReturnTrace());
            h.deinit();
        }

        pub fn delay_send_cancellable(self: Self, a: std.mem.Allocator, tag_: [:0]const u8, delay_us: u64, m: anytype) error{ OutOfMemory, ThespianSpawnFailed }!Cancellable {
            const msg = message.fmt(m);
            return Cancellable.init(try DelayedSender.send(self, a, tag_, delay_us, msg));
        }

        pub fn forward_error(self: Self, e: anyerror, stack_trace: ?*std.builtin.StackTrace) result {
            return self.send_raw(switch (e) {
                error.Exit => .{ .buf = error_message() },
                else => exit_message(e, stack_trace),
            });
        }

        pub fn link(self: Self) result {
            return c.thespian_link(self.h);
        }

        pub fn expired(self: Self) bool {
            return c.thespian_handle_is_expired(self.h);
        }

        pub fn wait_expired(self: Self, timeout_ns: isize) error{Timeout}!void {
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
        message_buffer.clearRetainingCapacity();
        const f = comptime switch (@typeInfo(@TypeOf(value))) {
            .@"struct" => |info| if (info.is_tuple)
                fmt_internal
            else
                @compileError("thespian.message template should be a tuple: " ++ @typeName(@TypeOf(value))),
            else => fmt_internal_scalar,
        };
        f(message_buffer.writer(), value) catch |e| std.debug.panic("thespian.message.fmt: {any}", .{e});
        return .{ .buf = message_buffer.items };
    }

    fn fmt_internal_scalar(writer: std.ArrayList(u8).Writer, value: anytype) !void {
        return fmt_internal(writer, .{value});
    }

    fn fmt_internal(writer: std.ArrayList(u8).Writer, value: anytype) !void {
        try cbor.writeValue(writer, value);
    }

    pub fn fmtbuf(buf: []u8, value: anytype) !Self {
        const f = comptime switch (@typeInfo(@TypeOf(value))) {
            .@"struct" => |info| if (info.is_tuple)
                fmtbuf_internal
            else
                @compileError("thespian.message template should be a tuple: " ++ @typeName(@TypeOf(value))),
            else => fmtbuf_internal_scalar,
        };
        return f(buf, value);
    }

    fn fmtbuf_internal_scalar(buf: []u8, value: anytype) !Self {
        return fmtbuf_internal(buf, .{value});
    }

    fn fmtbuf_internal(buf: []u8, value: anytype) !Self {
        var stream = std.io.fixedBufferStream(buf);
        try cbor.writeValue(stream.writer(), value);
        return .{ .buf = stream.getWritten() };
    }

    pub fn len(self: Self) usize {
        return self.buf.len;
    }

    pub fn from(span: anytype) Self {
        const buf = if (span.len > 0) span.base[0..span.len] else &[_]u8{};
        return .{ .buf = buf };
    }

    pub fn to(self: *const Self, comptime T: type) T {
        return T{ .base = self.buf.ptr, .len = self.buf.len };
    }

    pub fn clone(self: *const Self, a: std.mem.Allocator) !Self {
        return .{ .buf = try a.dupe(u8, self.buf) };
    }

    pub fn to_json(self: *const Self, buffer: []u8) (cbor.JsonEncodeError || error{NoSpaceLeft})![]const u8 {
        return cbor.toJson(self.buf, buffer);
    }

    pub const json_string_view = c.c_string_view;
    const json_callback = *const fn (json_string_view) callconv(.C) void;

    pub fn to_json_cb(self: *const Self, callback: json_callback) void {
        c.cbor_to_json(self.to(c_buffer_type), callback);
    }
    pub fn match(self: Self, m: anytype) error{Exit}!bool {
        return if (cbor.match(self.buf, m)) |ret| ret else |e| exit_error(e, @errorReturnTrace());
    }

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        return cbor.toJsonWriter(self.buf, writer, .{});
    }
};

pub fn exit_message(e: anytype, stack_trace: ?*std.builtin.StackTrace) message {
    if (!stack_trace_on_errors)
        return message.fmtbuf(&error_message_buffer, .{ "exit", e }) catch unreachable;
    if (stack_trace) |stack_trace_| {
        var debug_info_arena_allocator: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer debug_info_arena_allocator.deinit();
        const a = debug_info_arena_allocator.allocator();
        var out: std.Io.Writer.Allocating = .init(a);
        store_stack_trace(stack_trace_.*, &out.writer);
        return message.fmtbuf(&error_message_buffer, .{ "exit", e, out.getWritten() }) catch unreachable;
    } else {
        return message.fmtbuf(&error_message_buffer, .{ "exit", e }) catch unreachable;
    }
}

fn store_stack_trace(stack_trace: std.builtin.StackTrace, writer: *std.Io.Writer) void {
    nosuspend {
        if (builtin.strip_debug_info) {
            writer.print("Unable to store stack trace: debug info stripped\n", .{}) catch return;
            return;
        }
        const debug_info = std.debug.getSelfDebugInfo() catch |err| {
            writer.print("Unable to dump stack trace: Unable to open debug info: {s}\n", .{@errorName(err)}) catch return;
            return;
        };
        std.debug.writeStackTrace(stack_trace, writer, debug_info, .no_color) catch |err| {
            writer.print("Unable to dump stack trace: {s}\n", .{@errorName(err)}) catch return;
            return;
        };
    }
}

pub fn exit_normal() error{Exit} {
    return set_error_msg(exit_message("normal", null));
}

pub fn exit(e: []const u8) error{Exit} {
    return set_error_msg(exit_message(e, null));
}

pub fn exit_fmt(comptime fmt: anytype, args: anytype) error{Exit} {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch "FMTERROR";
    return set_error_msg(exit_message(msg, null));
}

pub fn exit_error(e: anyerror, stack_trace: ?*std.builtin.StackTrace) error{Exit} {
    if (stack_trace_on_errors and e == error.OutOfMemory) std.debug.panic("{any}", .{e});
    return switch (e) {
        error.Exit => error.Exit,
        else => set_error_msg(exit_message(e, stack_trace)),
    };
}

pub fn unexpected(b: message) error{Exit} {
    const txt = "UNEXPECTED_MESSAGE: ";
    var buf: [max_message_size]u8 = undefined;
    @memcpy(buf[0..txt.len], txt);
    const json = b.to_json(buf[txt.len..]) catch |e| return exit_error(e, @errorReturnTrace());
    return set_error_msg(message.fmt(.{ "exit", buf[0..(txt.len + json.len)] }));
}

pub fn error_message() []const u8 {
    if (error_buffer_tl.base) |base|
        return base[0..error_buffer_tl.len];
    set_error_msg(exit_message("NOERROR", null)) catch {};
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

pub const ScopedError = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
};

pub fn store_error(err: *ScopedError) void {
    if (error_buffer_tl.base) |base| {
        @memcpy(err.buf[0..error_buffer_tl.len], base[0..error_buffer_tl.len]);
        err.len = error_buffer_tl.len;
    } else err.* = .{};
}

pub fn restore_error(err: *const ScopedError) void {
    if (err.len > 0) {
        @memcpy(error_message_buffer[0..err.len], err.buf[0..err.len]);
        error_buffer_tl = .{
            .base = &error_message_buffer,
            .len = err.len,
        };
    } else error_buffer_tl = .{
        .base = null,
        .len = 0,
    };
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
    pub const debug: c.thespian_trace_channel = 16384;
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
            const m = message.fmtbuf(&trace_buffer, value) catch |e|
                std.debug.panic("TRACE ERROR: {}", .{e});
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

    pub fn get_last_error(buf: []u8) []const u8 {
        const err = std.mem.span(c.thespian_get_last_error());
        const err_len = @min(buf.len, err.len);
        @memcpy(buf[0..err_len], err[0..err_len]);
        return buf[0..err_len];
    }
};

fn log_last_error(err: anytype) @TypeOf(err) {
    log.err("{any}: {s}", .{ err, c.thespian_get_last_error() });
    return err;
}

fn exitHandlerRun(comptime T: type) c.thespian_exit_handler {
    if (T == @TypeOf(null)) return null;
    return switch (@typeInfo(T)) {
        .optional => |info| switch (@typeInfo(info.child)) {
            .pointer => |ptr_info| switch (ptr_info.size) {
                .one => ptr_info.child.run,
                else => @compileError("expected single item pointer, found: '" ++ @typeName(T) ++ "'"),
            },
        },
        .pointer => |ptr_info| switch (ptr_info.size) {
            .one => ptr_info.child.run,
            else => @compileError("expected single item pointer, found: '" ++ @typeName(T) ++ "'"),
        },
        else => @compileError("expected optional pointer or pointer type, found: '" ++ @typeName(T) ++ "'"),
    };
}

pub fn receive(r: anytype) void {
    const T = switch (@typeInfo(@TypeOf(r))) {
        .pointer => |ptr_info| switch (ptr_info.size) {
            .one => ptr_info.child,
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
    if (errcode < 0) return log_last_error(errortype);
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
        return .{ .handle = c.thespian_signal_create(signum, m.to(c.cbor_buffer)) orelse return log_last_error(error.ThespianSignalInitFailed) };
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
        return .{ .handle = c.thespian_metronome_create_us(@intCast(tick_time_us)) orelse return log_last_error(error.ThespianMetronomeInitFailed) };
    }

    pub fn init_ms(tick_time_us: u64) !Self {
        return .{ .handle = c.thespian_metronome_create_ms(tick_time_us) orelse return log_last_error(error.ThespianMetronomeInitFailed) };
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
        return .{ .handle = c.thespian_timeout_create_us(tick_time_us, m.to(c.cbor_buffer)) orelse return log_last_error(error.ThespianTimeoutInitFailed) };
    }

    pub fn init_ms(tick_time_us: u64, m: message) !Self {
        return .{ .handle = c.thespian_timeout_create_ms(tick_time_us, m.to(c.cbor_buffer)) orelse return log_last_error(error.ThespianTimeoutInitFailed) };
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

pub const file_stream = struct {
    handle: *c.struct_thespian_file_stream_handle,

    const Self = @This();

    pub fn init(tag_: []const u8, handle: *anyopaque) !Self {
        return .{ .handle = c.thespian_file_stream_create(tag_.ptr, handle) orelse return log_last_error(error.ThespianFileStreamInitFailed) };
    }

    pub fn start_read(self: *const Self) !void {
        return neg_to_error(c.thespian_file_stream_start_read(self.handle), error.ThespianFileStreamWaitReadFailed);
    }

    pub fn start_write(self: *const Self, data: []const u8) !void {
        return neg_to_error(c.thespian_file_stream_start_write(self.handle, data.ptr, data.len), error.ThespianFileStreamWaitWriteFailed);
    }

    pub fn cancel(self: *const Self) !void {
        return neg_to_error(c.thespian_file_stream_cancel(self.handle), error.ThespianFileStreamCancelFailed);
    }

    pub fn deinit(self: *const Self) void {
        c.thespian_file_stream_destroy(self.handle);
    }
};

const CallContext = struct {
    receiver: ReceiverT,
    from: pid,
    to: pid_ref,
    request: message,
    response: ?message,
    a: std.mem.Allocator,
    done: std.Thread.ResetEvent = .{},

    const Self = @This();
    const ReceiverT = Receiver(*Self);

    pub fn call(a: std.mem.Allocator, to: pid_ref, timeout_ns: u64, request: message) CallError!message {
        const self = try a.create(Self);
        self.* = .{
            .receiver = undefined,
            .from = self_pid().clone(),
            .to = to,
            .request = request,
            .response = null,
            .a = a,
        };
        self.receiver = ReceiverT.init(receive_, self);
        const proc = try spawn_link(a, self, start, @typeName(Self));
        defer proc.deinit();
        try self.done.timedWait(timeout_ns);
        defer self.deinit(); // only deinit on success. if we timed out proc will have to deinit
        return self.response orelse .{};
    }

    fn deinit(self: *Self) void {
        self.a.destroy(self);
    }

    fn start(self: *Self) result {
        errdefer self.done.set();
        _ = set_trap(true);
        try self.to.link();
        try self.to.send_raw(self.request);
        receive(&self.receiver);
    }

    fn receive_(self: *Self, _: pid_ref, m: message) result {
        defer {
            const expired = self.from.expired();
            self.from.deinit();
            self.done.set();
            if (expired) self.deinit();
        }
        self.response = m.clone(self.a) catch |e| return exit_error(e, @errorReturnTrace());
        return exit_normal();
    }
};

const DelayedSender = struct {
    a: std.mem.Allocator,
    target: pid,
    message: ?message,
    delay_us: u64,
    timeout: timeout = undefined,
    receiver: ReceiverT = undefined,

    const ReceiverT = Receiver(*DelayedSender);

    fn send(pid_: pid_ref, a: std.mem.Allocator, tag_: [:0]const u8, delay_us: u64, m: message) error{ OutOfMemory, ThespianSpawnFailed }!pid {
        const self = try a.create(DelayedSender);
        self.* = .{
            .a = a,
            .target = pid_.clone(),
            .message = try m.clone(a),
            .delay_us = delay_us,
        };
        return spawn_link(a, self, start, tag_);
    }

    fn start(self: *DelayedSender) result {
        self.receiver = ReceiverT.init(receive_, self);
        const m_ = self.message.?;
        self.timeout = timeout.init(self.delay_us, m_) catch |e| return exit_error(e, @errorReturnTrace());
        self.a.free(m_.buf);
        _ = set_trap(true);
        receive(&self.receiver);
    }

    fn deinit(self: *DelayedSender) void {
        self.timeout.deinit();
        self.target.deinit();
    }

    fn receive_(self: *DelayedSender, _: pid_ref, m_: message) result {
        if (try m_.match(.{"CANCEL"})) {
            self.timeout.cancel() catch |e| return exit_error(e, @errorReturnTrace());
            return;
        }
        defer self.deinit();
        if (try m_.match(.{ "exit", "timeout_error", any, any }))
            return exit_normal();
        try self.target.send_raw(m_);
        return exit_normal();
    }
};

pub const Cancellable = struct {
    sender: pid,

    fn init(pid_: pid) Cancellable {
        return .{ .sender = pid_ };
    }

    pub fn deinit(self: *Cancellable) void {
        self.sender.deinit();
    }

    pub fn cancel(self: *Cancellable) result {
        return self.sender.send(.{"CANCEL"});
    }
};
