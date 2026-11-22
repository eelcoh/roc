//! punkroc's own commands in the CLI: `punk fmt` on `.punk` files and
//! `punk check --schema`. The CLI hands over its writers; these functions
//! do not flush them.

const std = @import("std");
const punk = @import("punk");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Failed = error{Failed} || Allocator.Error || Writer.Error;

/// True when `paths` are all `.punk` files, so `fmt` is punk's.
pub fn allPunk(paths: []const []const u8) bool {
    if (paths.len == 0) return false;
    for (paths) |path| if (!punk.isPunkPath(path)) return false;
    return true;
}

/// `punk fmt`: lays each file out in punkroc's canonical form
/// (src/punk/format.zig). With `check` it only lists the files that are not
/// formatted.
pub fn format(gpa: Allocator, io: std.Io, stdout: *Writer, stderr: *Writer, paths: []const []const u8, check: bool) Failed!void {
    var failed: usize = 0;
    var unformatted: usize = 0;
    var changed: usize = 0;
    for (paths) |path| {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const src = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024 * 1024)) catch |err| {
            try stderr.print("{s}: cannot read: {s}\n", .{ path, @errorName(err) });
            failed += 1;
            continue;
        };
        var diag: punk.Diagnostic = .{};
        const out = punk.format.format(arena, src, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError, error.Unsafe => {
                try stderr.print("{s}:{d}:{d}: {s}\n", .{ path, diag.line, diag.col, diag.message });
                failed += 1;
                continue;
            },
        };
        if (std.mem.eql(u8, out, src)) continue;
        if (check) {
            try stdout.print("{s}\n", .{path});
            unformatted += 1;
        } else {
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out }) catch |err| {
                try stderr.print("{s}: cannot write: {s}\n", .{ path, @errorName(err) });
                failed += 1;
                continue;
            };
            changed += 1;
        }
    }
    if (check and unformatted > 0) {
        try stdout.print("{d} file(s) are not formatted; run `punk fmt` on them.\n", .{unformatted});
    } else if (!check) {
        try stdout.print("Formatted {d} file(s), {d} changed.\n", .{ paths.len - failed, changed });
    }
    if (failed > 0 or unformatted > 0) return error.Failed;
}

/// `punk check --schema app.punk`: brings the `schema.sql` next to the app
/// up to date with the tables it declares, adding a version when they
/// changed (src/punk/migrate.zig), and says what the new version does.
pub fn checkSchema(gpa: Allocator, io: std.Io, stdout: *Writer, stderr: *Writer, path: []const u8) Failed!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cwd = std.Io.Dir.cwd();
    const src = cwd.readFileAlloc(io, path, arena, .limited(256 * 1024 * 1024)) catch |err| {
        try stderr.print("{s}: cannot read: {s}\n", .{ path, @errorName(err) });
        return error.Failed;
    };
    const schema_path = try std.fs.path.join(arena, &.{ std.fs.path.dirname(path) orelse ".", "schema.sql" });
    const existing: ?[]const u8 = cwd.readFileAlloc(io, schema_path, arena, .limited(256 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            try stderr.print("{s}: cannot read: {s}\n", .{ schema_path, @errorName(err) });
            return error.Failed;
        },
    };
    var diag: punk.Diagnostic = .{};
    const result = punk.schema(arena, src, existing, &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => {
            try stderr.print("{s}:{d}:{d}: {s}\n", .{ path, diag.line, diag.col, diag.message });
            return error.Failed;
        },
    };
    if (!result.changed) {
        try stdout.print("{s} is up to date\n", .{schema_path});
        return;
    }
    cwd.writeFile(io, .{ .sub_path = schema_path, .data = result.sql }) catch |err| {
        try stderr.print("{s}: cannot write: {s}\n", .{ schema_path, @errorName(err) });
        return error.Failed;
    };
    try stdout.print("{s}: {s}", .{ schema_path, result.report });
}
