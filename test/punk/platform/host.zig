///! punkroc's small platform: standard input and output, files and the
///! command line arguments, for programs such as Advent of Code solutions.
const std = @import("std");
const Allocator = std.mem.Allocator;
const shim_io = @import("shim_io");
const builtins = @import("builtins");
const build_options = @import("build_options");
const host_alloc = @import("host_alloc");
const host_crash_handlers = @import("host_crash_handlers");

pub const std_options_elf_debug_info_search_paths = shim_io.elfDebugInfoSearchPaths;
pub const std_options_debug_io = shim_io.io();
pub const std_options_debug_threaded_io = null;
// See `shim_io.std_options_static_archive` for why these settings matter to a
// static archive that roc links into a program.
pub const std_options = shim_io.std_options_static_archive;

/// Host environment - contains DebugAllocator for leak detection
const HostEnv = struct {
    gpa: std.heap.DebugAllocator(.{ .thread_safe = false, .stack_trace_frames = build_options.debug_gpa_stack_trace_frames }),
    std_io: std.Io,

    pub fn rocAllocator(self: *HostEnv) Allocator {
        return self.gpa.allocator();
    }
};

const callbacks = host_alloc.Callbacks(HostEnv);

/// Roc expect failed function
fn rocExpectFailedFn(ops: *builtins.host_abi.RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
    _ = ops;
    const source_bytes = bytes[0..len];
    const trimmed = std.mem.trim(u8, source_bytes, " \t\n\r");
    std.debug.print("Expect failed: {s}\n", .{trimmed});
}

/// Roc crashed function
fn rocCrashedFn(ops: *builtins.host_abi.RocOps, bytes: [*]const u8, len: usize) callconv(.c) void {
    _ = ops;
    const message = bytes[0..len];
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "\n\x1b[31mRoc crashed:\x1b[0m {s}\n", .{message}) catch "\n\x1b[31mRoc crashed\x1b[0m\n";
    std.debug.print("{s}", .{msg});
    std.process.exit(1);
}

// The app's entrypoint, exported under its provides symbol with its natural
// C ABI: main_for_host! takes and returns nothing.
extern fn roc_main() callconv(.c) void;

// The command line, for Arg.list!.
var g_argc: usize = 0;
var g_argv: [*][*:0]u8 = undefined;

// OS-specific entry point handling
comptime {
    // Export main for all platforms
    @export(&main, .{ .name = "main" });

    // Windows MinGW/MSVCRT compatibility: export __main stub
    if (@import("builtin").os.tag == .windows) {
        @export(&__main, .{ .name = "__main" });
    }
}

// Windows MinGW/MSVCRT compatibility stub
// The C runtime on Windows calls __main from main for constructor initialization
fn __main() callconv(.c) void {}

// C compatible main for runtime
fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    host_crash_handlers.installForCurrentThread();
    const exit_code = platform_main(argc, argv) catch |err| {
        std.debug.print("{s}", .{"HOST ERROR: "});
        std.debug.print("{s}", .{@errorName(err)});
        std.debug.print("{s}", .{"\n"});
        return 1;
    };
    return exit_code;
}

// Use the actual RocStr and RocList from builtins
const RocStr = builtins.str.RocStr;
const RocList = builtins.list.RocList;
const RocOps = builtins.host_abi.RocOps;

// The host's private RocOps. Hosted functions have natural C ABIs with no ops
// parameter, so they reach the host's allocator and std.Io through this
// global, set by platform_main before any Roc code runs.
var g_roc_ops: ?*RocOps = null;

/// Hosted function: Stderr.line!
/// Returns {} and takes Str as argument; ownership of the Str transfers here.
fn hostedStderrLine(str: RocStr) callconv(.c) void {
    const ops = g_roc_ops.?;
    var owned = str;
    defer owned.decref(ops);
    const message = owned.asSlice();
    std.debug.print("{s}", .{message});
    std.debug.print("{s}", .{"\n"});
}

/// Hosted function: Stdout.line!
/// Returns {} and takes Str as argument; ownership of the Str transfers here.
fn hostedStdoutLine(str: RocStr) callconv(.c) void {
    const ops = g_roc_ops.?;
    var owned = str;
    defer owned.decref(ops);
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    const message = owned.asSlice();
    std.Io.File.stdout().writeStreamingAll(host.std_io, message) catch {};
    std.Io.File.stdout().writeStreamingAll(host.std_io, "\n") catch {};
}

/// Hosted function: Stdout.write!
fn hostedStdoutWrite(str: RocStr) callconv(.c) void {
    const ops = g_roc_ops.?;
    var owned = str;
    defer owned.decref(ops);
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    std.Io.File.stdout().writeStreamingAll(host.std_io, owned.asSlice()) catch {};
}

// What has been read from stdin but not given out yet, for Stdin.line!.
var g_stdin_buf: std.ArrayList(u8) = .empty;
var g_stdin_eof = false;

/// Reads more of stdin into `g_stdin_buf`. False at the end of the input.
fn readMoreStdin(host: *HostEnv) bool {
    if (g_stdin_eof) return false;
    var chunk: [64 * 1024]u8 = undefined;
    const n = std.Io.File.stdin().readStreaming(host.std_io, &.{&chunk}) catch 0;
    if (n == 0) {
        g_stdin_eof = true;
        return false;
    }
    g_stdin_buf.appendSlice(host.rocAllocator(), chunk[0..n]) catch return false;
    return true;
}

/// Hosted function: Stdin.line!
/// The next line without its line break; empty at the end of the input.
fn hostedStdinLine() callconv(.c) RocStr {
    const ops = g_roc_ops.?;
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    while (std.mem.findScalar(u8, g_stdin_buf.items, '\n') == null) {
        if (!readMoreStdin(host)) break;
    }
    const buf = g_stdin_buf.items;
    const end = std.mem.findScalar(u8, buf, '\n');
    var line = buf[0 .. end orelse buf.len];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    const result = RocStr.fromSlice(line, ops);
    const used = if (end) |e| e + 1 else buf.len;
    g_stdin_buf.replaceRangeAssumeCapacity(0, used, &.{});
    return result;
}

/// Hosted function: Stdin.read_all!
/// Everything up to the end of the input.
fn hostedStdinReadAll() callconv(.c) RocStr {
    const ops = g_roc_ops.?;
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    while (readMoreStdin(host)) {}
    const result = RocStr.fromSlice(g_stdin_buf.items, ops);
    g_stdin_buf.clearRetainingCapacity();
    return result;
}

// Matches the Roc types `Try(Str, [FileErr(Str)])` and
// `Try({}, [FileErr(Str)])`: the tags are in alphabetical order.
const ResultTag = enum(u8) {
    err = 0,
    ok = 1,
};

const StrResult = extern struct {
    payload: extern union {
        err: RocStr,
        ok: RocStr,
    },
    tag: ResultTag,
};

const UnitResult = extern struct {
    payload: extern union {
        err: RocStr,
        ok: void,
    },
    tag: ResultTag,
};

fn fileErr(ops: *RocOps, what: []const u8, path: []const u8, err: anyerror) RocStr {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "could not {s} {s}: {s}", .{ what, path, @errorName(err) }) catch "could not use the file";
    return RocStr.fromSlice(msg, ops);
}

/// Hosted function: File.read!
fn hostedFileRead(path_str: RocStr) callconv(.c) StrResult {
    const ops = g_roc_ops.?;
    var owned = path_str;
    defer owned.decref(ops);
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    const path = owned.asSlice();
    const gpa = host.rocAllocator();
    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(gpa);
    readWholeFile(host, path, &contents) catch |err| {
        return .{ .payload = .{ .err = fileErr(ops, "read", path, err) }, .tag = .err };
    };
    return .{ .payload = .{ .ok = RocStr.fromSlice(contents.items, ops) }, .tag = .ok };
}

fn readWholeFile(host: *HostEnv, path: []const u8, out: *std.ArrayList(u8)) !void {
    const io = host.std_io;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        if (n == 0) return;
        try out.appendSlice(host.rocAllocator(), chunk[0..n]);
    }
}

/// Hosted function: File.write!
/// The text comes first in Roc, so that punkroc, which passes the value a
/// function works on last, writes `File.write! path text`.
fn hostedFileWrite(text_str: RocStr, path_str: RocStr) callconv(.c) UnitResult {
    const ops = g_roc_ops.?;
    var path_owned = path_str;
    defer path_owned.decref(ops);
    var text_owned = text_str;
    defer text_owned.decref(ops);
    const host: *HostEnv = @ptrCast(@alignCast(ops.env));
    const io = host.std_io;
    const path = path_owned.asSlice();
    const file = createFile(path) catch |err| {
        return .{ .payload = .{ .err = fileErr(ops, "write", path, err) }, .tag = .err };
    };
    defer file.close(io);
    file.writeStreamingAll(io, text_owned.asSlice()) catch |err| {
        return .{ .payload = .{ .err = fileErr(ops, "write", path, err) }, .tag = .err };
    };
    return .{ .payload = .{ .ok = {} }, .tag = .ok };
}

/// Opens `path` for writing, emptied. The host's std.Io cannot create files,
/// so this goes to the OS.
fn createFile(path: []const u8) !std.Io.File {
    if (@import("builtin").os.tag == .windows) return error.Unsupported;
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Hosted function: Arg.list!
/// The arguments after the program's name.
fn hostedArgList() callconv(.c) RocList {
    const ops = g_roc_ops.?;
    if (g_argc <= 1) return RocList.empty();
    return buildArgsList(ops, @intCast(g_argc - 1), g_argv + 1);
}

// --- Symbol-ABI runtime exports
// The fixed runtime symbols every symbol-ABI host defines, plus this
// platform's hosted function symbols. All hidden: they are link-time plumbing
// between the app and the host, not part of the host binary's public API.

fn getOps() *RocOps {
    return g_roc_ops.?;
}

comptime {
    @export(&hostedArgList, .{ .name = "roc_arg_list", .visibility = .hidden });
    @export(&hostedFileRead, .{ .name = "roc_file_read", .visibility = .hidden });
    @export(&hostedFileWrite, .{ .name = "roc_file_write", .visibility = .hidden });
    @export(&hostedStderrLine, .{ .name = "roc_stderr_line", .visibility = .hidden });
    @export(&hostedStdinLine, .{ .name = "roc_stdin_line", .visibility = .hidden });
    @export(&hostedStdinReadAll, .{ .name = "roc_stdin_read_all", .visibility = .hidden });
    @export(&hostedStdoutLine, .{ .name = "roc_stdout_line", .visibility = .hidden });
    @export(&hostedStdoutWrite, .{ .name = "roc_stdout_write", .visibility = .hidden });

    host_alloc.exportRuntimeSymbols(getOps, .{});
}

/// Build a RocList of RocStr from argc/argv
fn buildArgsList(ops: *builtins.host_abi.RocOps, argc: c_int, argv: [*][*:0]u8) RocList {
    const count: usize = @intCast(argc);
    if (count == 0) {
        return RocList.empty();
    }

    // Allocate the list (RocStr is refcounted)
    const list = RocList.list_allocate(@alignOf(RocStr), count, @sizeOf(RocStr), true, ops);

    // Get pointer to list data
    const list_ptr: [*]RocStr = @ptrCast(@alignCast(list.bytes));

    // Fill in each string
    for (0..count) |i| {
        const arg = argv[i];
        const len = std.mem.len(arg);
        list_ptr[i] = RocStr.fromSlice(arg[0..len], ops);
    }

    return list;
}

/// Platform host entrypoint
fn platform_main(argc: c_int, argv: [*][*:0]u8) Allocator.Error!c_int {
    var host_env = HostEnv{
        .gpa = std.heap.DebugAllocator(.{ .thread_safe = false, .stack_trace_frames = build_options.debug_gpa_stack_trace_frames }){},
        .std_io = shim_io.io(),
    };
    defer {
        const leaked = host_env.gpa.deinit();
        if (leaked == .leak) {
            std.log.err("\x1b[33mMemory leak detected!\x1b[0m", .{});
            std.debug.print("{s}", .{build_options.debug_gpa_leak_hint});
        }
    }

    // The host's private RocOps for using builtins helpers (RocStr/RocList
    // allocation, decref). Not part of the ABI.
    var roc_ops = builtins.host_abi.RocOps{
        .env = @as(*anyopaque, @ptrCast(&host_env)),
        .roc_alloc = callbacks.rocAllocFn,
        .roc_dealloc = callbacks.rocDeallocFn,
        .roc_realloc = callbacks.rocReallocFn,
        .roc_dbg = callbacks.rocDbgFn,
        .roc_expect_failed = rocExpectFailedFn,
        .roc_crashed = rocCrashedFn,
        .hosted_fns = .{ .count = 0, .fns = undefined },
    };
    g_roc_ops = &roc_ops;

    g_argc = @intCast(argc);
    g_argv = argv;
    defer g_stdin_buf.deinit(host_env.rocAllocator());

    // Call the app's main_for_host! entrypoint with its natural C ABI.
    roc_main();
    return 0;
}
