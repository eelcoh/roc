//! punkroc: an Elm-like syntax for Roc. `.punk` files are translated to Roc
//! source when the compiler reads them, so everything after the parser sees
//! ordinary Roc.

const std = @import("std");
const builtin = @import("builtin");
const translate_mod = @import("translate.zig");
const interface = @import("interface.zig");

pub const Interface = interface.Interface;

pub const Diagnostic = translate_mod.Diagnostic;
pub const Error = translate_mod.Error;
pub const translate = translate_mod.translate;

/// The file extension of punkroc source files.
pub const extension = ".punk";

/// Whether `path` names a punkroc source file.
pub fn isPunkPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, extension);
}

/// Reads source files for the translator, so it can look at the modules a
/// file imports. Returns null when the file cannot be read.
pub const Reader = struct {
    ctx: ?*anyopaque,
    read: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8) ?[]u8,
};

/// Translate the punkroc source of `path` to Roc source owned by `allocator`.
/// A syntax error is printed to stderr as `path:line:col: message`, and
/// `error.ParseError` returned.
pub fn toRoc(allocator: std.mem.Allocator, path: []const u8, src: []const u8) Error![]u8 {
    return toRocWith(allocator, path, src, null);
}

/// Like `toRoc`, but reads the modules `path` imports with `reader`, so
/// their functions can be partially applied and called in the right order
/// (see `translate.Resolver`).
pub fn toRocWith(allocator: std.mem.Allocator, path: []const u8, src: []const u8, reader: ?Reader) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    var load_ctx: LoadCtx = undefined;
    var resolver: ?translate_mod.Resolver = null;
    if (reader) |r| {
        load_ctx = .{ .reader = r, .dir = std.fs.path.dirname(path) orelse "." };
        resolver = .{ .ctx = &load_ctx, .load = load };
    }
    const roc = translate_mod.translateWith(arena.allocator(), src, &diag, resolver) catch |err| switch (err) {
        error.ParseError => {
            // Freestanding targets (the wasm REPL and playground) have no stderr.
            if (comptime builtin.os.tag != .freestanding) {
                std.debug.print("{s}:{d}:{d}: {s}\n", .{ path, diag.line, diag.col, diag.message });
            }
            return error.ParseError;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return allocator.dupe(u8, roc);
}

const LoadCtx = struct { reader: Reader, dir: []const u8 };

fn load(ctx_ptr: ?*anyopaque, arena: std.mem.Allocator, imp: translate_mod.Import) Error!?*const Interface {
    const ctx: *LoadCtx = @ptrCast(@alignCast(ctx_ptr.?));
    return loadFrom(ctx.reader, ctx.dir, arena, imp);
}

/// Finds an imported module next to the importing file, or in the directory
/// of a package whose path the app header gives (`pf: platform "../pf/main.roc"`).
/// `Foo.roc` wins over `Foo.punk`, as in the compiler. Packages given by URL
/// are not looked up.
pub fn loadFrom(reader: Reader, dir: []const u8, arena: std.mem.Allocator, imp: translate_mod.Import) Error!?*const Interface {
    const base = if (imp.package != null) blk: {
        const pkg = imp.package_path orelse return null;
        if (std.mem.find(u8, pkg, "://") != null) return null;
        const main = if (std.fs.path.isAbsolute(pkg)) pkg else try std.fs.path.join(arena, &.{ dir, pkg });
        break :blk std.fs.path.dirname(main) orelse ".";
    } else dir;

    const rel = try arena.dupe(u8, imp.module);
    std.mem.replaceScalar(u8, rel, '.', '/');
    for ([_][]const u8{ ".roc", extension }) |ext| {
        const file = try std.fs.path.join(arena, &.{ base, try std.mem.concat(arena, u8, &.{ rel, ext }) });
        const src = reader.read(reader.ctx, arena, file) orelse continue;
        const iface = try arena.create(Interface);
        if (std.mem.eql(u8, ext, ".roc")) {
            iface.* = try interface.scanRoc(arena, src);
        } else {
            var diag: Diagnostic = .{};
            // A syntax error is reported when the module itself is translated.
            iface.* = translate_mod.punkInterface(arena, src, &diag) catch |err| switch (err) {
                error.ParseError => return null,
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        return iface;
    }
    return null;
}

test {
    _ = @import("test.zig");
}
