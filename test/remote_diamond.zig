//! Four-process unix-socket "diamond" topology exercise:
//!
//!         A
//!        / \
//!       B   C
//!        \ /
//!         D
//!
//! * `A` listens on two paths and spawns `B` and `C` as subprocesses.
//! * `B` connects to `A`, spawns `D` as a subprocess, then connects to `D`.
//! * `C` connects to `A`, and (once `A` tells it that `D` is up) connects to `D`.
//! * `D` listens for `B` and `C`; each node registers a well-known
//!   `app_*` actor and logs the pings it receives.
//!
//! Coordination:
//! * `D` prints `D_READY\n` to its stdout once its listener has bound;
//!   `B` (its spawner) reads that, then connects to `D`.
//! * `B` tells `A` via `d_ready`, and `A` relays `connect_d` to `C`.
//! * When `A` has heard `d_ready` and `c_ready`, it knows all four
//!   diamond edges are up and fans out three pings (one direct to each
//!   of `B` and `C`, one that `B` relays to `D` via the `B-D` socket).

const std = @import("std");
const builtin = @import("builtin");
const tp = @import("thespian");
const cbor = @import("cbor");
const remote = @import("remote");
const endpoint = remote.endpoint.unx;
const protocol = remote.protocol;

const Allocator = std.mem.Allocator;
const lpiid = protocol.lpiid;
const piid = tp.piid;

const sock_mode: tp.unx_mode = if (builtin.os.tag == .linux) .abstract else .file;

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // exe
    const mode = args.next() orelse return try NodeA.run(init);

    if (std.mem.eql(u8, mode, "a")) {
        try NodeA.run(init);
    } else if (std.mem.eql(u8, mode, "b")) {
        const path_ab = args.next() orelse return usage(init.io);
        const path_d = args.next() orelse return usage(init.io);
        const exe = args.next() orelse return usage(init.io);
        try NodeB.run(init, path_ab, path_d, exe);
    } else if (std.mem.eql(u8, mode, "c")) {
        const path_ac = args.next() orelse return usage(init.io);
        const path_d = args.next() orelse return usage(init.io);
        try NodeC.run(init, path_ac, path_d);
    } else if (std.mem.eql(u8, mode, "d")) {
        const path_d = args.next() orelse return usage(init.io);
        try NodeD.run(init, path_d);
    } else {
        try usage(init.io);
    }
}

fn usage(io: std.Io) !void {
    _ = std.Io.File.stderr().writeStreamingAll(io, "usage: diamond a|b|c|d|-h|--help [args...]\n") catch {};
    std.process.exit(2);
}

fn say(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = std.Io.File.stdout().writeStreamingAll(io, s) catch {};
}

// Node A: root of the diamond.
const NodeA = struct {
    allocator: Allocator,
    io: std.Io,
    path_ab: [:0]const u8,
    path_ac: [:0]const u8,
    path_d: [:0]const u8,
    exe: []const u8,
    listen_ab: tp.pid,
    listen_ac: tp.pid,
    proc_b: ?tp.subprocess = null,
    proc_c: ?tp.subprocess = null,
    ab_conn: ?tp.pid = null,
    ac_conn: ?tp.pid = null,
    shutdown_timer: ?tp.timeout = null,
    listeners_ready: u8 = 0,
    pings_sent: bool = false,
    b_ready: bool = false,
    c_ready: bool = false,
    receiver: tp.Receiver(*@This()),

    const b_tag = "PROC_B";
    const c_tag = "PROC_C";

    const Args = struct {
        allocator: Allocator,
        io: std.Io,
        path_ab: [:0]const u8,
        path_ac: [:0]const u8,
        path_d: [:0]const u8,
        exe: []const u8,
    };

    fn run(pinit: std.process.Init) !void {
        var ctx = try tp.context.init(pinit.gpa, .{});
        defer ctx.deinit();

        const pid_str = try std.fmt.allocPrint(pinit.gpa, "{d}", .{std.os.linux.getpid()});
        defer pinit.gpa.free(pid_str);
        const path_ab = try std.fmt.allocPrintSentinel(pinit.gpa, "diamond_ab_{s}", .{pid_str}, 0);
        defer pinit.gpa.free(path_ab);
        const path_ac = try std.fmt.allocPrintSentinel(pinit.gpa, "diamond_ac_{s}", .{pid_str}, 0);
        defer pinit.gpa.free(path_ac);
        const path_d = try std.fmt.allocPrintSentinel(pinit.gpa, "diamond_d_{s}", .{pid_str}, 0);
        defer pinit.gpa.free(path_d);

        say(pinit.io, "[a] paths: ab={s} ac={s} d={s}\n", .{ path_ab, path_ac, path_d });

        // linux-only: /proc/self/exe is an absolute symlink to the running binary.
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_len = try std.Io.Dir.readLinkAbsolute(pinit.io, "/proc/self/exe", &exe_buf);
        const exe = exe_buf[0..exe_len];

        var exit_ok = false;
        var exit_handler = tp.make_exit_handler(&exit_ok, struct {
            fn handle(ok: *bool, status: []const u8) void {
                ok.* = std.mem.eql(u8, status, "success");
            }
        }.handle);

        _ = try ctx.spawn_link(
            NodeA.Args{
                .allocator = pinit.gpa,
                .io = pinit.io,
                .path_ab = path_ab,
                .path_ac = path_ac,
                .path_d = path_d,
                .exe = exe,
            },
            NodeA.start,
            "root_a",
            &exit_handler,
            null,
        );
        ctx.run();
        std.process.exit(if (exit_ok) 0 else 1);
    }

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        _ = tp.set_trap(true);
        tp.env.get().proc_set("app_a", tp.self_pid().ref());

        const listen_ab = try endpoint.listen(args.allocator, args.path_ab, sock_mode, tp.self_pid().clone());
        const listen_ac = try endpoint.listen(args.allocator, args.path_ac, sock_mode, tp.self_pid().clone());

        // The `get`/`path` round-trip serves as a sync barrier: reply only
        // arrives once the listener has bound. Only then is it safe to fork
        // subprocesses that will `connect` to us.
        try listen_ab.send(.{ "get", "path" });
        try listen_ac.send(.{ "get", "path" });

        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .io = args.io,
            .path_ab = args.path_ab,
            .path_ac = args.path_ac,
            .path_d = args.path_d,
            .exe = args.exe,
            .listen_ab = listen_ab,
            .listen_ac = listen_ac,
            .receiver = .init(receive_fn, deinit, self),
        };
        errdefer self.deinit();
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        if (self.shutdown_timer) |*t| t.deinit();
        if (self.ab_conn) |*p| p.deinit();
        if (self.ac_conn) |*p| p.deinit();
        if (self.proc_b) |*p| p.deinit();
        if (self.proc_c) |*p| p.deinit();
        self.listen_ab.deinit();
        self.listen_ac.deinit();
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        var conn_id: piid = .empty;
        var reason: []const u8 = "";
        var path_out: []const u8 = "";
        var bytes: []const u8 = "";

        if (try m.match(.{ "path", tp.extract(&path_out) })) {
            self.listeners_ready += 1;
            if (self.listeners_ready == 2) {
                try self.spawn_children();
            }
        } else if (try m.match(.{ "connected", tp.extract(&conn_id) })) {
            const conn = tp.pid.from_id(conn_id) orelse return tp.unexpected(m);
            if (from.instance_id() == self.listen_ab.instance_id()) {
                self.ab_conn = conn;
                say(self.io, "[a] B connected on AB\n", .{});
            } else if (from.instance_id() == self.listen_ac.instance_id()) {
                self.ac_conn = conn;
                say(self.io, "[a] C connected on AC\n", .{});
            } else return tp.unexpected(m);
        } else if (try m.match(.{"d_ready"})) {
            self.b_ready = true;
            say(self.io, "[a] B reports D_READY, relaying to C\n", .{});
            const my_id = lpiid.fromInt(tp.self_pid().instance_id().toInt());
            try self.ac_conn.?.send(.{ "send", my_id, "app_c", .{"connect_d"} });
        } else if (try m.match(.{"c_ready"})) {
            self.c_ready = true;
            say(self.io, "[a] C reports READY\n", .{});
            try self.maybe_ping();
        } else if (try m.match(.{ b_tag, "stdout", tp.extract(&bytes) })) {
            self.log_child_stdout("b", bytes);
        } else if (try m.match(.{ b_tag, "stderr", tp.extract(&bytes) })) {
            self.log_child_stdout("b/err", bytes);
        } else if (try m.match(.{ c_tag, "stdout", tp.extract(&bytes) })) {
            self.log_child_stdout("c", bytes);
        } else if (try m.match(.{ c_tag, "stderr", tp.extract(&bytes) })) {
            self.log_child_stdout("c/err", bytes);
        } else if (try m.match(.{ b_tag, "term", tp.any, tp.any })) {
            // subprocess exit ignored - we drive shutdown by closing sockets.
        } else if (try m.match(.{ c_tag, "term", tp.any, tp.any })) {
            // ditto
        } else if (try m.match(.{"shutdown"})) {
            say(self.io, "[a] shutting down\n", .{});
            // Close our own connections; peers will see peer_closed and exit,
            // which propagates down through B->D and C->D too.
            if (self.ab_conn) |p| p.send(.{ "exit", "shutdown" }) catch {};
            if (self.ac_conn) |p| p.send(.{ "exit", "shutdown" }) catch {};
            return tp.exit("success");
        } else if (try m.match(.{ "exit", tp.extract(&reason) })) {
            if (std.mem.eql(u8, reason, "normal")) return;
            return tp.unexpected(m);
        } else {
            return tp.unexpected(m);
        }
    }

    fn spawn_children(self: *@This()) !void {
        say(self.io, "[a] both listeners bound; forking B and C\n", .{});
        const argv_b = tp.message.fmt(.{ self.exe, "b", self.path_ab, self.path_d, self.exe });
        self.proc_b = try tp.subprocess.init(self.io, self.allocator, argv_b, b_tag, .ignore);
        const argv_c = tp.message.fmt(.{ self.exe, "c", self.path_ac, self.path_d });
        self.proc_c = try tp.subprocess.init(self.io, self.allocator, argv_c, c_tag, .ignore);
    }

    fn maybe_ping(self: *@This()) !void {
        if (self.pings_sent or !self.b_ready or !self.c_ready) return;
        self.pings_sent = true;
        say(self.io, "[a] all peers ready; sending three pings\n", .{});
        const my_id = lpiid.fromInt(tp.self_pid().instance_id().toInt());
        try self.ab_conn.?.send(.{ "send", my_id, "app_b", .{ "ping", "A" } });
        try self.ac_conn.?.send(.{ "send", my_id, "app_c", .{ "ping", "A" } });
        try self.ab_conn.?.send(.{ "send", my_id, "app_b", .{ "relay_ping", "app_d", "A" } });
        // give receivers time to log, then shut down.
        self.shutdown_timer = try tp.timeout.init_ms(500, tp.message.fmt(.{"shutdown"}));
    }

    fn log_child_stdout(self: *@This(), label: []const u8, bytes: []const u8) void {
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            say(self.io, "[{s}> ] {s}\n", .{ label, line });
        }
    }
};

// Node B: connects to A, spawns D, connects to D.
const NodeB = struct {
    allocator: Allocator,
    io: std.Io,
    path_ab: [:0]const u8,
    path_d: [:0]const u8,
    exe: []const u8,
    connect_ab: tp.pid,
    connect_bd: ?tp.pid = null,
    proc_d: ?tp.subprocess = null,
    a_conn: ?tp.pid = null,
    d_conn: ?tp.pid = null,
    d_stdout: std.ArrayList(u8) = .empty,
    d_ready: bool = false,
    receiver: tp.Receiver(*@This()),

    const d_tag = "PROC_D";

    const Args = struct {
        allocator: Allocator,
        io: std.Io,
        path_ab: [:0]const u8,
        path_d: [:0]const u8,
        exe: []const u8,
    };

    fn run(pinit: std.process.Init, path_ab: [:0]const u8, path_d: [:0]const u8, exe: []const u8) !void {
        var ctx = try tp.context.init(pinit.gpa, .{});
        defer ctx.deinit();

        var exit_ok = false;
        var exit_handler = tp.make_exit_handler(&exit_ok, struct {
            fn handle(ok: *bool, status: []const u8) void {
                ok.* = true;
                _ = status;
            }
        }.handle);

        _ = try ctx.spawn_link(
            NodeB.Args{
                .allocator = pinit.gpa,
                .io = pinit.io,
                .path_ab = path_ab,
                .path_d = path_d,
                .exe = exe,
            },
            NodeB.start,
            "root_b",
            &exit_handler,
            null,
        );
        ctx.run();
        std.process.exit(if (exit_ok) 0 else 1);
    }

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        _ = tp.set_trap(true);
        tp.env.get().proc_set("app_b", tp.self_pid().ref());

        const connect_ab = try endpoint.connect(args.allocator, args.path_ab, sock_mode, tp.self_pid().clone());

        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .io = args.io,
            .path_ab = args.path_ab,
            .path_d = args.path_d,
            .exe = args.exe,
            .connect_ab = connect_ab,
            .receiver = .init(receive_fn, deinit, self),
        };
        errdefer self.deinit();
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        self.d_stdout.deinit(self.allocator);
        if (self.a_conn) |*p| p.deinit();
        if (self.d_conn) |*p| p.deinit();
        if (self.proc_d) |*p| p.deinit();
        if (self.connect_bd) |*p| p.deinit();
        self.connect_ab.deinit();
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), _: tp.pid_ref, m: tp.message) !void {
        var conn_id: piid = .empty;
        var bytes: []const u8 = "";
        var origin: []const u8 = "";
        var target: []const u8 = "";
        var reason: []const u8 = "";

        if (try m.match(.{ "connected", tp.extract(&conn_id) })) {
            const conn = tp.pid.from_id(conn_id) orelse return tp.unexpected(m);
            if (self.a_conn == null) {
                self.a_conn = conn;
                say(self.io, "[b] connected to A; spawning D\n", .{});
                const argv = tp.message.fmt(.{ self.exe, "d", self.path_d });
                self.proc_d = try tp.subprocess.init(self.io, self.allocator, argv, d_tag, .ignore);
            } else {
                self.d_conn = conn;
                say(self.io, "[b] connected to D; telling A\n", .{});
                const my_id = lpiid.fromInt(tp.self_pid().instance_id().toInt());
                try self.a_conn.?.send(.{ "send", my_id, "app_a", .{"d_ready"} });
            }
        } else if (try m.match(.{ d_tag, "stdout", tp.extract(&bytes) })) {
            try self.d_stdout.appendSlice(self.allocator, bytes);
            while (std.mem.indexOfScalar(u8, self.d_stdout.items, '\n')) |nl| {
                const line = self.d_stdout.items[0..nl];
                if (std.mem.eql(u8, line, "D_READY") and !self.d_ready) {
                    self.d_ready = true;
                    say(self.io, "[b] D signalled READY; connecting\n", .{});
                    self.connect_bd = try endpoint.connect(self.allocator, self.path_d, sock_mode, tp.self_pid().clone());
                } else if (line.len > 0) {
                    say(self.io, "[d> ] {s}\n", .{line});
                }
                _ = self.d_stdout.orderedRemove(0);
                for (0..nl) |_| _ = self.d_stdout.orderedRemove(0);
            }
        } else if (try m.match(.{ d_tag, "stderr", tp.extract(&bytes) })) {
            say(self.io, "[d/err] {s}\n", .{bytes});
        } else if (try m.match(.{ d_tag, "term", tp.any, tp.any })) {
            // ignore
        } else if (try m.match(.{ "ping", tp.extract(&origin) })) {
            say(self.io, "[b] received PING from {s}\n", .{origin});
        } else if (try m.match(.{ "relay_ping", tp.extract(&target), tp.extract(&origin) })) {
            say(self.io, "[b] relaying PING from {s} to {s} via BD\n", .{ origin, target });
            const my_id = lpiid.fromInt(tp.self_pid().instance_id().toInt());
            try self.d_conn.?.send(.{ "send", my_id, target, .{ "ping", origin } });
        } else if (try m.match(.{ "endpoint_exit", tp.extract(&reason) })) {
            // A or D closed the socket; time to exit.
            return tp.exit_normal();
        } else if (try m.match(.{ "exit", tp.extract(&reason) })) {
            if (std.mem.eql(u8, reason, "normal")) return;
            if (std.mem.eql(u8, reason, "transport_closed")) return tp.exit_normal();
            if (std.mem.eql(u8, reason, "peer_closed")) return tp.exit_normal();
            return tp.unexpected(m);
        } else {
            return tp.unexpected(m);
        }
    }
};

// Node C: connects to A, then (when told) connects to D.
const NodeC = struct {
    allocator: Allocator,
    io: std.Io,
    path_ac: [:0]const u8,
    path_d: [:0]const u8,
    connect_ac: tp.pid,
    connect_cd: ?tp.pid = null,
    a_conn: ?tp.pid = null,
    d_conn: ?tp.pid = null,
    receiver: tp.Receiver(*@This()),

    const Args = struct {
        allocator: Allocator,
        io: std.Io,
        path_ac: [:0]const u8,
        path_d: [:0]const u8,
    };

    fn run(pinit: std.process.Init, path_ac: [:0]const u8, path_d: [:0]const u8) !void {
        var ctx = try tp.context.init(pinit.gpa, .{});
        defer ctx.deinit();

        var exit_ok = false;
        var exit_handler = tp.make_exit_handler(&exit_ok, struct {
            fn handle(ok: *bool, status: []const u8) void {
                ok.* = true;
                _ = status;
            }
        }.handle);

        _ = try ctx.spawn_link(
            NodeC.Args{
                .allocator = pinit.gpa,
                .io = pinit.io,
                .path_ac = path_ac,
                .path_d = path_d,
            },
            NodeC.start,
            "root_c",
            &exit_handler,
            null,
        );
        ctx.run();
        std.process.exit(if (exit_ok) 0 else 1);
    }

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        _ = tp.set_trap(true);
        tp.env.get().proc_set("app_c", tp.self_pid().ref());

        const connect_ac = try endpoint.connect(args.allocator, args.path_ac, sock_mode, tp.self_pid().clone());

        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .io = args.io,
            .path_ac = args.path_ac,
            .path_d = args.path_d,
            .connect_ac = connect_ac,
            .receiver = .init(receive_fn, deinit, self),
        };
        errdefer self.deinit();
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        if (self.a_conn) |*p| p.deinit();
        if (self.d_conn) |*p| p.deinit();
        if (self.connect_cd) |*p| p.deinit();
        self.connect_ac.deinit();
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), _: tp.pid_ref, m: tp.message) !void {
        var conn_id: piid = .empty;
        var origin: []const u8 = "";
        var reason: []const u8 = "";

        if (try m.match(.{ "connected", tp.extract(&conn_id) })) {
            const conn = tp.pid.from_id(conn_id) orelse return tp.unexpected(m);
            if (self.a_conn == null) {
                self.a_conn = conn;
                say(self.io, "[c] connected to A; waiting for connect_d\n", .{});
            } else {
                self.d_conn = conn;
                say(self.io, "[c] connected to D; telling A\n", .{});
                const my_id = lpiid.fromInt(tp.self_pid().instance_id().toInt());
                try self.a_conn.?.send(.{ "send", my_id, "app_a", .{"c_ready"} });
            }
        } else if (try m.match(.{"connect_d"})) {
            say(self.io, "[c] told to connect_d; connecting\n", .{});
            self.connect_cd = try endpoint.connect(self.allocator, self.path_d, sock_mode, tp.self_pid().clone());
        } else if (try m.match(.{ "ping", tp.extract(&origin) })) {
            say(self.io, "[c] received PING from {s}\n", .{origin});
        } else if (try m.match(.{ "endpoint_exit", tp.extract(&reason) })) {
            return tp.exit_normal();
        } else if (try m.match(.{ "exit", tp.extract(&reason) })) {
            if (std.mem.eql(u8, reason, "normal")) return;
            if (std.mem.eql(u8, reason, "transport_closed")) return tp.exit_normal();
            if (std.mem.eql(u8, reason, "peer_closed")) return tp.exit_normal();
            return tp.unexpected(m);
        } else {
            return tp.unexpected(m);
        }
    }
};

// Node D: listens for B and C.
const NodeD = struct {
    allocator: Allocator,
    io: std.Io,
    path_d: [:0]const u8,
    listen_d: tp.pid,
    conns: [2]?tp.pid = .{ null, null },
    accepted: u8 = 0,
    receiver: tp.Receiver(*@This()),

    const Args = struct {
        allocator: Allocator,
        io: std.Io,
        path_d: [:0]const u8,
    };

    fn run(pinit: std.process.Init, path_d: [:0]const u8) !void {
        var ctx = try tp.context.init(pinit.gpa, .{});
        defer ctx.deinit();

        var exit_ok = false;
        var exit_handler = tp.make_exit_handler(&exit_ok, struct {
            fn handle(ok: *bool, status: []const u8) void {
                ok.* = true;
                _ = status;
            }
        }.handle);

        _ = try ctx.spawn_link(
            NodeD.Args{
                .allocator = pinit.gpa,
                .io = pinit.io,
                .path_d = path_d,
            },
            NodeD.start,
            "root_d",
            &exit_handler,
            null,
        );
        ctx.run();
        std.process.exit(if (exit_ok) 0 else 1);
    }

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        _ = tp.set_trap(true);
        tp.env.get().proc_set("app_d", tp.self_pid().ref());

        const listen_d = try endpoint.listen(args.allocator, args.path_d, sock_mode, tp.self_pid().clone());
        try listen_d.send(.{ "get", "path" });

        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .io = args.io,
            .path_d = args.path_d,
            .listen_d = listen_d,
            .receiver = .init(receive_fn, deinit, self),
        };
        errdefer self.deinit();
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        for (&self.conns) |*slot| if (slot.*) |*p| p.deinit();
        self.listen_d.deinit();
        self.allocator.destroy(self);
    }

    fn receive_fn(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive(self: *@This(), _: tp.pid_ref, m: tp.message) !void {
        var conn_id: piid = .empty;
        var origin: []const u8 = "";
        var path_out: []const u8 = "";
        var reason: []const u8 = "";

        if (try m.match(.{ "path", tp.extract(&path_out) })) {
            say(self.io, "D_READY\n", .{});
        } else if (try m.match(.{ "connected", tp.extract(&conn_id) })) {
            const conn = tp.pid.from_id(conn_id) orelse return tp.unexpected(m);
            if (self.accepted < 2) {
                self.conns[self.accepted] = conn;
                self.accepted += 1;
                say(self.io, "[d] accepted connection #{d}\n", .{self.accepted});
            } else {
                conn.deinit();
            }
        } else if (try m.match(.{ "ping", tp.extract(&origin) })) {
            say(self.io, "[d] received PING from {s}\n", .{origin});
        } else if (try m.match(.{ "endpoint_exit", tp.extract(&reason) })) {
            // A remote connection went down; if both are gone, quit.
            var alive: u8 = 0;
            for (self.conns) |slot| if (slot) |p| if (!p.expired()) {
                alive += 1;
            };
            if (alive == 0) return tp.exit_normal();
        } else if (try m.match(.{ "exit", tp.extract(&reason) })) {
            if (std.mem.eql(u8, reason, "normal")) return;
            if (std.mem.eql(u8, reason, "transport_closed")) return;
            if (std.mem.eql(u8, reason, "peer_closed")) return;
            return tp.unexpected(m);
        } else {
            return tp.unexpected(m);
        }
    }
};
