const std = @import("std");
const cbor = @import("cbor");
const tp = @import("thespian.zig");

pid: ?tp.pid,
stdin_behavior: StdIo,

const Self = @This();
pub const max_chunk_size = 4096 - 32;
pub const StdIo = std.process.SpawnOptions.StdIo;

pub fn init(io: std.Io, a: std.mem.Allocator, argv: tp.message, tag: [:0]const u8, stdin_behavior: StdIo) !Self {
    return .{
        .pid = try Proc.create(io, a, argv, tag, stdin_behavior),
        .stdin_behavior = stdin_behavior,
    };
}

pub fn deinit(self: *Self) void {
    if (self.pid) |pid| {
        pid.deinit();
        self.pid = null;
    }
}

pub fn write(self: *Self, bytes: []const u8) error{WriteFailed}!usize {
    self.send(bytes) catch return error.WriteFailed;
    return bytes.len;
}

pub fn send(self: *const Self, bytes_: []const u8) tp.result {
    if (self.stdin_behavior != .pipe) return tp.exit("cannot send to closed stdin");
    const pid = if (self.pid) |pid| pid else return tp.exit_error(error.Closed, null);
    var bytes = bytes_;
    while (bytes.len > 0)
        bytes = loop: {
            if (bytes.len > max_chunk_size) {
                try pid.send(.{ "stdin", bytes[0..max_chunk_size] });
                break :loop bytes[max_chunk_size..];
            } else {
                try pid.send(.{ "stdin", bytes });
                break :loop &[_]u8{};
            }
        };
}

pub fn close(self: *Self) tp.result {
    defer self.deinit();
    if (self.stdin_behavior == .pipe)
        if (self.pid) |pid| if (!pid.expired()) try pid.send(.{"stdin_close"});
}

pub fn term(self: *Self) tp.result {
    defer self.deinit();
    if (self.pid) |pid| if (!pid.expired()) try pid.send(.{"term"});
}

pub const Writer = struct {
    subprocess: *Self,
    interface: std.Io.Writer,
};

pub fn writer(self: *Self, buffer: []u8) Writer {
    return .{
        .subprocess = self,
        .interface = .{
            .vtable = &.{
                .drain = drain,
            },
            .buffer = buffer,
        },
    };
}

fn drain(w: *std.Io.Writer, data_: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const writer_: *Self.Writer = @alignCast(@fieldParentPtr("interface", w));
    var written: usize = 0;
    const buffered = w.buffered();
    if (buffered.len != 0) {
        const n = try writer_.subprocess.write(buffered);
        written += w.consume(n);
    }
    if (data_.len == 0) return written;
    for (data_[0 .. data_.len - 1]) |bytes| {
        written += try writer_.subprocess.write(bytes);
    }
    const pattern_ = data_[data_.len - 1];
    switch (pattern_.len) {
        0 => return written,
        else => for (0..splat) |_| {
            written += try writer_.subprocess.write(pattern_);
        },
    }
    return written;
}

const Proc = struct {
    a: std.mem.Allocator,
    receiver: Receiver,
    args: std.heap.ArenaAllocator,
    parent: tp.pid,
    child: Child,
    tag: [:0]const u8,
    stdin_buffer: std.ArrayList(u8),
    stream_stdout: ?tp.file_stream = null,
    stream_stderr: ?tp.file_stream = null,

    const Receiver = tp.Receiver(*Proc);

    fn create(_: std.Io, a: std.mem.Allocator, argv: tp.message, tag: [:0]const u8, stdin_behavior: StdIo) !tp.pid {
        const self: *Proc = try a.create(Proc);

        var args = std.heap.ArenaAllocator.init(a);
        const args_a = args.allocator();
        var iter = argv.buf;
        var len = cbor.decodeArrayHeader(&iter) catch return error.InvalidArgument;
        var argv_ = try args_a.alloc([]const u8, len);
        var arg: []const u8 = undefined;
        var i: usize = 0;
        while (len > 0) : (len -= 1) {
            if (!(cbor.matchString(&iter, &arg) catch return error.InvalidArgument))
                return error.InvalidArgument;
            argv_[i] = try args_a.dupe(u8, arg);
            i += 1;
        }

        var child = Child.init(argv_, a);
        child.stdin_behavior = stdin_behavior;
        child.stdout_behavior = .pipe;
        child.stderr_behavior = .pipe;

        self.* = .{
            .a = a,
            .receiver = Receiver.init(receive, Proc.deinit, self),
            .args = args,
            .parent = tp.self_pid().clone(),
            .child = child,
            .tag = try a.dupeZ(u8, tag),
            .stdin_buffer = .empty,
        };
        return tp.spawn_link(a, self, Proc.start, tag);
    }

    fn deinit(self: *Proc) void {
        self.args.deinit();
        if (self.stream_stdout) |stream| stream.deinit();
        if (self.stream_stderr) |stream| stream.deinit();
        self.stdin_buffer.deinit(self.a);
        self.parent.deinit();
        self.a.free(self.tag);
        self.a.destroy(self);
    }

    fn start(self: *Proc) tp.result {
        errdefer self.deinit();

        self.child.spawn() catch |e| return self.handle_error(e);
        _ = self.args.reset(.free_all);

        self.stream_stdout = tp.file_stream.init("stdout", self.child.stdout.?.handle) catch |e| return self.handle_error(e);
        self.child.stdout = null; // ownership transferred
        self.stream_stderr = tp.file_stream.init("stderr", self.child.stderr.?.handle) catch |e| return self.handle_error(e);
        self.child.stderr = null; // ownership transferred
        if (self.stream_stdout) |stream| stream.start_read() catch |e| return self.handle_error(e);
        if (self.stream_stderr) |stream| stream.start_read() catch |e| return self.handle_error(e);

        tp.receive(&self.receiver);
    }

    fn receive(self: *Proc, _: tp.pid_ref, m: tp.message) tp.result {
        var bytes: []const u8 = "";
        var stream_name: []const u8 = "";
        var err: i64 = 0;
        var err_msg: []const u8 = "";
        if (try m.match(.{ "stream", "stdout", "read_complete", tp.extract(&bytes) })) {
            try self.dispatch_stdout(bytes);
            if (self.stream_stdout) |stream| stream.start_read() catch |e| return self.handle_error(e);
        } else if (try m.match(.{ "stream", "stderr", "read_complete", tp.extract(&bytes) })) {
            try self.dispatch_stderr(bytes);
            if (self.stream_stderr) |stream| stream.start_read() catch |e| return self.handle_error(e);
        } else if (try m.match(.{ "stdin", tp.extract(&bytes) })) {
            try self.start_write(bytes);
        } else if (try m.match(.{"stdin_close"})) {
            self.stdin_close();
        } else if (try m.match(.{"stdout_close"})) {
            if (self.child.stdout) |*fd| {
                fd.close();
                self.child.stdout = null;
            }
        } else if (try m.match(.{"stderr_close"})) {
            if (self.child.stderr) |*fd| {
                fd.close();
                self.child.stderr = null;
            }
        } else if (try m.match(.{"term"})) {
            const term_ = self.child.kill() catch |e| return self.handle_error(e);
            return self.handle_term(term_);
        } else if (try m.match(.{ "stream", "stdout", "read_error", Child.ERROR_BROKEN_PIPE, tp.extract(&err_msg) })) {
            // stdout closed
            self.child.stdout = null;
            return self.handle_terminate();
        } else if (try m.match(.{ "stream", "stderr", "read_error", Child.ERROR_BROKEN_PIPE, tp.extract(&err_msg) })) {
            // stderr closed
            self.child.stderr = null;
        } else if (try m.match(.{ "stream", tp.extract(&stream_name), "read_error", tp.extract(&err), tp.extract(&err_msg) })) {
            try self.parent.send(.{ self.tag, "term", err_msg, 1 });
            return tp.exit_normal();
        }
    }

    fn start_write(self: *Proc, bytes: []const u8) tp.result {
        if (self.child.stdin) |stdin|
            stdin.writeAll(bytes) catch |e| return self.handle_error(e);
    }

    fn stdin_close(self: *Proc) void {
        if (self.child.stdin) |*fd| {
            fd.close();
            self.child.stdin = null;
            tp.env.get().trace(tp.message.fmt(.{ self.tag, "stdin", "closed" }).to(tp.message.c_buffer_type));
        }
    }

    fn dispatch_stdout(self: *Proc, bytes: []const u8) tp.result {
        if (bytes.len == 0)
            return self.handle_terminate();
        try self.parent.send(.{ self.tag, "stdout", bytes });
    }

    fn dispatch_stderr(self: *Proc, bytes: []const u8) tp.result {
        if (bytes.len == 0)
            return;
        try self.parent.send(.{ self.tag, "stderr", bytes });
    }

    fn handle_terminate(self: *Proc) error{Exit} {
        return self.handle_term(self.child.wait() catch |e| return self.handle_error(e));
    }

    fn handle_term(self: *Proc, term_: Child.Term) error{Exit} {
        (switch (term_) {
            .Exited => |val| self.parent.send(.{ self.tag, "term", "exited", val }),
            .Signal => |val| self.parent.send(.{ self.tag, "term", "signal", val }),
            .Stopped => |val| self.parent.send(.{ self.tag, "term", "stop", val }),
            .Unknown => |val| self.parent.send(.{ self.tag, "term", "unknown", val }),
        }) catch {};
        return tp.exit_normal();
    }

    fn handle_error(self: *Proc, e: anyerror) error{Exit} {
        try self.parent.send(.{ self.tag, "term", e, 1 });
        return tp.exit_normal();
    }
};

const Child = struct {
    const windows = std.os.windows;
    const posix = std.posix;
    const unicode = std.unicode;
    const process = std.process;
    const fs = std.fs;
    const mem = std.mem;
    const EnvMap = std.process.Environ.Map;

    const ERROR_BROKEN_PIPE = 109;

    // Win32 constants removed from std.os.windows in zig-0.16
    const INFINITE: windows.DWORD = 0xFFFFFFFF;
    const HANDLE_FLAG_INHERIT: windows.DWORD = 0x00000001;
    const PIPE_ACCESS_INBOUND: windows.DWORD = 0x00000001;
    const FILE_FLAG_OVERLAPPED: windows.DWORD = 0x40000000;
    const FILE_FLAG_BACKUP_SEMANTICS: windows.DWORD = 0x02000000;
    const PIPE_TYPE_BYTE: windows.DWORD = 0x00000000;
    const OPEN_EXISTING: windows.DWORD = 3;
    const FILE_ATTRIBUTE_NORMAL: windows.DWORD = 0x80;
    const GENERIC_READ: windows.DWORD = 0x80000000;
    const GENERIC_WRITE: windows.DWORD = 0x40000000;
    const SYNCHRONIZE: windows.DWORD = 0x00100000;
    const FILE_SHARE_READ: windows.DWORD = 0x00000001;
    const FILE_SHARE_WRITE: windows.DWORD = 0x00000002;
    const FILE_SHARE_DELETE: windows.DWORD = 0x00000004;
    const STD_INPUT_HANDLE: windows.DWORD = 0xFFFFFFF6;
    const STD_OUTPUT_HANDLE: windows.DWORD = 0xFFFFFFF5;
    const STD_ERROR_HANDLE: windows.DWORD = 0xFFFFFFF4;

    extern "kernel32" fn CreatePipe(
        hReadPipe: *windows.HANDLE,
        hWritePipe: *windows.HANDLE,
        lpPipeAttributes: ?*windows.SECURITY_ATTRIBUTES,
        nSize: windows.DWORD,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn SetHandleInformation(
        hObject: windows.HANDLE,
        dwMask: windows.DWORD,
        dwFlags: windows.DWORD,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn WriteFile(
        hFile: windows.HANDLE,
        lpBuffer: *const anyopaque,
        nNumberOfBytesToWrite: windows.DWORD,
        lpNumberOfBytesWritten: ?*windows.DWORD,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn GetExitCodeProcess(
        hProcess: windows.HANDLE,
        lpExitCode: *windows.DWORD,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn WaitForSingleObjectEx(
        hHandle: windows.HANDLE,
        dwMilliseconds: windows.DWORD,
        bAlertable: windows.BOOL,
    ) callconv(.winapi) windows.DWORD;

    extern "kernel32" fn TerminateProcess(
        hProcess: windows.HANDLE,
        uExitCode: windows.UINT,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn CreateNamedPipeW(
        lpName: [*:0]const u16,
        dwOpenMode: windows.DWORD,
        dwPipeMode: windows.DWORD,
        nMaxInstances: windows.DWORD,
        nOutBufferSize: windows.DWORD,
        nInBufferSize: windows.DWORD,
        nDefaultTimeOut: windows.DWORD,
        lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
    ) callconv(.winapi) windows.HANDLE;

    extern "kernel32" fn CreateFileW(
        lpFileName: [*:0]const u16,
        dwDesiredAccess: windows.DWORD,
        dwShareMode: windows.DWORD,
        lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
        dwCreationDisposition: windows.DWORD,
        dwFlagsAndAttributes: windows.DWORD,
        hTemplateFile: ?windows.HANDLE,
    ) callconv(.winapi) windows.HANDLE;

    extern "kernel32" fn GetSystemDirectoryW(
        lpBuffer: [*:0]u16,
        uSize: windows.UINT,
    ) callconv(.winapi) windows.UINT;

    extern "kernel32" fn GetStdHandle(
        nStdHandle: windows.DWORD,
    ) callconv(.winapi) ?windows.HANDLE;

    const WindowsHandle = struct {
        handle: windows.HANDLE,

        fn writeAll(self: @This(), bytes: []const u8) !void {
            var remaining = bytes;
            while (remaining.len > 0) {
                var written: windows.DWORD = 0;
                if (WriteFile(self.handle, remaining.ptr, @intCast(remaining.len), &written, null) == .FALSE) {
                    switch (windows.GetLastError()) {
                        else => |err| return windows.unexpectedError(err),
                    }
                }
                remaining = remaining[written..];
            }
        }

        fn close(self: @This()) void {
            windows.CloseHandle(self.handle);
        }
    };

    pub const Term = union(enum) {
        Exited: u8,
        Signal: u32,
        Stopped: u32,
        Unknown: u32,
    };

    pub const SpawnError = error{
        OutOfMemory,
        InvalidWtf8,
        CurrentWorkingDirectoryUnlinked,
        InvalidBatchScriptArg,
        Unexpected,
        FileNotFound,
        InvalidExe,
        AccessDenied,
        BadPathName,
        NameTooLong,
        AlreadyTerminated,
    };

    id: windows.HANDLE,
    thread_handle: windows.HANDLE,
    allocator: mem.Allocator,
    stdin: ?WindowsHandle,
    stdout: ?WindowsHandle,
    stderr: ?WindowsHandle,
    term: ?(SpawnError!Term),
    argv: []const []const u8,
    env_map: ?*const EnvMap,
    stdin_behavior: StdIo,
    stdout_behavior: StdIo,
    stderr_behavior: StdIo,
    cwd: ?[]const u8,
    cwd_dir: ?std.Io.Dir = null,

    pub fn init(argv: []const []const u8, allocator: mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .argv = argv,
            .id = undefined,
            .thread_handle = undefined,
            .term = null,
            .env_map = null,
            .cwd = null,
            .stdin = null,
            .stdout = null,
            .stderr = null,
            .stdin_behavior = .inherit,
            .stdout_behavior = .inherit,
            .stderr_behavior = .inherit,
        };
    }

    pub fn spawn(self: *@This()) !void {
        var saAttr = windows.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .bInheritHandle = .TRUE,
            .lpSecurityDescriptor = null,
        };

        const any_ignore = (self.stdin_behavior == .ignore or self.stdout_behavior == .ignore or self.stderr_behavior == .ignore);

        const nul_handle: windows.HANDLE = if (any_ignore) nul: {
            const nul_name = [_]u16{ '\\', 'D', 'e', 'v', 'i', 'c', 'e', '\\', 'N', 'u', 'l', 'l' };
            var nul_unicode = windows.UNICODE_STRING{
                .Length = @intCast(nul_name.len * 2),
                .MaximumLength = @intCast(nul_name.len * 2),
                .Buffer = @constCast(&nul_name),
            };
            var nul_attr = windows.OBJECT.ATTRIBUTES{ .ObjectName = &nul_unicode };
            var io_status: windows.IO_STATUS_BLOCK = undefined;
            var nul_h: windows.HANDLE = undefined;
            const rc = windows.ntdll.NtCreateFile(
                &nul_h,
                @bitCast(@as(windows.DWORD, GENERIC_READ | GENERIC_WRITE | SYNCHRONIZE)),
                &nul_attr,
                &io_status,
                null,
                .{},
                .{ .READ = true, .WRITE = true, .DELETE = true },
                .OPEN,
                .{ .IO = .SYNCHRONOUS_NONALERT },
                null,
                0,
            );
            if (rc != .SUCCESS) return windows.unexpectedStatus(rc);
            break :nul nul_h;
        } else undefined;
        defer {
            if (any_ignore) windows.CloseHandle(nul_handle);
        }

        var g_hChildStd_IN_Rd: ?windows.HANDLE = null;
        var g_hChildStd_IN_Wr: ?windows.HANDLE = null;
        switch (self.stdin_behavior) {
            .pipe => {
                try makePipeIn(&g_hChildStd_IN_Rd, &g_hChildStd_IN_Wr, &saAttr);
            },
            .ignore => {
                g_hChildStd_IN_Rd = nul_handle;
            },
            .inherit => {
                g_hChildStd_IN_Rd = GetStdHandle(STD_INPUT_HANDLE);
            },
            .file => |f| {
                g_hChildStd_IN_Rd = f.handle;
            },
            .close => {
                g_hChildStd_IN_Rd = null;
            },
        }
        errdefer if (self.stdin_behavior == .pipe) {
            destroyPipe(g_hChildStd_IN_Rd, g_hChildStd_IN_Wr);
        };

        var g_hChildStd_OUT_Rd: ?windows.HANDLE = null;
        var g_hChildStd_OUT_Wr: ?windows.HANDLE = null;
        switch (self.stdout_behavior) {
            .pipe => {
                try makeAsyncPipe(&g_hChildStd_OUT_Rd, &g_hChildStd_OUT_Wr, &saAttr);
            },
            .ignore => {
                g_hChildStd_OUT_Wr = nul_handle;
            },
            .inherit => {
                g_hChildStd_OUT_Wr = GetStdHandle(STD_OUTPUT_HANDLE);
            },
            .file => |f| {
                g_hChildStd_OUT_Wr = f.handle;
            },
            .close => {
                g_hChildStd_OUT_Wr = null;
            },
        }
        errdefer if (self.stdout_behavior == .pipe) {
            destroyPipe(g_hChildStd_OUT_Rd, g_hChildStd_OUT_Wr);
        };

        var g_hChildStd_ERR_Rd: ?windows.HANDLE = null;
        var g_hChildStd_ERR_Wr: ?windows.HANDLE = null;
        switch (self.stderr_behavior) {
            .pipe => {
                try makeAsyncPipe(&g_hChildStd_ERR_Rd, &g_hChildStd_ERR_Wr, &saAttr);
            },
            .ignore => {
                g_hChildStd_ERR_Wr = nul_handle;
            },
            .inherit => {
                g_hChildStd_ERR_Wr = GetStdHandle(STD_ERROR_HANDLE);
            },
            .file => |f| {
                g_hChildStd_ERR_Wr = f.handle;
            },
            .close => {
                g_hChildStd_ERR_Wr = null;
            },
        }
        errdefer if (self.stderr_behavior == .pipe) {
            destroyPipe(g_hChildStd_ERR_Rd, g_hChildStd_ERR_Wr);
        };

        var siStartInfo = windows.STARTUPINFOW{
            .cb = @sizeOf(windows.STARTUPINFOW),
            .hStdError = g_hChildStd_ERR_Wr,
            .hStdOutput = g_hChildStd_OUT_Wr,
            .hStdInput = g_hChildStd_IN_Rd,
            .dwFlags = windows.STARTF_USESTDHANDLES,

            .lpReserved = null,
            .lpDesktop = null,
            .lpTitle = null,
            .dwX = 0,
            .dwY = 0,
            .dwXSize = 0,
            .dwYSize = 0,
            .dwXCountChars = 0,
            .dwYCountChars = 0,
            .dwFillAttribute = 0,
            .wShowWindow = 0,
            .cbReserved2 = 0,
            .lpReserved2 = null,
        };
        var piProcInfo: windows.PROCESS.INFORMATION = undefined;

        const cwd_w = if (self.cwd) |cwd| try unicode.wtf8ToWtf16LeAllocZ(self.allocator, cwd) else null;
        defer if (cwd_w) |cwd| self.allocator.free(cwd);
        const cwd_w_ptr = if (cwd_w) |cwd| cwd.ptr else null;

        const maybe_env_block: ?std.process.Environ.WindowsBlock = if (self.env_map) |env_map| try env_map.createWindowsBlock(self.allocator, .{}) else null;
        defer if (maybe_env_block) |block| block.deinit(self.allocator);
        const envp_ptr: ?[*:0]const u16 = if (maybe_env_block) |block| block.slice.ptr else null;

        const app_name_wtf8 = self.argv[0];
        const app_name_is_absolute = fs.path.isAbsolute(app_name_wtf8);

        var cwd_path_w_needs_free = false;
        const cwd_path_w = x: {
            if (app_name_is_absolute) {
                cwd_path_w_needs_free = true;
                const dir = fs.path.dirname(app_name_wtf8).?;
                break :x try unicode.wtf8ToWtf16LeAllocZ(self.allocator, dir);
            } else if (self.cwd) |cwd| {
                cwd_path_w_needs_free = true;
                break :x try unicode.wtf8ToWtf16LeAllocZ(self.allocator, cwd);
            } else {
                break :x &[_:0]u16{}; // empty for cwd
            }
        };
        defer if (cwd_path_w_needs_free) self.allocator.free(cwd_path_w);

        const app_basename_wtf8 = fs.path.basename(app_name_wtf8);
        const maybe_app_dirname_wtf8 = if (!app_name_is_absolute) fs.path.dirname(app_name_wtf8) else null;
        const app_dirname_w: ?[:0]u16 = x: {
            if (maybe_app_dirname_wtf8) |app_dirname_wtf8| {
                break :x try unicode.wtf8ToWtf16LeAllocZ(self.allocator, app_dirname_wtf8);
            }
            break :x null;
        };
        defer if (app_dirname_w != null) self.allocator.free(app_dirname_w.?);

        const app_name_w = try unicode.wtf8ToWtf16LeAllocZ(self.allocator, app_basename_wtf8);
        defer self.allocator.free(app_name_w);

        run: {
            const global_environ: std.process.Environ = .{ .block = .{ .use_global = true } };
            const PATH: [:0]const u16 = std.process.Environ.getWindows(global_environ, unicode.utf8ToUtf16LeStringLiteral("PATH")) orelse &[_:0]u16{};
            const PATHEXT: [:0]const u16 = std.process.Environ.getWindows(global_environ, unicode.utf8ToUtf16LeStringLiteral("PATHEXT")) orelse &[_:0]u16{};

            var cmd_line_cache = CommandLineCache.init(self.allocator, self.argv);
            defer cmd_line_cache.deinit();

            var app_buf = std.ArrayListUnmanaged(u16).empty;
            defer app_buf.deinit(self.allocator);

            try app_buf.appendSlice(self.allocator, app_name_w);

            var dir_buf = std.ArrayListUnmanaged(u16).empty;
            defer dir_buf.deinit(self.allocator);

            if (cwd_path_w.len > 0) {
                try dir_buf.appendSlice(self.allocator, cwd_path_w);
            }
            if (app_dirname_w) |app_dir| {
                if (dir_buf.items.len > 0) try dir_buf.append(self.allocator, fs.path.sep);
                try dir_buf.appendSlice(self.allocator, app_dir);
            }
            if (dir_buf.items.len > 0) {
                const normalized_len = windows.normalizePath(u16, dir_buf.items) catch return error.BadPathName;
                dir_buf.shrinkRetainingCapacity(normalized_len);
            }

            createProcessPathExt(self.allocator, &dir_buf, &app_buf, PATHEXT, &cmd_line_cache, envp_ptr, cwd_w_ptr, &siStartInfo, &piProcInfo) catch |no_path_err| {
                const original_err = switch (no_path_err) {
                    error.InvalidArg0 => return error.FileNotFound,
                    error.FileNotFound, error.InvalidExe, error.AccessDenied => |e| e,
                    error.UnrecoverableInvalidExe => return error.InvalidExe,
                    else => |e| return e,
                };

                if (app_dirname_w != null or app_name_is_absolute) {
                    return original_err;
                }

                var it = mem.tokenizeScalar(u16, PATH, ';');
                while (it.next()) |search_path| {
                    dir_buf.clearRetainingCapacity();
                    try dir_buf.appendSlice(self.allocator, search_path);
                    const normalized_len = windows.normalizePath(u16, dir_buf.items) catch continue;
                    dir_buf.shrinkRetainingCapacity(normalized_len);

                    if (createProcessPathExt(self.allocator, &dir_buf, &app_buf, PATHEXT, &cmd_line_cache, envp_ptr, cwd_w_ptr, &siStartInfo, &piProcInfo)) {
                        break :run;
                    } else |err| switch (err) {
                        error.InvalidArg0 => return error.FileNotFound,
                        error.FileNotFound, error.AccessDenied, error.InvalidExe => continue,
                        error.UnrecoverableInvalidExe => return error.InvalidExe,
                        else => |e| return e,
                    }
                } else {
                    return original_err;
                }
            };
        }

        if (g_hChildStd_IN_Wr) |h| {
            self.stdin = WindowsHandle{ .handle = h };
        } else {
            self.stdin = null;
        }
        if (g_hChildStd_OUT_Rd) |h| {
            self.stdout = WindowsHandle{ .handle = h };
        } else {
            self.stdout = null;
        }
        if (g_hChildStd_ERR_Rd) |h| {
            self.stderr = WindowsHandle{ .handle = h };
        } else {
            self.stderr = null;
        }

        self.id = piProcInfo.hProcess;
        self.thread_handle = piProcInfo.hThread;
        self.term = null;

        if (self.stdin_behavior == .pipe) {
            windows.CloseHandle(g_hChildStd_IN_Rd.?);
        }
        if (self.stderr_behavior == .pipe) {
            windows.CloseHandle(g_hChildStd_ERR_Wr.?);
        }
        if (self.stdout_behavior == .pipe) {
            windows.CloseHandle(g_hChildStd_OUT_Wr.?);
        }
    }

    fn makePipeIn(rd: *?windows.HANDLE, wr: *?windows.HANDLE, sattr: *windows.SECURITY_ATTRIBUTES) !void {
        var rd_h: windows.HANDLE = undefined;
        var wr_h: windows.HANDLE = undefined;
        if (CreatePipe(&rd_h, &wr_h, sattr, 0) == .FALSE) {
            switch (windows.GetLastError()) {
                else => |err| return windows.unexpectedError(err),
            }
        }
        errdefer destroyPipe(rd_h, wr_h);
        if (SetHandleInformation(wr_h, HANDLE_FLAG_INHERIT, 0) == .FALSE) {
            switch (windows.GetLastError()) {
                else => |err| return windows.unexpectedError(err),
            }
        }
        rd.* = rd_h;
        wr.* = wr_h;
    }

    fn destroyPipe(rd: ?windows.HANDLE, wr: ?windows.HANDLE) void {
        if (rd) |h| windows.CloseHandle(h);
        if (wr) |h| windows.CloseHandle(h);
    }

    var pipe_name_counter = std.atomic.Value(u32).init(1);

    fn makeAsyncPipe(rd: *?windows.HANDLE, wr: *?windows.HANDLE, sattr: *windows.SECURITY_ATTRIBUTES) !void {
        var tmp_bufw: [128]u16 = undefined;

        const pipe_path = blk: {
            var tmp_buf: [128]u8 = undefined;
            const pipe_path = std.fmt.bufPrintZ(
                &tmp_buf,
                "\\\\.\\pipe\\zig-childprocess-{d}-{d}",
                .{ windows.GetCurrentProcessId(), pipe_name_counter.fetchAdd(1, .monotonic) },
            ) catch unreachable;
            const len = std.unicode.wtf8ToWtf16Le(&tmp_bufw, pipe_path) catch unreachable;
            tmp_bufw[len] = 0;
            break :blk tmp_bufw[0..len :0];
        };

        const read_handle = CreateNamedPipeW(
            pipe_path.ptr,
            PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED,
            PIPE_TYPE_BYTE,
            1,
            4096,
            4096,
            0,
            sattr,
        );
        if (read_handle == windows.INVALID_HANDLE_VALUE) {
            switch (windows.GetLastError()) {
                else => |err| return windows.unexpectedError(err),
            }
        }
        errdefer windows.CloseHandle(read_handle);

        var sattr_copy = sattr.*;
        const write_handle = CreateFileW(
            pipe_path.ptr,
            GENERIC_WRITE,
            0,
            &sattr_copy,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (write_handle == windows.INVALID_HANDLE_VALUE) {
            switch (windows.GetLastError()) {
                else => |err| return windows.unexpectedError(err),
            }
        }
        errdefer windows.CloseHandle(write_handle);

        if (SetHandleInformation(read_handle, HANDLE_FLAG_INHERIT, 0) == .FALSE) {
            switch (windows.GetLastError()) {
                else => |err| return windows.unexpectedError(err),
            }
        }

        rd.* = read_handle;
        wr.* = write_handle;
    }

    const CommandLineCache = struct {
        cmd_line: ?[:0]u16 = null,
        script_cmd_line: ?[:0]u16 = null,
        cmd_exe_path: ?[:0]u16 = null,
        argv: []const []const u8,
        allocator: mem.Allocator,

        fn init(allocator: mem.Allocator, argv: []const []const u8) CommandLineCache {
            return .{
                .allocator = allocator,
                .argv = argv,
            };
        }

        fn deinit(self: *CommandLineCache) void {
            if (self.cmd_line) |cmd_line| self.allocator.free(cmd_line);
            if (self.script_cmd_line) |script_cmd_line| self.allocator.free(script_cmd_line);
            if (self.cmd_exe_path) |cmd_exe_path| self.allocator.free(cmd_exe_path);
        }

        fn commandLine(self: *CommandLineCache) ![:0]u16 {
            if (self.cmd_line == null) {
                self.cmd_line = try argvToCommandLine(self.allocator, self.argv);
            }
            return self.cmd_line.?;
        }

        fn scriptCommandLine(self: *CommandLineCache, script_path: []const u16) ![:0]u16 {
            if (self.script_cmd_line) |v| self.allocator.free(v);
            self.script_cmd_line = try argvToScriptCommandLine(
                self.allocator,
                script_path,
                self.argv[1..],
            );
            return self.script_cmd_line.?;
        }

        fn cmdExePath(self: *CommandLineCache) ![:0]u16 {
            if (self.cmd_exe_path == null) {
                self.cmd_exe_path = try wcdExePath(self.allocator);
            }
            return self.cmd_exe_path.?;
        }
    };

    fn createProcessPathExt(
        allocator: mem.Allocator,
        dir_buf: *std.ArrayListUnmanaged(u16),
        app_buf: *std.ArrayListUnmanaged(u16),
        pathext: [:0]const u16,
        cmd_line_cache: *CommandLineCache,
        envp_ptr: ?[*:0]const u16,
        cwd_ptr: ?[*:0]u16,
        lpStartupInfo: *windows.STARTUPINFOW,
        lpProcessInformation: *windows.PROCESS.INFORMATION,
    ) !void {
        const app_name_len = app_buf.items.len;
        const dir_path_len = dir_buf.items.len;

        if (app_name_len == 0) return error.FileNotFound;

        defer app_buf.shrinkRetainingCapacity(app_name_len);
        defer dir_buf.shrinkRetainingCapacity(dir_path_len);

        const dir_handle: windows.HANDLE = dir_handle: {
            try dir_buf.append(allocator, 0);
            defer dir_buf.shrinkRetainingCapacity(dir_path_len);
            const dir_path_z = dir_buf.items[0 .. dir_buf.items.len - 1 :0];
            const h = CreateFileW(
                dir_path_z.ptr,
                GENERIC_READ,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                null,
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS,
                null,
            );
            if (h == windows.INVALID_HANDLE_VALUE) return error.FileNotFound;
            break :dir_handle h;
        };
        defer windows.CloseHandle(dir_handle);

        try app_buf.append(allocator, '*');
        try app_buf.append(allocator, 0);
        const app_name_wildcard = app_buf.items[0 .. app_buf.items.len - 1 :0];

        var file_information_buf: [2048]u8 align(@alignOf(windows.FILE_DIRECTORY_INFORMATION)) = undefined;
        const file_info_maximum_single_entry_size = @sizeOf(windows.FILE_DIRECTORY_INFORMATION) + (windows.NAME_MAX * 2);
        if (file_information_buf.len < file_info_maximum_single_entry_size) {
            @compileError("file_information_buf must be large enough to contain at least one maximum size FILE_DIRECTORY_INFORMATION entry");
        }
        var io_status: windows.IO_STATUS_BLOCK = undefined;

        const num_supported_pathext = @typeInfo(CreateProcessSupportedExtension).@"enum".fields.len;
        var pathext_seen = [_]bool{false} ** num_supported_pathext;
        var any_pathext_seen = false;
        var unappended_exists = false;

        while (true) {
            const app_name_len_bytes = std.math.cast(u16, app_name_wildcard.len * 2) orelse return error.NameTooLong;
            var app_name_unicode_string = windows.UNICODE_STRING{
                .Length = app_name_len_bytes,
                .MaximumLength = app_name_len_bytes,
                .Buffer = @constCast(app_name_wildcard.ptr),
            };
            const rc = windows.ntdll.NtQueryDirectoryFile(
                dir_handle,
                null,
                null,
                null,
                &io_status,
                &file_information_buf,
                file_information_buf.len,
                .Directory,
                .FALSE, // single result
                &app_name_unicode_string,
                .FALSE, // restart iteration
            );

            switch (rc) {
                .SUCCESS => {},
                .NO_SUCH_FILE => return error.FileNotFound,
                .NO_MORE_FILES => break,
                .ACCESS_DENIED => return error.AccessDenied,
                else => return windows.unexpectedStatus(rc),
            }

            std.debug.assert(io_status.Information != 0);

            var it = windows.FileInformationIterator(windows.FILE_DIRECTORY_INFORMATION){ .buf = &file_information_buf };
            while (it.next()) |info| {
                if (info.FileAttributes.DIRECTORY) continue;
                const filename = @as([*]u16, @ptrCast(&info.FileName))[0 .. info.FileNameLength / 2];
                if (filename.len == app_name_len) {
                    unappended_exists = true;
                } else if (createProcessSupportsExtension(filename[app_name_len..])) |pathext_ext| {
                    pathext_seen[@intFromEnum(pathext_ext)] = true;
                    any_pathext_seen = true;
                }
            }
        }

        const unappended_err = unappended: {
            if (unappended_exists) {
                if (dir_path_len != 0) switch (dir_buf.items[dir_buf.items.len - 1]) {
                    '/', '\\' => {},
                    else => try dir_buf.append(allocator, fs.path.sep),
                };
                try dir_buf.appendSlice(allocator, app_buf.items[0..app_name_len]);
                try dir_buf.append(allocator, 0);
                const full_app_name = dir_buf.items[0 .. dir_buf.items.len - 1 :0];

                const is_bat_or_cmd = bat_or_cmd: {
                    const app_name = app_buf.items[0..app_name_len];
                    const ext_start = std.mem.lastIndexOfScalar(u16, app_name, '.') orelse break :bat_or_cmd false;
                    const ext = app_name[ext_start..];
                    const ext_enum = createProcessSupportsExtension(ext) orelse break :bat_or_cmd false;
                    switch (ext_enum) {
                        .cmd, .bat => break :bat_or_cmd true,
                        else => break :bat_or_cmd false,
                    }
                };
                const cmd_line_w = if (is_bat_or_cmd)
                    try cmd_line_cache.scriptCommandLine(full_app_name)
                else
                    try cmd_line_cache.commandLine();
                const app_name_w = if (is_bat_or_cmd)
                    try cmd_line_cache.cmdExePath()
                else
                    full_app_name;

                if (createProcess(app_name_w.ptr, cmd_line_w.ptr, envp_ptr, cwd_ptr, lpStartupInfo, lpProcessInformation)) |_| {
                    return;
                } else |err| switch (err) {
                    error.FileNotFound,
                    error.AccessDenied,
                    => break :unappended err,
                    error.InvalidExe => {
                        const app_name = app_buf.items[0..app_name_len];
                        const ext_start = std.mem.lastIndexOfScalar(u16, app_name, '.') orelse break :unappended err;
                        const ext = app_name[ext_start..];
                        if (windows.eqlIgnoreCaseWtf16(ext, unicode.utf8ToUtf16LeStringLiteral(".EXE"))) {
                            return error.UnrecoverableInvalidExe;
                        }
                        break :unappended err;
                    },
                    else => return err,
                }
            }
            break :unappended error.FileNotFound;
        };

        if (!any_pathext_seen) return unappended_err;

        var ext_it = mem.tokenizeScalar(u16, pathext, ';');
        while (ext_it.next()) |ext| {
            const ext_enum = createProcessSupportsExtension(ext) orelse continue;
            if (!pathext_seen[@intFromEnum(ext_enum)]) continue;

            dir_buf.shrinkRetainingCapacity(dir_path_len);
            if (dir_path_len != 0) switch (dir_buf.items[dir_buf.items.len - 1]) {
                '/', '\\' => {},
                else => try dir_buf.append(allocator, fs.path.sep),
            };
            try dir_buf.appendSlice(allocator, app_buf.items[0..app_name_len]);
            try dir_buf.appendSlice(allocator, ext);
            try dir_buf.append(allocator, 0);
            const full_app_name = dir_buf.items[0 .. dir_buf.items.len - 1 :0];

            const is_bat_or_cmd = switch (ext_enum) {
                .cmd, .bat => true,
                else => false,
            };
            const cmd_line_w = if (is_bat_or_cmd)
                try cmd_line_cache.scriptCommandLine(full_app_name)
            else
                try cmd_line_cache.commandLine();
            const app_name_w = if (is_bat_or_cmd)
                try cmd_line_cache.cmdExePath()
            else
                full_app_name;

            if (createProcess(app_name_w.ptr, cmd_line_w.ptr, envp_ptr, cwd_ptr, lpStartupInfo, lpProcessInformation)) |_| {
                return;
            } else |err| switch (err) {
                error.FileNotFound => continue,
                error.AccessDenied => continue,
                error.InvalidExe => {
                    if (windows.eqlIgnoreCaseWtf16(ext, unicode.utf8ToUtf16LeStringLiteral(".EXE"))) {
                        return error.UnrecoverableInvalidExe;
                    }
                    continue;
                },
                else => return err,
            }
        }

        return unappended_err;
    }

    fn argvToCommandLine(
        allocator: mem.Allocator,
        argv: []const []const u8,
    ) ![:0]u16 {
        var buf = std.array_list.Managed(u8).init(allocator);
        defer buf.deinit();

        if (argv.len != 0) {
            const arg0 = argv[0];

            var needs_quotes = arg0.len == 0;
            for (arg0) |c| {
                if (c <= ' ') {
                    needs_quotes = true;
                } else if (c == '"') {
                    return error.InvalidArg0;
                }
            }
            if (needs_quotes) {
                try buf.append('"');
                try buf.appendSlice(arg0);
                try buf.append('"');
            } else {
                try buf.appendSlice(arg0);
            }

            for (argv[1..]) |arg| {
                try buf.append(' ');

                needs_quotes = for (arg) |c| {
                    if (c <= ' ' or c == '"') {
                        break true;
                    }
                } else arg.len == 0;
                if (!needs_quotes) {
                    try buf.appendSlice(arg);
                    continue;
                }

                try buf.append('"');
                var backslash_count: usize = 0;
                for (arg) |byte| {
                    switch (byte) {
                        '\\' => {
                            backslash_count += 1;
                        },
                        '"' => {
                            try buf.appendNTimes('\\', backslash_count * 2 + 1);
                            try buf.append('"');
                            backslash_count = 0;
                        },
                        else => {
                            try buf.appendNTimes('\\', backslash_count);
                            try buf.append(byte);
                            backslash_count = 0;
                        },
                    }
                }
                try buf.appendNTimes('\\', backslash_count * 2);
                try buf.append('"');
            }
        }

        return try unicode.wtf8ToWtf16LeAllocZ(allocator, buf.items);
    }

    fn argvToScriptCommandLine(
        allocator: mem.Allocator,
        script_path: []const u16,
        script_args: []const []const u8,
    ) ![:0]u16 {
        var buf = try std.array_list.Managed(u8).initCapacity(allocator, 64);
        defer buf.deinit();

        buf.appendSliceAssumeCapacity("cmd.exe /d /e:ON /v:OFF /c \"");

        buf.appendAssumeCapacity('"');
        if (mem.indexOfAny(u16, script_path, &[_]u16{ mem.nativeToLittle(u16, '\\'), mem.nativeToLittle(u16, '/') }) == null) {
            try buf.appendSlice(".\\");
        }
        try unicode.wtf16LeToWtf8ArrayList(&buf, script_path);
        buf.appendAssumeCapacity('"');

        for (script_args) |arg| {
            if (std.mem.indexOfAny(u8, arg, "\x00\r\n") != null) {
                return error.InvalidBatchScriptArg;
            }

            try buf.append(' ');

            var needs_quotes = arg.len == 0 or arg[arg.len - 1] == '\\';
            if (!needs_quotes) {
                for (arg) |c| {
                    switch (c) {
                        'A'...'Z', 'a'...'z', '0'...'9', '#', '$', '*', '+', '-', '.', '/', ':', '?', '@', '\\', '_' => {},
                        else => {
                            needs_quotes = true;
                            break;
                        },
                    }
                }
            }
            if (needs_quotes) {
                try buf.append('"');
            }
            var backslashes: usize = 0;
            for (arg) |c| {
                switch (c) {
                    '\\' => {
                        backslashes += 1;
                    },
                    '"' => {
                        try buf.appendNTimes('\\', backslashes);
                        try buf.append('"');
                        backslashes = 0;
                    },
                    '%' => {
                        try buf.appendSlice("%%cd:~,");
                        backslashes = 0;
                    },
                    else => {
                        backslashes = 0;
                    },
                }
                try buf.append(c);
            }
            if (needs_quotes) {
                try buf.appendNTimes('\\', backslashes);
                try buf.append('"');
            }
        }

        try buf.append('"');

        return try unicode.wtf8ToWtf16LeAllocZ(allocator, buf.items);
    }

    fn wcdExePath(allocator: mem.Allocator) error{ OutOfMemory, Unexpected }![:0]u16 {
        var buf = try std.ArrayListUnmanaged(u16).initCapacity(allocator, 128);
        errdefer buf.deinit(allocator);
        while (true) {
            const unused_slice = buf.unusedCapacitySlice();
            const len = GetSystemDirectoryW(@ptrCast(unused_slice), @intCast(unused_slice.len));
            if (len == 0) {
                switch (windows.GetLastError()) {
                    else => |err| return windows.unexpectedError(err),
                }
            }
            if (len > unused_slice.len) {
                try buf.ensureUnusedCapacity(allocator, len);
            } else {
                buf.items.len = len;
                break;
            }
        }
        switch (buf.items[buf.items.len - 1]) {
            '/', '\\' => {},
            else => try buf.append(allocator, fs.path.sep),
        }
        try buf.appendSlice(allocator, unicode.utf8ToUtf16LeStringLiteral("cmd.exe"));
        return try buf.toOwnedSliceSentinel(allocator, 0);
    }

    const CreateProcessSupportedExtension = enum {
        bat,
        cmd,
        com,
        exe,
    };

    fn createProcessSupportsExtension(ext: []const u16) ?CreateProcessSupportedExtension {
        if (ext.len != 4) return null;
        const State = enum {
            start,
            dot,
            b,
            ba,
            c,
            cm,
            co,
            e,
            ex,
        };
        var state: State = .start;
        for (ext) |c| switch (state) {
            .start => switch (c) {
                '.' => state = .dot,
                else => return null,
            },
            .dot => switch (c) {
                'b', 'B' => state = .b,
                'c', 'C' => state = .c,
                'e', 'E' => state = .e,
                else => return null,
            },
            .b => switch (c) {
                'a', 'A' => state = .ba,
                else => return null,
            },
            .c => switch (c) {
                'm', 'M' => state = .cm,
                'o', 'O' => state = .co,
                else => return null,
            },
            .e => switch (c) {
                'x', 'X' => state = .ex,
                else => return null,
            },
            .ba => switch (c) {
                't', 'T' => return .bat,
                else => return null,
            },
            .cm => switch (c) {
                'd', 'D' => return .cmd,
                else => return null,
            },
            .co => switch (c) {
                'm', 'M' => return .com,
                else => return null,
            },
            .ex => switch (c) {
                'e', 'E' => return .exe,
                else => return null,
            },
        };
        return null;
    }

    pub const CREATE_NO_WINDOW = 0x08000000;

    fn createProcess(
        app_name: [*:0]u16,
        cmd_line: [*:0]u16,
        envp_ptr: ?[*:0]const u16,
        cwd_ptr: ?[*:0]u16,
        lpStartupInfo: *windows.STARTUPINFOW,
        lpProcessInformation: *windows.PROCESS.INFORMATION,
    ) !void {
        if (windows.kernel32.CreateProcessW(
            app_name,
            cmd_line,
            null,
            null,
            .TRUE,
            .{
                .create_unicode_environment = true,
                .create_no_window = true,
            },
            envp_ptr,
            cwd_ptr,
            lpStartupInfo,
            lpProcessInformation,
        ) == .FALSE) {
            switch (windows.GetLastError()) {
                .FILE_NOT_FOUND, .PATH_NOT_FOUND, .DIRECTORY => return error.FileNotFound,
                .ACCESS_DENIED => return error.AccessDenied,
                .BAD_FORMAT,
                .INVALID_STARTING_CODESEG,
                .INVALID_STACKSEG,
                .INVALID_MODULETYPE,
                .INVALID_EXE_SIGNATURE,
                .EXE_MARKED_INVALID,
                .BAD_EXE_FORMAT,
                .ITERATED_DATA_EXCEEDS_64k,
                .INVALID_MINALLOCSIZE,
                .DYNLINK_FROM_INVALID_RING,
                .IOPL_NOT_ENABLED,
                .INVALID_SEGDPL,
                .AUTODATASEG_EXCEEDS_64k,
                .RING2SEG_MUST_BE_MOVABLE,
                .RELOC_CHAIN_XEEDS_SEGLIM,
                .INFLOOP_IN_RELOC_CHAIN,
                .EXE_MACHINE_TYPE_MISMATCH,
                => return error.InvalidExe,
                else => |err| return windows.unexpectedError(err),
            }
        }
    }

    pub fn wait(self: *@This()) !Term {
        if (self.term) |term_| {
            self.cleanupStreams();
            return term_;
        }

        defer self.id = undefined;
        try self.waitUnwrapped();
        return self.term.?;
    }

    fn waitUnwrapped(self: *@This()) !void {
        const wait_result = WaitForSingleObjectEx(self.id, INFINITE, .FALSE);
        if (wait_result == 0xFFFFFFFF) { // WAIT_FAILED
            switch (windows.GetLastError()) {
                else => |err| return windows.unexpectedError(err),
            }
        }

        self.term = @as(SpawnError!Term, x: {
            var exit_code: windows.DWORD = undefined;
            if (GetExitCodeProcess(self.id, &exit_code) == .FALSE) {
                break :x Term{ .Unknown = 0 };
            } else {
                break :x Term{ .Exited = @as(u8, @truncate(exit_code)) };
            }
        });

        windows.CloseHandle(self.id);
        windows.CloseHandle(self.thread_handle);
        self.cleanupStreams();
    }

    fn cleanupStreams(self: *@This()) void {
        if (self.stdin) |*stdin| {
            stdin.close();
            self.stdin = null;
        }
        if (self.stdout) |*stdout| {
            stdout.close();
            self.stdout = null;
        }
        if (self.stderr) |*stderr| {
            stderr.close();
            self.stderr = null;
        }
    }

    pub fn kill(self: *@This()) !Term {
        if (self.term) |term_| {
            self.cleanupStreams();
            return term_;
        }

        if (TerminateProcess(self.id, 1) == .FALSE) {
            switch (windows.GetLastError()) {
                .ACCESS_DENIED => {
                    const r = WaitForSingleObjectEx(self.id, 0, .FALSE);
                    if (r == 0) return error.AlreadyTerminated; // WAIT_OBJECT_0
                    return error.Unexpected;
                },
                else => |err| return windows.unexpectedError(err),
            }
        }
        try self.waitUnwrapped();
        return self.term.?;
    }
};
