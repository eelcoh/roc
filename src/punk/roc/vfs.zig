//! The compiler sees punkroc's files through this: a layer over the build's
//! filesystem (`CoreCtx`) that translates `.punk` files to Roc as they are
//! read. Nothing in Roc's own code knows about `.punk` files.
//!
//! - Reading `app.punk` gives its Roc translation.
//! - `import Foo` makes Roc look for `Foo.roc`. When there is no `Foo.roc`
//!   but there is a `Foo.punk`, this layer answers for `Foo.roc` as if it
//!   were there, with the translation of `Foo.punk`. Such a "virtual" path is
//!   remembered, so a report about it can point at `Foo.punk` (see
//!   `report.zig`).
//!
//! The layer keeps its state in globals: the CLI makes one build at a time,
//! and the translator's source maps are global too.

const std = @import("std");
const punk = @import("punk");
const ctx_mod = @import("ctx");
const compile = @import("compile");
const base = @import("base");

const CoreCtx = ctx_mod.CoreCtx;
const BuildEnv = compile.BuildEnv;
const package_resolution = compile.package_resolution;
const Allocator = std.mem.Allocator;

/// The filesystem under this layer, as it was before `install`.
var inner: CoreCtx.VTable = undefined;
var gpa: Allocator = undefined;
var arena: Allocator = undefined;
/// URL packages are not fetched for the translator when a dependency is replaced.
var replaced_deps = false;
var package_limit: ?u64 = null;

/// The `.roc` paths answered with a `.punk` file, mapped to that file.
const virtual = struct {
    var mutex: std.atomic.Mutex = .unlocked;
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    const alloc = std.heap.page_allocator;

    fn lock() void {
        while (!mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn remember(roc_path: []const u8, punk_path: []const u8) void {
        lock();
        defer mutex.unlock();
        if (map.contains(roc_path)) return;
        const k = alloc.dupe(u8, roc_path) catch return;
        const v = alloc.dupe(u8, punk_path) catch return;
        map.put(alloc, k, v) catch return;
    }

    fn get(roc_path: []const u8) ?[]const u8 {
        lock();
        defer mutex.unlock();
        return map.get(roc_path);
    }
};

/// Puts this layer over the filesystem of `env`. Call before the build
/// starts (the coordinator copies the filesystem when it is made).
pub fn install(env: *BuildEnv) void {
    const fs = &env.filesystem;
    // The layer passes the context through unchanged, so it only needs to
    // remember the functions it replaces.
    inner = fs.vtable;
    gpa = fs.gpa;
    arena = fs.arena;
    replaced_deps = env.resolution_config.replace_deps.len > 0;
    package_limit = env.resolution_config.max_platform_transitive_expanded_bytes;
    fs.vtable.readFile = readFile;
    fs.vtable.readFileInto = readFileInto;
    fs.vtable.fileExists = fileExists;
    fs.vtable.stat = stat;
    fs.vtable.canonicalize = canonicalize;
    fs.vtable.mapFilePrivate = mapFilePrivate;
    env.sink.rewrite = @import("report.zig").rewrite;
}

/// The `.punk` file the build reads for `path`, or null when it reads
/// `path` itself. `path` is a `.punk` file, or a `.roc` path that only
/// exists as a `.punk` file.
fn punkFor(ctx: ?*anyopaque, io: std.Io, path: []const u8, buf: []u8) ?[]const u8 {
    if (punk.isPunkPath(path)) return path;
    if (!std.mem.endsWith(u8, path, ".roc")) return null;
    if (virtual.get(path)) |p| return p;
    if (inner.fileExists(ctx, io, path)) return null;
    const stem = path[0 .. path.len - ".roc".len];
    if (stem.len + punk.extension.len > buf.len) return null;
    @memcpy(buf[0..stem.len], stem);
    @memcpy(buf[stem.len..][0..punk.extension.len], punk.extension);
    const punk_path = buf[0 .. stem.len + punk.extension.len];
    if (!inner.fileExists(ctx, io, punk_path)) return null;
    virtual.remember(path, punk_path);
    return virtual.get(path);
}

/// The `.punk` file behind the virtual `.roc` path `path`, if it is one.
pub fn virtualPunk(path: []const u8) ?[]const u8 {
    return virtual.get(path);
}

const Raw = struct { ctx: ?*anyopaque, io: std.Io };

fn readFile(ctx: ?*anyopaque, io: std.Io, path: []const u8, allocator: Allocator) CoreCtx.ReadError![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const punk_path = punkFor(ctx, io, path, &buf) orelse return inner.readFile(ctx, io, path, allocator);
    const data = try inner.readFile(ctx, io, punk_path, allocator);
    defer allocator.free(data);
    var raw: Raw = .{ .ctx = ctx, .io = io };
    const reader: punk.Reader = .{ .ctx = &raw, .read = readRaw, .packageDir = packageDir };
    // A syntax error is remembered by the translator; `report.zig` turns
    // the build's "could not read" into a report about it.
    return punk.toRocWith(allocator, punk_path, data, reader) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ParseError => error.IoError,
    };
}

fn readFileInto(ctx: ?*anyopaque, io: std.Io, path: []const u8, buffer: []u8) CoreCtx.ReadError!usize {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (punkFor(ctx, io, path, &buf) == null) return inner.readFileInto(ctx, io, path, buffer);
    const roc = try readFile(ctx, io, path, gpa);
    defer gpa.free(roc);
    if (roc.len > buffer.len) return error.StreamTooLong;
    @memcpy(buffer[0..roc.len], roc);
    return roc.len;
}

fn fileExists(ctx: ?*anyopaque, io: std.Io, path: []const u8) bool {
    if (inner.fileExists(ctx, io, path)) return true;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return punkFor(ctx, io, path, &buf) != null;
}

fn stat(ctx: ?*anyopaque, io: std.Io, path: []const u8) CoreCtx.StatError!CoreCtx.FileInfo {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const punk_path = punkFor(ctx, io, path, &buf) orelse return inner.stat(ctx, io, path);
    // The size is of the `.punk` file; readers use `readFile` for the bytes.
    return inner.stat(ctx, io, punk_path);
}

fn canonicalize(ctx: ?*anyopaque, io: std.Io, path: []const u8, allocator: Allocator) CoreCtx.CanonicalizeError![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const punk_path = punkFor(ctx, io, path, &buf) orelse return inner.canonicalize(ctx, io, path, allocator);
    if (punk_path.ptr == path.ptr) return inner.canonicalize(ctx, io, path, allocator);
    // A virtual `Foo.roc`: canonicalize `Foo.punk`, and keep the name `Foo.roc`.
    const canonical_punk = try inner.canonicalize(ctx, io, punk_path, allocator);
    defer allocator.free(canonical_punk);
    const stem = canonical_punk[0 .. canonical_punk.len - punk.extension.len];
    const canonical = try std.mem.concat(allocator, u8, &.{ stem, ".roc" });
    virtual.remember(canonical, canonical_punk);
    return canonical;
}

fn mapFilePrivate(ctx: ?*anyopaque, io: std.Io, path: []const u8) ?CoreCtx.MappedFile {
    // A punkroc file must go through `readFile`, which translates it.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (punkFor(ctx, io, path, &buf) != null) return null;
    return inner.mapFilePrivate(ctx, io, path);
}

/// Reads a source file as it is on disk, for the translator, which looks at
/// the modules a `.punk` file imports.
fn readRaw(ctx: ?*anyopaque, allocator: Allocator, path: []const u8) ?[]u8 {
    const raw: *const Raw = @ptrCast(@alignCast(ctx.?));
    if (!inner.fileExists(raw.ctx, raw.io, path)) return null;
    return inner.readFile(raw.ctx, raw.io, path, allocator) catch null;
}

/// The directory of the package at `url`, for the translator. The package
/// is downloaded into the package cache when it is not there yet, as package
/// resolution would do right after; the download is the same, so resolution
/// then finds it cached. Any problem gives null: resolution reports it
/// properly.
fn packageDir(ctx: ?*anyopaque, allocator: Allocator, url: []const u8) ?[]const u8 {
    const raw: *const Raw = @ptrCast(@alignCast(ctx.?));
    // A replaced dependency need not be downloaded at all.
    if (replaced_deps) return null;
    const parsed = base.url.parseUrlPath(url) catch return null;
    const fs: CoreCtx = .{ .ctx = raw.ctx, .vtable = inner, .std_io = raw.io, .gpa = gpa, .arena = arena };
    const cache_dir = compile.build.packagesCacheDir(fs, allocator) catch return null;
    var ctx_fetcher: package_resolution.CtxFetcher = .{ .fs = fs, .gpa = gpa, .cache_packages_dir = cache_dir };
    const fetcher = ctx_fetcher.fetcher();
    var reports = package_resolution.HeaderReports.init(allocator);
    defer {
        for (reports.items) |*report| report.deinit();
        reports.deinit();
    }
    // The largest limit resolution applies; it checks the real one.
    const fetched = fetcher.fetchUrlFn(fetcher.ctx, allocator, url, parsed.hash, package_limit, &reports) catch return null;
    return fetched.root_dir;
}

/// Translates `source`, read from `path`, when `path` is a `.punk` file;
/// otherwise returns null. For the CLI's look at an app before the build.
pub fn translateRaw(allocator: Allocator, io: std.Io, path: []const u8, source: []const u8) punk.Error!?[]u8 {
    if (!punk.isPunkPath(path)) return null;
    var raw: Raw = .{ .ctx = null, .io = io };
    const reader: punk.Reader = .{ .ctx = &raw, .read = readRawDisk };
    return try punk.toRocWith(allocator, path, source, reader);
}

fn readRawDisk(ctx: ?*anyopaque, allocator: Allocator, path: []const u8) ?[]u8 {
    const raw: *const Raw = @ptrCast(@alignCast(ctx.?));
    return std.Io.Dir.cwd().readFileAlloc(raw.io, path, allocator, .limited(256 * 1024 * 1024)) catch null;
}
