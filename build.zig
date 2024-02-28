const std = @import("std");

const CrossTarget = std.zig.CrossTarget;

const cppflags = [_][]const u8{
    "-fcolor-diagnostics",
    "-std=c++20",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-Wpedantic",
    "-Wno-deprecated-declarations",
    "-Wno-unqualified-std-cast-call",
    "-Wno-bitwise-instead-of-logical", //for notcurses
    "-fno-sanitize=undefined",
    "-gen-cdb-fragment-path",
    ".cache/cdb",
};

pub fn build(b: *std.Build) void {
    const enable_tracy_option = b.option(bool, "enable_tracy", "Enable tracy client library (default: no)");
    const tracy_enabled = if (enable_tracy_option) |enabled| enabled else false;

    const options = b.addOptions();
    options.addOption(bool, "enable_tracy", tracy_enabled);

    const options_mod = options.createModule();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mode = .{ .target = target, .optimize = optimize };

    const asio_dep = b.dependency("asio", mode);
    const tracy_dep = if (tracy_enabled) b.dependency("tracy", mode) else undefined;

    const lib = b.addStaticLibrary(.{
        .name = "thespian",
        .target = target,
        .optimize = optimize,
    });
    if (tracy_enabled) {
        lib.defineCMacro("TRACY_ENABLE", null);
        lib.defineCMacro("TRACY_CALLSTACK", null);
    }
    lib.addIncludePath(.{ .path = "src" });
    lib.addIncludePath(.{ .path = "include" });
    lib.addCSourceFiles(.{ .files = &[_][]const u8{
        "src/backtrace.cpp",
        "src/c/context.cpp",
        "src/c/env.cpp",
        "src/c/file_descriptor.cpp",
        "src/c/handle.cpp",
        "src/c/instance.cpp",
        "src/c/metronome.cpp",
        "src/c/signal.cpp",
        "src/c/timeout.cpp",
        "src/c/trace.cpp",
        "src/cbor.cpp",
        "src/executor_asio.cpp",
        "src/hub.cpp",
        "src/instance.cpp",
        "src/trace.cpp",
    }, .flags = &cppflags });
    if (tracy_enabled) {
        lib.linkLibrary(tracy_dep.artifact("tracy"));
    }
    lib.linkLibrary(asio_dep.artifact("asio"));
    lib.linkLibCpp();
    b.installArtifact(lib);

    const cbor_mod = b.addModule("cbor", .{
        .root_source_file = .{ .path = "src/cbor.zig" },
    });

    const thespian_mod = b.addModule("thespian", .{
        .root_source_file = .{ .path = "src/thespian.zig" },
        .imports = &.{
            .{ .name = "cbor", .module = cbor_mod },
        },
    });
    thespian_mod.addIncludePath(.{ .path = "include" });
    thespian_mod.linkLibrary(lib);

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "test/tests.zig" },
        .target = target,
        .optimize = optimize,
    });

    tests.root_module.addImport("build_options", options_mod);
    tests.root_module.addImport("cbor", cbor_mod);
    tests.root_module.addImport("thespian", thespian_mod);
    tests.addIncludePath(.{ .path = "test" });
    tests.addIncludePath(.{ .path = "src" });
    tests.addIncludePath(.{ .path = "include" });
    tests.addCSourceFiles(.{ .files = &[_][]const u8{
        "test/cbor_match.cpp",
        "test/debug.cpp",
        "test/endpoint_unx.cpp",
        "test/endpoint_tcp.cpp",
        "test/hub_filter.cpp",
        "test/ip_tcp_client_server.cpp",
        "test/ip_udp_echo.cpp",
        "test/metronome_test.cpp",
        "test/perf_cbor.cpp",
        "test/perf_hub.cpp",
        "test/perf_ring.cpp",
        "test/perf_spawn.cpp",
        "test/spawn_exit.cpp",
        "test/tests.cpp",
        "test/timeout_test.cpp",
    }, .flags = &cppflags });
    tests.linkLibrary(lib);
    tests.linkLibrary(asio_dep.artifact("asio"));
    tests.linkLibCpp();
    b.installArtifact(tests);

    const test_run_cmd = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run_cmd.step);
}
