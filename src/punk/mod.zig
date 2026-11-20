//! punkroc: an Elm-like syntax for Roc. `.punk` files are translated to Roc
//! source when the compiler reads them, so everything after the parser sees
//! ordinary Roc.

const std = @import("std");
const translate_mod = @import("translate.zig");

pub const Diagnostic = translate_mod.Diagnostic;
pub const Error = translate_mod.Error;
pub const translate = translate_mod.translate;

/// The file extension of punkroc source files.
pub const extension = ".punk";

/// Whether `path` names a punkroc source file.
pub fn isPunkPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, extension);
}

/// Translate the punkroc source of `path` to Roc source owned by `allocator`.
/// A syntax error is printed to stderr as `path:line:col: message`, and
/// `error.ParseError` returned.
pub fn toRoc(allocator: std.mem.Allocator, path: []const u8, src: []const u8) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const roc = translate(arena.allocator(), src, &diag) catch |err| switch (err) {
        error.ParseError => {
            std.debug.print("{s}:{d}:{d}: {s}\n", .{ path, diag.line, diag.col, diag.message });
            return error.ParseError;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return allocator.dupe(u8, roc);
}

test {
    _ = @import("test.zig");
}
