//! punkroc's query language (roadmap B1): tables declared in punk, and
//! queries on them written as pipelines that compile to one SQL statement.
//!
//!     table links : Link
//!         key id
//!         read everyone
//!         insert everyone
//!         update nobody
//!         delete nobody
//!
//!     findLink : Str -> Db.Query (Maybe Link)
//!     findLink = fn id ->
//!         links
//!             |> Db.filter (fn link -> link.id == id)
//!             |> Db.first
//!
//! The translator sees the whole pipeline, so it writes the SQL
//! (`SELECT id, url, created FROM links WHERE id = $1 LIMIT 1`), the values
//! that go in as parameters (`Db.param_text(id)`) and a decoder for the
//! rows, and gives them to the platform's `Db` module (platforms/server/Db.roc).
//! What can't run in the database, a column the table doesn't have, a value
//! of the wrong type and an operation the table's policy forbids are errors
//! with a rule code (P401..P404, see rules.zig). The parameters are typed by
//! the column they meet (`Db.param_text`), so Roc's type checker catches a
//! variable of the wrong type.

const std = @import("std");
const tr = @import("translate.zig");
const Allocator = std.mem.Allocator;
const Emitter = tr.Emitter;
const Expr = tr.Expr;
const Block = tr.Block;
const Error = tr.Error;

/// A table as the parser reads it: `table links : Link` and its lines.
pub const TableDecl = struct {
    name: []const u8,
    row_type: []const u8,
    lines: []const Line,

    /// `key id`, `read everyone`, `read fn user, link -> ...` (then
    /// `policy` is the function and `arg` is "fn").
    pub const Line = struct { word: []const u8, arg: []const u8, policy: ?*Expr = null };
};

/// The type of a column: Str, Int, Float or Bool, or `Maybe` of one of
/// these for a column that can be NULL.
pub const ColType = struct {
    base: Base,
    nullable: bool = false,

    pub const Base = enum { str, int, float, bool };

    pub fn eql(a: ColType, b: ColType) bool {
        return a.base == b.base and a.nullable == b.nullable;
    }

    pub fn name(t: ColType, a: Allocator) Allocator.Error![]const u8 {
        const base = switch (t.base) {
            .str => "Str",
            .int => "Int",
            .float => "Float",
            .bool => "Bool",
        };
        return if (t.nullable) std.fmt.allocPrint(a, "Maybe {s}", .{base}) else base;
    }

    /// The type's name after "a" or "an": "an Int", "a Maybe Str".
    pub fn an(t: ColType, a: Allocator) Allocator.Error![]const u8 {
        const n = try t.name(a);
        return std.fmt.allocPrint(a, "{s} {s}", .{ if (n[0] == 'I') "an" else "a", n });
    }
};

pub const Column = struct {
    /// The field of the row type, as punk writes it (`createdAt`).
    name: []const u8,
    /// Its name in SQL (`created_at`, or `"user"` when it is a keyword).
    sql: []const u8,
    /// Its name as Postgres gives it back, without quotes.
    plain: []const u8,
    ty: ColType,
};

/// Who may do an operation on a table: everyone, nobody, or the users for
/// whom a function of the user and the row is true. Each becomes a
/// row-level security policy in Postgres (`securitySql`), so the database
/// itself keeps to it, also for SQL that doesn't come from a query.
pub const Access = union(enum) {
    everyone,
    nobody,
    /// `fn user, link -> link.owner == user.id`, as the SQL of the policy.
    rule: []const u8,
};

/// A field of the user that a policy looks at (`user.id`): the app gives it
/// with `Db.runAs! user query`, and the policy reads it from the setting
/// `punk.user_<field>` of the transaction.
pub const UserField = struct {
    name: []const u8,
    setting: []const u8,
    ty: ColType,
};

pub const Op = enum {
    read,
    insert,
    update,
    delete,

    pub fn verb(op: Op) []const u8 {
        return switch (op) {
            .read => "read",
            .insert => "insert",
            .update => "update",
            .delete => "delete",
        };
    }
};

/// A table whose row type and policy have been checked.
pub const Table = struct {
    decl: TableDecl,
    sql: []const u8,
    columns: []const Column,
    key: ?usize,
    access: [4]Access,

    /// The table's name in SQL without quotes (`links`).
    pub fn plain(t: *const Table) []const u8 {
        return if (t.sql[0] == '"') t.sql[1 .. t.sql.len - 1] else t.sql;
    }

    pub fn column(t: *const Table, name: []const u8) ?*const Column {
        for (t.columns) |*c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }

    fn columnNames(t: *const Table, a: Allocator) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (t.columns, 0..) |c, i| {
            if (i > 0) try out.appendSlice(a, ", ");
            try out.appendSlice(a, c.name);
        }
        return out.items;
    }
};

// Tables

/// Checks the table declarations of a module against its type aliases and
/// adds them to `e.tables`.
pub fn resolveTables(e: *Emitter, items: []const tr.Item) Error!void {
    for (items) |item| {
        if (item.kind != .table) continue;
        const decl = item.kind.table;
        if (e.tables.contains(decl.name)) {
            return e.errAtRule(decl.name, .table_decl, try std.fmt.allocPrint(e.a, "there is already a table '{s}'", .{decl.name}));
        }
        const table = try resolveTable(e, items, decl);
        try e.tables.put(e.a, decl.name, table);
    }
    // A table's name is not a value: it only starts a query.
    for (items) |item| switch (item.kind) {
        .def => |d| if (d.pat.* == .ident) if (e.tables.contains(d.pat.ident)) {
            return e.errAtRule(d.pat.ident, .table_decl, try std.fmt.allocPrint(e.a, "'{s}' is the name of a table, so it can't also be a definition", .{d.pat.ident}));
        },
        else => {},
    };
}

fn resolveTable(e: *Emitter, items: []const tr.Item, decl: TableDecl) Error!*Table {
    const a = e.a;
    const ty = findAlias(items, decl.row_type) orelse {
        return e.errAtRule(decl.row_type, .table_decl, try std.fmt.allocPrint(a, "the table '{s}' holds rows of type {s}, but this module has no 'type alias {s} = {{ ... }}'", .{ decl.name, decl.row_type, decl.row_type }));
    };
    var inner = ty;
    while (inner.* == .paren) inner = inner.paren;
    if (inner.* != .record or inner.record.ext != null or inner.record.fields.len == 0) {
        return e.errAtRule(decl.row_type, .table_decl, try std.fmt.allocPrint(a, "the rows of a table are a record: 'type alias {s} = {{ id : Str, ... }}'", .{decl.row_type}));
    }
    var columns: std.ArrayList(Column) = .empty;
    for (inner.record.fields) |f| {
        const col_ty = columnType(f.ty) orelse {
            return e.errAtRule(f.name, .table_decl, try std.fmt.allocPrint(a, "the column '{s}' of the table '{s}' can't be stored: a column is a Str, Int, Float or Bool, or a Maybe of one of these when it can be empty", .{ f.name, decl.name }));
        };
        const plain = try tr.snake(a, f.name);
        try columns.append(a, .{ .name = f.name, .sql = try sqlIdent(a, plain), .plain = plain, .ty = col_ty });
    }

    var table = try a.create(Table);
    const plain_name = try tr.snake(a, decl.name);
    table.* = .{ .decl = decl, .sql = try sqlIdent(a, plain_name), .columns = columns.items, .key = null, .access = undefined };
    var seen = [4]bool{ false, false, false, false };
    for (decl.lines) |line| {
        if (std.mem.eql(u8, line.word, "key")) {
            if (table.key != null) return e.errAtRule(line.word, .table_decl, "a table has one key");
            for (table.columns, 0..) |c, i| if (std.mem.eql(u8, c.name, line.arg)) {
                table.key = i;
            };
            const key = table.key orelse {
                return e.errAtRule(line.arg, .table_decl, try std.fmt.allocPrint(a, "the table '{s}' has no column '{s}' for its key (it has {s})", .{ decl.name, line.arg, try table.columnNames(a) }));
            };
            if (table.columns[key].ty.nullable) {
                return e.errAtRule(line.arg, .table_decl, try std.fmt.allocPrint(a, "the key '{s}' can't be a Maybe: every row has a key", .{line.arg}));
            }
            continue;
        }
        const op = std.meta.stringToEnum(Op, line.word) orelse {
            return e.errAtRule(line.word, .table_decl, try std.fmt.allocPrint(a, "a table has the lines 'key', 'read', 'insert', 'update' and 'delete', not '{s}'", .{line.word}));
        };
        if (seen[@backingInt(op)]) {
            return e.errAtRule(line.word, .table_decl, try std.fmt.allocPrint(a, "the table '{s}' says twice who may {s}", .{ decl.name, op.verb() }));
        }
        const access: Access = if (line.policy) |policy|
            .{ .rule = try policySql(e, table, op, line.word, policy) }
        else if (std.mem.eql(u8, line.arg, "everyone"))
            .everyone
        else if (std.mem.eql(u8, line.arg, "nobody"))
            .nobody
        else {
            return e.errAtRule(line.arg, .table_decl, try std.fmt.allocPrint(a, "who may {s}: 'everyone', 'nobody' or a function of the user and the row (fn user, {s} -> ...), not '{s}'", .{ op.verb(), rowName(table), line.arg }));
        };
        seen[@backingInt(op)] = true;
        table.access[@backingInt(op)] = access;
    }
    for (seen, 0..) |s, i| if (!s) {
        const op: Op = @fromBackingInt(@intCast(i));
        return e.errAtRule(decl.name, .table_decl, try std.fmt.allocPrint(a, "the table '{s}' doesn't say who may {s} its rows: add the line '{s} everyone' or '{s} nobody'. A table says who may read, insert, update and delete, so that no rows are open by accident.", .{ decl.name, op.verb(), op.verb(), op.verb() }));
    };
    return table;
}

/// A name for a row of the table in examples: `links` gives `link`.
fn rowName(t: *const Table) []const u8 {
    const n = t.decl.name;
    return if (n.len > 1 and n[n.len - 1] == 's') n[0 .. n.len - 1] else "row";
}

/// The SQL of a policy `fn user, link -> ...`: an expression over the
/// columns of the row and the fields of the user, which it reads from the
/// settings `Db.runAs!` gives the transaction. Without a user (`Db.run!`) a
/// setting is NULL, and a policy that compares with it is not true.
fn policySql(e: *Emitter, table: *const Table, op: Op, at: []const u8, policy: *Expr) Error![]const u8 {
    const a = e.a;
    var x = policy;
    while (x.* == .paren) x = x.paren;
    const example = try std.fmt.allocPrint(a, "{s} fn user, {s} -> {s}.owner == user.id", .{ op.verb(), rowName(table), rowName(table) });
    if (x.* != .lambda or x.lambda.params.len != 2) {
        return e.errAtRule(at, .table_decl, try std.fmt.allocPrint(a, "a policy is 'everyone', 'nobody' or a function of the user and the row: {s}", .{example}));
    }
    const lam = x.lambda;
    var names: [2]?[]const u8 = .{ null, null };
    for (lam.params, 0..) |param, i| names[i] = switch (param.*) {
        .ident => |n| n,
        .underscore => null,
        else => return e.errAtRule(at, .table_decl, try std.fmt.allocPrint(a, "the function of a policy takes the user and the row as names: {s}", .{example})),
    };
    if (lam.body.stmts.len > 0 or lam.body.result == null) {
        return e.errAtRule(at, .table_decl, "the function of a policy is one expression, so that it can run in the database");
    }
    var sql: std.ArrayList(u8) = .empty;
    var params: std.ArrayList(Param) = .empty;
    var q: Sql = .{ .e = e, .table = table, .row = names[1], .out = &sql, .params = &params, .user = names[0], .policy = true };
    const body = lam.body.result.?;
    const ty = try q.expr(body, .{ .base = .bool }, 0);
    if (ty.base != .bool or ty.nullable) {
        return e.errAtRule(exprText(body) orelse at, .query_type, try std.fmt.allocPrint(a, "the function of a policy gives a Bool, true for the rows the user may {s}, but this one gives {s}", .{ op.verb(), try ty.an(a) }));
    }
    return sql.items;
}

/// The field `name` of the user, typed `ty` by the column it meets; the
/// same field has one type in all policies of the module.
fn userField(e: *Emitter, name: []const u8, ty: ColType) Error!*const UserField {
    const a = e.a;
    for (e.db_user.items) |*f| if (std.mem.eql(u8, f.name, name)) {
        if (!f.ty.eql(ty)) {
            return e.errAtRule(name, .query_type, try std.fmt.allocPrint(a, "'user.{s}' is {s} in another policy, and {s} here", .{ name, try f.ty.an(a), try ty.an(a) }));
        }
        return f;
    };
    try e.db_user.append(a, .{ .name = name, .setting = try std.fmt.allocPrint(a, "punk.user_{s}", .{try tr.snake(a, name)}), .ty = ty });
    return &e.db_user.items[e.db_user.items.len - 1];
}

fn findAlias(items: []const tr.Item, name: []const u8) ?*tr.Type {
    for (items) |item| if (item.kind == .type_alias) {
        const t = item.kind.type_alias;
        if (std.mem.eql(u8, t.name, name) and t.params.len == 0) return t.ty;
    };
    return null;
}

pub fn columnType(ty: *tr.Type) ?ColType {
    switch (ty.*) {
        .paren => |inner| return columnType(inner),
        .name => |n| return .{ .base = baseType(n) orelse return null },
        .app => |app| {
            if (!std.mem.eql(u8, app.head, "Maybe") or app.args.len != 1) return null;
            const inner = columnType(app.args[0]) orelse return null;
            if (inner.nullable) return null;
            return .{ .base = inner.base, .nullable = true };
        },
        else => return null,
    }
}

fn baseType(n: []const u8) ?ColType.Base {
    const names = .{
        .{ "Str", .str },     .{ "String", .str },
        .{ "Int", .int },     .{ "I64", .int },
        .{ "Float", .float }, .{ "F64", .float },
        .{ "Bool", .bool },
    };
    inline for (names) |row| if (std.mem.eql(u8, n, row[0])) return row[1];
    return null;
}

const sql_keywords = [_][]const u8{
    "all",        "analyse",      "analyze",      "and",          "any",               "array",        "as",             "asc",
    "asymmetric", "both",         "case",         "cast",         "check",             "collate",      "column",         "constraint",
    "create",     "current_date", "current_role", "current_time", "current_timestamp", "current_user", "default",        "deferrable",
    "desc",       "distinct",     "do",           "else",         "end",               "except",       "false",          "fetch",
    "for",        "foreign",      "from",         "grant",        "group",             "having",       "in",             "initially",
    "intersect",  "into",         "lateral",      "leading",      "limit",             "localtime",    "localtimestamp", "not",
    "null",       "offset",       "on",           "only",         "or",                "order",        "placing",        "primary",
    "references", "returning",    "select",       "session_user", "some",              "symmetric",    "table",          "then",
    "to",         "trailing",     "true",         "union",        "unique",            "user",         "using",          "variadic",
    "when",       "where",        "window",       "with",
};

/// How a name is written in SQL: as it is, or in double quotes when it is a
/// keyword (`"user"`).
pub fn sqlIdent(a: Allocator, plain: []const u8) Allocator.Error![]const u8 {
    for (sql_keywords) |k| if (std.mem.eql(u8, k, plain)) return std.fmt.allocPrint(a, "\"{s}\"", .{plain});
    return plain;
}

/// The `CREATE TABLE` statement of a table.
pub fn createSql(a: Allocator, out: *std.ArrayList(u8), t: *const Table) Allocator.Error!void {
    try out.print(a, "CREATE TABLE {s} (\n", .{t.sql});
    for (t.columns, 0..) |c, i| {
        const constraint: []const u8 = if (t.key != null and t.key.? == i) " PRIMARY KEY" else if (c.ty.nullable) "" else " NOT NULL";
        try out.print(a, "    {s} {s}{s}{s}\n", .{ c.sql, sqlType(c.ty), constraint, if (i + 1 < t.columns.len) "," else "" });
    }
    try out.appendSlice(a, ");\n");
}

/// The Postgres type of a column.
pub fn sqlType(ty: ColType) []const u8 {
    return switch (ty.base) {
        .str => "text",
        .int => "bigint",
        .float => "double precision",
        .bool => "boolean",
    };
}

/// The row-level security of a new table: Postgres only gives the rows a
/// policy allows, also to SQL that doesn't come from a query, and also to
/// the owner of the table (FORCE).
pub fn securitySql(a: Allocator, out: *std.ArrayList(u8), t: *const Table) Allocator.Error!void {
    try out.print(a, "ALTER TABLE {s} ENABLE ROW LEVEL SECURITY;\n", .{t.sql});
    try out.print(a, "ALTER TABLE {s} FORCE ROW LEVEL SECURITY;\n", .{t.sql});
    try policiesSql(a, out, t);
}

/// The name of the policy of a table for an operation (`links_read`).
pub fn policyName(a: Allocator, table_plain: []const u8, op: Op) Allocator.Error![]const u8 {
    return sqlIdent(a, try std.fmt.allocPrint(a, "{s}_{s}", .{ table_plain, op.verb() }));
}

/// The policy of each operation: `everyone` is `true`, a function its SQL.
/// An operation that is `nobody` gets no policy, so no row is allowed.
pub fn policiesSql(a: Allocator, out: *std.ArrayList(u8), t: *const Table) Allocator.Error!void {
    for (t.access, 0..) |access, i| {
        const op: Op = @fromBackingInt(@intCast(i));
        const cond = policyCond(access) orelse continue;
        const name = try policyName(a, t.plain(), op);
        const command = switch (op) {
            .read => "SELECT",
            .insert => "INSERT",
            .update => "UPDATE",
            .delete => "DELETE",
        };
        try out.print(a, "CREATE POLICY {s} ON {s} FOR {s}", .{ name, t.sql, command });
        switch (op) {
            .insert => try out.print(a, " WITH CHECK ({s});\n", .{cond}),
            .update => try out.print(a, " USING ({s}) WITH CHECK ({s});\n", .{ cond, cond }),
            .read, .delete => try out.print(a, " USING ({s});\n", .{cond}),
        }
    }
}

/// The SQL condition of a policy, null for `nobody`.
pub fn policyCond(access: Access) ?[]const u8 {
    return switch (access) {
        .nobody => null,
        .everyone => "true",
        .rule => |sql| sql,
    };
}

// Queries

const Member = enum { filter, map, join, sortBy, sortByDescending, take, drop, all, first, insert, insertIfNew, update, delete, runAs, transactionAs };

/// The query-language function `name` names (`Db.filter`), if it is one.
pub fn member(e: *const Emitter, name: []const u8) ?Member {
    const alias = e.db_alias orelse return null;
    if (name.len <= alias.len + 1 or !std.mem.startsWith(u8, name, alias) or name[alias.len] != '.') return null;
    const rest = name[alias.len + 1 ..];
    if (std.mem.eql(u8, rest, "runAs!")) return .runAs;
    if (std.mem.eql(u8, rest, "transactionAs!")) return .transactionAs;
    if (std.mem.eql(u8, rest, "runAs") or std.mem.eql(u8, rest, "transactionAs")) return null;
    return std.meta.stringToEnum(Member, rest);
}

/// The error for a query-language function used other than at the end of
/// a pipeline (`List.map Db.filter xs`).
pub fn notInPipeline(e: *Emitter, name: []const u8) Error {
    const alias = e.db_alias orelse "Db";
    return e.errAtRule(name, .not_in_database, try std.fmt.allocPrint(e.a, "'{s}' only works in a query, a pipeline that starts at a table and ends in {s}.all, {s}.first or {s}.delete: links |> {s}.filter (fn link -> link.id == id) |> {s}.first", .{ name, alias, alias, alias, alias, alias }));
}

/// The error for the name of a table used as a value.
pub fn tableAsValue(e: *Emitter, name: []const u8) Error {
    const alias = e.db_alias orelse "Db";
    return e.errAtRule(name, .not_in_database, try std.fmt.allocPrint(e.a, "'{s}' is a table: it starts a query, as in {s} |> {s}.all, and is not a value on its own", .{ name, name, alias }));
}

pub const Param = struct { expr: *Expr, ty: ColType };

/// What a query gives for each row.
const Shape = union(enum) {
    /// The whole row, as the table's record.
    row,
    /// One value: `Db.map .url`.
    single: Out,
    /// A record of values: `Db.map (fn l -> { url = l.url, ... })`.
    record: []const Out,

    const Out = struct { field: []const u8, sql: []const u8, plain: []const u8, ty: ColType };
};

/// A table a query reads, with the name SQL gives it when the query has a
/// join (`t0`, `t1`, ...).
const Source = struct {
    table: *const Table,
    alias: ?[]const u8,
};

/// A step of a query between its table and its end, in pipeline order.
const Step = struct {
    kind: Kind,
    name: []const u8,
    arg: *Expr,
    /// For a join: the table it joins.
    table: ?*const Table = null,

    const Kind = enum { join, filter, sortBy, sortByDescending, drop, take, map };

    /// The order steps come in: joins, filters, sorts, drop, take, map.
    fn phase(s: Step) u8 {
        return switch (s.kind) {
            .join => 0,
            .filter => 1,
            .sortBy, .sortByDescending => 2,
            .drop => 3,
            .take => 4,
            .map => 5,
        };
    }
};

/// Writes the Roc for a query whose last step is `name` (`Db.all`), with
/// the arguments it got (the pipeline before it is the last argument).
pub fn emit(e: *Emitter, name: []const u8, m: Member, args: []*Expr) Error!void {
    const a = e.a;
    const alias = e.db_alias.?;
    if (m == .runAs) return emitAs(e, name, args, "run_as!", "the query", "(findLinks user)");
    if (m == .transactionAs) return emitAs(e, name, args, "transaction_as!", "a function that runs queries", "(fn _ -> ...)");
    const want: usize = switch (m) {
        .filter, .map, .join, .sortBy, .sortByDescending, .take, .drop => return e.errAtRule(name, .not_in_database, try std.fmt.allocPrint(a, "a query ends in {s}.all, {s}.first, {s}.update or {s}.delete, which say what it gives: links |> {s}.filter (fn link -> ...) |> {s}.all", .{ alias, alias, alias, alias, alias, alias })),
        .all, .first, .delete => 1,
        .update, .insert, .insertIfNew => 2,
        .runAs, .transactionAs => unreachable,
    };
    if (args.len != want) {
        return e.errAtRule(name, .not_in_database, try std.fmt.allocPrint(a, "'{s}' needs {d} argument{s} here, the last one the query before it: punk turns the whole query into SQL, so it can't be applied partly", .{ name, want, if (want == 1) "" else "s" }));
    }

    if (m == .insert or m == .insertIfNew) return emitInsert(e, name, m, args[0], args[1]);

    // Walk back from the last step to the table.
    var steps: std.ArrayList(Step) = .empty;
    var src = args[args.len - 1];
    const table: *const Table = while (true) {
        while (src.* == .paren) src = src.paren;
        switch (src.*) {
            .ident => |n| {
                if (e.tables.get(n)) |t| break t;
                return notATable(e, n);
            },
            .app => |app| {
                var f = app.func;
                while (f.* == .paren) f = f.paren;
                const step_name = if (f.* == .ident) f.ident else return notATableExpr(e, name);
                const step = member(e, step_name) orelse return notATable(e, step_name);
                const kind: Step.Kind = switch (step) {
                    .filter => .filter,
                    .map => .map,
                    .join => .join,
                    .sortBy => .sortBy,
                    .sortByDescending => .sortByDescending,
                    .take => .take,
                    .drop => .drop,
                    else => return e.errAtRule(step_name, .not_in_database, try std.fmt.allocPrint(a, "'{s}' ends a query, so nothing can come after it but {s}.run!", .{ step_name, alias })),
                };
                const wants: usize = if (kind == .join) 3 else 2;
                if (app.args.len != wants) {
                    const example = switch (kind) {
                        .filter => "|> Db.filter (fn link -> link.id == id)",
                        .map => "|> Db.map .url",
                        .join => "|> Db.join users (fn link, user -> link.owner == user.id)",
                        .sortBy => "|> Db.sortBy .created",
                        .sortByDescending => "|> Db.sortByDescending .created",
                        .take => "|> Db.take 10",
                        .drop => "|> Db.drop 20",
                    };
                    return e.errAtRule(step_name, .not_in_database, try std.fmt.allocPrint(a, "'{s}' takes {s} and the query before it: {s}", .{ step_name, if (kind == .join) "a table, a function" else if (kind == .take or kind == .drop) "a number" else "a function", example }));
                }
                var step_value: Step = .{ .kind = kind, .name = step_name, .arg = app.args[0] };
                if (kind == .join) {
                    var t_expr = app.args[0];
                    while (t_expr.* == .paren) t_expr = t_expr.paren;
                    if (t_expr.* != .ident) return notATableExpr(e, step_name);
                    step_value.table = e.tables.get(t_expr.ident) orelse return notATable(e, t_expr.ident);
                    step_value.arg = app.args[1];
                }
                try steps.append(a, step_value);
                src = app.args[app.args.len - 1];
            },
            else => return notATableExpr(e, name),
        }
    };
    std.mem.reverse(Step, steps.items);

    // The steps come in their order, each kind at most once where one is enough.
    var last_phase: u8 = 0;
    var sources: std.ArrayList(Source) = .empty;
    try sources.append(a, .{ .table = table, .alias = null });
    var joins: std.ArrayList(Step) = .empty;
    var filters: std.ArrayList(Step) = .empty;
    var sorts: std.ArrayList(Step) = .empty;
    var drop: ?Step = null;
    var take: ?Step = null;
    var map: ?Step = null;
    for (steps.items) |s| {
        const ph = s.phase();
        if (ph < last_phase) {
            return e.errAtRule(s.name, .not_in_database, try std.fmt.allocPrint(a, "the steps of a query come in this order: {s}.join, {s}.filter, {s}.sortBy, {s}.drop, {s}.take, {s}.map; '{s}' comes earlier", .{ alias, alias, alias, alias, alias, alias, s.name }));
        }
        last_phase = ph;
        switch (s.kind) {
            .join => {
                try joins.append(a, s);
                try sources.append(a, .{ .table = s.table.?, .alias = null });
            },
            .filter => try filters.append(a, s),
            .sortBy, .sortByDescending => try sorts.append(a, s),
            .drop, .take, .map => {
                const slot = switch (s.kind) {
                    .drop => &drop,
                    .take => &take,
                    else => &map,
                };
                if (slot.* != null) return e.errAtRule(s.name, .not_in_database, try std.fmt.allocPrint(a, "a query has one '{s}'", .{s.name}));
                slot.* = s;
            },
        }
    }
    if (joins.items.len > 0) for (sources.items, 0..) |*s, i| {
        s.alias = try std.fmt.allocPrint(a, "t{d}", .{i});
    };

    const op: Op = switch (m) {
        .all, .first => .read,
        .update => .update,
        .delete => .delete,
        else => unreachable,
    };
    try checkAccess(e, table, op, name);
    for (joins.items) |j| try checkAccess(e, j.table.?, .read, j.name);
    if (m == .update or m == .delete) {
        const extra: ?Step = if (map) |s| s else if (joins.items.len > 0) joins.items[0] else if (sorts.items.len > 0) sorts.items[0] else if (take) |s| s else drop;
        if (extra) |s| return e.errAtRule(s.name, .not_in_database, try std.fmt.allocPrint(a, "'{s}' changes the rows its filters keep, all of them: '{s}' has no place before it", .{ name, s.name }));
    }
    if (m == .first and take != null) {
        return e.errAtRule(take.?.name, .not_in_database, try std.fmt.allocPrint(a, "{s}.first takes one row already: leave out the {s}.take", .{ alias, alias }));
    }
    if (joins.items.len > 0 and map == null) {
        return e.errAtRule(name, .not_in_database, try std.fmt.allocPrint(a, "a query with a join says what it gives for each pair of rows: {s}.map (fn link, user -> {{ url = link.url, name = user.name }})", .{alias}));
    }

    // The conditions of the joins first: a map reads the rows they give.
    for (joins.items, 2..) |j, n| _ = try rowLambda(e, j.arg, j.name, n);

    var params: std.ArrayList(Param) = .empty;
    var sql: std.ArrayList(u8) = .empty;
    var shape: Shape = .row;
    switch (m) {
        .all, .first => {
            if (map) |s| shape = try mapShape(e, sources.items, s.arg, &params);
            try sql.appendSlice(a, "SELECT ");
            switch (shape) {
                .row => for (table.columns, 0..) |c, i| {
                    if (i > 0) try sql.appendSlice(a, ", ");
                    try sql.appendSlice(a, c.sql);
                },
                .single => |out| try selectOut(a, &sql, out),
                .record => |outs| for (outs, 0..) |out, i| {
                    if (i > 0) try sql.appendSlice(a, ", ");
                    try selectOut(a, &sql, out);
                },
            }
            try sql.print(a, " FROM {s}", .{table.sql});
            if (sources.items[0].alias) |t0| try sql.print(a, " {s}", .{t0});
            for (joins.items, 1..) |j, i| {
                try sql.print(a, " JOIN {s} {s} ON ", .{ j.table.?.sql, sources.items[i].alias.? });
                try boolStep(e, sources.items[0 .. i + 1], j, &sql, &params, false);
            }
        },
        .delete => try sql.print(a, "DELETE FROM {s}", .{table.sql}),
        .update => {
            try sql.print(a, "UPDATE {s} SET ", .{table.sql});
            try updateSet(e, table, args[0], &sql, &params);
        },
        else => unreachable,
    }
    if (filters.items.len > 0) {
        try sql.appendSlice(a, " WHERE ");
        for (filters.items, 0..) |f, i| {
            if (i > 0) try sql.appendSlice(a, " AND ");
            try boolStep(e, sources.items, f, &sql, &params, filters.items.len > 1);
        }
    }
    if (sorts.items.len > 0) {
        // As with List.sortBy, the last sort decides first: it sorts what
        // the ones before it sorted.
        try sql.appendSlice(a, " ORDER BY ");
        var i = sorts.items.len;
        while (i > 0) {
            i -= 1;
            const s = sorts.items[i];
            const lam = try rowLambda(e, s.arg, s.name, sources.items.len);
            var q: Sql = .{ .e = e, .table = table, .row = null, .out = &sql, .params = &params, .bound = try bind(a, sources.items, lam.rows) };
            const ty = try q.expr(lam.body, null, 0);
            if (ty.base == .bool) return e.errAtRule(lam.at, .query_type, "a sort key is a Str, an Int or a Float: Bool has no order in Elm");
            try sql.appendSlice(a, if (s.kind == .sortByDescending) " DESC" else " ASC");
            if (i > 0) try sql.appendSlice(a, ", ");
        }
    }
    if (take) |s| {
        try sql.appendSlice(a, " LIMIT ");
        try countParam(e, s, &sql, &params);
    }
    if (drop) |s| {
        try sql.appendSlice(a, " OFFSET ");
        try countParam(e, s, &sql, &params);
    }
    if (m == .first) try sql.appendSlice(a, " LIMIT 1");

    // The Roc: `Db.all_rows([params], "SQL", decoder)`.
    try e.markAt(name, 0);
    try e.w(alias);
    try e.w(switch (m) {
        .all => ".all_rows(",
        .first => ".first_row(",
        else => ".changes(",
    });
    try emitParams(e, params.items);
    try e.w(", ");
    try emitSqlString(e, sql.items);
    if (m == .all or m == .first) {
        try e.w(", ");
        try emitDecoder(e, table, shape);
    }
    try e.w(")");
}

/// The SQL of a filter or the condition of a join: a Bool of the rows.
fn boolStep(e: *Emitter, sources: []const Source, s: Step, sql: *std.ArrayList(u8), params: *std.ArrayList(Param), paren_or: bool) Error!void {
    const a = e.a;
    const lam = try rowLambda(e, s.arg, s.name, sources.len);
    var q: Sql = .{ .e = e, .table = sources[0].table, .row = null, .out = sql, .params = params, .bound = try bind(a, sources, lam.rows) };
    const many = paren_or and lam.body.* == .binop and std.mem.eql(u8, lam.body.binop.op, "||");
    if (many) try sql.appendSlice(a, "(");
    const ty = try q.expr(lam.body, .{ .base = .bool }, 0);
    if (many) try sql.appendSlice(a, ")");
    if (ty.base != .bool or ty.nullable) {
        const what = if (s.kind == .join) "the function of a join gives a Bool, true for the pairs of rows that go together" else "the function of a filter gives a Bool, true for the rows to keep";
        return e.errAtRule(lam.at, .query_type, try std.fmt.allocPrint(a, "{s}, but this one gives {s}", .{ what, try ty.an(a) }));
    }
}

/// The number of `Db.take` or `Db.drop`, a parameter.
fn countParam(e: *Emitter, s: Step, sql: *std.ArrayList(u8), params: *std.ArrayList(Param)) Error!void {
    const ty: ColType = .{ .base = .int };
    try checkLiteral(e, s.arg, ty, try std.fmt.allocPrint(e.a, "the number of {s}", .{s.name}));
    try params.append(e.a, .{ .expr = s.arg, .ty = ty });
    try sql.print(e.a, "${d}", .{params.items.len});
}

/// The rows of a function in a query, by the names its parameters give them.
fn bind(a: Allocator, sources: []const Source, rows: []const ?[]const u8) Allocator.Error![]const Bound {
    var out = try a.alloc(Bound, rows.len);
    for (rows, 0..) |r, i| out[i] = .{ .row = r, .table = sources[i].table, .alias = sources[i].alias };
    return out;
}

/// A row in a function of a query: its name, its table, its name in SQL.
pub const Bound = struct {
    row: ?[]const u8,
    table: *const Table,
    alias: ?[]const u8,
};

/// `Db.runAs! user query` and `Db.transactionAs! user (fn _ -> ...)`: run
/// the query, or the queries of the function, as this user, so that the
/// policies of the tables see the fields of the user they look at. They go
/// to the database as settings of the transaction:
/// `Db.run_as!([Db.setting_text("punk.user_id", u.id)], query)`.
fn emitAs(e: *Emitter, name: []const u8, args: []*Expr, roc_fn: []const u8, what: []const u8, example: []const u8) Error!void {
    const a = e.a;
    const alias = e.db_alias.?;
    if (args.len != 2) {
        return e.errAtRule(name, .not_in_database, try std.fmt.allocPrint(a, "'{s}' takes the user and {s}: {s} user {s}", .{ name, what, name, example }));
    }
    if (e.db_user.items.len == 0) {
        return e.errAtRule(name, .not_allowed, try std.fmt.allocPrint(a, "no policy of a table in this module looks at the user, so '{s}' has nothing to give it: use {s}.run!, or a policy such as 'read fn user, link -> link.owner == user.id'", .{ name, alias }));
    }
    e.fresh += 1;
    const tmp = try std.fmt.allocPrint(a, "punk_user{d}", .{e.fresh});
    try e.markAt(name, 0);
    try e.w("{");
    e.indent += 1;
    try e.nl();
    try e.w(tmp);
    try e.w(" = ");
    try e.emitExpr(args[0]);
    try e.nl();
    try e.w(alias);
    try e.w(".");
    try e.w(roc_fn);
    try e.w("([");
    for (e.db_user.items, 0..) |f, i| {
        if (i > 0) try e.w(", ");
        try e.w(alias);
        try e.w(switch (f.ty.base) {
            .str => ".setting_text(\"",
            .int => ".setting_int(\"",
            .float => ".setting_float(\"",
            .bool => ".setting_bool(\"",
        });
        try e.w(f.setting);
        try e.w("\", ");
        try e.w(tmp);
        try e.w(".");
        try e.w(try tr.snake(a, f.name));
        try e.w(")");
    }
    try e.w("], ");
    try e.emitExpr(args[1]);
    try e.w(")");
    e.indent -= 1;
    try e.nl();
    try e.w("}");
}

fn notATable(e: *Emitter, n: []const u8) Error {
    const alias = e.db_alias orelse "Db";
    return e.errAtRule(n, .not_in_database, try std.fmt.allocPrint(e.a, "a query starts at a table that this module declares ('table links : Link'), but '{s}' is not one: links |> {s}.filter (fn link -> ...) |> {s}.all", .{ n, alias, alias }));
}

fn notATableExpr(e: *Emitter, at: []const u8) Error {
    const alias = e.db_alias orelse "Db";
    return e.errAtRule(at, .not_in_database, try std.fmt.allocPrint(e.a, "a query starts at a table that this module declares, written right here: links |> {s}.filter (fn link -> ...) |> {s}.all", .{ alias, alias }));
}

fn checkAccess(e: *Emitter, table: *const Table, op: Op, at: []const u8) Error!void {
    if (table.access[@backingInt(op)] != .nobody) return;
    return e.errAtRule(at, .not_allowed, try std.fmt.allocPrint(e.a, "the table '{s}' doesn't allow anyone to {s} its rows ('{s} nobody' in its declaration)", .{ table.decl.name, op.verb(), op.verb() }));
}

fn selectOut(a: Allocator, sql: *std.ArrayList(u8), out: Shape.Out) Allocator.Error!void {
    try sql.appendSlice(a, out.sql);
    if (!std.mem.eql(u8, out.sql, out.plain) and !(out.sql.len == out.plain.len + 2 and out.sql[0] == '"')) {
        try sql.print(a, " AS {s}", .{try sqlIdent(a, out.plain)});
    }
}

const RowLambda = struct { rows: []const ?[]const u8, body: *Expr, at: []const u8 };

/// The function of a step of a query (`filter`, `map`, `sortBy`, `update`,
/// the condition of a `join`), which has to be written in the query (`fn
/// link -> link.id == id`) so that punk can see its body. It takes a row of
/// each table of the query: `n` of them.
fn rowLambda(e: *Emitter, x_in: *Expr, step: []const u8, n: usize) Error!RowLambda {
    const a = e.a;
    var x = x_in;
    while (x.* == .paren) x = x.paren;
    const is_map = std.mem.endsWith(u8, step, ".map");
    const example = if (is_map)
        (if (n == 1) "(fn link -> link.url)" else "(fn link, user -> { url = link.url, name = user.name })")
    else if (n == 1) "(fn link -> link.id == id)" else "(fn link, user -> link.owner == user.id)";
    if (x.* != .lambda or x.lambda.params.len != n) {
        const at = if (x.* == .lambda and x.lambda.params.len > 0) switch (x.lambda.params[0].*) {
            .ident, .underscore => |t| t,
            else => step,
        } else exprText(x_in) orelse step;
        const rows = if (n == 1) "one row" else try std.fmt.allocPrint(a, "{d} rows, one of each table of the query,", .{n});
        return e.errAtRule(at, .not_in_database, try std.fmt.allocPrint(a, "{s} takes a function of {s} written right here, such as {s}, so that punk can turn it into SQL", .{ step, rows, example }));
    }
    const lam = x.lambda;
    var rows = try a.alloc(?[]const u8, n);
    for (lam.params, 0..) |param, i| rows[i] = switch (param.*) {
        .ident => |name| name,
        .underscore => null,
        else => {
            return e.errAtRule(exprText(x_in) orelse step, .not_in_database, try std.fmt.allocPrint(a, "the function of {s} takes the rows as names, as in {s}", .{ step, example }));
        },
    };
    const first: ?[]const u8 = for (rows) |r| {
        if (r != null) break r;
    } else null;
    if (lam.body.stmts.len > 0 or lam.body.result == null) {
        return e.errAtRule(first orelse step, .not_in_database, try std.fmt.allocPrint(a, "the function of {s} is one expression, so that it can run in the database", .{step}));
    }
    return .{ .rows = rows, .body = lam.body.result.?, .at = first orelse step };
}

fn mapShape(e: *Emitter, sources: []const Source, f: *Expr, params: *std.ArrayList(Param)) Error!Shape {
    const a = e.a;
    const alias = e.db_alias orelse "Db";
    const lam = try rowLambda(e, f, try std.fmt.allocPrint(a, "{s}.map", .{alias}), sources.len);
    const bound = try bind(a, sources, lam.rows);
    var body = lam.body;
    while (body.* == .paren) body = body.paren;
    if (body.* == .ident) for (lam.rows) |r| if (r != null and std.mem.eql(u8, body.ident, r.?)) {
        if (sources.len == 1) return .row;
        return e.errAtRule(body.ident, .not_in_database, try std.fmt.allocPrint(a, "a query with a join gives the values it names: {s}.map (fn link, user -> {{ url = link.url, name = user.name }})", .{alias}));
    };
    if (body.* == .record and body.record.base == null) {
        var outs: std.ArrayList(Shape.Out) = .empty;
        for (body.record.fields) |fld| {
            const value = fld.value orelse return e.errAtRule(fld.name, .not_in_database, try std.fmt.allocPrint(a, "write where '{s}' comes from: {{ {s} = {s}.{s} }}", .{ fld.name, fld.name, lam.rows[0] orelse "row", fld.name }));
            try outs.append(a, try mapOut(e, sources[0].table, bound, value, fld.name, params));
        }
        return .{ .record = outs.items };
    }
    const fallback = if (body.* == .field) body.field.name else "value";
    return .{ .single = try mapOut(e, sources[0].table, bound, body, fallback, params) };
}

fn mapOut(e: *Emitter, table: *const Table, bound: []const Bound, value: *Expr, field: []const u8, params: *std.ArrayList(Param)) Error!Shape.Out {
    const a = e.a;
    const from_row = for (bound) |b| {
        if (b.row != null and mentions(value, b.row.?)) break true;
    } else false;
    if (!from_row) {
        return e.errAtRule(exprText(value) orelse field, .not_in_database, "a map in a query gives values from the row, such as link.url: a value that doesn't come from the row is easier to add after the query");
    }
    var out: std.ArrayList(u8) = .empty;
    var q: Sql = .{ .e = e, .table = table, .row = null, .out = &out, .params = params, .bound = bound };
    const ty = try q.expr(value, null, 0);
    return .{ .field = field, .sql = out.items, .plain = try tr.snake(a, field), .ty = ty };
}

fn updateSet(e: *Emitter, table: *const Table, f: *Expr, sql: *std.ArrayList(u8), params: *std.ArrayList(Param)) Error!void {
    const a = e.a;
    const alias = e.db_alias orelse "Db";
    const lam1 = try rowLambda(e, f, try std.fmt.allocPrint(a, "{s}.update", .{alias}), 1);
    const lam: struct { row: ?[]const u8, body: *Expr, at: []const u8 } = .{ .row = lam1.rows[0], .body = lam1.body, .at = lam1.at };
    var body = lam.body;
    while (body.* == .paren) body = body.paren;
    const ok = body.* == .record and body.record.base != null and lam.row != null and blk: {
        var base = body.record.base.?;
        while (base.* == .paren) base = base.paren;
        break :blk base.* == .ident and std.mem.eql(u8, base.ident, lam.row.?);
    };
    if (!ok or body.record.fields.len == 0) {
        return e.errAtRule(lam.at, .not_in_database, try std.fmt.allocPrint(a, "{s}.update takes a function that says which columns change: {s}.update (fn link -> {{ link | url = newUrl }})", .{ alias, alias }));
    }
    for (body.record.fields, 0..) |fld, i| {
        const col = table.column(fld.name) orelse return unknownColumn(e, table, fld.name);
        if (table.key != null and &table.columns[table.key.?] == col) {
            return e.errAtRule(fld.name, .not_in_database, try std.fmt.allocPrint(a, "'{s}' is the key of the table '{s}': a row keeps its key", .{ fld.name, table.decl.name }));
        }
        if (i > 0) try sql.appendSlice(a, ", ");
        try sql.print(a, "{s} = ", .{col.sql});
        const value = fld.value orelse return e.errAtRule(fld.name, .not_in_database, try std.fmt.allocPrint(a, "write the new value of '{s}': {{ {s} | {s} = ... }}", .{ fld.name, lam.row.?, fld.name }));
        var q: Sql = .{ .e = e, .table = table, .row = lam.row, .out = sql, .params = params };
        const ty = try q.expr(value, col.ty, 0);
        try q.expectType(value, ty, col.ty, fld.name);
    }
}

fn emitInsert(e: *Emitter, name: []const u8, m: Member, row_expr: *Expr, table_expr: *Expr) Error!void {
    const a = e.a;
    const alias = e.db_alias.?;
    var t_expr = table_expr;
    while (t_expr.* == .paren) t_expr = t_expr.paren;
    if (t_expr.* != .ident) return notATableExpr(e, name);
    const table = e.tables.get(t_expr.ident) orelse return notATable(e, t_expr.ident);
    try checkAccess(e, table, .insert, name);

    var params: std.ArrayList(Param) = .empty;
    var sql: std.ArrayList(u8) = .empty;
    try sql.print(a, "INSERT INTO {s} (", .{table.sql});
    for (table.columns, 0..) |c, i| {
        if (i > 0) try sql.appendSlice(a, ", ");
        try sql.appendSlice(a, c.sql);
    }
    try sql.appendSlice(a, ") VALUES (");
    for (table.columns, 0..) |_, i| {
        if (i > 0) try sql.appendSlice(a, ", ");
        try sql.print(a, "${d}", .{i + 1});
    }
    try sql.appendSlice(a, ")");
    if (m == .insertIfNew) try sql.appendSlice(a, " ON CONFLICT DO NOTHING");

    var row = row_expr;
    while (row.* == .paren) row = row.paren;
    try e.markAt(name, 0);
    if (row.* == .record and row.record.base == null) {
        // A record written here: each field is a parameter, typed by its column.
        for (row.record.fields) |fld| if (table.column(fld.name) == null) return unknownColumn(e, table, fld.name);
        for (table.columns) |c| {
            const fld = for (row.record.fields) |fld| {
                if (std.mem.eql(u8, fld.name, c.name)) break fld;
            } else {
                return e.errAtRule(name, .query_type, try std.fmt.allocPrint(a, "the row for the table '{s}' has no '{s}': a new row has all of {s}", .{ table.decl.name, c.name, try table.columnNames(a) }));
            };
            const value = fld.value orelse try e.newExpr(.{ .ident = fld.name });
            try checkLiteral(e, value, c.ty, try std.fmt.allocPrint(a, "the column '{s}'", .{c.name}));
            try params.append(a, .{ .expr = value, .ty = c.ty });
        }
        try e.w(alias);
        try e.w(".changes(");
        try emitParams(e, params.items);
        try e.w(", ");
        try emitSqlString(e, sql.items);
        try e.w(")");
        return;
    }
    // Another expression: compute it once, then its fields are the parameters.
    e.fresh += 1;
    const tmp = try std.fmt.allocPrint(a, "punk_row{d}", .{e.fresh});
    const tmp_expr = try e.newExpr(.{ .ident_raw = tmp });
    for (table.columns) |c| {
        try params.append(a, .{ .expr = try e.newExpr(.{ .field = .{ .target = tmp_expr, .name = c.name } }), .ty = c.ty });
    }
    try e.w("{");
    e.indent += 1;
    try e.nl();
    try e.w(tmp);
    try e.w(" = ");
    try e.emitExpr(row_expr);
    try e.nl();
    try e.w(alias);
    try e.w(".changes(");
    try emitParams(e, params.items);
    try e.w(", ");
    try emitSqlString(e, sql.items);
    try e.w(")");
    e.indent -= 1;
    try e.nl();
    try e.w("}");
}

fn unknownColumn(e: *Emitter, table: *const Table, name: []const u8) Error {
    return e.errAtRule(name, .query_type, try std.fmt.allocPrint(e.a, "the table '{s}' has no column '{s}' (it has {s})", .{ table.decl.name, name, try table.columnNames(e.a) }));
}

fn emitParams(e: *Emitter, params: []const Param) Error!void {
    const alias = e.db_alias.?;
    try e.w("[");
    for (params, 0..) |p, i| {
        if (i > 0) try e.w(", ");
        const base = switch (p.ty.base) {
            .str => "param_text",
            .int => "param_int",
            .float => "param_float",
            .bool => "param_bool",
        };
        try e.w(alias);
        if (p.ty.nullable) try e.w(".param_nullable(") else {
            try e.w(".");
            try e.w(base);
            try e.w("(");
        }
        try e.emitExpr(p.expr);
        if (p.ty.nullable) {
            try e.w(", ");
            try e.w(alias);
            try e.w(".");
            try e.w(base);
        }
        try e.w(")");
    }
    try e.w("]");
}

fn emitSqlString(e: *Emitter, sql: []const u8) Error!void {
    try e.w("\"");
    for (sql) |c| switch (c) {
        '"' => try e.w("\\\""),
        '\\' => try e.w("\\\\"),
        else => try e.buf.append(e.a, c),
    };
    try e.w("\"");
}

fn emitDecoder(e: *Emitter, table: *const Table, shape: Shape) Error!void {
    const a = e.a;
    const alias = e.db_alias.?;
    switch (shape) {
        .single => |out| {
            try e.w(alias);
            try e.w(".field(");
            try emitReader(e, out.ty);
            try e.buf.print(a, ", \"{s}\", {s}.done)", .{ out.plain, alias });
        },
        .row, .record => {
            var fields: std.ArrayList(struct { field: []const u8, var_name: []const u8 }) = .empty;
            var count: usize = 0;
            const n = if (shape == .row) table.columns.len else shape.record.len;
            for (0..n) |i| {
                const field, const plain, const ty = if (shape == .row)
                    .{ table.columns[i].name, table.columns[i].plain, table.columns[i].ty }
                else
                    .{ shape.record[i].field, shape.record[i].plain, shape.record[i].ty };
                e.fresh += 1;
                const v = try std.fmt.allocPrint(a, "punk_c{d}", .{e.fresh});
                try fields.append(a, .{ .field = try tr.snake(a, field), .var_name = v });
                try e.w(alias);
                try e.w(".field(");
                try emitReader(e, ty);
                try e.buf.print(a, ", \"{s}\", |{s}| ", .{ plain, v });
                count += 1;
            }
            try e.w(alias);
            try e.w(".done({ ");
            for (fields.items, 0..) |f, i| {
                if (i > 0) try e.w(", ");
                try e.buf.print(a, "{s}: {s}", .{ f.field, f.var_name });
            }
            try e.w(" })");
            for (0..count) |_| try e.w(")");
        },
    }
}

fn emitReader(e: *Emitter, ty: ColType) Error!void {
    const alias = e.db_alias.?;
    const base = switch (ty.base) {
        .str => "read_text",
        .int => "read_int",
        .float => "read_float",
        .bool => "read_bool",
    };
    if (ty.nullable) {
        try e.w(alias);
        try e.w(".read_nullable(");
    }
    try e.w(alias);
    try e.w(".");
    try e.w(base);
    if (ty.nullable) try e.w(")");
}

/// Checks a literal against the type of the column it goes into; other
/// values are checked by Roc, through the typed `Db.param_*`.
fn checkLiteral(e: *Emitter, value: *Expr, ty: ColType, column: []const u8) Error!void {
    var v = value;
    while (v.* == .paren) v = v.paren;
    const lit: ?ColType.Base = switch (v.*) {
        .string => .str,
        .literal => |l| if (l.len > 0 and l[0] == '\'') null else if (std.mem.findAny(u8, l, ".eE") != null and !std.mem.startsWith(u8, l, "0x")) .float else .int,
        else => null,
    };
    const base = lit orelse return;
    if (base == ty.base or (base == .int and ty.base == .float)) {
        if (!ty.nullable) return;
    }
    return e.errAtRule(exprText(v) orelse column, .query_type, try std.fmt.allocPrint(e.a, "this value doesn't fit {s}, which is {s}", .{ column, try ty.an(e.a) }));
}

/// Writes the SQL for an expression in a query's function, whose row is
/// called `row`.
pub const Sql = struct {
    e: *Emitter,
    table: *const Table,
    row: ?[]const u8,
    out: *std.ArrayList(u8),
    params: *std.ArrayList(Param),
    /// In a policy: the name of the user (`fn user, link -> ...`). A policy
    /// has no parameters: its values are the row, the user and constants.
    user: ?[]const u8 = null,
    policy: bool = false,
    /// What the expression is in, for errors: "a policy", "a migration".
    what: []const u8 = "a policy",
    /// The rows of a query's function, each of its table (with a join).
    /// When there are any, `table` and `row` are not used for columns.
    bound: []const Bound = &.{},

    fn w(q: *Sql, s: []const u8) Allocator.Error!void {
        try q.out.appendSlice(q.e.a, s);
    }

    /// The type an expression has in SQL, when it can tell without context:
    /// a column, an operation on columns, a literal or `True`/`False`.
    fn typeOf(q: *Sql, x: *Expr) Error!?ColType {
        switch (x.*) {
            .paren => |inner| return q.typeOf(inner),
            .field => |f| if (q.boundOf(f.target)) |b| {
                const col = b.table.column(f.name) orelse return unknownColumn(q.e, b.table, f.name);
                return col.ty;
            },
            .binop => |b| {
                if (isComparison(b.op) or std.mem.eql(u8, b.op, "&&") or std.mem.eql(u8, b.op, "||")) return .{ .base = .bool };
                if (std.mem.eql(u8, b.op, "++")) return .{ .base = .str };
                if (isArith(b.op)) return (try q.typeOf(b.lhs)) orelse try q.typeOf(b.rhs);
            },
            .not => return .{ .base = .bool },
            .neg => |inner| return q.typeOf(inner),
            .upper => |u| if (std.mem.eql(u8, u, "True") or std.mem.eql(u8, u, "False")) return .{ .base = .bool },
            else => {},
        }
        return null;
    }

    /// The row `x` names, with its table.
    fn boundOf(q: *Sql, x_in: *Expr) ?Bound {
        var x = x_in;
        while (x.* == .paren) x = x.paren;
        if (x.* != .ident) return null;
        if (q.bound.len > 0) {
            for (q.bound) |b| if (b.row != null and std.mem.eql(u8, x.ident, b.row.?)) return b;
            return null;
        }
        const row = q.row orelse return null;
        if (!std.mem.eql(u8, x.ident, row)) return null;
        return .{ .row = row, .table = q.table, .alias = null };
    }

    fn isRow(q: *Sql, x: *Expr) bool {
        return q.boundOf(x) != null;
    }

    fn mentionsRow(q: *Sql, x: *Expr) bool {
        if (q.bound.len > 0) {
            for (q.bound) |b| if (b.row != null and mentions(x, b.row.?)) return true;
            return false;
        }
        const row = q.row orelse return false;
        return mentions(x, row);
    }

    /// Writes the SQL of `x` and gives its type. `want` is the type the
    /// place it is in asks for (a parameter takes it); `prec` the precedence
    /// of the operator around it.
    pub fn expr(q: *Sql, x: *Expr, want: ?ColType, prec: u8) Error!ColType {
        const a = q.e.a;
        if (q.policy) if (try q.policyLeaf(x, want)) |ty| return ty;
        if (!q.policy and !q.mentionsRow(x)) {
            var v = x;
            while (v.* == .paren) v = v.paren;
            if (v.* == .upper and (std.mem.eql(u8, v.upper, "True") or std.mem.eql(u8, v.upper, "False"))) {
                try q.w(if (std.mem.eql(u8, v.upper, "True")) "TRUE" else "FALSE");
                return .{ .base = .bool };
            }
            const ty = want orelse literalType(v) orelse {
                return q.e.errAtRule(exprText(v) orelse "", .query_type, "punk can't tell the type of this value in the query: compare it with a column of the row");
            };
            try checkLiteral(q.e, v, ty, "the column it meets");
            try q.params.append(a, .{ .expr = x, .ty = ty });
            try q.out.print(a, "${d}", .{q.params.items.len});
            return ty;
        }
        switch (x.*) {
            .paren => |inner| return q.expr(inner, want, prec),
            .field => |f| if (q.boundOf(f.target)) |b| {
                const col = b.table.column(f.name) orelse return unknownColumn(q.e, b.table, f.name);
                if (b.alias) |t| {
                    try q.w(t);
                    try q.w(".");
                }
                try q.w(col.sql);
                return col.ty;
            },
            .not => |inner| {
                try q.w("NOT ");
                const ty = try q.expr(inner, .{ .base = .bool }, 9);
                try q.expectType(inner, ty, .{ .base = .bool }, "not");
                return .{ .base = .bool };
            },
            .neg => |inner| {
                try q.w("-");
                return q.expr(inner, want, 9);
            },
            .binop => |b| return q.binop(x, b.op, b.lhs, b.rhs, prec),
            else => {},
        }
        return q.notInDatabase(x);
    }

    /// A value in a policy that is not a column: a field of the user, a
    /// constant, True or False. Null for an operation, which `expr` writes.
    fn policyLeaf(q: *Sql, x: *Expr, want: ?ColType) Error!?ColType {
        const a = q.e.a;
        switch (x.*) {
            .paren => |inner| {
                switch (inner.*) {
                    .field, .string, .literal, .upper, .ident => return q.policyLeaf(inner, want),
                    else => return null,
                }
            },
            .field => |f| {
                if (q.isRow(f.target)) return null;
                var target = f.target;
                while (target.* == .paren) target = target.paren;
                const user = q.user orelse return q.notInPolicy(x);
                if (target.* != .ident or !std.mem.eql(u8, target.ident, user)) return q.notInPolicy(x);
                const ty = want orelse {
                    return q.e.errAtRule(f.name, .query_type, try std.fmt.allocPrint(a, "punk can't tell the type of '{s}.{s}' here: compare it with a column of the row, as in {s}.owner == {s}.{s}", .{ user, f.name, q.row orelse "row", user, f.name }));
                };
                if (ty.nullable) {
                    return q.e.errAtRule(f.name, .query_type, try std.fmt.allocPrint(a, "'{s}.{s}' meets a Maybe column here: a policy compares the user with a column that always has a value, so that a user without '{s}' gets no rows", .{ user, f.name, f.name }));
                }
                const field = try userField(q.e, f.name, ty);
                const cast = switch (ty.base) {
                    .str => "",
                    .int => "::bigint",
                    .float => "::double precision",
                    .bool => "::boolean",
                };
                try q.out.print(a, "NULLIF(current_setting('{s}', true), ''){s}", .{ field.setting, cast });
                return ty;
            },
            .upper => |u| {
                if (std.mem.eql(u8, u, "True") or std.mem.eql(u8, u, "False")) {
                    try q.w(if (std.mem.eql(u8, u, "True")) "TRUE" else "FALSE");
                    return .{ .base = .bool };
                }
                return q.notInPolicy(x);
            },
            .string => |s| {
                if (s.len < 2 or s[0] != '"' or std.mem.findAny(u8, s[1 .. s.len - 1], "\\$\"\n") != null) {
                    return q.e.errAtRule(s, .not_in_database, "a text in a policy is plain text, without \\, ${...} or quotes");
                }
                try q.w("'");
                for (s[1 .. s.len - 1]) |c| {
                    if (c == '\'') try q.w("'");
                    try q.out.append(a, c);
                }
                try q.w("'");
                const ty: ColType = .{ .base = .str };
                if (want) |w_ty| try q.expectType(x, ty, w_ty, "the column it meets");
                return ty;
            },
            .literal => |l| {
                const ty = literalType(x) orelse return q.notInPolicy(x);
                if (want) |w_ty| try checkLiteral(q.e, x, w_ty, "the column it meets");
                for (l) |c| if (c != '_') try q.out.append(a, c);
                return ty;
            },
            .ident => return q.notInPolicy(x),
            else => return null,
        }
    }

    fn notInPolicy(q: *Sql, x: *Expr) Error {
        if (q.user == null) {
            return q.e.errAtRule(exprText(x) orelse "", .not_in_database, try std.fmt.allocPrint(q.e.a, "{s} can use the columns of the row, constants, ==, /=, <, <=, >, >=, &&, ||, not, +, -, * and ++", .{q.what}));
        }
        return q.e.errAtRule(exprText(x) orelse "", .not_in_database, try std.fmt.allocPrint(q.e.a, "{s} can use the columns of the row, the fields of the user ({s}.id), constants, ==, /=, <, <=, >, >=, &&, ||, not, +, -, * and ++", .{ q.what, q.user.? }));
    }

    fn binop(q: *Sql, x: *Expr, op: []const u8, lhs: *Expr, rhs: *Expr, outer: u8) Error!ColType {
        const a = q.e.a;
        const info = tr.Parser.opInfo(op) orelse return q.notInDatabase(x);
        const paren = info.prec < outer;
        if (paren) try q.w("(");
        defer if (paren) q.out.appendSlice(a, ")") catch {};

        if (std.mem.eql(u8, op, "&&") or std.mem.eql(u8, op, "||")) {
            const lt = try q.expr(lhs, .{ .base = .bool }, info.prec);
            try q.expectType(lhs, lt, .{ .base = .bool }, op);
            try q.w(if (op[0] == '&') " AND " else " OR ");
            const rt = try q.expr(rhs, .{ .base = .bool }, info.prec);
            try q.expectType(rhs, rt, .{ .base = .bool }, op);
            return .{ .base = .bool };
        }
        if (isComparison(op)) {
            // `link.note == Nothing` is `note IS NULL`.
            const l_nothing = isNothing(lhs);
            const r_nothing = isNothing(rhs);
            if (l_nothing or r_nothing) {
                const side = if (l_nothing) rhs else lhs;
                const ty = (try q.typeOf(side)) orelse return q.notInDatabase(x);
                if (!ty.nullable) return q.e.errAtRule(exprText(if (l_nothing) lhs else rhs) orelse op, .query_type, try std.fmt.allocPrint(a, "this column is {s}, so it is never Nothing", .{try ty.an(a)}));
                const negate = std.mem.eql(u8, op, "/=") or std.mem.eql(u8, op, "!=");
                if (!negate and !std.mem.eql(u8, op, "==")) return q.e.errAtRule(op, .query_type, "compare with Nothing using == or /=");
                _ = try q.expr(side, null, 9);
                try q.w(if (negate) " IS NOT NULL" else " IS NULL");
                return .{ .base = .bool };
            }
            const lt0 = (try q.typeOf(lhs)) orelse if (q.policy) literalType(unparen(lhs)) else null;
            const rt0 = (try q.typeOf(rhs)) orelse if (q.policy) literalType(unparen(rhs)) else null;
            const nullable = (lt0 != null and lt0.?.nullable) or (rt0 != null and rt0.?.nullable);
            if (nullable and !(std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "/=") or std.mem.eql(u8, op, "!="))) {
                return q.e.errAtRule(op, .query_type, "a Maybe column is compared with == or /=: there is no order between Nothing and a value");
            }
            const lt = try q.expr(lhs, rt0, info.prec + 1);
            try q.w(" ");
            try q.w(if (nullable) (if (std.mem.eql(u8, op, "==")) "IS NOT DISTINCT FROM" else "IS DISTINCT FROM") else sqlOp(op));
            try q.w(" ");
            const rt = try q.expr(rhs, lt, info.prec + 1);
            if (!lt.eql(rt) and !(isNumber(lt) and isNumber(rt) and lt.nullable == rt.nullable)) {
                return q.e.errAtRule(op, .query_type, try std.fmt.allocPrint(a, "this compares {s} with {s}", .{ try lt.an(a), try rt.an(a) }));
            }
            return .{ .base = .bool };
        }
        if (isArith(op) or std.mem.eql(u8, op, "++")) {
            const known = (try q.typeOf(lhs)) orelse (try q.typeOf(rhs));
            const want: ?ColType = if (std.mem.eql(u8, op, "++")) ColType{ .base = .str } else known;
            const lt = try q.expr(lhs, want, info.prec);
            try q.w(" ");
            try q.w(sqlOp(op));
            try q.w(" ");
            const rt = try q.expr(rhs, want orelse lt, info.prec + 1);
            if (std.mem.eql(u8, op, "++")) {
                try q.expectType(lhs, lt, .{ .base = .str }, op);
                try q.expectType(rhs, rt, .{ .base = .str }, op);
                return .{ .base = .str };
            }
            if (!isNumber(lt) or lt.nullable or !lt.eql(rt)) {
                return q.e.errAtRule(op, .query_type, try std.fmt.allocPrint(a, "'{s}' works on two Ints or two Floats, not {s} and {s}", .{ op, try lt.an(a), try rt.an(a) }));
            }
            return lt;
        }
        return q.notInDatabase(x);
    }

    fn expectType(q: *Sql, x: *Expr, got: ColType, want: ColType, what: []const u8) Error!void {
        if (got.eql(want) or (isNumber(got) and isNumber(want) and got.nullable == want.nullable)) return;
        return q.e.errAtRule(exprText(x) orelse what, .query_type, try std.fmt.allocPrint(q.e.a, "'{s}' wants {s} here, but this is {s}", .{ what, try want.an(q.e.a), try got.an(q.e.a) }));
    }

    fn notInDatabase(q: *Sql, x: *Expr) Error {
        if (q.policy) return q.notInPolicy(x);
        return q.e.errAtRule(exprText(x) orelse "", .not_in_database, "this can't run in the database. A query's function can use the fields of the row, values from outside the query, ==, /=, <, <=, >, >=, &&, ||, not, +, -, * and ++. Compute other values before the query and use them in it.");
    }
};

fn isComparison(op: []const u8) bool {
    const ops = [_][]const u8{ "==", "/=", "!=", "<", "<=", ">", ">=" };
    for (ops) |o| if (std.mem.eql(u8, o, op)) return true;
    return false;
}

fn isArith(op: []const u8) bool {
    return std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-") or std.mem.eql(u8, op, "*");
}

fn isNumber(t: ColType) bool {
    return t.base == .int or t.base == .float;
}

pub fn unparen(x_in: *Expr) *Expr {
    var x = x_in;
    while (x.* == .paren) x = x.paren;
    return x;
}

pub fn isNothing(x_in: *Expr) bool {
    var x = x_in;
    while (x.* == .paren) x = x.paren;
    return x.* == .upper and std.mem.eql(u8, x.upper, "Nothing");
}

fn sqlOp(op: []const u8) []const u8 {
    if (std.mem.eql(u8, op, "==")) return "=";
    if (std.mem.eql(u8, op, "/=") or std.mem.eql(u8, op, "!=")) return "<>";
    if (std.mem.eql(u8, op, "++")) return "||";
    return op;
}

pub fn literalType(x: *Expr) ?ColType {
    return switch (x.*) {
        .string => .{ .base = .str },
        .literal => |l| if (l.len > 0 and l[0] == '\'') null else if (std.mem.findAny(u8, l, ".eE") != null and !std.mem.startsWith(u8, l, "0x")) .{ .base = .float } else .{ .base = .int },
        else => null,
    };
}

/// Source text to point an error at, for the expressions that have one.
pub fn exprText(x_in: *Expr) ?[]const u8 {
    var x = x_in;
    while (x.* == .paren) x = x.paren;
    return switch (x.*) {
        .ident, .upper, .literal, .string => |s| s,
        .field => |f| f.name,
        .binop => |b| b.op,
        .app => |app| exprText(app.func),
        .neg, .not => |inner| exprText(inner),
        .lambda => |l| if (l.body.result) |r| exprText(r) else null,
        .record => |r| if (r.fields.len > 0) r.fields[0].name else null,
        else => null,
    };
}

/// Whether the name `name` occurs in `x` (so `x` depends on the row).
fn mentions(x: *const Expr, name: []const u8) bool {
    return switch (x.*) {
        .ident => |n| std.mem.eql(u8, n, name),
        .ident_raw, .upper, .literal, .string, .unit, .underscore => false,
        .field => |f| mentions(f.target, name),
        .app => |app| blk: {
            if (mentions(app.func, name)) break :blk true;
            for (app.args) |arg| if (mentions(arg, name)) break :blk true;
            break :blk false;
        },
        .binop => |b| mentions(b.lhs, name) or mentions(b.rhs, name),
        .neg, .not, .try_, .paren => |inner| mentions(inner, name),
        .lambda => |l| mentionsBlock(l.body, name),
        .if_ => |f| mentions(f.cond, name) or mentionsBlock(f.then, name) or (f.else_ != null and mentionsBlock(f.else_.?, name)),
        .case => |c| blk: {
            if (mentions(c.subject, name)) break :blk true;
            for (c.arms) |arm| {
                if (arm.guard) |g| if (mentions(g, name)) break :blk true;
                if (mentionsBlock(arm.body, name)) break :blk true;
            }
            break :blk false;
        },
        .list, .tuple => |items| blk: {
            for (items) |item| if (mentions(item, name)) break :blk true;
            break :blk false;
        },
        .record => |r| blk: {
            if (r.base) |b| if (mentions(b, name)) break :blk true;
            for (r.fields) |f| {
                if (f.value) |v| {
                    if (mentions(v, name)) break :blk true;
                } else if (std.mem.eql(u8, f.name, name)) break :blk true;
            }
            break :blk false;
        },
        .kw => |k| mentions(k.arg, name),
    };
}

fn mentionsBlock(b: *const Block, name: []const u8) bool {
    for (b.stmts) |s| switch (s.kind) {
        .def => |d| if (mentionsBlock(d.body, name)) return true,
        .expect => |body| if (mentionsBlock(body, name)) return true,
        .expr => |x| if (mentions(x, name)) return true,
        .anno => {},
    };
    if (b.result) |r| return mentions(r, name);
    return false;
}
