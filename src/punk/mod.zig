//! punkroc: an Elm-like syntax for Roc. `.punk` files are translated to Roc
//! source when the compiler reads them, so everything after the parser sees
//! ordinary Roc.

const std = @import("std");
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
    /// The directory a package given by URL is in on disk, downloading it
    /// first when it is not there yet. Null (the function, or its answer)
    /// leaves the package's modules unread.
    packageDir: ?*const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, url: []const u8) ?[]const u8 = null,
};

/// Finds the directory of URL packages for `Reader.packageDir`.
pub const PackageFinder = struct {
    ctx: ?*anyopaque,
    dir: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, url: []const u8) ?[]const u8,
};

/// Translate the punkroc source of `path` to Roc source owned by `allocator`.
/// On a syntax error `error.ParseError` is returned, and `syntaxError(path)`
/// tells what it was.
pub fn toRoc(allocator: std.mem.Allocator, path: []const u8, src: []const u8) Error![]u8 {
    return toRocWith(allocator, path, src, null);
}

/// The syntax errors of the `.punk` files translated last, by path, as
/// `path:line:col: message`, so the compiler can report them like its own.
/// The compiler reads files from several threads.
const syntax_errors = struct {
    var mutex: std.atomic.Mutex = .unlocked;
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    const gpa = std.heap.page_allocator;

    fn lock() void {
        while (!mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn set(path: []const u8, message: ?[]const u8) void {
        lock();
        defer mutex.unlock();
        if (map.fetchRemove(path)) |old| {
            gpa.free(old.key);
            gpa.free(old.value);
        }
        const msg = message orelse return;
        const key = gpa.dupe(u8, path) catch return;
        const value = gpa.dupe(u8, msg) catch {
            gpa.free(key);
            return;
        };
        map.put(gpa, key, value) catch {
            gpa.free(key);
            gpa.free(value);
        };
    }
};

/// The syntax error that stopped the last translation of `path`, as
/// `path:line:col: message`, owned by `allocator`. Null when there was none.
pub fn syntaxError(allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!?[]u8 {
    syntax_errors.lock();
    defer syntax_errors.mutex.unlock();
    const msg = syntax_errors.map.get(path) orelse return null;
    return try allocator.dupe(u8, msg);
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
            const msg = try std.fmt.allocPrint(arena.allocator(), "{s}:{d}:{d}: {s}", .{ path, diag.line, diag.col, diag.message });
            syntax_errors.set(path, msg);
            return error.ParseError;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    syntax_errors.set(path, null);
    return allocator.dupe(u8, roc);
}

const LoadCtx = struct { reader: Reader, dir: []const u8 };

fn load(ctx_ptr: ?*anyopaque, arena: std.mem.Allocator, imp: translate_mod.Import) Error!?*const Interface {
    const ctx: *LoadCtx = @ptrCast(@alignCast(ctx_ptr.?));
    return loadFrom(ctx.reader, ctx.dir, arena, imp);
}

/// Finds an imported module next to the importing file, or in the directory
/// of a package whose path the app header gives (`pf: platform "../pf/main.roc"`).
/// `Foo.roc` wins over `Foo.punk`, as in the compiler. A package given by URL
/// is looked up where `reader.packageDir` says it is.
pub fn loadFrom(reader: Reader, dir: []const u8, arena: std.mem.Allocator, imp: translate_mod.Import) Error!?*const Interface {
    const base = if (imp.package != null) blk: {
        const pkg = imp.package_path orelse return null;
        if (std.mem.find(u8, pkg, "://") != null) {
            const find = reader.packageDir orelse return null;
            break :blk find(reader.ctx, arena, pkg) orelse return null;
        }
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
