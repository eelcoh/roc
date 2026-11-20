//! `punk2roc`: translate a `.punk` file to Roc source.
//!
//!     punk2roc input.punk            # prints the Roc code
//!     punk2roc input.punk -o out.roc # writes it to a file

const std = @import("std");
const punk = @import("translate.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
            i += 1;
            output = args[i];
        } else if (input == null) {
            input = args[i];
        } else {
            return usage(io);
        }
    }
    const path = input orelse return usage(io);

    const src = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch |err| {
        try printErr(io, "punk2roc: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };

    var diag: punk.Diagnostic = .{};
    const roc = punk.translate(arena, src, &diag) catch |err| switch (err) {
        error.ParseError => {
            try printErr(io, "{s}:{d}:{d}: {s}\n", .{ path, diag.line, diag.col, diag.message });
            std.process.exit(1);
        },
        error.OutOfMemory => return err,
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

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    try stderr.interface.print(fmt, args);
    try stderr.interface.flush();
}

fn usage(io: std.Io) !void {
    try printErr(io, "usage: punk2roc <input.punk> [-o <output.roc>]\n", .{});
    std.process.exit(2);
}
