//! punkroc: the compiler reports errors in the Roc translation of a `.punk`
//! file. This turns the positions and source lines in such a report into the
//! ones of the `.punk` file the programmer wrote.

const std = @import("std");
const punk = @import("punk");
const reporting = @import("reporting");
const vfs = @import("vfs.zig");

const Allocator = std.mem.Allocator;
const Report = reporting.Report;
const Document = reporting.Document;
const DocumentElement = reporting.DocumentElement;

/// The build's hook for every report it emits (`OrderedSink.rewrite`).
/// A failure to read a `.punk` file that did not translate becomes the
/// report of its syntax error; any other report about a `.punk` file points
/// at that file instead of its Roc translation.
pub fn rewrite(report: *Report) Allocator.Error!void {
    if (try syntaxReportFor(report)) |replacement| {
        report.deinit();
        report.* = replacement;
        return;
    }
    try remapReport(report);
}

/// Rewrites every source region and location in `report` that is in a
/// translated `.punk` file to point at the `.punk` source instead.
pub fn remapReport(report: *Report) Allocator.Error!void {
    if (report.file) |f| if (vfs.virtualPunk(f)) |p| {
        report.file = try report.addOwnedString(p);
    };
    const about_punk = mentionsPunk(&report.headline) or mentionsPunk(&report.document) or
        (if (report.file) |f| isPunk(f) != null else false);
    if (!about_punk) return;
    try remapDocument(&report.headline);
    try remapDocument(&report.document);
}

/// When `report` is the build failing to read a `.punk` file (or a virtual
/// `.roc` path for one) because it has a syntax error, the report of that
/// syntax error.
fn syntaxReportFor(report: *const Report) Allocator.Error!?Report {
    const read_failure = std.mem.eql(u8, report.title, "Could Not Read File") or
        std.mem.eql(u8, report.title, "Parsing Failed");
    if (!read_failure) return null;
    for (report.headline.elements.items) |el| switch (el) {
        .annotated => |a| if (a.annotation == .path) {
            const path = vfs.virtualPunk(a.content) orelse a.content;
            if (!punk.isPunkPath(path)) continue;
            return try syntaxReport(report.allocator, path);
        },
        else => {},
    };
    return null;
}

/// The report for a syntax error in the `.punk` file `path`, when that is
/// why reading it failed. The translator finds these, not the Roc parser;
/// the report shows the line of the `.punk` file.
pub fn syntaxReport(gpa: Allocator, path: []const u8) Allocator.Error!?Report {
    const full = (try punk.syntaxError(gpa, path)) orelse return null;
    defer gpa.free(full);
    // `full` is `path:line:col: message`.
    const rest = if (std.mem.startsWith(u8, full, path)) full[path.len..] else full;
    const split = std.mem.find(u8, rest, ": ") orelse rest.len;
    const message = if (split + 2 <= rest.len) rest[split + 2 ..] else "";
    var position = std.mem.splitScalar(u8, rest[0..split], ':');
    _ = position.next();
    const line = position.next() orelse "?";
    const col = position.next() orelse "?";
    var report = try Report.initWithPath(gpa, "Syntax Error", "There is a syntax error in ", path, ".", .fatal);
    errdefer report.deinit();
    try report.document.addReflowingText(message);
    try addSyntaxErrorSource(&report, path, line, col);
    return report;
}

fn mentionsPunk(doc: *const Document) bool {
    for (doc.elements.items) |el| if (elementMentionsPunk(el)) return true;
    return false;
}

fn elementMentionsPunk(el: DocumentElement) bool {
    return switch (el) {
        .vertical_stack, .horizontal_concat => |children| for (children) |c| {
            if (elementMentionsPunk(c)) break true;
        } else false,
        .source_code_region => |r| isPunk(r.filename) != null,
        .source_code_with_underlines => |sw| isPunk(sw.display_region.filename) != null,
        .source_code_multi_region => |mr| isPunk(mr.filename) != null,
        .source_location => |loc| isPunk(loc.filename) != null,
        else => false,
    };
}

fn remapDocument(doc: *Document) Allocator.Error!void {
    for (doc.elements.items) |*el| try remapElement(doc, el);
}

fn isPunk(filename: ?[]const u8) ?[]const u8 {
    const name = filename orelse return null;
    const f = vfs.virtualPunk(name) orelse name;
    if (!punk.isPunkPath(f) or !punk.hasSourceMap(f)) return null;
    return f;
}

fn remapElement(doc: *Document, el: *DocumentElement) Allocator.Error!void {
    switch (el.*) {
        .vertical_stack, .horizontal_concat => |children| for (children) |*c| try remapElement(doc, c),
        .source_code_region => |*r| {
            const path = isPunk(r.filename) orelse return;
            const m = (try remapOwned(doc, path, r.start_line, r.start_column, r.end_line, r.end_column)) orelse return;
            r.* = .{
                .line_text = m.lines,
                .start_line = m.start.line,
                .start_column = m.start.column,
                .end_line = m.end.line,
                .end_column = m.end.column,
                .region_annotation = r.region_annotation,
                .filename = path,
            };
        },
        .source_code_with_underlines => |*sw| {
            const path = isPunk(sw.display_region.filename) orelse return;
            var start_line: u32 = std.math.maxInt(u32);
            var end_line: u32 = 0;
            for (sw.underline_regions) |*u| {
                const m = (try remapOwned(doc, path, u.start_line, u.start_column, u.end_line, u.end_column)) orelse return;
                u.* = .{ .start_line = m.start.line, .start_column = m.start.column, .end_line = m.end.line, .end_column = m.end.column, .annotation = u.annotation };
                start_line = @min(start_line, m.start.line);
                end_line = @max(end_line, m.end.line);
            }
            const d = &sw.display_region;
            const m = (try remapOwned(doc, path, d.start_line, d.start_column, d.end_line, d.end_column)) orelse return;
            // Show every line an underline is on, and only whole lines.
            const first = @min(start_line, m.start.line);
            const last = @max(end_line, m.end.line);
            const lines = (try linesOf(doc, path, first, last)) orelse m.lines;
            d.* = .{
                .line_text = lines,
                .start_line = first,
                .start_column = 1,
                .end_line = last,
                .end_column = 1,
                .region_annotation = d.region_annotation,
                .filename = path,
            };
        },
        .source_code_multi_region => |*mr| {
            const path = isPunk(mr.filename) orelse return;
            var last: u32 = 1;
            for (mr.regions) |*r| {
                const m = (try remapOwned(doc, path, r.start_line, r.start_column, r.end_line, r.end_column)) orelse return;
                r.* = .{ .start_line = m.start.line, .start_column = m.start.column, .end_line = m.end.line, .end_column = m.end.column, .annotation = r.annotation };
                last = @max(last, m.end.line);
            }
            // The renderer slices the regions' lines out of `source`.
            mr.source = (try linesOf(doc, path, 1, std.math.maxInt(u32))) orelse return;
            mr.filename = path;
        },
        .source_location => |*loc| {
            const path = isPunk(loc.filename) orelse return;
            const m = (try remapOwned(doc, path, loc.line, loc.column, loc.line, loc.column)) orelse return;
            loc.line = m.start.line;
            loc.column = m.start.column;
            loc.filename = path;
        },
        // Names in the message as the programmer wrote them.
        .text => |t| if (try camel(doc, t)) |c| {
            el.* = .{ .text = c };
        },
        .reflowing_text => |t| if (try camel(doc, t)) |c| {
            el.* = .{ .reflowing_text = c };
        },
        .raw => |t| if (try camel(doc, t)) |c| {
            el.* = .{ .raw = c };
        },
        .annotated => |a| if (a.annotation == .path) {
            if (vfs.virtualPunk(a.content)) |p| el.* = .{ .annotated = .{ .content = p, .annotation = a.annotation } };
        } else if (try camel(doc, a.content)) |c| {
            el.* = .{ .annotated = .{ .content = c, .annotation = a.annotation } };
        },
        else => {},
    }
}

fn camel(doc: *Document, text: []const u8) Allocator.Error!?[]const u8 {
    const c = (try punk.camelText(doc.allocator, text)) orelse return null;
    defer doc.allocator.free(c);
    return try doc.ownString(c);
}

fn remapOwned(doc: *Document, path: []const u8, sl: u32, sc: u32, el: u32, ec: u32) Allocator.Error!?punk.SourceRegion {
    const m = (try punk.remap(doc.allocator, path, .{ .line = sl, .column = sc }, .{ .line = el, .column = ec })) orelse return null;
    defer doc.allocator.free(m.lines);
    return .{ .start = m.start, .end = m.end, .lines = @constCast(try doc.ownString(m.lines)) };
}

/// The lines `first` to `last` of the `.punk` file `path`, owned by `doc`.
fn linesOf(doc: *Document, path: []const u8, first: u32, last: u32) Allocator.Error!?[]u8 {
    const text = (try punk.sourceLines(doc.allocator, path, first, last)) orelse return null;
    defer doc.allocator.free(text);
    return @constCast(try doc.ownString(text));
}

/// Shows the line of a punkroc syntax error at `line`:`col` (as text, from
/// the translator's message) below the message, with the place underlined.
pub fn addSyntaxErrorSource(report: *Report, path: []const u8, line: []const u8, col: []const u8) Allocator.Error!void {
    var l = std.fmt.parseInt(u32, line, 10) catch return;
    var c = std.fmt.parseInt(u32, col, 10) catch return;
    const doc = &report.document;
    var text = (try linesOf(doc, path, l, l)) orelse return;
    // At the end of the file, point just after the last code instead.
    while (std.mem.trim(u8, text, " \t\r").len == 0 and l > 1) {
        l -= 1;
        text = (try linesOf(doc, path, l, l)) orelse return;
        c = @intCast(std.mem.trimEnd(u8, text, " \t\r").len + 1);
    }
    const shown_line = l;
    try doc.addLineBreak();
    try doc.addLineBreak();
    try doc.addSourceCodeWithUnderlines(.{
        .line_text = text,
        .start_line = shown_line,
        .start_column = 1,
        .end_line = shown_line,
        .end_column = 1,
        .region_annotation = .error_highlight,
        .filename = path,
    }, &.{.{ .start_line = shown_line, .start_column = c, .end_line = shown_line, .end_column = c + 1, .annotation = .error_highlight }});
}
