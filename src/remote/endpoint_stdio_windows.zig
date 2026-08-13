const std = @import("std");
const tp = @import("thespian");

const windows = std.os.windows;
const STD_INPUT_HANDLE: windows.DWORD = 0xFFFFFFF6;
const STD_OUTPUT_HANDLE: windows.DWORD = 0xFFFFFFF5;
extern "kernel32" fn GetStdHandle(nStdHandle: windows.DWORD) callconv(.winapi) ?windows.HANDLE;

pub fn start(_: std.Io, allocator: std.mem.Allocator) error{ OutOfMemory, ThespianSpawnFailed }!tp.pid {
    return tp.spawn_link(
        allocator,
        Process.Args{
            .allocator = allocator,
        },
        Process.start,
        @typeName(@This()),
    );
}

const Process = struct {
    allocator: std.mem.Allocator,
    stream_stdin: tp.file_stream,
    stream_stdout: tp.file_stream,
    endpoint: @import("endpoint_common.zig").create(@This()),
    receiver: tp.Receiver(*@This()),

    write_queue: std.ArrayList([]u8) = .empty,
    write_in_flight: ?[]u8 = null,

    const Args = struct {
        allocator: std.mem.Allocator,
    };

    fn start(args: Args) tp.result {
        return init(args) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn init(args: Args) !void {
        const stdin_h = GetStdHandle(STD_INPUT_HANDLE) orelse return error.EndpointStdioNoStdin;
        const stdout_h = GetStdHandle(STD_OUTPUT_HANDLE) orelse return error.EndpointStdioNoStdout;
        if (stdin_h == windows.INVALID_HANDLE_VALUE) return error.EndpointStdioNoStdin;
        if (stdout_h == windows.INVALID_HANDLE_VALUE) return error.EndpointStdioNoStdout;

        const stream_stdin = try tp.file_stream.init("stdin", stdin_h);
        var stdin_owned = true;
        errdefer if (stdin_owned) stream_stdin.deinit();

        const stream_stdout = try tp.file_stream.init("stdout", stdout_h);
        var stdout_owned = true;
        errdefer if (stdout_owned) stream_stdout.deinit();

        const self = try args.allocator.create(@This());
        self.* = .{
            .allocator = args.allocator,
            .stream_stdin = stream_stdin,
            .stream_stdout = stream_stdout,
            .endpoint = .init(args.allocator),
            .receiver = .init(receive, deinit, self),
        };
        stdin_owned = false;
        stdout_owned = false;
        errdefer self.deinit();

        _ = tp.set_trap(true);
        try self.stream_stdin.start_read();
        tp.receive(&self.receiver);
    }

    fn deinit(self: *@This()) void {
        const allocator = self.allocator;
        if (self.write_in_flight) |b| allocator.free(b);
        for (self.write_queue.items) |b| allocator.free(b);
        self.write_queue.deinit(allocator);
        self.endpoint.deinit();
        self.stream_stdout.deinit();
        self.stream_stdin.deinit();
        allocator.destroy(self);
    }

    fn receive(self: *@This(), from: tp.pid_ref, m: tp.message) tp.result {
        return self.receive_safe(from, m) catch |e| return tp.exit_error(e, @errorReturnTrace());
    }

    fn receive_safe(self: *@This(), from: tp.pid_ref, m: tp.message) !void {
        var bytes: []const u8 = "";
        var reason: []const u8 = "";
        if (try m.match(.{ "stream", "stdin", "read_complete", tp.extract(&bytes) })) {
            if (bytes.len == 0) {
                try self.endpoint.send_transport_error("stdin_closed");
                return tp.exit("stdin_closed");
            }
            try self.endpoint.feed(bytes);
            try self.stream_stdin.start_read();
        } else if (try m.match(.{ "stream", "stdout", "write_complete", tp.any })) {
            if (self.write_in_flight) |b| {
                self.allocator.free(b);
                self.write_in_flight = null;
            }
            try self.pump_writes();
        } else if (try m.match(.{ "stream", "stdin", "read_error", tp.any, tp.extract(&reason) })) {
            try self.endpoint.send_transport_error(reason);
            return tp.exit(reason);
        } else if (try m.match(.{ "stream", "stdout", "write_error", tp.any, tp.extract(&reason) })) {
            try self.endpoint.send_transport_error(reason);
            return tp.exit(reason);
        } else {
            return self.endpoint.receive(from, m);
        }
    }

    fn pump_writes(self: *@This()) !void {
        if (self.write_in_flight != null) return;
        if (self.write_queue.items.len == 0) return;
        const next = self.write_queue.orderedRemove(0);
        self.write_in_flight = next;
        try self.stream_stdout.start_write(next);
    }

    pub fn send_frame(self: *@This(), frame: []const u8) !void {
        const owned = try self.allocator.dupe(u8, frame);
        {
            errdefer self.allocator.free(owned);
            try self.write_queue.append(self.allocator, owned);
        }
        try self.pump_writes();
    }
};
