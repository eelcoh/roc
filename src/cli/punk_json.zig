//! punkroc: `roc check --json` (or `punk check --json`) writes the problems
//! the check found as one JSON document on stdout, for tools and agents:
//!
//!     {
//!       "file": "Day01.punk",
//!       "errors": 1,
//!       "warnings": 0,
//!       "problems": [
//!         {
//!           "severity": "error",
//!           "code": "P101",
//!           "title": "Syntax Error",
//!           "file": "Day01.punk",
//!           "line": 12, "column": 9, "endLine": 12, "endColumn": 14,
//!           "message": "P101: 'crash' is only allowed inside an 'expect' test. ...",
//!           "fix": null
//!         }
//!       ]
//!     }
//!
//! `code` is stable: a punk rule's code (`P101`, see src/punk/rules.zig),
//! `P001` for any other punkroc syntax error, and `roc/<title>` for the
//! problems the Roc compiler reports (`roc/type-mismatch`). Positions are
//! 1-based and point into the `.punk` file (the reports are already mapped
//! back from the Roc translation). `line` is null for a problem without a
//! place in a file. `fix` is reserved for a concrete replacement text; no
//! problem has one yet.

const std = @import("std");
const reporting = @import("reporting");

const Allocator = std.mem.Allocator;
const Report = reporting.Report;
const Document = reporting.Document;
const DocumentElement = reporting.DocumentElement;

const Location = struct {
    file: ?[]const u8,
    line: u32,
    column: u32,
    end_line: u32,
    end_column: u32,
};

/// The first place in a file the document points at.
fn locationOf(doc: *const Document) ?Location {
    for (doc.elements.items) |el| if (locationOfElement(el)) |l| return l;
    return null;
}

fn locationOfElement(el: DocumentElement) ?Location {
    return switch (el) {
        .vertical_stack, .horizontal_concat => |children| for (children) |c| {
            if (locationOfElement(c)) |l| break l;
        } else null,
        .source_code_with_underlines => |sw| if (sw.underline_regions.len > 0) .{
            .file = sw.display_region.filename,
            .line = sw.underline_regions[0].start_line,
            .column = sw.underline_regions[0].start_column,
            .end_line = sw.underline_regions[0].end_line,
            .end_column = sw.underline_regions[0].end_column,
        } else .{
            .file = sw.display_region.filename,
            .line = sw.display_region.start_line,
            .column = sw.display_region.start_column,
            .end_line = sw.display_region.end_line,
            .end_column = sw.display_region.end_column,
        },
        .source_code_region => |r| .{ .file = r.filename, .line = r.start_line, .column = r.start_column, .end_line = r.end_line, .end_column = r.end_column },
        .source_code_multi_region => |mr| if (mr.regions.len > 0) .{
            .file = mr.filename,
            .line = mr.regions[0].start_line,
            .column = mr.regions[0].start_column,
            .end_line = mr.regions[0].end_line,
            .end_column = mr.regions[0].end_column,
        } else null,
        .source_location => |loc| .{ .file = loc.filename, .line = loc.line, .column = loc.column, .end_line = loc.line, .end_column = loc.column },
        else => null,
    };
}

/// A punk rule code (`P` and three digits) at the start of `text`.
fn punkCode(text: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, text, " \n");
    if (t.len >= 5 and t[0] == 'P' and std.ascii.isDigit(t[1]) and std.ascii.isDigit(t[2]) and std.ascii.isDigit(t[3]) and t[4] == ':') return t[0..4];
    return null;
}

/// `roc/` and the title in lower case with dashes: `roc/type-mismatch`.
fn rocCode(a: Allocator, title: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "roc/");
    var dash = false;
    for (title) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (dash and out.items.len > 4) try out.append(a, '-');
            dash = false;
            try out.append(a, std.ascii.toLower(c));
        } else dash = true;
    }
    return out.items;
}

fn writeString(w: *std.Io.Writer, s: []const u8) error{WriteFailed}!void {
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

fn renderPlain(a: Allocator, doc: *const Document, config: reporting.ReportingConfig) (Allocator.Error || error{WriteFailed})![]const u8 {
    var buf = std.Io.Writer.Allocating.init(a);
    try reporting.renderDocumentToTerminal(doc, &buf.writer, reporting.ColorPalette.NO_COLOR, config);
    return std.mem.trim(u8, buf.written(), " \n");
}

/// One check's problems, as JSON. `modules` is the compiler's reports
/// grouped by module (anything with a `reports: []Report` field).
pub fn write(
    a: Allocator,
    w: *std.Io.Writer,
    path: []const u8,
    modules: anytype,
    errors: usize,
    warnings: usize,
    config: reporting.ReportingConfig,
) (Allocator.Error || error{WriteFailed})!void {
    try w.writeAll("{\n  \"file\": ");
    try writeString(w, path);
    try w.print(",\n  \"errors\": {d},\n  \"warnings\": {d},\n  \"problems\": [", .{ errors, warnings });
    var first = true;
    for (modules) |module| for (module.reports) |*report| {
        try w.writeAll(if (first) "\n    {" else ",\n    {");
        first = false;
        const headline = try renderPlain(a, &report.headline, config);
        const body = try renderPlain(a, &report.document, config);
        const message = if (headline.len == 0) body else if (body.len == 0) headline else try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ headline, body });
        const code = punkCode(body) orelse punkCode(headline) orelse
            if (std.mem.eql(u8, report.title, "Syntax Error") and std.mem.endsWith(u8, report.file orelse path, ".punk")) "P001" else try rocCode(a, report.title);
        const severity: []const u8 = if (report.severity.isError()) "error" else "warning";
        try w.writeAll("\n      \"severity\": ");
        try writeString(w, severity);
        try w.writeAll(",\n      \"code\": ");
        try writeString(w, code);
        try w.writeAll(",\n      \"title\": ");
        try writeString(w, report.title);
        const loc = locationOf(&report.headline) orelse locationOf(&report.document);
        try w.writeAll(",\n      \"file\": ");
        const file = if (loc) |l| l.file else report.file;
        if (file) |f| try writeString(w, try reporting.displayPath(a, f, config.source_path_base)) else try w.writeAll("null");
        if (loc) |l| {
            try w.print(",\n      \"line\": {d}, \"column\": {d}, \"endLine\": {d}, \"endColumn\": {d}", .{ l.line, l.column, l.end_line, l.end_column });
        } else {
            try w.writeAll(",\n      \"line\": null, \"column\": null, \"endLine\": null, \"endColumn\": null");
        }
        try w.writeAll(",\n      \"message\": ");
        try writeString(w, message);
        try w.writeAll(",\n      \"fix\": null\n    }");
    };
    try w.writeAll(if (first) "]\n}\n" else "\n  ]\n}\n");
}

test "codes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("P101", punkCode("P101: 'crash' is only ...").?);
    try std.testing.expect(punkCode("Nothing is named x") == null);
    try std.testing.expectEqualStrings("roc/type-mismatch", try rocCode(arena.allocator(), "TYPE MISMATCH"));
    try std.testing.expectEqualStrings("roc/name-not-in-scope", try rocCode(arena.allocator(), "name not in scope"));
}
