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
/// The schema of the tables of a `.punk` file, as the history of versions in
/// its `schema.sql` (src/punk/migrate.zig).
pub const schema = translate_mod.schema;
pub const SchemaResult = translate_mod.SchemaResult;

/// `punk fmt`: lays out punkroc source in its one canonical form.
pub const format = @import("format.zig");

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
        resolver = .{ .ctx = &load_ctx, .load = load, .schema = loadSchema };
    }
    const mapped = translate_mod.translateMapped(arena.allocator(), src, &diag, resolver) catch |err| switch (err) {
        error.ParseError => {
            const msg = try std.fmt.allocPrint(arena.allocator(), "{s}:{d}:{d}: {s}", .{ path, diag.line, diag.col, diag.message });
            syntax_errors.set(path, msg);
            // Kept so the report can show the line.
            source_maps.set(path, src, "", &.{});
            return error.ParseError;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    syntax_errors.set(path, null);
    source_maps.set(path, src, mapped.roc, mapped.marks);
    return allocator.dupe(u8, mapped.roc);
}

/// The source maps of the `.punk` files translated last, by path, so the
/// compiler's error messages can show the `.punk` file instead of its Roc
/// translation (see `remap`).
const source_maps = struct {
    const Entry = struct { punk: []const u8, punk_lines: []const u32, roc_lines: []const u32, marks: []const translate_mod.Mark };
    var mutex: std.atomic.Mutex = .unlocked;
    var map: std.StringHashMapUnmanaged(Entry) = .empty;
    const gpa = std.heap.page_allocator;

    fn lock() void {
        while (!mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn free(e: Entry) void {
        gpa.free(e.punk);
        gpa.free(e.punk_lines);
        gpa.free(e.roc_lines);
        gpa.free(e.marks);
    }

    fn set(path: []const u8, punk: []const u8, roc: []const u8, marks: []const translate_mod.Mark) void {
        const entry = make(punk, roc, marks) catch return;
        lock();
        defer mutex.unlock();
        if (map.getPtr(path)) |old| {
            free(old.*);
            old.* = entry;
            return;
        }
        const key = gpa.dupe(u8, path) catch return free(entry);
        map.put(gpa, key, entry) catch {
            gpa.free(key);
            free(entry);
        };
    }

    fn make(punk: []const u8, roc: []const u8, marks: []const translate_mod.Mark) !Entry {
        const p = try gpa.dupe(u8, punk);
        errdefer gpa.free(p);
        const pl = try lineStarts(punk);
        errdefer gpa.free(pl);
        const rl = try lineStarts(roc);
        errdefer gpa.free(rl);
        return .{ .punk = p, .punk_lines = pl, .roc_lines = rl, .marks = try gpa.dupe(translate_mod.Mark, marks) };
    }

    fn lineStarts(text: []const u8) ![]u32 {
        var list: std.ArrayList(u32) = .empty;
        errdefer list.deinit(gpa);
        try list.append(gpa, 0);
        for (text, 0..) |c, i| if (c == '\n') try list.append(gpa, @intCast(i + 1));
        return list.toOwnedSlice(gpa);
    }
};

/// A position in a file: line and column, both counted from 1.
pub const Position = struct { line: u32, column: u32 };

/// A part of a `.punk` file, for an error message.
pub const SourceRegion = struct {
    start: Position,
    end: Position,
    /// The whole lines `start` to `end` are on, owned by the caller.
    lines: []u8,
};

/// The part of the `.punk` file `path` that the part `start`..`end` of its
/// Roc translation came from. Null when `path` is not a translated `.punk`
/// file. The compiler reports errors in the translation; this turns them
/// into errors in the file the programmer wrote.
pub fn remap(allocator: std.mem.Allocator, path: []const u8, start: Position, end: Position) std.mem.Allocator.Error!?SourceRegion {
    source_maps.lock();
    defer source_maps.mutex.unlock();
    const e = source_maps.map.get(path) orelse return null;
    // A file that did not translate has no translation to point into.
    if (e.marks.len == 0) return null;
    const s = offsetOf(e.roc_lines, start);
    const t = @max(offsetOf(e.roc_lines, end), s);
    const span = translate_mod.sourceSpan(e.marks, s, t);
    const ps = positionOf(e.punk_lines, span.start);
    const pe = positionOf(e.punk_lines, span.end);
    const from = e.punk_lines[ps.line - 1];
    var to: usize = if (pe.line < e.punk_lines.len) e.punk_lines[pe.line] - 1 else e.punk.len;
    if (to > from and e.punk[to - 1] == '\r') to -= 1;
    return .{ .start = ps, .end = pe, .lines = try allocator.dupe(u8, e.punk[from..@max(to, from)]) };
}

/// The lines `first` to `last` (from 1, `last` clamped to the end) of the
/// `.punk` file `path`, owned by the caller. Null when `path` is not known
/// or has no line `first`.
pub fn sourceLines(allocator: std.mem.Allocator, path: []const u8, first: u32, last: u32) std.mem.Allocator.Error!?[]u8 {
    source_maps.lock();
    defer source_maps.mutex.unlock();
    const e = source_maps.map.get(path) orelse return null;
    const lines = e.punk_lines;
    if (first > lines.len) return null;
    const f = @max(first, 1) - 1;
    const l = @min(@max(last, first), lines.len);
    var to: usize = if (l < lines.len) lines[l] - 1 else e.punk.len;
    if (to > lines[f] and e.punk[to - 1] == '\r') to -= 1;
    return try allocator.dupe(u8, e.punk[lines[f]..@max(to, lines[f])]);
}

/// `text` from an error message with the Roc spelling of names turned back
/// into punkroc's (`not_defined` is `notDefined`, `List.keep_if` is
/// `List.keepIf`), owned by `allocator`. Null when nothing changes. Words
/// with a `/` in them (paths) and names starting with `_` stay as they are.
pub fn camelText(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var changed = false;
    var word_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == ' ' or c == '\n') word_start = i + 1;
        if (c == '_' and i > 0 and i + 1 < text.len and isLowerOrDigit(text[i - 1]) and std.ascii.isLower(text[i + 1])) {
            const word_end = std.mem.findAnyPos(u8, text, i, " \n") orelse text.len;
            if (std.mem.findScalar(u8, text[word_start..word_end], '/') == null and !startsWithUnderscore(text, i)) {
                try out.append(allocator, std.ascii.toUpper(text[i + 1]));
                i += 1;
                changed = true;
                continue;
            }
        }
        try out.append(allocator, c);
    }
    if (!changed) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

fn isLowerOrDigit(c: u8) bool {
    return std.ascii.isLower(c) or std.ascii.isDigit(c);
}

/// Whether the name the `_` at `i` is in starts with `_` (`_unused_thing`).
fn startsWithUnderscore(text: []const u8, i: usize) bool {
    var j = i;
    while (j > 0 and (std.ascii.isAlphanumeric(text[j - 1]) or text[j - 1] == '_')) j -= 1;
    return text[j] == '_';
}

/// Whether `remap` knows the `.punk` file `path`.
pub fn hasSourceMap(path: []const u8) bool {
    source_maps.lock();
    defer source_maps.mutex.unlock();
    return source_maps.map.contains(path);
}

fn offsetOf(lines: []const u32, p: Position) u32 {
    if (p.line == 0) return 0;
    const idx = @min(p.line - 1, lines.len - 1);
    return lines[idx] + (p.column -| 1);
}

fn positionOf(lines: []const u32, offset: u32) Position {
    var lo: usize = 0;
    var hi: usize = lines.len;
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (lines[mid] <= offset) lo = mid else hi = mid;
    }
    return .{ .line = @intCast(lo + 1), .column = offset - lines[lo] + 1 };
}

const LoadCtx = struct { reader: Reader, dir: []const u8 };

/// The `schema.sql` next to the file being translated.
fn loadSchema(ctx_ptr: ?*anyopaque, arena: std.mem.Allocator) ?[]const u8 {
    const ctx: *LoadCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const path = std.fs.path.join(arena, &.{ ctx.dir, "schema.sql" }) catch return null;
    return ctx.reader.read(ctx.reader.ctx, arena, path);
}

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
