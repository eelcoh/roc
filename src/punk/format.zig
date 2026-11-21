//! `punk fmt`: the canonical layout of punkroc source, with no options (like
//! elm-format). Agents do not have to think about style, and a reader always
//! sees the same shape.
//!
//! The formatter works on the tokens, not on a syntax tree, so it never loses
//! a comment and never changes what the code means:
//!
//! - indentation is 4 spaces per level (each deeper indentation in the
//!   source becomes one level deeper than the line it belongs under);
//! - one space between tokens, none inside `( )` and `[ ]`, one inside
//!   `{ }`, none before a comma and one after it, spaces around operators,
//!   `=`, `->`, `:` and `|`; `.field` and `-x` keep their tight form;
//! - at most one blank line in a row; exactly one between top-level
//!   items, and none between an annotation and its definition or between
//!   imports;
//! - no trailing spaces, and one newline at the end of the file.
//!
//! Line breaks are the author's: the formatter does not join or split lines.
//! Header lines (`app`, `module`, `import`) are kept as written.
//!
//! To be sure the layout changed nothing else, the formatted text is
//! translated again and its Roc translation compared with that of the
//! original (ignoring whitespace). If they differ, `format` refuses with
//! `error.Unsafe` and the file is left alone.

const std = @import("std");
const translate = @import("translate.zig");

const Allocator = std.mem.Allocator;
const Token = translate.Token;
const Tag = translate.Tag;
const Diagnostic = translate.Diagnostic;

pub const Error = error{ ParseError, OutOfMemory, Unsafe };

/// The indentation of one level.
pub const indent_width = 4;

/// Formats punkroc source. On a syntax error `error.ParseError` is returned
/// with `diag` filled in; the source is left as it is.
pub fn format(a: Allocator, src: []const u8, diag: *Diagnostic) Error![]const u8 {
    const before = try translate.translate(a, src, diag);
    const toks = try translate.lex(a, src, diag);
    const out = try render(a, src, toks);
    var d2: Diagnostic = .{};
    const after = translate.translate(a, out, &d2) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => return unsafe(diag, d2.line, d2.col),
    };
    if (!sameIgnoringSpace(before, after)) return unsafe(diag, 1, 1);
    return out;
}

fn unsafe(diag: *Diagnostic, line: u32, col: u32) error{Unsafe} {
    diag.* = .{ .line = line, .col = col, .message = "punk fmt would change what this file means, so it left the file alone (this is a bug in punk fmt)" };
    return error.Unsafe;
}

/// Whether `x` and `y` are the same text when every run of whitespace counts
/// as one space.
pub fn sameIgnoringSpace(x: []const u8, y: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        const ws_i = skipSpace(x, &i);
        const ws_j = skipSpace(y, &j);
        const end_i = i == x.len;
        const end_j = j == y.len;
        if (end_i or end_j) return end_i and end_j;
        if (ws_i != ws_j) return false;
        if (x[i] != y[j]) return false;
        i += 1;
        j += 1;
    }
}

fn skipSpace(s: []const u8, i: *usize) bool {
    const start = i.*;
    while (i.* < s.len and std.ascii.isWhitespace(s[i.*])) i.* += 1;
    return i.* > start;
}

const Level = struct { orig: u32, new: u32 };

const Renderer = struct {
    a: Allocator,
    src: []const u8,
    toks: []const Token,
    out: std.ArrayList(u8) = .empty,
    stack: std.ArrayList(Level) = .empty,
    /// Indentation of the current line, in the source and in the output.
    old_indent: u32 = 1,
    new_indent: u32 = 1,
    /// Whether the token written last was a prefix `-` or `!`.
    prev_unary: bool = false,
    /// For each `(` and `[`: whether its items are written with leading
    /// commas on lines of their own. Such a bracket gets a space after it,
    /// Elm style (`[ 1` / `, 2` / `]`).
    spans_lines: []bool = &.{},

    fn w(r: *Renderer, s: []const u8) Error!void {
        try r.out.appendSlice(r.a, s);
    }

    fn spaces(r: *Renderer, n: u32) Error!void {
        try r.out.appendNTimes(r.a, ' ', n);
    }

    fn trimTrailingSpaces(r: *Renderer) void {
        while (r.out.items.len > 0 and r.out.items[r.out.items.len - 1] == ' ') r.out.items.len -= 1;
    }

    /// The new column for a line that starts at column `col` in the source.
    fn indentFor(r: *Renderer, col: u32) Error!u32 {
        while (r.stack.items.len > 1 and r.stack.items[r.stack.items.len - 1].orig > col) r.stack.items.len -= 1;
        const top = r.stack.items[r.stack.items.len - 1];
        if (top.orig == col) return top.new;
        if (col < top.orig) return top.new; // only the column-1 level is left
        const new = top.new + indent_width;
        try r.stack.append(r.a, .{ .orig = col, .new = new });
        return new;
    }

    /// Writes `text`, which starts in the source at a column `delta` columns
    /// from where it is written now, moving its later lines by as much.
    fn writeShifted(r: *Renderer, text: []const u8, delta: i64) Error!void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var first = true;
        while (lines.next()) |l| {
            if (!first) {
                try r.w("\n");
                var line = l;
                if (delta > 0) {
                    if (line.len > 0) try r.spaces(@intCast(delta));
                } else if (delta < 0) {
                    var k: usize = 0;
                    while (k < @as(usize, @intCast(-delta)) and k < line.len and line[k] == ' ') k += 1;
                    line = line[k..];
                }
                try r.w(line);
            } else try r.w(l);
            first = false;
        }
    }

    fn markLeadingCommas(r: *Renderer) Error!void {
        r.spans_lines = try r.a.alloc(bool, r.toks.len);
        @memset(r.spans_lines, false);
        var open: std.ArrayList(usize) = .empty;
        for (r.toks, 0..) |t, i| switch (t.tag) {
            .lparen, .lbrack, .lbrace => try open.append(r.a, i),
            .rparen, .rbrack, .rbrace => _ = open.pop(),
            .comma => if (t.first_on_line and open.items.len > 0) {
                r.spans_lines[open.items[open.items.len - 1]] = true;
            },
            else => {},
        };
    }

    fn run(r: *Renderer) Error![]const u8 {
        try r.markLeadingCommas();
        try r.stack.append(r.a, .{ .orig = 1, .new = 1 });
        var prev: ?Token = null;
        var prev_end: usize = 0;
        // The first token of the previous top-level item, and its second.
        var item_first: ?Token = null;
        var item_second: ?Token = null;
        var i: usize = 0;
        while (i < r.toks.len) {
            const t = r.toks[i];
            const gap = r.src[prev_end..t.start];
            if (t.tag == .eof) {
                try r.lineGap(gap, prev != null, false, 0, true);
                break;
            }
            if (t.first_on_line) {
                const new_col = try r.indentFor(t.col);
                var tight = false;
                if (t.col == 1) {
                    if (item_first) |f| tight = tightAfter(f, item_second, t, if (i + 1 < r.toks.len) r.toks[i + 1] else t);
                    item_first = t;
                    item_second = if (i + 1 < r.toks.len) r.toks[i + 1] else null;
                }
                try r.lineGap(gap, prev != null, t.col == 1 and prev != null, new_col, tight);
                r.old_indent = t.col;
                r.new_indent = new_col;
                try r.spaces(new_col - 1);
                r.prev_unary = false;
            } else {
                try r.inlineGap(gap, prev.?, t, i);
            }
            // A header is kept as written, up to the next top-level line.
            if (t.tag == .kw_header and t.first_on_line and t.col == 1) {
                var j = i;
                while (j + 1 < r.toks.len and r.toks[j + 1].tag != .eof and !(r.toks[j + 1].first_on_line and r.toks[j + 1].col == 1)) j += 1;
                var lines = std.mem.splitScalar(u8, r.src[t.start..r.toks[j].end], '\n');
                var first = true;
                while (lines.next()) |l| {
                    if (!first) try r.w("\n");
                    first = false;
                    try r.w(std.mem.trimEnd(u8, l, " \r"));
                }
                prev = r.toks[j];
                prev_end = r.toks[j].end;
                i = j + 1;
                continue;
            }
            const delta: i64 = @as(i64, r.new_indent) - @as(i64, r.old_indent);
            try r.writeShifted(r.src[t.start..t.end], delta);
            r.prev_unary = isUnary(prev, t, r.toks, i);
            prev = t;
            prev_end = t.end;
            i += 1;
        }
        r.trimTrailingSpaces();
        while (r.out.items.len > 0 and r.out.items[r.out.items.len - 1] == '\n') r.out.items.len -= 1;
        try r.w("\n");
        return r.out.items;
    }

    /// Writes the space between two tokens on one line.
    fn inlineGap(r: *Renderer, gap: []const u8, prev: Token, cur: Token, i: usize) Error!void {
        // A block comment between them stays.
        const comment = std.mem.trim(u8, gap, " \r");
        if (comment.len > 0) {
            try r.w(" ");
            try r.w(comment);
            try r.w(" ");
            return;
        }
        const after_open = (prev.tag == .lparen or prev.tag == .lbrack) and r.spans_lines[i - 1];
        if (after_open or wantSpace(prev, cur, gap.len > 0, r.prev_unary, r.toks, i)) try r.w(" ");
    }

    /// Writes the line break(s) and comments between two lines. `at_top` is
    /// set when the next line is a new top-level item; `tight` when it may
    /// follow the item before it without a blank line.
    fn lineGap(r: *Renderer, gap: []const u8, after_token: bool, at_top: bool, new_col: u32, tight: bool) Error!void {
        var k: usize = 0;
        var newlines: u32 = 0;
        var entries: u32 = 0;
        const indent_out: u32 = if (new_col == 0) 1 else new_col;
        while (k < gap.len) {
            const c = gap[k];
            if (c == '\n') {
                newlines += 1;
                k += 1;
            } else if (c == ' ' or c == '\r') {
                k += 1;
            } else {
                // A comment.
                const comment_start = k;
                var end = k;
                if (c == '-') {
                    while (end < gap.len and gap[end] != '\n') end += 1;
                } else {
                    var depth: u32 = 0;
                    while (end < gap.len) {
                        if (end + 1 < gap.len and gap[end] == '{' and gap[end + 1] == '-') {
                            depth += 1;
                            end += 2;
                        } else if (end + 1 < gap.len and gap[end] == '-' and gap[end + 1] == '}') {
                            depth -= 1;
                            end += 2;
                            if (depth == 0) break;
                        } else end += 1;
                    }
                }
                const text = std.mem.trimEnd(u8, gap[comment_start..end], " \r");
                const line_start = if (std.mem.findScalarLast(u8, gap[0..comment_start], '\n')) |nl| nl + 1 else 0;
                const old_col: i64 = @intCast(comment_start - line_start + 1);
                if (newlines == 0 and after_token) {
                    // A comment at the end of the line before.
                    try r.w(" ");
                    try r.writeShifted(text, @as(i64, r.new_indent) - @as(i64, r.old_indent));
                } else {
                    try r.breaks(newlines, after_token or r.out.items.len > 0, at_top and entries == 0, tight);
                    try r.spaces(indent_out - 1);
                    try r.writeShifted(text, @as(i64, indent_out) - old_col);
                    entries += 1;
                }
                newlines = 0;
                k = end;
            }
        }
        if (new_col == 0) return; // end of file
        try r.breaks(newlines, after_token or r.out.items.len > 0, at_top and entries == 0, tight);
    }

    /// Ends the current line and writes the blank line (at most one) that
    /// should follow.
    fn breaks(r: *Renderer, newlines: u32, started: bool, at_top: bool, tight: bool) Error!void {
        r.trimTrailingSpaces();
        if (!started) return;
        try r.w("\n");
        const blank = if (at_top) !tight else newlines >= 2;
        if (blank) try r.w("\n");
    }
};

/// Whether a top-level item may follow the one before it without a blank
/// line: a definition after its annotation, an import after an import.
fn tightAfter(prev_first: Token, prev_second: ?Token, cur: Token, cur_second: Token) bool {
    if (isImport(prev_first) and isImport(cur)) return true;
    if (prev_first.tag == .lower and cur.tag == .lower and std.mem.eql(u8, prev_first.text, cur.text)) {
        const s = prev_second orelse return false;
        return s.tag == .colon and cur_second.tag != .colon;
    }
    return false;
}

fn isImport(t: Token) bool {
    return t.tag == .kw_header and std.mem.eql(u8, t.text, "import");
}

fn endsValue(tag: Tag) bool {
    return switch (tag) {
        .lower, .upper, .qlower, .int, .float, .string, .char, .rparen, .rbrack, .rbrace, .dot_field, .underscore => true,
        else => false,
    };
}

fn isOp(t: Token, text: []const u8) bool {
    return t.tag == .op and std.mem.eql(u8, t.text, text);
}

/// Whether `cur` (at index `i`) is a prefix `-` or `!`: written tight
/// against what follows, and not after a value without a space.
fn isUnary(prev: ?Token, cur: Token, toks: []const Token, i: usize) bool {
    if (!(isOp(cur, "-") or isOp(cur, "!"))) return false;
    const next = if (i + 1 < toks.len) toks[i + 1] else return false;
    if (next.space_before or next.first_on_line) return false;
    const p = prev orelse return true;
    if (cur.first_on_line) return true;
    return !endsValue(p.tag) or cur.space_before;
}

fn isRangeOp(t: Token) bool {
    return isOp(t, "..=") or isOp(t, "..<");
}

fn spacedPunct(tag: Tag) bool {
    return switch (tag) {
        .equals, .arrow, .fat_arrow, .colon, .bar => true,
        else => false,
    };
}

/// Whether there is a space between `prev` and `cur` (at index `i`) on one
/// line; `had` tells whether the source had one.
fn wantSpace(prev: Token, cur: Token, had: bool, prev_unary: bool, toks: []const Token, i: usize) bool {
    if (cur.tag == .dot_field) return had; // `.name` access vs accessor function
    if (cur.tag == .comma) return false;
    if (prev.tag == .comma) return true;
    if (prev.tag == .lparen or prev.tag == .lbrack) return false;
    if (cur.tag == .rparen or cur.tag == .rbrack) return false;
    if (prev.tag == .lbrace) return cur.tag != .rbrace;
    if (cur.tag == .rbrace) return prev.tag != .lbrace;
    if (prev.tag == .double_dot) return false;
    if (cur.tag == .double_dot) return had;
    if (prev_unary) return false;
    if (cur.tag == .op) {
        if (isRangeOp(cur)) return had;
        if (isUnary(prev, cur, toks, i)) return had or !endsValue(prev.tag) and prev.tag != .lparen;
        return true;
    }
    if (prev.tag == .op) return if (isRangeOp(prev)) had else true;
    if (spacedPunct(cur.tag) or spacedPunct(prev.tag)) return true;
    return had;
}

/// Lays out `toks` (the tokens of `src`) without the safety check.
pub fn render(a: Allocator, src: []const u8, toks: []const Token) Error![]const u8 {
    var r = Renderer{ .a = a, .src = src, .toks = toks };
    return r.run();
}
