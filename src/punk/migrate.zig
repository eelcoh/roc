//! Verified migrations (roadmap B2): the schema of a program is a history of
//! versions in `schema.sql`, next to the program. Each version records the
//! tables as they were (as comments) and holds the SQL that gets the database
//! from the version before to it. The wiring applies each version once, in
//! order, and refuses a version that was changed after it was applied
//! (`Owner::migrate` in platforms/server/postgres).
//!
//! punk compares the tables of the program with the last version:
//!
//! - A new table, a new `Maybe` column and a changed policy are a new version
//!   by themselves.
//! - Any other change of a table (a column added, removed, renamed or of
//!   another type, another key) needs a migration in the program, a function
//!   from a row as it was to a row as it is now:
//!
//!       migrate links
//!           fn old -> { old | owner = "anonymous", createdAt = old.created }
//!
//!   A field that is `old.x` is the column `x`, renamed; another value is
//!   computed in the database for the rows there are (the same expressions
//!   as in a query, without values from outside); a column of the old row
//!   that the new row doesn't take is dropped. `{ old | ... }` keeps the
//!   columns it doesn't name.
//!
//! Without the migration the program doesn't compile (P405), so the database
//! always holds what the program declares. `punk check --schema app.punk`
//! adds the new version to `schema.sql` and says what it does; after that the
//! `migrate` has done its work and goes (P405 again while it is there).

const std = @import("std");
const tr = @import("translate.zig");
const query = @import("query.zig");
const Allocator = std.mem.Allocator;
const Emitter = tr.Emitter;
const Expr = tr.Expr;
const Error = tr.Error;
const ColType = query.ColType;
const Table = query.Table;
const Op = query.Op;

/// `migrate links` and its function, as the parser reads it.
pub const MigrateDecl = struct {
    table: []const u8,
    func: *Expr,
};

/// A table as a version of the schema records it.
const Snap = struct {
    name: []const u8,
    columns: []const SnapCol,
    key: ?[]const u8,
    /// The SQL condition of each policy, null for `nobody`.
    policies: [4]?[]const u8,

    fn column(s: *const Snap, name: []const u8) ?*const SnapCol {
        for (s.columns) |*c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }
};

const SnapCol = struct { name: []const u8, ty: ColType };

/// The versions in a `schema.sql`, and the tables as the last one left them.
const History = struct {
    version: u32,
    tables: []const Snap,
};

pub const header =
    \\-- Made by `punk check --schema` from the tables of the program: one version
    \\-- for each change of the tables. The wiring applies each version once, in
    \\-- order, and refuses a version that changed after it was applied. Change
    \\-- the tables in the program, not this file.
    \\
;

/// What `punk check --schema` gives: the whole new `schema.sql`, whether it
/// differs from the one there was, and what the new version does.
pub const Result = struct {
    sql: []const u8,
    changed: bool,
    report: []const u8,
};

/// The schema of the module's tables, as a history that continues
/// `existing` (the `schema.sql` there is, null when there is none).
pub fn history(e: *Emitter, items: []const tr.Item, existing: ?[]const u8) Error!Result {
    const a = e.a;
    const old = try parseHistory(e, existing orelse "");
    var tables: std.ArrayList(*const Table) = .empty;
    for (items) |item| if (item.kind == .table) try tables.append(a, e.tables.get(item.kind.table.name).?);
    var migrations: std.ArrayList(MigrateDecl) = .empty;
    for (items) |item| if (item.kind == .migrate) {
        const m = item.kind.migrate;
        for (migrations.items) |prev| if (std.mem.eql(u8, prev.table, m.table)) {
            return e.errAtRule(m.table, .migration, try std.fmt.allocPrint(a, "there is already a migration of '{s}'", .{m.table}));
        };
        try migrations.append(a, m);
    };

    var body: std.ArrayList(u8) = .empty;
    var report: std.ArrayList(u8) = .empty;
    const version = old.version + 1;

    // Tables that went away.
    for (old.tables) |snap| {
        if (e.tables.get(snap.name) == null) {
            const at = for (migrations.items) |m| {
                if (std.mem.eql(u8, m.table, snap.name)) break m.table;
            } else "";
            return e.errAtRule(at, .migration, try std.fmt.allocPrint(a, "the table '{s}' of schema.sql version {d} is gone from the program; punk can't remove a table yet, so keep its declaration", .{ snap.name, old.version }));
        }
    }
    for (migrations.items) |m| {
        if (e.tables.get(m.table) == null) {
            return e.errAtRule(m.table, .migration, try std.fmt.allocPrint(a, "'{s}' is not a table of this module", .{m.table}));
        }
    }

    for (tables.items) |t| {
        const snap = findSnap(old.tables, t.decl.name);
        const mig = for (migrations.items) |m| {
            if (std.mem.eql(u8, m.table, t.decl.name)) break m;
        } else null;
        if (snap == null) {
            if (mig) |m| return e.errAtRule(m.table, .migration, try std.fmt.allocPrint(a, "the table '{s}' is new, so it has no rows to migrate: remove the migrate", .{m.table}));
            try query.createSql(a, &body, t);
            try query.securitySql(a, &body, t);
            try report.print(a, "  {s}: new table\n", .{t.decl.name});
            continue;
        }
        try tableChange(e, t, snap.?, mig, &body, &report);
    }

    if (body.items.len == 0) {
        return .{ .sql = existing orelse "", .changed = false, .report = "" };
    }

    var out: std.ArrayList(u8) = .empty;
    if (existing) |text| {
        if (text.len > 0) {
            try out.appendSlice(a, text);
            if (text[text.len - 1] != '\n') try out.append(a, '\n');
        } else try out.appendSlice(a, header);
    } else try out.appendSlice(a, header);
    try out.print(a, "\n-- punk version {d}\n", .{version});
    for (tables.items) |t| try snapshotLines(a, &out, t);
    try out.appendSlice(a, body.items);
    return .{
        .sql = out.items,
        .changed = true,
        .report = try std.fmt.allocPrint(a, "version {d}:\n{s}", .{ version, report.items }),
    };
}

/// The error for a module whose tables differ from its `schema.sql`, or
/// that still has a migration that has been done. `existing` is null when
/// there is no `schema.sql`.
pub fn check(e: *Emitter, items: []const tr.Item, existing: ?[]const u8) Error!void {
    const a = e.a;
    var has_tables = false;
    for (items) |item| if (item.kind == .table) {
        has_tables = true;
    };
    if (!has_tables) {
        for (items) |item| if (item.kind == .migrate) {
            return e.errAtRule(item.kind.migrate.table, .migration, try std.fmt.allocPrint(a, "'{s}' is not a table of this module", .{item.kind.migrate.table}));
        };
        return;
    }
    const first = for (items) |item| {
        if (item.kind == .table) break item.kind.table.name;
    } else unreachable;
    if (existing == null) {
        return e.errAtRule(first, .migration, "this program's tables have no schema.sql next to it yet: run 'punk check --schema' on this file, which writes it");
    }
    const result = try history(e, items, existing);
    if (result.changed) {
        const at = for (items) |item| {
            if (item.kind == .migrate) break item.kind.migrate.table;
        } else first;
        return e.errAtRule(at, .migration, try std.fmt.allocPrint(a, "the tables differ from schema.sql: run 'punk check --schema' on this file, which adds this version:\n{s}", .{result.report}));
    }
    // Up to date: a migrate still there has been done.
    for (items) |item| if (item.kind == .migrate) {
        return e.errAtRule(item.kind.migrate.table, .migration, try std.fmt.allocPrint(a, "the migration of '{s}' is in schema.sql already: remove the migrate", .{item.kind.migrate.table}));
    };
}

fn findSnap(snaps: []const Snap, name: []const u8) ?*const Snap {
    for (snaps) |*s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

// The history in schema.sql

/// Reads the versions of `text`: the number of the last one, and the tables
/// it records (`-- table links : id Str key, url Str` and `-- policy links
/// read true`).
fn parseHistory(e: *Emitter, text: []const u8) Error!History {
    const a = e.a;
    var version: u32 = 0;
    var tables: std.ArrayList(Snap) = .empty;
    var cols: std.ArrayList(std.ArrayList(SnapCol)) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "-- punk version ")) {
            version = std.fmt.parseInt(u32, line["-- punk version ".len..], 10) catch return badHistory(e, line);
            tables.clearRetainingCapacity();
            cols.clearRetainingCapacity();
        } else if (std.mem.startsWith(u8, line, "-- table ")) {
            const rest = line["-- table ".len..];
            const colon = std.mem.find(u8, rest, " : ") orelse return badHistory(e, line);
            var snap: Snap = .{ .name = rest[0..colon], .columns = &.{}, .key = null, .policies = .{ null, null, null, null } };
            var list: std.ArrayList(SnapCol) = .empty;
            var parts = std.mem.splitSequence(u8, rest[colon + 3 ..], ", ");
            while (parts.next()) |part| {
                var words = std.mem.tokenizeScalar(u8, part, ' ');
                const name = words.next() orelse return badHistory(e, line);
                var w = words.next() orelse return badHistory(e, line);
                var ty: ColType = .{ .base = .str };
                if (std.mem.eql(u8, w, "Maybe")) {
                    ty.nullable = true;
                    w = words.next() orelse return badHistory(e, line);
                }
                ty.base = baseOf(w) orelse return badHistory(e, line);
                if (words.next()) |k| {
                    if (!std.mem.eql(u8, k, "key")) return badHistory(e, line);
                    snap.key = name;
                }
                try list.append(a, .{ .name = name, .ty = ty });
            }
            snap.columns = list.items;
            try tables.append(a, snap);
        } else if (std.mem.startsWith(u8, line, "-- policy ")) {
            var words = std.mem.tokenizeScalar(u8, line["-- policy ".len..], ' ');
            const name = words.next() orelse return badHistory(e, line);
            const verb = words.next() orelse return badHistory(e, line);
            const op = std.meta.stringToEnum(Op, verb) orelse return badHistory(e, line);
            const cond = std.mem.trim(u8, words.rest(), " ");
            const snap = for (tables.items) |*s| {
                if (std.mem.eql(u8, s.name, name)) break s;
            } else return badHistory(e, line);
            snap.policies[@intFromEnum(op)] = if (std.mem.eql(u8, cond, "-")) null else cond;
        }
    }
    return .{ .version = version, .tables = tables.items };
}

fn badHistory(e: *Emitter, line: []const u8) Error {
    return e.errAtRule("", .migration, try std.fmt.allocPrint(e.a, "schema.sql has a line punk doesn't understand: '{s}'. It is made by 'punk check --schema'; don't edit it by hand", .{line}));
}

fn baseOf(n: []const u8) ?ColType.Base {
    if (std.mem.eql(u8, n, "Str")) return .str;
    if (std.mem.eql(u8, n, "Int")) return .int;
    if (std.mem.eql(u8, n, "Float")) return .float;
    if (std.mem.eql(u8, n, "Bool")) return .bool;
    return null;
}

fn snapshotLines(a: Allocator, out: *std.ArrayList(u8), t: *const Table) Allocator.Error!void {
    try out.print(a, "-- table {s} : ", .{t.decl.name});
    for (t.columns, 0..) |c, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.print(a, "{s} {s}", .{ c.name, try c.ty.name(a) });
        if (t.key != null and t.key.? == i) try out.appendSlice(a, " key");
    }
    try out.append(a, '\n');
    for (t.access, 0..) |access, i| {
        const op: Op = @enumFromInt(i);
        try out.print(a, "-- policy {s} {s} {s}\n", .{ t.decl.name, op.verb(), query.policyCond(access) orelse "-" });
    }
}

// The change of one table

/// What the new version does to a table that the last version has.
fn tableChange(e: *Emitter, t: *const Table, snap: *const Snap, mig: ?MigrateDecl, body: *std.ArrayList(u8), report: *std.ArrayList(u8)) Error!void {
    const a = e.a;
    var policies_same = true;
    for (t.access, 0..) |access, i| {
        const now = query.policyCond(access);
        const then = snap.policies[i];
        if ((now == null) != (then == null) or (now != null and !std.mem.eql(u8, now.?, then.?))) policies_same = false;
    }
    const key_now: ?[]const u8 = if (t.key) |k| t.columns[k].name else null;
    const columns_same = blk: {
        if (t.columns.len != snap.columns.len) break :blk false;
        if (!optEql(key_now, snap.key)) break :blk false;
        for (t.columns) |c| {
            const old = snap.column(c.name) orelse break :blk false;
            if (!old.ty.eql(c.ty)) break :blk false;
        }
        break :blk true;
    };
    if (columns_same and mig == null) {
        if (policies_same) return;
        try dropPolicies(a, body, t);
        try query.policiesSql(a, body, t);
        try report.print(a, "  {s}: new policies\n", .{t.decl.name});
        return;
    }
    if (columns_same) {
        return e.errAtRule(mig.?.table, .migration, try std.fmt.allocPrint(a, "the columns of '{s}' are what schema.sql says already: remove the migrate", .{t.decl.name}));
    }

    // Only new Maybe columns: they are NULL for the rows there are.
    const only_added = mig == null and optEql(key_now, snap.key) and blk: {
        for (snap.columns) |old| {
            const c = t.column(old.name) orelse break :blk false;
            if (!c.ty.eql(old.ty)) break :blk false;
        }
        for (t.columns) |c| if (snap.column(c.name) == null and !c.ty.nullable) break :blk false;
        break :blk true;
    };
    var plan: Plan = .{ .e = e, .t = t, .snap = snap };
    if (only_added) {
        for (t.columns) |*c| if (snap.column(c.name) == null) try plan.steps.append(a, .{ .column = c, .how = .empty });
        for (snap.columns) |old| try plan.steps.append(a, .{ .column = t.column(old.name).?, .how = .{ .keep = old.name } });
    } else {
        const m = mig orelse return e.errAtRule(t.decl.name, .migration, try std.fmt.allocPrint(a, "the table '{s}' changed since the last version in schema.sql ({s}), so its rows need a migration: a function from a row as it was to a row as it is now, as in\n\n    migrate {s}\n        fn old -> {{ old | ... }}\n", .{ t.decl.name, try describeChange(a, t, snap), t.decl.name }));
        try plan.fromMigration(m);
    }
    try plan.write(body, report);
}

fn optEql(x: ?[]const u8, y: ?[]const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    return std.mem.eql(u8, x.?, y.?);
}

/// What changed in a table, for an error: "owner added, note removed".
fn describeChange(a: Allocator, t: *const Table, snap: *const Snap) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (t.columns) |c| {
        if (snap.column(c.name)) |old| {
            if (!old.ty.eql(c.ty)) try sep(a, &out, try std.fmt.allocPrint(a, "{s} is {s}, was {s}", .{ c.name, try c.ty.an(a), try old.ty.an(a) }));
        } else try sep(a, &out, try std.fmt.allocPrint(a, "{s} added", .{c.name}));
    }
    for (snap.columns) |old| if (t.column(old.name) == null) try sep(a, &out, try std.fmt.allocPrint(a, "{s} removed", .{old.name}));
    const key_now: ?[]const u8 = if (t.key) |k| t.columns[k].name else null;
    if (!optEql(key_now, snap.key)) try sep(a, &out, try std.fmt.allocPrint(a, "the key is {s}, was {s}", .{ key_now orelse "none", snap.key orelse "none" }));
    return out.items;
}

fn sep(a: Allocator, out: *std.ArrayList(u8), s: []const u8) Allocator.Error!void {
    if (out.items.len > 0) try out.appendSlice(a, ", ");
    try out.appendSlice(a, s);
}

fn dropPolicies(a: Allocator, body: *std.ArrayList(u8), t: *const Table) Allocator.Error!void {
    for (0..4) |i| {
        const op: Op = @enumFromInt(i);
        try body.print(a, "DROP POLICY IF EXISTS {s} ON {s};\n", .{ try query.policyName(a, t.plain(), op), t.sql });
    }
}

/// How each column of the new row gets its values.
const Plan = struct {
    e: *Emitter,
    t: *const Table,
    snap: *const Snap,
    steps: std.ArrayList(Step) = .empty,

    const Step = struct {
        column: *const query.Column,
        how: union(enum) {
            /// The old column of this name, under the column's name.
            keep: []const u8,
            /// NULL for the rows there are.
            empty,
            /// This SQL, over the old columns, for the rows there are.
            computed: struct { sql: []const u8 },
        },
    };

    /// The plan a `migrate` function gives.
    fn fromMigration(plan: *Plan, m: MigrateDecl) Error!void {
        const e = plan.e;
        const a = e.a;
        const t = plan.t;
        const lam = blk: {
            const x = query.unparen(m.func);
            if (x.* != .lambda or x.lambda.params.len != 1 or x.lambda.body.stmts.len > 0 or x.lambda.body.result == null) break :blk null;
            break :blk x.lambda;
        } orelse return e.errAtRule(m.table, .migration, try std.fmt.allocPrint(a, "a migration is a function of the old row that gives the new one: migrate {s}\n    fn old -> {{ old | ... }}", .{m.table}));
        const row: ?[]const u8 = switch (lam.params[0].*) {
            .ident => |n| n,
            .underscore => null,
            else => return e.errAtRule(m.table, .migration, "the function of a migration takes the old row as a name, as in (fn old -> ...)"),
        };
        const body = query.unparen(lam.body.result.?);
        if (body.* != .record) {
            return e.errAtRule(query.exprText(body) orelse m.table, .migration, try std.fmt.allocPrint(a, "a migration gives the new row as a record: fn old -> {{ old | ... }} or {{ {s} }}", .{try columnList(a, t)}));
        }
        const rec = body.record;
        const keeps_rest = if (rec.base) |b| blk: {
            const base = query.unparen(b);
            if (row == null or base.* != .ident or !std.mem.eql(u8, base.ident, row.?)) {
                return e.errAtRule(query.exprText(b) orelse m.table, .migration, "in a migration, { old | ... } starts from the old row");
            }
            break :blk true;
        } else false;
        for (rec.fields) |f| if (t.column(f.name) == null) {
            return e.errAtRule(f.name, .migration, try std.fmt.allocPrint(a, "the table '{s}' has no column '{s}' now (it has {s})", .{ t.decl.name, f.name, try columnList(a, t) }));
        };

        // The old columns that are renamed: `createdAt = old.created`.
        var renamed: std.ArrayList([]const u8) = .empty;
        for (t.columns) |*c| {
            const field = for (rec.fields) |f| {
                if (std.mem.eql(u8, f.name, c.name)) break f;
            } else null;
            if (field) |f| {
                const value = f.value orelse return e.errAtRule(f.name, .migration, try std.fmt.allocPrint(a, "write what '{s}' is for the rows there are: {{ {s} = ... }}", .{ f.name, f.name }));
                if (plan.oldColumn(value, row)) |old| {
                    const free = std.mem.eql(u8, old.name, c.name) or plan.t.column(old.name) == null;
                    if (fits(old.ty, c.ty) and free) {
                        if (!contains(renamed.items, old.name)) {
                            try renamed.append(a, old.name);
                            try plan.steps.append(a, .{ .column = c, .how = .{ .keep = old.name } });
                            continue;
                        }
                    }
                }
                if (query.isNothing(value)) {
                    if (!c.ty.nullable) return e.errAtRule(query.exprText(value) orelse f.name, .query_type, try std.fmt.allocPrint(a, "'{s}' is {s}, so it can't be Nothing", .{ c.name, try c.ty.an(a) }));
                    try plan.steps.append(a, .{ .column = c, .how = .empty });
                    continue;
                }
                try plan.steps.append(a, .{ .column = c, .how = .{ .computed = .{ .sql = try plan.compute(value, row, c) } } });
                continue;
            }
            if (keeps_rest) if (plan.snap.column(c.name)) |old| {
                if (!fits(old.ty, c.ty)) {
                    return e.errAtRule(m.table, .migration, try std.fmt.allocPrint(a, "'{s}' is {s} now and was {s}: write what it becomes, {{ old | {s} = ... }}", .{ c.name, try c.ty.an(a), try old.ty.an(a), c.name }));
                }
                if (contains(renamed.items, old.name)) {
                    return e.errAtRule(m.table, .migration, try std.fmt.allocPrint(a, "the old '{s}' is renamed, so the migration says what '{s}' is now: {{ old | {s} = ... }}", .{ old.name, c.name, c.name }));
                }
                try renamed.append(a, old.name);
                try plan.steps.append(a, .{ .column = c, .how = .{ .keep = old.name } });
                continue;
            };
            return e.errAtRule(m.table, .migration, try std.fmt.allocPrint(a, "the migration of '{s}' doesn't say what '{s}' is for the rows there are: fn old -> {{ old | {s} = ... }}", .{ t.decl.name, c.name, c.name }));
        }
    }

    /// The old column `value` is (`old.created`), if it is one.
    fn oldColumn(plan: *Plan, value: *Expr, row: ?[]const u8) ?*const SnapCol {
        const v = query.unparen(value);
        if (v.* != .field or row == null) return null;
        const target = query.unparen(v.field.target);
        if (target.* != .ident or !std.mem.eql(u8, target.ident, row.?)) return null;
        return plan.snap.column(v.field.name);
    }

    /// The SQL of a value over the old row, of the column's type.
    fn compute(plan: *Plan, value: *Expr, row: ?[]const u8, c: *const query.Column) Error![]const u8 {
        const e = plan.e;
        const a = e.a;
        const old_table = try plan.oldTable();
        var sql: std.ArrayList(u8) = .empty;
        var params: std.ArrayList(query.Param) = .empty;
        var q: query.Sql = .{ .e = e, .table = old_table, .row = row, .out = &sql, .params = &params, .policy = true, .what = "a migration" };
        const ty = try q.expr(value, c.ty, 0);
        if (!fits(ty, c.ty)) {
            return e.errAtRule(query.exprText(value) orelse c.name, .query_type, try std.fmt.allocPrint(a, "'{s}' is {s}, but this gives {s}", .{ c.name, try c.ty.an(a), try ty.an(a) }));
        }
        return sql.items;
    }

    /// The table as the last version left it, for the SQL of a migration.
    fn oldTable(plan: *Plan) Error!*const Table {
        const a = plan.e.a;
        var cols: std.ArrayList(query.Column) = .empty;
        var key: ?usize = null;
        for (plan.snap.columns, 0..) |c, i| {
            const plain = try tr.snake(a, c.name);
            try cols.append(a, .{ .name = c.name, .sql = try query.sqlIdent(a, plain), .plain = plain, .ty = c.ty });
            if (plan.snap.key != null and std.mem.eql(u8, plan.snap.key.?, c.name)) key = i;
        }
        const t = try a.create(Table);
        t.* = plan.t.*;
        t.columns = cols.items;
        t.key = key;
        return t;
    }

    fn write(plan: *Plan, body: *std.ArrayList(u8), report: *std.ArrayList(u8)) Error!void {
        const a = plan.e.a;
        const t = plan.t;
        const snap = plan.snap;
        const old_table = try plan.oldTable();
        try dropPolicies(a, body, t);
        // The owner of the table changes every row, whatever the policies say.
        try body.print(a, "ALTER TABLE {s} NO FORCE ROW LEVEL SECURITY;\n", .{t.sql});
        const key_now: ?[]const u8 = if (t.key) |k| t.columns[k].name else null;
        const key_renamed = blk: {
            for (plan.steps.items) |s| if (s.how == .keep and snap.key != null and std.mem.eql(u8, s.how.keep, snap.key.?)) {
                break :blk key_now != null and std.mem.eql(u8, s.column.name, key_now.?);
            };
            break :blk false;
        };
        const key_changes = !key_renamed and !(snap.key == null and key_now == null);
        if (key_changes and snap.key != null) try body.print(a, "ALTER TABLE {s} DROP CONSTRAINT IF EXISTS {s};\n", .{ t.sql, try query.sqlIdent(a, try std.fmt.allocPrint(a, "{s}_pkey", .{t.plain()})) });

        // New columns first, under a name of their own while an old column
        // still has theirs, then their values, from the old columns.
        var updates: std.ArrayList(u8) = .empty;
        for (plan.steps.items) |s| switch (s.how) {
            .keep => {},
            .empty, .computed => {
                const name = try plan.newName(s.column, old_table);
                try body.print(a, "ALTER TABLE {s} ADD COLUMN {s} {s};\n", .{ t.sql, name, query.sqlType(s.column.ty) });
                if (s.how == .computed) {
                    if (updates.items.len > 0) try updates.appendSlice(a, ", ");
                    try updates.print(a, "{s} = {s}", .{ name, s.how.computed.sql });
                    try report.print(a, "  {s}: {s} added, {s} for the rows there are\n", .{ t.decl.name, s.column.name, s.how.computed.sql });
                } else try report.print(a, "  {s}: {s} added, Nothing for the rows there are\n", .{ t.decl.name, s.column.name });
            },
        };
        if (updates.items.len > 0) try body.print(a, "UPDATE {s} SET {s};\n", .{ t.sql, updates.items });
        // Old columns the new row doesn't take.
        for (old_table.columns) |old| {
            const kept = for (plan.steps.items) |s| {
                if (s.how == .keep and std.mem.eql(u8, s.how.keep, old.name)) break true;
            } else false;
            if (!kept) {
                try body.print(a, "ALTER TABLE {s} DROP COLUMN {s};\n", .{ t.sql, old.sql });
                try report.print(a, "  {s}: {s} removed, its values are gone\n", .{ t.decl.name, old.name });
            }
        }
        // Renames, then the new columns get their names.
        for (plan.steps.items) |s| switch (s.how) {
            .keep => |from| if (!std.mem.eql(u8, from, s.column.name)) {
                const old = old_table.column(from).?;
                if (!std.mem.eql(u8, old.sql, s.column.sql)) try body.print(a, "ALTER TABLE {s} RENAME COLUMN {s} TO {s};\n", .{ t.sql, old.sql, s.column.sql });
                try report.print(a, "  {s}: {s} renamed to {s}\n", .{ t.decl.name, from, s.column.name });
            },
            else => {},
        };
        for (plan.steps.items) |s| switch (s.how) {
            .keep => {},
            else => {
                const name = try plan.newName(s.column, old_table);
                if (!std.mem.eql(u8, name, s.column.sql)) try body.print(a, "ALTER TABLE {s} RENAME COLUMN {s} TO {s};\n", .{ t.sql, name, s.column.sql });
            },
        };
        // NOT NULL as the new row says.
        for (plan.steps.items) |s| {
            const was_nullable = switch (s.how) {
                .keep => |from| old_table.column(from).?.ty.nullable,
                else => true,
            };
            const is_key = key_now != null and std.mem.eql(u8, s.column.name, key_now.?);
            if (was_nullable and !s.column.ty.nullable and !is_key) {
                try body.print(a, "ALTER TABLE {s} ALTER COLUMN {s} SET NOT NULL;\n", .{ t.sql, s.column.sql });
            } else if (!was_nullable and s.column.ty.nullable) {
                try body.print(a, "ALTER TABLE {s} ALTER COLUMN {s} DROP NOT NULL;\n", .{ t.sql, s.column.sql });
            }
        }
        if (key_changes) if (t.key) |k| {
            try body.print(a, "ALTER TABLE {s} ADD PRIMARY KEY ({s});\n", .{ t.sql, t.columns[k].sql });
            try report.print(a, "  {s}: the key is {s}\n", .{ t.decl.name, t.columns[k].name });
        };
        try body.print(a, "ALTER TABLE {s} FORCE ROW LEVEL SECURITY;\n", .{t.sql});
        try query.policiesSql(a, body, t);
    }

    /// The name a new column has while the old columns are there.
    fn newName(plan: *Plan, c: *const query.Column, old_table: *const Table) Error![]const u8 {
        for (old_table.columns) |old| if (std.mem.eql(u8, old.plain, c.plain)) {
            return query.sqlIdent(plan.e.a, try std.fmt.allocPrint(plan.e.a, "{s}_punk_new", .{c.plain}));
        };
        return c.sql;
    }
};

/// A value of type `got` can go in a column of type `want`.
fn fits(got: ColType, want: ColType) bool {
    if (got.base != want.base) return false;
    return want.nullable or !got.nullable;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn columnList(a: Allocator, t: *const Table) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (t.columns, 0..) |c, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, c.name);
    }
    return out.items;
}
