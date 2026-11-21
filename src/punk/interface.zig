//! What punkroc knows about a module that a `.punk` file imports: which
//! functions it has, how many arguments they take, and what it exposes.
//!
//! The translator uses this on the boundary between modules: a partial
//! application of `Math.add 1` needs the arity of `Math.add`, a call to a
//! function of a Roc module gets its arguments in Roc's order, and a name a
//! punkroc module does not expose is an error.
//!
//! Interfaces of `.punk` modules come from the punkroc parser (see
//! `translate.punkInterface`); interfaces of `.roc` modules from `scanRoc`
//! below, a light scan of the top-level annotations and definitions that
//! needs no Roc parser.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The language a module is written in.
pub const Kind = enum { punk, roc };

/// The interface of one imported module.
pub const Interface = struct {
    kind: Kind,
    /// Every lowercase top-level name (in Roc spelling, `sum_of_squares`),
    /// with its arity when it is a function of known arity.
    values: std.StringHashMapUnmanaged(?u8) = .empty,
    /// Type names defined in the module, with their tags.
    types: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    /// What the module exposes; null means everything (Roc modules and
    /// `exposing (..)`).
    exposing: ?Exposing = null,

    pub const Exposing = struct {
        /// Lowercase names, in Roc spelling.
        values: std.StringHashMapUnmanaged(void) = .empty,
        /// Type names, and whether their tags are exposed too (`Shape(..)`).
        types: std.StringHashMapUnmanaged(bool) = .empty,
        /// The entries as written, slices of the list.
        items: std.ArrayList([]const u8) = .empty,
    };

    /// Whether a lowercase name (Roc spelling) may be used from outside.
    pub fn exposesValue(i: *const Interface, name: []const u8) bool {
        const ex = i.exposing orelse return true;
        return ex.values.contains(name);
    }

    /// The type a tag belongs to, if the module defines it.
    pub fn tagType(i: *const Interface, tag: []const u8) ?[]const u8 {
        var it = i.types.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.*) |t| if (std.mem.eql(u8, t, tag)) return entry.key_ptr.*;
        }
        return null;
    }

    /// Whether an uppercase name, a type or a tag, may be used from outside.
    /// Names the module does not define are left to the Roc compiler.
    pub fn exposesUpper(i: *const Interface, name: []const u8) bool {
        const ex = i.exposing orelse return true;
        if (i.types.contains(name)) return ex.types.contains(name);
        if (i.tagType(name)) |ty| return ex.types.get(ty) orelse false;
        return true;
    }
};

/// Parses the names in an Elm-style exposing list, `(double, Shape(..), Color)`,
/// given the text between the outer parentheses. Returns null for `(..)`.
/// Lowercase names are converted with `snake`.
pub fn parseExposing(
    a: Allocator,
    list: []const u8,
    comptime snake: fn (Allocator, []const u8) Allocator.Error![]const u8,
) Allocator.Error!?Interface.Exposing {
    if (std.mem.eql(u8, std.mem.trim(u8, list, " \t\r\n"), "..")) return null;
    var ex: Interface.Exposing = .{};
    var depth: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= list.len) : (i += 1) {
        const c: u8 = if (i < list.len) list[i] else ',';
        switch (c) {
            '(', '[' => depth += 1,
            ')', ']' => depth -|= 1,
            ',' => if (depth == 0) {
                const item = std.mem.trim(u8, list[start..i], " \t\r\n");
                start = i + 1;
                if (item.len == 0) continue;
                try ex.items.append(a, item);
                if (std.ascii.isUpper(item[0])) {
                    const paren = std.mem.findScalar(u8, item, '(');
                    const name = std.mem.trimEnd(u8, item[0 .. paren orelse item.len], " ");
                    try ex.types.put(a, name, paren != null);
                } else {
                    try ex.values.put(a, try snake(a, item), {});
                }
            },
            else => {},
        }
    }
    return ex;
}

/// Scans the top-level definitions of a Roc module.
///
/// A type module (`Foo := [].{ ... }`) has its definitions inside the block;
/// other files at column 1. Only lines at that indentation count. Arity comes
/// from the annotation (`map : List(a), (a -> b) -> List(b)` takes two) or,
/// without one, from the lambda (`|a, b| ...`).
pub fn scanRoc(a: Allocator, src: []const u8) Allocator.Error!Interface {
    var iface: Interface = .{ .kind = .roc };
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| try lines.append(a, std.mem.trimEnd(u8, line, "\r"));

    // The indentation of the definitions: the first definition-like line
    // after a line that opens a type module's block, or column 1.
    var def_indent: usize = 0;
    for (lines.items, 0..) |line, n| {
        const code = stripComment(line);
        if (std.mem.endsWith(u8, std.mem.trimEnd(u8, code, " \t"), ".{")) {
            for (lines.items[n + 1 ..]) |next| {
                const c = stripComment(next);
                if (std.mem.trim(u8, c, " \t").len == 0) continue;
                def_indent = indentOf(c);
                break;
            }
            break;
        }
    }

    var n: usize = 0;
    while (n < lines.items.len) : (n += 1) {
        const line = stripComment(lines.items[n]);
        if (std.mem.trim(u8, line, " \t").len == 0 or indentOf(line) != def_indent) continue;
        const rest = line[def_indent..];
        const name_end = lowerNameEnd(rest) orelse continue;
        const name = rest[0..name_end];
        const after = std.mem.trimStart(u8, rest[name_end..], " \t");
        if (after.len == 0) continue;

        if (after[0] == ':' and !(after.len > 1 and (after[1] == '=' or after[1] == ':'))) {
            // An annotation, possibly continued on more indented lines.
            var ty: std.ArrayList(u8) = .empty;
            try ty.appendSlice(a, after[1..]);
            while (n + 1 < lines.items.len) {
                const next = stripComment(lines.items[n + 1]);
                if (std.mem.trim(u8, next, " \t").len != 0 and indentOf(next) <= def_indent) break;
                try ty.append(a, ' ');
                try ty.appendSlice(a, next);
                n += 1;
            }
            try iface.values.put(a, name, typeArity(ty.items));
        } else if (after[0] == '=' and !(after.len > 1 and after[1] == '=')) {
            const body = std.mem.trimStart(u8, after[1..], " \t");
            const arity = lambdaArity(body);
            const entry = try iface.values.getOrPut(a, name);
            // An annotation wins; a lambda fills in when there is none.
            if (!entry.found_existing or entry.value_ptr.* == null) entry.value_ptr.* = arity;
        }
    }
    return iface;
}

fn indentOf(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return i;
}

/// The line without a trailing `# comment` (outside of strings).
fn stripComment(line: []const u8) []const u8 {
    var in_str = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            '\\' => if (in_str) {
                i += 1;
            },
            '"' => in_str = !in_str,
            '#' => if (!in_str) return line[0..i],
            else => {},
        }
    }
    return line;
}

/// The end of a lowercase Roc name at the start of `s` (`line!`, `_x`), or
/// null when `s` does not start with one.
fn lowerNameEnd(s: []const u8) ?usize {
    if (s.len == 0 or !(std.ascii.isLower(s[0]) or s[0] == '_')) return null;
    var i: usize = 1;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '_')) i += 1;
    if (i < s.len and s[i] == '!') i += 1;
    return i;
}

/// The number of arguments of a Roc function type: `A, B -> C` takes two,
/// `() => {}` none. Null when the type is not a function.
pub fn typeArity(ty_in: []const u8) ?u8 {
    var ty = std.mem.trim(u8, ty_in, " \t");
    // A `where` clause at the outer level is not part of the arguments.
    if (findOuter(ty, " where ")) |w| ty = ty[0..w];
    var depth: usize = 0;
    var commas: usize = 0;
    var i: usize = 0;
    while (i < ty.len) : (i += 1) {
        switch (ty[i]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            ',' => if (depth == 0) {
                commas += 1;
            },
            '-', '=' => if (depth == 0 and i + 1 < ty.len and ty[i + 1] == '>') {
                const args = std.mem.trim(u8, ty[0..i], " \t");
                if (args.len == 0 or std.mem.eql(u8, args, "()")) return 0;
                return @intCast(@min(commas + 1, 255));
            },
            else => {},
        }
    }
    return null;
}

/// The number of parameters of a Roc lambda `|a, b| ...`. Null when `body`
/// does not start with one.
pub fn lambdaArity(body: []const u8) ?u8 {
    if (body.len == 0 or body[0] != '|') return null;
    if (body.len > 1 and body[1] == '|') return 0;
    var depth: usize = 0;
    var commas: usize = 0;
    var any = false;
    for (body[1..]) |c| {
        switch (c) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            ',' => if (depth == 0) {
                commas += 1;
            },
            '|' => if (depth == 0) return if (any) @intCast(@min(commas + 1, 255)) else 0,
            ' ', '\t' => {},
            else => any = true,
        }
    }
    return null;
}

fn findOuter(s: []const u8, needle: []const u8) ?usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => depth -|= 1,
            else => if (depth == 0 and std.mem.startsWith(u8, s[i..], needle)) return i,
        }
    }
    return null;
}
