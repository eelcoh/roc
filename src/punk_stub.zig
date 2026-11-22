//! punkroc: the stand-in for punk's seam (`src/punk/roc/` of eelcoh/punk)
//! when this compiler is built on its own. It knows no `.punk` files, so the
//! build is plain Roc. eelcoh/punk builds this compiler with `-Dpunk=<its src/>`,
//! which puts the real seam in its place (see build.zig).

const std = @import("std");

/// The build reads `.punk` files (the real seam puts a layer over its filesystem).
pub fn install(_: anytype) void {}

/// Translates a `.punk` file; here nothing is one.
pub fn translateRaw(_: std.mem.Allocator, _: std.Io, _: []const u8, _: []const u8) error{ OutOfMemory, ParseError }!?[]u8 {
    return null;
}

pub const cli = struct {
    pub const Failed = error{Failed} || std.mem.Allocator.Error || std.Io.Writer.Error;

    pub fn allPunk(_: []const []const u8) bool {
        return false;
    }

    pub fn format(_: std.mem.Allocator, _: std.Io, _: *std.Io.Writer, stderr: *std.Io.Writer, _: []const []const u8, _: bool) Failed!void {
        try stderr.print("This compiler was built without punk.\n", .{});
        return error.Failed;
    }

    pub fn checkSchema(_: std.mem.Allocator, _: std.Io, _: *std.Io.Writer, stderr: *std.Io.Writer, _: []const u8) Failed!void {
        try stderr.print("This compiler was built without punk.\n", .{});
        return error.Failed;
    }
};

pub const json = struct {
    pub fn write(_: anytype, stdout: *std.Io.Writer, _: anytype, _: anytype, _: anytype, _: anytype, _: anytype) !void {
        try stdout.print("{{\"error\": \"this compiler was built without punk\"}}\n", .{});
    }
};
