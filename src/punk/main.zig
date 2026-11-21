//! `punk2roc`: translate a `.punk` file to Roc source.
//!
//!     punk2roc input.punk            # prints the Roc code
//!     punk2roc input.punk -o out.roc # writes it to a file
//!     punk2roc --fmt input.punk      # prints the file as `punk fmt` lays it out

const std = @import("std");
const punk = @import("translate.zig");
const format = @import("format.zig");

/// Entry point of the `punk2roc` command.
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("punk2roc: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

const RunError = std.mem.Allocator.Error || std.Io.Writer.Error || std.Io.Dir.WriteFileError;

fn run(init: std.process.Init) RunError!void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var fmt = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--fmt")) {
            fmt = true;
        } else if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
            i += 1;
            output = args[i];
        } else if (input == null) {
            input = args[i];
        } else {
            usage();
        }
    }
    const path = input orelse usage();

    const src = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch |err| {
        std.debug.print("punk2roc: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };

    var diag: punk.Diagnostic = .{};
    const roc = (if (fmt) format.format(arena, src, &diag) else punk.translate(arena, src, &diag)) catch |err| switch (err) {
        error.ParseError, error.Unsafe => {
            std.debug.print("{s}:{d}:{d}: {s}\n", .{ path, diag.line, diag.col, diag.message });
            std.process.exit(1);
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (output) |out_path| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = roc });
    } else {
        var buf: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(io, &buf);
        try stdout.interface.writeAll(roc);
        try stdout.interface.flush();
    }
}

fn usage() noreturn {
    std.debug.print("usage: punk2roc [--fmt] <input.punk> [-o <output>]\n", .{});
    std.process.exit(2);
}
