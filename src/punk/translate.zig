//! punkroc: translates Elm-like `.punk` source into ordinary Roc source.
//!
//! The pipeline is lex -> parse (layout-sensitive, Elm-style offside rule)
//! -> emit Roc text. Everything is allocated in one arena owned by the caller.
//!
//! Step 3 of the punkroc plan adds Elm's semantics on top of Roc:
//! - `|>` passes the value as the LAST argument (`x |> f a` == `f a x`);
//! - builtins take the value they work on last (`List.map f xs`), see stdlib.zig;
//! - functions are curried: `add 1` is a function when `add` takes two
//!   arguments. The emitter knows the arity of every function defined in the
//!   file and of the builtins, and writes partial applications as lambdas.
//!   Functions it knows nothing about (lambda parameters, other modules) are
//!   called with all their arguments at once, as in Roc.

const std = @import("std");
const stdlib = @import("stdlib.zig");
const Allocator = std.mem.Allocator;

/// Where and why translation failed.
pub const Diagnostic = struct {
    line: u32 = 0,
    col: u32 = 0,
    message: []const u8 = "",
};

/// Errors from translating punkroc source.
pub const Error = error{ ParseError, OutOfMemory };

/// Translate a whole `.punk` module to Roc source text.
/// On `error.ParseError`, `diag` describes the problem.
pub fn translate(arena: Allocator, src: []const u8, diag: *Diagnostic) Error![]const u8 {
    const toks = try lex(arena, src, diag);
    var p = Parser{ .a = arena, .src = src, .toks = toks, .diag = diag };
    const items = try p.parseModule();
    var e = Emitter{ .a = arena, .diag = diag };
    try e.emitModule(items);
    return e.buf.items;
}

// Lexer

/// The kind of a punkroc token.
pub const Tag = enum {
    lower, // foo, foo!, _foo
    upper, // Foo, Foo.Bar
    qlower, // List.map, Foo.Bar.baz!
    int,
    float,
    string,
    char,
    lparen,
    rparen,
    lbrack,
    rbrack,
    lbrace,
    rbrace,
    comma,
    colon,
    equals,
    arrow, // ->
    fat_arrow, // =>
    bar, // |
    dot_field, // .name directly after an expression (text excludes the dot)
    double_dot, // ..
    underscore,
    op,
    question,
    kw_fn,
    kw_if,
    kw_then,
    kw_else,
    kw_case,
    kw_of,
    kw_type,
    kw_alias,
    kw_var,
    kw_for,
    kw_in,
    kw_while,
    kw_return,
    kw_crash,
    kw_dbg,
    kw_expect,
    kw_as,
    kw_header, // app, module, package, platform, hosted, import: copied verbatim
    eof,
};

/// One token, with its position and the comments before it.
pub const Token = struct {
    tag: Tag,
    text: []const u8,
    start: u32,
    line: u32,
    col: u32,
    first_on_line: bool,
    space_before: bool,
    blank_before: bool,
    /// Comments preceding this token, already in Roc form (`# ...`, `## ...`).
    comments: []const []const u8,
};

const keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "fn", .kw_fn },
    .{ "if", .kw_if },
    .{ "then", .kw_then },
    .{ "else", .kw_else },
    .{ "case", .kw_case },
    .{ "of", .kw_of },
    .{ "type", .kw_type },
    .{ "alias", .kw_alias },
    .{ "var", .kw_var },
    .{ "for", .kw_for },
    .{ "in", .kw_in },
    .{ "while", .kw_while },
    .{ "return", .kw_return },
    .{ "crash", .kw_crash },
    .{ "dbg", .kw_dbg },
    .{ "expect", .kw_expect },
    .{ "as", .kw_as },
    .{ "app", .kw_header },
    .{ "module", .kw_header },
    .{ "package", .kw_header },
    .{ "platform", .kw_header },
    .{ "hosted", .kw_header },
    .{ "import", .kw_header },
});

const multi_ops = [_][]const u8{ "..=", "..<", "|>", "<|", "->", "=>", "==", "/=", "!=", "<=", ">=", "&&", "||", "++", "//", "??", "::" };
const single_ops = "+-*/<>%^!&";

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn fail(diag: *Diagnostic, line: u32, col: u32, message: []const u8) error{ParseError} {
    diag.* = .{ .line = line, .col = col, .message = message };
    return error.ParseError;
}

/// Split punkroc source into tokens, keeping layout information.
pub fn lex(a: Allocator, src: []const u8, diag: *Diagnostic) Error![]Token {
    var toks: std.ArrayList(Token) = .empty;
    var comments: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    var line: u32 = 1;
    var line_start: usize = 0;
    var newlines_since_tok: u32 = 1;
    var space_before = true;
    var last_tok_line: u32 = 0;

    while (true) {
        // Skip whitespace and comments.
        while (i < src.len) {
            const c = src[i];
            if (c == '\n') {
                i += 1;
                line += 1;
                line_start = i;
                newlines_since_tok += 1;
                space_before = true;
            } else if (c == ' ' or c == '\r') {
                i += 1;
                space_before = true;
            } else if (c == '\t') {
                return fail(diag, line, @intCast(i - line_start + 1), "tabs are not allowed; indent with spaces");
            } else if (c == '-' and i + 1 < src.len and src[i + 1] == '-') {
                var j = i + 2;
                while (j < src.len and src[j] != '\n') j += 1;
                const body = std.mem.trimEnd(u8, src[i + 2 .. j], " \r");
                const text = if (body.len == 0) "#" else try std.fmt.allocPrint(a, "#{s}{s}", .{ if (body[0] == ' ') "" else " ", body });
                try comments.append(a, text);
                i = j;
                space_before = true;
            } else if (c == '{' and i + 1 < src.len and src[i + 1] == '-') {
                const is_doc = i + 2 < src.len and src[i + 2] == '|';
                var depth: u32 = 1;
                var j = i + (if (is_doc) @as(usize, 3) else 2);
                const body_start = j;
                while (j < src.len and depth > 0) {
                    if (src[j] == '{' and j + 1 < src.len and src[j + 1] == '-') {
                        depth += 1;
                        j += 2;
                    } else if (src[j] == '-' and j + 1 < src.len and src[j + 1] == '}') {
                        depth -= 1;
                        j += 2;
                    } else {
                        if (src[j] == '\n') {
                            line += 1;
                            line_start = j + 1;
                            newlines_since_tok += 1;
                        }
                        j += 1;
                    }
                }
                if (depth > 0) return fail(diag, line, 1, "unterminated block comment");
                const body = std.mem.trim(u8, src[body_start .. j - 2], " \r\n");
                const prefix: []const u8 = if (is_doc) "##" else "#";
                var it = std.mem.splitScalar(u8, body, '\n');
                while (it.next()) |raw| {
                    const l = std.mem.trim(u8, raw, " \r");
                    try comments.append(a, if (l.len == 0) prefix else try std.fmt.allocPrint(a, "{s} {s}", .{ prefix, l }));
                }
                i = j;
                space_before = true;
            } else break;
        }

        const col: u32 = @intCast(i - line_start + 1);
        const first_on_line = line != last_tok_line;
        const tok_start = i;
        var tag: Tag = undefined;
        var text_start = i;
        var text_end = i;

        if (i >= src.len) {
            tag = .eof;
        } else {
            const c = src[i];
            if (std.ascii.isLower(c) or (c == '_' and i + 1 < src.len and std.ascii.isAlphabetic(src[i + 1]))) {
                var j = i + 1;
                while (j < src.len and isIdentChar(src[j])) j += 1;
                if (j < src.len and src[j] == '!') j += 1;
                const word = src[i..j];
                tag = keywords.get(word) orelse .lower;
                text_end = j;
                i = j;
            } else if (std.ascii.isUpper(c)) {
                var j = i + 1;
                while (j < src.len and isIdentChar(src[j])) j += 1;
                tag = .upper;
                while (j + 1 < src.len and src[j] == '.' and std.ascii.isAlphabetic(src[j + 1])) {
                    var k = j + 2;
                    while (k < src.len and isIdentChar(src[k])) k += 1;
                    if (std.ascii.isLower(src[j + 1])) {
                        if (k < src.len and src[k] == '!') k += 1;
                        tag = .qlower;
                        j = k;
                        break;
                    }
                    j = k;
                }
                text_end = j;
                i = j;
            } else if (std.ascii.isDigit(c)) {
                var j = i + 1;
                tag = .int;
                if (c == '0' and j < src.len and (src[j] == 'x' or src[j] == 'b' or src[j] == 'o')) {
                    j += 1;
                    while (j < src.len and (std.ascii.isHex(src[j]) or src[j] == '_')) j += 1;
                } else {
                    while (j < src.len and (std.ascii.isDigit(src[j]) or src[j] == '_')) j += 1;
                    if (j + 1 < src.len and src[j] == '.' and std.ascii.isDigit(src[j + 1])) {
                        tag = .float;
                        j += 1;
                        while (j < src.len and (std.ascii.isDigit(src[j]) or src[j] == '_')) j += 1;
                    }
                    if (j < src.len and (src[j] == 'e' or src[j] == 'E')) {
                        var k = j + 1;
                        if (k < src.len and (src[k] == '+' or src[k] == '-')) k += 1;
                        if (k < src.len and std.ascii.isDigit(src[k])) {
                            tag = .float;
                            j = k;
                            while (j < src.len and std.ascii.isDigit(src[j])) j += 1;
                        }
                    }
                }
                text_end = j;
                i = j;
            } else if (c == '"') {
                if (i + 2 < src.len and src[i + 1] == '"' and src[i + 2] == '"') {
                    return fail(diag, line, col, "multi-line strings (\"\"\") are not supported yet");
                }
                var j = i + 1;
                var depth: u32 = 0; // depth of ${ ... } nesting
                while (true) {
                    if (j >= src.len or (src[j] == '\n' and depth == 0)) return fail(diag, line, col, "unterminated string");
                    const d = src[j];
                    if (depth == 0) {
                        if (d == '\\') {
                            j += 2;
                            continue;
                        }
                        if (d == '"') break;
                        if (d == '$' and j + 1 < src.len and src[j + 1] == '{') {
                            depth = 1;
                            j += 2;
                            continue;
                        }
                    } else {
                        if (d == '{') depth += 1;
                        if (d == '}') depth -= 1;
                        if (d == '"') {
                            // nested string inside interpolation
                            j += 1;
                            while (j < src.len and src[j] != '"') : (j += 1) {
                                if (src[j] == '\\') j += 1;
                            }
                        }
                    }
                    j += 1;
                }
                tag = .string;
                text_end = j + 1;
                i = j + 1;
            } else if (c == '\'') {
                var j = i + 1;
                while (j < src.len and src[j] != '\'' and src[j] != '\n') : (j += 1) {
                    if (src[j] == '\\') j += 1;
                }
                if (j >= src.len or src[j] != '\'') return fail(diag, line, col, "unterminated character literal");
                tag = .char;
                text_end = j + 1;
                i = j + 1;
            } else if (c == '.' and !(std.mem.startsWith(u8, src[i..], "..=") or std.mem.startsWith(u8, src[i..], "..<"))) {
                if (i + 1 < src.len and src[i + 1] == '.') {
                    tag = .double_dot;
                    text_end = i + 2;
                    i += 2;
                } else if (!space_before and i + 1 < src.len and std.ascii.isAlphanumeric(src[i + 1])) {
                    var j = i + 1;
                    while (j < src.len and isIdentChar(src[j])) j += 1;
                    tag = .dot_field;
                    text_start = i + 1;
                    text_end = j;
                    i = j;
                } else {
                    return fail(diag, line, col, "unexpected '.'; field access must directly follow a value, like person.name");
                }
            } else {
                tag = .op;
                var matched = false;
                for (multi_ops) |m| {
                    if (std.mem.startsWith(u8, src[i..], m)) {
                        text_end = i + m.len;
                        matched = true;
                        break;
                    }
                }
                if (!matched) {
                    text_end = i + 1;
                    switch (c) {
                        '(' => tag = .lparen,
                        ')' => tag = .rparen,
                        '[' => tag = .lbrack,
                        ']' => tag = .rbrack,
                        '{' => tag = .lbrace,
                        '}' => tag = .rbrace,
                        ',' => tag = .comma,
                        ':' => tag = .colon,
                        '=' => tag = .equals,
                        '|' => tag = .bar,
                        '?' => tag = .question,
                        '_' => tag = .underscore,
                        else => if (std.mem.findScalar(u8, single_ops, c) == null) {
                            return fail(diag, line, col, try std.fmt.allocPrint(a, "unexpected character '{c}'", .{c}));
                        },
                    }
                } else {
                    const t = src[i..text_end];
                    if (std.mem.eql(u8, t, "->")) tag = .arrow;
                    if (std.mem.eql(u8, t, "=>")) tag = .fat_arrow;
                }
                i = text_end;
            }
        }

        try toks.append(a, .{
            .tag = tag,
            .text = src[text_start..text_end],
            .start = @intCast(tok_start),
            .line = line,
            .col = col,
            .first_on_line = first_on_line,
            .space_before = space_before,
            .blank_before = newlines_since_tok >= 2 and toks.items.len > 0,
            .comments = try comments.toOwnedSlice(a),
        });
        if (tag == .eof) break;
        last_tok_line = line;
        newlines_since_tok = 0;
        space_before = false;
    }
    return toks.items;
}

// AST

/// A punkroc expression.
pub const Expr = union(enum) {
    ident: []const u8, // lower or qualified lower (List.map)
    ident_raw: []const u8, // a name the emitter made up, written as-is
    upper: []const u8, // tag or qualified tag
    literal: []const u8, // int, float, char
    string: []const u8, // raw, including quotes
    unit,
    underscore,
    field: struct { target: *Expr, name: []const u8 },
    app: struct { func: *Expr, args: []*Expr },
    binop: struct { op: []const u8, lhs: *Expr, rhs: *Expr },
    neg: *Expr,
    not: *Expr,
    try_: *Expr,
    lambda: struct { params: []*Pattern, body: *Block },
    if_: struct { cond: *Expr, then: *Block, else_: ?*Block }, // no else: statement-only `if`
    case: struct { subject: *Expr, arms: []Arm },
    list: []*Expr,
    tuple: []*Expr,
    paren: *Expr,
    record: struct { base: ?*Expr, fields: []Field },
    kw: struct { kw: []const u8, arg: *Expr }, // return, crash, dbg
};

/// A record field in an expression; `value` is null for punning (`{ x }`).
pub const Field = struct { name: []const u8, value: ?*Expr };
/// One branch of a `case`.
pub const Arm = struct { pats: []*Pattern, guard: ?*Expr, body: *Block };

/// An indented body: statements followed by an optional result expression.
pub const Block = struct {
    stmts: []Stmt,
    result: ?*Expr,
    result_blank_before: bool = false,
};

/// A statement inside a block.
pub const Stmt = struct {
    comments: []const []const u8,
    blank_before: bool,
    kind: union(enum) {
        def: struct { pat: *Pattern, body: *Block },
        var_def: struct { name: []const u8, body: *Block },
        anno: struct { name: []const u8, ty: *Type },
        for_: struct { pat: *Pattern, iter: *Expr, body: *Block },
        while_: struct { cond: *Expr, body: *Block },
        expect: *Block,
        expr: *Expr,
    },
};

/// A punkroc pattern.
pub const Pattern = union(enum) {
    ident: []const u8,
    underscore: []const u8,
    tag: struct { name: []const u8, args: []*Pattern },
    literal: []const u8,
    string: []const u8,
    record: []PField,
    list: []*Pattern,
    rest: ?[]const u8, // `..` or `..name` inside a list pattern
    tuple: []*Pattern,
    unit,
    as_: struct { pat: *Pattern, name: []const u8 },
};

/// A record field in a pattern; `pat` is null for punning.
pub const PField = struct { name: []const u8, pat: ?*Pattern };

/// A punkroc type annotation.
pub const Type = union(enum) {
    name: []const u8, // Upper, qualified, type variable or `_`
    app: struct { head: []const u8, args: []*Type },
    func: struct { args: []*Type, effectful: bool, ret: *Type },
    record: struct { fields: []TField, ext: ?[]const u8 },
    tuple: []*Type,
    unit,
    union_: struct { tags: []*Type, ext: ?[]const u8 }, // ext "" means open `..`
    paren: *Type,
};

/// A record field in a type.
pub const TField = struct { name: []const u8, ty: *Type };

/// A top-level item of a module.
pub const Item = struct {
    comments: []const []const u8,
    blank_before: bool,
    kind: union(enum) {
        raw: []const u8,
        anno: struct { name: []const u8, ty: *Type },
        def: struct { pat: *Pattern, body: *Block },
        type_alias: struct { name: []const u8, params: [][]const u8, ty: *Type },
        type_nominal: struct { name: []const u8, params: [][]const u8, alts: []*Type },
        expect: *Block,
    },
    trailing_comments: []const []const u8 = &.{},
};

// Parser

const Parser = struct {
    a: Allocator,
    src: []const u8,
    toks: []Token,
    diag: *Diagnostic,
    pos: usize = 0,
    /// Layout: a token that starts a line at a column <= stop_col ends the
    /// current construct. 0 disables layout (inside brackets).
    stop_col: u32 = 1,
    /// When set, tokens on a later line end the current construct
    /// (used for `for`/`while` headers, which have no closing keyword).
    line_limit: ?u32 = null,
    /// The token that starts the current statement, item or case branch is
    /// never a stop, even though it sits at the stop column.
    stmt_start: usize = std.math.maxInt(usize),

    fn tok(p: *Parser) Token {
        return p.toks[p.pos];
    }

    fn peekAt(p: *Parser, n: usize) Token {
        const idx = @min(p.pos + n, p.toks.len - 1);
        return p.toks[idx];
    }

    fn atStop(p: *Parser) bool {
        const t = p.tok();
        if (t.tag == .eof) return true;
        if (p.pos == p.stmt_start) return false;
        if (p.line_limit) |l| if (t.line > l) return true;
        return t.first_on_line and t.col <= p.stop_col;
    }

    fn at(p: *Parser, tag: Tag) bool {
        return !p.atStop() and p.tok().tag == tag;
    }

    fn advance(p: *Parser) Token {
        const t = p.tok();
        if (t.tag != .eof) p.pos += 1;
        return t;
    }

    fn errAt(p: *Parser, t: Token, comptime fmt: []const u8, args: anytype) Error {
        const msg = try std.fmt.allocPrint(p.a, fmt, args);
        return fail(p.diag, t.line, t.col, msg);
    }

    fn describe(t: Token) []const u8 {
        return if (t.tag == .eof) "end of file" else t.text;
    }

    fn expect(p: *Parser, tag: Tag, what: []const u8) Error!Token {
        if (!p.at(tag)) {
            const t = p.tok();
            return p.errAt(t, "expected {s} but found '{s}'", .{ what, describe(t) });
        }
        return p.advance();
    }

    /// Like `expect`, but ignores layout as long as the token is not to the
    /// left of `min_col`. Used for `then`, `else`, `of`.
    fn atLoose(p: *Parser, tag: Tag, min_col: u32) bool {
        const t = p.tok();
        if (t.tag != tag) return false;
        if (p.line_limit) |l| if (t.line > l) return false;
        return !t.first_on_line or t.col >= min_col;
    }

    fn new(p: *Parser, comptime T: type, v: T) Error!*T {
        const ptr = try p.a.create(T);
        ptr.* = v;
        return ptr;
    }

    // module

    fn parseModule(p: *Parser) Error![]Item {
        var items: std.ArrayList(Item) = .empty;
        p.stop_col = 1;
        while (p.tok().tag != .eof) {
            const t = p.tok();
            if (t.col != 1) return p.errAt(t, "top-level definitions must start at column 1", .{});
            p.stmt_start = p.pos;
            const kind = try p.parseItemKind();
            try items.append(p.a, .{ .comments = t.comments, .blank_before = t.blank_before, .kind = kind });
            const n = p.tok();
            if (n.tag != .eof and !(n.first_on_line and n.col == 1)) {
                return p.errAt(n, "unexpected '{s}'", .{describe(n)});
            }
        }
        if (p.tok().comments.len > 0) {
            if (items.items.len == 0) {
                try items.append(p.a, .{ .comments = p.tok().comments, .blank_before = false, .kind = .{ .raw = "" } });
            } else {
                items.items[items.items.len - 1].trailing_comments = p.tok().comments;
            }
        }
        return items.items;
    }

    fn parseItemKind(p: *Parser) Error!@FieldType(Item, "kind") {
        const t = p.tok();
        switch (t.tag) {
            .kw_header => {
                _ = p.advance();
                var last = t;
                while (!p.atStop()) last = p.advance();
                const end = @intFromPtr(last.text.ptr) - @intFromPtr(p.src.ptr) + last.text.len;
                const raw = std.mem.trimEnd(u8, p.src[t.start..end], " \r\n");
                // Comments inside a header end up in the raw text only if they
                // are Roc comments; drop the ones attached to tokens we skipped.
                return .{ .raw = raw };
            },
            .kw_type => return p.parseTypeDecl(),
            .kw_expect => {
                _ = p.advance();
                return .{ .expect = try p.parseBody() };
            },
            .lower => if (p.peekAt(1).tag == .colon) {
                _ = p.advance();
                _ = p.advance();
                return .{ .anno = .{ .name = t.text, .ty = try p.parseType() } };
            },
            .upper, .qlower, .int, .float, .string, .char, .lparen, .rparen, .lbrack, .rbrack, .lbrace, .rbrace, .comma, .colon, .equals, .arrow, .fat_arrow, .bar, .dot_field, .double_dot, .underscore, .op, .question, .kw_fn, .kw_if, .kw_then, .kw_else, .kw_case, .kw_of, .kw_alias, .kw_var, .kw_for, .kw_in, .kw_while, .kw_return, .kw_crash, .kw_dbg, .kw_as, .eof => {},
        }
        const lhs = try p.parseExpr();
        _ = try p.expect(.equals, "'=' in a definition");
        const pat = try p.exprToPattern(lhs, t);
        return .{ .def = .{ .pat = pat, .body = try p.parseBody() } };
    }

    fn parseTypeDecl(p: *Parser) Error!@FieldType(Item, "kind") {
        _ = p.advance(); // type
        const is_alias = p.at(.kw_alias);
        if (is_alias) _ = p.advance();
        const name = (try p.expect(.upper, "a type name")).text;
        var params: std.ArrayList([]const u8) = .empty;
        while (p.at(.lower)) try params.append(p.a, p.advance().text);
        _ = try p.expect(.equals, "'=' in a type declaration");
        if (is_alias) {
            return .{ .type_alias = .{ .name = name, .params = params.items, .ty = try p.parseType() } };
        }
        var alts: std.ArrayList(*Type) = .empty;
        try alts.append(p.a, try p.parseTypeApp());
        while (p.at(.bar)) {
            _ = p.advance();
            try alts.append(p.a, try p.parseTypeApp());
        }
        return .{ .type_nominal = .{ .name = name, .params = params.items, .alts = alts.items } };
    }

    // blocks

    /// After `=`, `->`, `then`, `else`, `in`: either an indented block on the
    /// following lines, or an expression on the same line.
    fn parseBody(p: *Parser) Error!*Block {
        const t = p.tok();
        if (p.atStop()) return p.errAt(t, "expected an expression here, indented further than the line above", .{});
        if (t.first_on_line) return p.parseBlock();
        const saved_limit = p.line_limit;
        p.line_limit = null;
        defer p.line_limit = saved_limit;
        const e = try p.parseExpr();
        return p.new(Block, .{ .stmts = &.{}, .result = e });
    }

    fn parseBlock(p: *Parser) Error!*Block {
        const block_col = p.tok().col;
        const saved_stop = p.stop_col;
        const saved_limit = p.line_limit;
        p.line_limit = null;
        defer {
            p.stop_col = saved_stop;
            p.line_limit = saved_limit;
        }
        var stmts: std.ArrayList(Stmt) = .empty;
        while (true) {
            p.stop_col = block_col;
            p.stmt_start = p.pos;
            const first = p.tok();
            try stmts.append(p.a, .{
                .comments = first.comments,
                .blank_before = first.blank_before and stmts.items.len > 0,
                .kind = try p.parseStmtKind(),
            });
            const n = p.tok();
            if (n.tag == .eof or !n.first_on_line) break;
            if (n.col == block_col) continue;
            if (n.col > block_col) return p.errAt(n, "unexpected indentation", .{});
            break;
        }
        var result: ?*Expr = null;
        var result_blank = false;
        if (stmts.items.len > 0) {
            const last = stmts.items[stmts.items.len - 1];
            if (last.kind == .expr and last.comments.len == 0) {
                result = last.kind.expr;
                result_blank = last.blank_before;
                stmts.items.len -= 1;
            }
        }
        return p.new(Block, .{ .stmts = stmts.items, .result = result, .result_blank_before = result_blank });
    }

    fn parseStmtKind(p: *Parser) Error!@FieldType(Stmt, "kind") {
        const t = p.tok();
        switch (t.tag) {
            .kw_var => {
                _ = p.advance();
                const name = (try p.expect(.lower, "a variable name after 'var'")).text;
                _ = try p.expect(.equals, "'=' after the variable name");
                return .{ .var_def = .{ .name = name, .body = try p.parseBody() } };
            },
            .kw_for => {
                _ = p.advance();
                const saved = p.line_limit;
                p.line_limit = t.line;
                const pat = try p.parsePattern();
                _ = try p.expect(.kw_in, "'in'");
                const iter = try p.parseExpr();
                p.line_limit = saved;
                return .{ .for_ = .{ .pat = pat, .iter = iter, .body = try p.parseBody() } };
            },
            .kw_while => {
                _ = p.advance();
                const saved = p.line_limit;
                p.line_limit = t.line;
                const cond = try p.parseExpr();
                p.line_limit = saved;
                return .{ .while_ = .{ .cond = cond, .body = try p.parseBody() } };
            },
            .kw_expect => {
                _ = p.advance();
                return .{ .expect = try p.parseBody() };
            },
            .lower => if (p.peekAt(1).tag == .colon and !p.peekAt(1).first_on_line) {
                _ = p.advance();
                _ = p.advance();
                return .{ .anno = .{ .name = t.text, .ty = try p.parseType() } };
            },
            .upper, .qlower, .int, .float, .string, .char, .lparen, .rparen, .lbrack, .rbrack, .lbrace, .rbrace, .comma, .colon, .equals, .arrow, .fat_arrow, .bar, .dot_field, .double_dot, .underscore, .op, .question, .kw_fn, .kw_if, .kw_then, .kw_else, .kw_case, .kw_of, .kw_type, .kw_alias, .kw_in, .kw_return, .kw_crash, .kw_dbg, .kw_as, .kw_header, .eof => {},
        }
        const e = try p.parseExpr();
        if (p.at(.equals)) {
            _ = p.advance();
            const pat = try p.exprToPattern(e, t);
            return .{ .def = .{ .pat = pat, .body = try p.parseBody() } };
        }
        return .{ .expr = e };
    }

    // expressions

    fn parseExpr(p: *Parser) Error!*Expr {
        return p.parseExprBp(0);
    }

    const OpInfo = struct { prec: u8, right: bool };

    fn opInfo(text: []const u8) ?OpInfo {
        const table = .{
            .{ "|>", 0, false },  .{ "<|", 0, true },
            .{ "??", 1, false },  .{ "||", 2, true },
            .{ "..=", 5, false }, .{ "..<", 5, false },
            .{ "&&", 3, true },   .{ "==", 4, false },
            .{ "/=", 4, false },  .{ "!=", 4, false },
            .{ "<", 4, false },   .{ "<=", 4, false },
            .{ ">", 4, false },   .{ ">=", 4, false },
            .{ "++", 5, true },   .{ "+", 6, false },
            .{ "-", 6, false },   .{ "*", 7, false },
            .{ "/", 7, false },   .{ "//", 7, false },
            .{ "%", 7, false },
        };
        inline for (table) |row| {
            if (std.mem.eql(u8, text, row[0])) return .{ .prec = row[1], .right = row[2] };
        }
        return null;
    }

    /// A binary operator may also start a continuation line at the same
    /// column as the statement (`|> f` lines, Elm style).
    fn binopHere(p: *Parser) ?OpInfo {
        const t = p.tok();
        if (t.tag != .op) return null;
        if (p.line_limit) |l| if (t.line > l) return null;
        if (t.first_on_line and t.col < p.stop_col) return null;
        if (t.first_on_line and p.stop_col == 1 and t.col == 1) return null;
        return opInfo(t.text);
    }

    fn parseExprBp(p: *Parser, min_prec: u8) Error!*Expr {
        var lhs = try p.parseOperand();
        while (p.binopHere()) |info| {
            if (info.prec < min_prec) break;
            const op_tok = p.advance();
            const rhs = try p.parseExprBp(if (info.right) info.prec else info.prec + 1);
            lhs = try p.makeBinop(op_tok.text, lhs, rhs);
        }
        return lhs;
    }

    fn makeBinop(p: *Parser, op: []const u8, lhs: *Expr, rhs: *Expr) Error!*Expr {
        if (std.mem.eql(u8, op, "|>")) {
            // `x |> f a?` means `(f x a)?`: the ? applies after piping.
            if (rhs.* == .try_) {
                return p.new(Expr, .{ .try_ = try p.makeBinop(op, lhs, rhs.try_) });
            }
            // data-last, as in Elm: x |> f a  ==  f a x
            if (rhs.* == .app) {
                var args: std.ArrayList(*Expr) = .empty;
                try args.appendSlice(p.a, rhs.app.args);
                try args.append(p.a, lhs);
                return p.new(Expr, .{ .app = .{ .func = rhs.app.func, .args = args.items } });
            }
            return p.new(Expr, .{ .app = .{ .func = rhs, .args = try p.a.dupe(*Expr, &.{lhs}) } });
        }
        if (std.mem.eql(u8, op, "<|")) {
            if (lhs.* == .app) {
                var args: std.ArrayList(*Expr) = .empty;
                try args.appendSlice(p.a, lhs.app.args);
                try args.append(p.a, rhs);
                return p.new(Expr, .{ .app = .{ .func = lhs.app.func, .args = args.items } });
            }
            return p.new(Expr, .{ .app = .{ .func = lhs, .args = try p.a.dupe(*Expr, &.{rhs}) } });
        }
        return p.new(Expr, .{ .binop = .{ .op = op, .lhs = lhs, .rhs = rhs } });
    }

    fn parseOperand(p: *Parser) Error!*Expr {
        const t = p.tok();
        if (p.atStop()) return p.errAt(t, "expected an expression but found '{s}'", .{describe(t)});
        switch (t.tag) {
            .kw_fn => return p.parseLambda(),
            .kw_if => return p.parseIf(),
            .kw_case => return p.parseCase(),
            .kw_return, .kw_crash, .kw_dbg => {
                _ = p.advance();
                return p.new(Expr, .{ .kw = .{ .kw = t.text, .arg = try p.parseExpr() } });
            },
            .op => if (std.mem.eql(u8, t.text, "-")) {
                _ = p.advance();
                return p.new(Expr, .{ .neg = try p.parseApplication() });
            } else if (std.mem.eql(u8, t.text, "!")) {
                _ = p.advance();
                return p.new(Expr, .{ .not = try p.parseApplication() });
            },
            .lower, .upper, .qlower, .int, .float, .string, .char, .lparen, .rparen, .lbrack, .rbrack, .lbrace, .rbrace, .comma, .colon, .equals, .arrow, .fat_arrow, .bar, .dot_field, .double_dot, .underscore, .question, .kw_then, .kw_else, .kw_of, .kw_type, .kw_alias, .kw_var, .kw_for, .kw_in, .kw_while, .kw_expect, .kw_as, .kw_header, .eof => {},
        }
        return p.parseApplication();
    }

    fn isAtomStart(p: *Parser) bool {
        if (p.atStop()) return false;
        const t = p.tok();
        return switch (t.tag) {
            .lower, .upper, .qlower, .int, .float, .string, .char, .lparen, .lbrack, .lbrace, .underscore => true,
            // `f -1` passes a negative number; `f - 1` subtracts.
            .op => std.mem.eql(u8, t.text, "-") and t.space_before and !p.peekAt(1).space_before and
                (p.peekAt(1).tag == .int or p.peekAt(1).tag == .float or p.peekAt(1).tag == .lower),
            .rparen, .rbrack, .rbrace, .comma, .colon, .equals, .arrow, .fat_arrow, .bar, .dot_field, .double_dot, .question, .kw_fn, .kw_if, .kw_then, .kw_else, .kw_case, .kw_of, .kw_type, .kw_alias, .kw_var, .kw_for, .kw_in, .kw_while, .kw_return, .kw_crash, .kw_dbg, .kw_expect, .kw_as, .kw_header, .eof => false,
        };
    }

    fn parseApplication(p: *Parser) Error!*Expr {
        const head = try p.parseAtom();
        var args: std.ArrayList(*Expr) = .empty;
        while (p.isAtomStart()) try args.append(p.a, try p.parseAtom());
        var e = head;
        if (args.items.len > 0) {
            if (head.* == .ident and std.mem.eql(u8, head.ident, "not") and args.items.len == 1) {
                e = try p.new(Expr, .{ .not = args.items[0] });
            } else {
                e = try p.new(Expr, .{ .app = .{ .func = head, .args = args.items } });
            }
        }
        if (p.at(.question) and !p.tok().space_before) {
            _ = p.advance();
            e = try p.new(Expr, .{ .try_ = e });
        }
        return e;
    }

    fn parseAtom(p: *Parser) Error!*Expr {
        const t = p.tok();
        if (p.atStop()) return p.errAt(t, "expected an expression but found '{s}'", .{describe(t)});
        var e: *Expr = switch (t.tag) {
            .lower, .qlower => blk: {
                _ = p.advance();
                break :blk try p.new(Expr, .{ .ident = t.text });
            },
            .upper => blk: {
                _ = p.advance();
                break :blk try p.new(Expr, .{ .upper = t.text });
            },
            .int, .float, .char => blk: {
                _ = p.advance();
                break :blk try p.new(Expr, .{ .literal = t.text });
            },
            .string => blk: {
                _ = p.advance();
                break :blk try p.new(Expr, .{ .string = t.text });
            },
            .underscore => blk: {
                _ = p.advance();
                break :blk try p.new(Expr, .underscore);
            },
            .op => blk: {
                // negative literal argument: f -1
                _ = p.advance();
                break :blk try p.new(Expr, .{ .neg = try p.parseAtom() });
            },
            .lparen => try p.parseParenExpr(),
            .lbrack => try p.parseListExpr(),
            .lbrace => try p.parseRecordExpr(),
            .rparen, .rbrack, .rbrace, .comma, .colon, .equals, .arrow, .fat_arrow, .bar, .dot_field, .double_dot, .question, .kw_fn, .kw_if, .kw_then, .kw_else, .kw_case, .kw_of, .kw_type, .kw_alias, .kw_var, .kw_for, .kw_in, .kw_while, .kw_return, .kw_crash, .kw_dbg, .kw_expect, .kw_as, .kw_header, .eof => return p.errAt(t, "expected an expression but found '{s}'", .{describe(t)}),
        };
        while (p.tok().tag == .dot_field) {
            const f = p.advance();
            e = try p.new(Expr, .{ .field = .{ .target = e, .name = f.text } });
        }
        return e;
    }

    const Saved = struct { stop: u32, limit: ?u32 };

    fn enterBrackets(p: *Parser) Saved {
        const s = Saved{ .stop = p.stop_col, .limit = p.line_limit };
        p.stop_col = 0;
        p.line_limit = null;
        return s;
    }

    fn leaveBrackets(p: *Parser, s: Saved) void {
        p.stop_col = s.stop;
        p.line_limit = s.limit;
    }

    fn parseParenExpr(p: *Parser) Error!*Expr {
        _ = p.advance();
        const s = p.enterBrackets();
        defer p.leaveBrackets(s);
        if (p.at(.rparen)) {
            _ = p.advance();
            return p.new(Expr, .unit);
        }
        const first = try p.parseExpr();
        if (p.at(.comma)) {
            var items: std.ArrayList(*Expr) = .empty;
            try items.append(p.a, first);
            while (p.at(.comma)) {
                _ = p.advance();
                if (p.at(.rparen)) break;
                try items.append(p.a, try p.parseExpr());
            }
            _ = try p.expect(.rparen, "')'");
            return p.new(Expr, .{ .tuple = items.items });
        }
        _ = try p.expect(.rparen, "')'");
        return p.new(Expr, .{ .paren = first });
    }

    fn parseListExpr(p: *Parser) Error!*Expr {
        _ = p.advance();
        const s = p.enterBrackets();
        defer p.leaveBrackets(s);
        var items: std.ArrayList(*Expr) = .empty;
        while (!p.at(.rbrack)) {
            try items.append(p.a, try p.parseExpr());
            if (!p.at(.comma)) break;
            _ = p.advance();
        }
        _ = try p.expect(.rbrack, "']' or ','");
        return p.new(Expr, .{ .list = items.items });
    }

    fn parseRecordExpr(p: *Parser) Error!*Expr {
        _ = p.advance();
        const s = p.enterBrackets();
        defer p.leaveBrackets(s);
        var base: ?*Expr = null;
        if (p.at(.lower) and p.peekAt(1).tag == .bar) {
            base = try p.new(Expr, .{ .ident = p.advance().text });
            _ = p.advance();
        }
        var fields: std.ArrayList(Field) = .empty;
        while (!p.at(.rbrace)) {
            const name = (try p.expect(.lower, "a field name")).text;
            var value: ?*Expr = null;
            if (p.at(.equals)) {
                _ = p.advance();
                value = try p.parseExpr();
            } else if (p.at(.colon)) {
                return p.errAt(p.tok(), "record fields use '=' in punkroc, like {{ {s} = ... }}", .{name});
            }
            try fields.append(p.a, .{ .name = name, .value = value });
            if (!p.at(.comma)) break;
            _ = p.advance();
        }
        _ = try p.expect(.rbrace, "'}' or ','");
        return p.new(Expr, .{ .record = .{ .base = base, .fields = fields.items } });
    }

    fn parseLambda(p: *Parser) Error!*Expr {
        _ = p.advance(); // fn
        var params: std.ArrayList(*Pattern) = .empty;
        if (p.at(.lparen) and p.peekAt(1).tag == .rparen) {
            _ = p.advance();
            _ = p.advance();
        } else {
            while (true) {
                try params.append(p.a, try p.parsePattern());
                if (!p.at(.comma)) break;
                _ = p.advance();
            }
        }
        _ = try p.expect(.arrow, "'->' after the lambda arguments");
        return p.new(Expr, .{ .lambda = .{ .params = params.items, .body = try p.parseBody() } });
    }

    fn parseIf(p: *Parser) Error!*Expr {
        return p.parseIfFrom(p.tok().col);
    }

    /// `min_col` is the column of the first `if` in an `else if` chain, so
    /// that every `else` may line up with it.
    fn parseIfFrom(p: *Parser, min_col: u32) Error!*Expr {
        _ = p.advance(); // if
        const cond = try p.parseExpr();
        if (!p.atLoose(.kw_then, min_col)) return p.errAt(p.tok(), "expected 'then' but found '{s}'", .{describe(p.tok())});
        _ = p.advance();
        const then = try p.parseBody();
        if (!p.atLoose(.kw_else, min_col)) {
            // Roc allows an `if` without `else` as a statement (its value is {}).
            return p.new(Expr, .{ .if_ = .{ .cond = cond, .then = then, .else_ = null } });
        }
        _ = p.advance();
        var else_: *Block = undefined;
        if (p.tok().tag == .kw_if and !p.tok().first_on_line) {
            const nested = try p.parseIfFrom(min_col);
            else_ = try p.new(Block, .{ .stmts = &.{}, .result = nested });
        } else {
            else_ = try p.parseBody();
        }
        return p.new(Expr, .{ .if_ = .{ .cond = cond, .then = then, .else_ = else_ } });
    }

    fn parseCase(p: *Parser) Error!*Expr {
        const case_tok = p.advance();
        const subject = try p.parseExpr();
        if (!p.atLoose(.kw_of, case_tok.col)) return p.errAt(p.tok(), "expected 'of' but found '{s}'", .{describe(p.tok())});
        _ = p.advance();
        const first = p.tok();
        if (!first.first_on_line or p.atStop()) {
            return p.errAt(first, "the branches of a case go on their own lines, indented further than 'case'", .{});
        }
        const arm_col = first.col;
        const saved = p.stop_col;
        const saved_limit = p.line_limit;
        p.line_limit = null;
        defer {
            p.stop_col = saved;
            p.line_limit = saved_limit;
        }
        var arms: std.ArrayList(Arm) = .empty;
        while (true) {
            p.stop_col = arm_col;
            p.stmt_start = p.pos;
            var pats: std.ArrayList(*Pattern) = .empty;
            try pats.append(p.a, try p.parsePattern());
            while (p.at(.bar)) {
                _ = p.advance();
                try pats.append(p.a, try p.parsePattern());
            }
            var guard: ?*Expr = null;
            if (p.at(.kw_if)) {
                _ = p.advance();
                guard = try p.parseExpr();
            }
            _ = try p.expect(.arrow, "'->' after the pattern");
            try arms.append(p.a, .{ .pats = pats.items, .guard = guard, .body = try p.parseBody() });
            const n = p.tok();
            if (n.tag != .eof and n.first_on_line and n.col == arm_col) continue;
            if (n.tag != .eof and n.first_on_line and n.col > arm_col) return p.errAt(n, "unexpected indentation", .{});
            break;
        }
        return p.new(Expr, .{ .case = .{ .subject = subject, .arms = arms.items } });
    }

    // patterns

    fn parsePattern(p: *Parser) Error!*Pattern {
        var pat = try p.parsePatternApp();
        if (p.at(.kw_as)) {
            _ = p.advance();
            const name = (try p.expect(.lower, "a name after 'as'")).text;
            pat = try p.new(Pattern, .{ .as_ = .{ .pat = pat, .name = name } });
        }
        return pat;
    }

    fn parsePatternApp(p: *Parser) Error!*Pattern {
        if (p.at(.upper)) {
            const name = p.advance().text;
            var args: std.ArrayList(*Pattern) = .empty;
            while (!p.atStop() and switch (p.tok().tag) {
                .lower, .upper, .int, .float, .string, .char, .lparen, .lbrack, .lbrace, .underscore => true,
                .qlower, .rparen, .rbrack, .rbrace, .comma, .colon, .equals, .arrow, .fat_arrow, .bar, .dot_field, .double_dot, .op, .question, .kw_fn, .kw_if, .kw_then, .kw_else, .kw_case, .kw_of, .kw_type, .kw_alias, .kw_var, .kw_for, .kw_in, .kw_while, .kw_return, .kw_crash, .kw_dbg, .kw_expect, .kw_as, .kw_header, .eof => false,
            }) try args.append(p.a, try p.parsePatternAtom());
            return p.new(Pattern, .{ .tag = .{ .name = name, .args = args.items } });
        }
        return p.parsePatternAtom();
    }

    fn parsePatternAtom(p: *Parser) Error!*Pattern {
        const t = p.tok();
        if (p.atStop()) return p.errAt(t, "expected a pattern but found '{s}'", .{describe(t)});
        switch (t.tag) {
            .lower => {
                _ = p.advance();
                if (t.text[0] == '_') return p.new(Pattern, .{ .underscore = t.text });
                return p.new(Pattern, .{ .ident = t.text });
            },
            .underscore => {
                _ = p.advance();
                return p.new(Pattern, .{ .underscore = "_" });
            },
            .upper => {
                _ = p.advance();
                return p.new(Pattern, .{ .tag = .{ .name = t.text, .args = &.{} } });
            },
            .int, .float, .char => {
                _ = p.advance();
                return p.new(Pattern, .{ .literal = t.text });
            },
            .string => {
                _ = p.advance();
                return p.new(Pattern, .{ .string = t.text });
            },
            .op => if (std.mem.eql(u8, t.text, "-") and (p.peekAt(1).tag == .int or p.peekAt(1).tag == .float)) {
                _ = p.advance();
                const n = p.advance();
                return p.new(Pattern, .{ .literal = try std.fmt.allocPrint(p.a, "-{s}", .{n.text}) });
            },
            .lparen => {
                _ = p.advance();
                const s = p.enterBrackets();
                defer p.leaveBrackets(s);
                if (p.at(.rparen)) {
                    _ = p.advance();
                    return p.new(Pattern, .unit);
                }
                const first = try p.parsePattern();
                if (p.at(.comma)) {
                    var items: std.ArrayList(*Pattern) = .empty;
                    try items.append(p.a, first);
                    while (p.at(.comma)) {
                        _ = p.advance();
                        try items.append(p.a, try p.parsePattern());
                    }
                    _ = try p.expect(.rparen, "')'");
                    return p.new(Pattern, .{ .tuple = items.items });
                }
                _ = try p.expect(.rparen, "')'");
                return first;
            },
            .lbrack => {
                _ = p.advance();
                const s = p.enterBrackets();
                defer p.leaveBrackets(s);
                var items: std.ArrayList(*Pattern) = .empty;
                while (!p.at(.rbrack)) {
                    if (p.at(.double_dot)) {
                        _ = p.advance();
                        var name: ?[]const u8 = null;
                        if (p.at(.lower)) name = p.advance().text;
                        try items.append(p.a, try p.new(Pattern, .{ .rest = name }));
                    } else {
                        try items.append(p.a, try p.parsePattern());
                    }
                    if (!p.at(.comma)) break;
                    _ = p.advance();
                }
                _ = try p.expect(.rbrack, "']' or ','");
                return p.new(Pattern, .{ .list = items.items });
            },
            .lbrace => {
                _ = p.advance();
                const s = p.enterBrackets();
                defer p.leaveBrackets(s);
                var fields: std.ArrayList(PField) = .empty;
                while (!p.at(.rbrace)) {
                    const name = (try p.expect(.lower, "a field name")).text;
                    var sub: ?*Pattern = null;
                    if (p.at(.equals)) {
                        _ = p.advance();
                        sub = try p.parsePattern();
                    }
                    try fields.append(p.a, .{ .name = name, .pat = sub });
                    if (!p.at(.comma)) break;
                    _ = p.advance();
                }
                _ = try p.expect(.rbrace, "'}' or ','");
                return p.new(Pattern, .{ .record = fields.items });
            },
            .qlower, .rparen, .rbrack, .rbrace, .comma, .colon, .equals, .arrow, .fat_arrow, .bar, .dot_field, .double_dot, .question, .kw_fn, .kw_if, .kw_then, .kw_else, .kw_case, .kw_of, .kw_type, .kw_alias, .kw_var, .kw_for, .kw_in, .kw_while, .kw_return, .kw_crash, .kw_dbg, .kw_expect, .kw_as, .kw_header, .eof => {},
        }
        return p.errAt(t, "expected a pattern but found '{s}'", .{describe(t)});
    }

    /// `x = ...`, `Ok v = ...`, `(a, b) = ...`: we parse the left side as an
    /// expression and convert it.
    fn exprToPattern(p: *Parser, e: *Expr, at_tok: Token) Error!*Pattern {
        return switch (e.*) {
            .ident => |name| if (std.mem.findScalar(u8, name, '.') != null)
                p.errAt(at_tok, "cannot define a qualified name", .{})
            else if (name[0] == '_')
                p.new(Pattern, .{ .underscore = name })
            else
                p.new(Pattern, .{ .ident = name }),
            .underscore => p.new(Pattern, .{ .underscore = "_" }),
            .upper => |name| p.new(Pattern, .{ .tag = .{ .name = name, .args = &.{} } }),
            .literal => |l| p.new(Pattern, .{ .literal = l }),
            .string => |s| p.new(Pattern, .{ .string = s }),
            .unit => p.new(Pattern, .unit),
            .paren => |inner| p.exprToPattern(inner, at_tok),
            .app => |app| blk: {
                if (app.func.* != .upper) break :blk p.errAt(at_tok, "the left side of '=' must be a name or a pattern", .{});
                var args: std.ArrayList(*Pattern) = .empty;
                for (app.args) |arg| try args.append(p.a, try p.exprToPattern(arg, at_tok));
                break :blk p.new(Pattern, .{ .tag = .{ .name = app.func.upper, .args = args.items } });
            },
            .tuple, .list => |items| blk: {
                var pats: std.ArrayList(*Pattern) = .empty;
                for (items) |item| try pats.append(p.a, try p.exprToPattern(item, at_tok));
                break :blk if (e.* == .tuple) p.new(Pattern, .{ .tuple = pats.items }) else p.new(Pattern, .{ .list = pats.items });
            },
            .record => |r| blk: {
                if (r.base != null) break :blk p.errAt(at_tok, "a record update cannot be a pattern", .{});
                var fields: std.ArrayList(PField) = .empty;
                for (r.fields) |f| try fields.append(p.a, .{
                    .name = f.name,
                    .pat = if (f.value) |v| try p.exprToPattern(v, at_tok) else null,
                });
                break :blk p.new(Pattern, .{ .record = fields.items });
            },
            .ident_raw, .field, .binop, .neg, .not, .try_, .lambda, .if_, .case, .kw => p.errAt(at_tok, "the left side of '=' must be a name or a pattern", .{}),
        };
    }

    // types

    fn parseType(p: *Parser) Error!*Type {
        var items: std.ArrayList(*Type) = .empty;
        try items.append(p.a, try p.parseTypeApp());
        while (p.at(.comma)) {
            _ = p.advance();
            try items.append(p.a, try p.parseTypeApp());
        }
        if (p.at(.arrow) or p.at(.fat_arrow)) {
            const effectful = p.advance().tag == .fat_arrow;
            const ret = try p.parseType();
            return p.new(Type, .{ .func = .{ .args = items.items, .effectful = effectful, .ret = ret } });
        }
        if (items.items.len > 1) return p.errAt(p.tok(), "expected '->' after the function argument types", .{});
        return items.items[0];
    }

    /// A type that cannot take several comma-separated arguments, for places
    /// where a comma means something else (record fields).
    fn parseTypeNoComma(p: *Parser) Error!*Type {
        const first = try p.parseTypeApp();
        if (p.at(.arrow) or p.at(.fat_arrow)) {
            const effectful = p.advance().tag == .fat_arrow;
            const ret = try p.parseTypeNoComma();
            return p.new(Type, .{ .func = .{ .args = try p.a.dupe(*Type, &.{first}), .effectful = effectful, .ret = ret } });
        }
        return first;
    }

    fn isTypeAtomStart(p: *Parser) bool {
        if (p.atStop()) return false;
        return switch (p.tok().tag) {
            .lower, .upper, .lparen, .lbrace, .underscore => true,
            .qlower, .int, .float, .string, .char, .rparen, .lbrack, .rbrack, .rbrace, .comma, .colon, .equals, .arrow, .fat_arrow, .bar, .dot_field, .double_dot, .op, .question, .kw_fn, .kw_if, .kw_then, .kw_else, .kw_case, .kw_of, .kw_type, .kw_alias, .kw_var, .kw_for, .kw_in, .kw_while, .kw_return, .kw_crash, .kw_dbg, .kw_expect, .kw_as, .kw_header, .eof => false,
        };
    }

    fn parseTypeApp(p: *Parser) Error!*Type {
        if (p.at(.upper)) {
            const head = p.advance().text;
            var args: std.ArrayList(*Type) = .empty;
            while (p.isTypeAtomStart()) try args.append(p.a, try p.parseTypeAtom());
            if (args.items.len == 0) return p.new(Type, .{ .name = head });
            return p.new(Type, .{ .app = .{ .head = head, .args = args.items } });
        }
        return p.parseTypeAtom();
    }

    fn parseTypeAtom(p: *Parser) Error!*Type {
        const t = p.tok();
        if (p.atStop()) return p.errAt(t, "expected a type but found '{s}'", .{describe(t)});
        switch (t.tag) {
            .lower, .upper => {
                _ = p.advance();
                return p.new(Type, .{ .name = t.text });
            },
            .underscore => {
                _ = p.advance();
                return p.new(Type, .{ .name = "_" });
            },
            .lparen => {
                _ = p.advance();
                const s = p.enterBrackets();
                defer p.leaveBrackets(s);
                if (p.at(.rparen)) {
                    _ = p.advance();
                    return p.new(Type, .unit);
                }
                var tags: std.ArrayList(*Type) = .empty;
                if (!p.at(.double_dot)) try tags.append(p.a, try p.parseTypeApp());
                if (p.at(.bar) or p.at(.double_dot)) {
                    var ext: ?[]const u8 = null;
                    while (true) {
                        if (p.at(.bar)) _ = p.advance();
                        if (p.at(.double_dot)) {
                            _ = p.advance();
                            ext = if (p.at(.lower)) p.advance().text else "";
                            break;
                        }
                        try tags.append(p.a, try p.parseTypeApp());
                        if (!p.at(.bar)) break;
                    }
                    _ = try p.expect(.rparen, "')' to close the tag union");
                    return p.new(Type, .{ .union_ = .{ .tags = tags.items, .ext = ext } });
                }
                var items = tags;
                while (p.at(.comma)) {
                    _ = p.advance();
                    try items.append(p.a, try p.parseTypeApp());
                }
                if (p.at(.arrow) or p.at(.fat_arrow)) {
                    const effectful = p.advance().tag == .fat_arrow;
                    const ret = try p.parseType();
                    _ = try p.expect(.rparen, "')'");
                    const f = try p.new(Type, .{ .func = .{ .args = items.items, .effectful = effectful, .ret = ret } });
                    return p.new(Type, .{ .paren = f });
                }
                _ = try p.expect(.rparen, "')'");
                if (items.items.len > 1) return p.new(Type, .{ .tuple = items.items });
                return p.new(Type, .{ .paren = items.items[0] });
            },
            .lbrace => {
                _ = p.advance();
                const s = p.enterBrackets();
                defer p.leaveBrackets(s);
                var ext: ?[]const u8 = null;
                if (p.at(.lower) and p.peekAt(1).tag == .bar) {
                    ext = p.advance().text;
                    _ = p.advance();
                }
                var fields: std.ArrayList(TField) = .empty;
                while (!p.at(.rbrace)) {
                    const name = (try p.expect(.lower, "a field name")).text;
                    _ = try p.expect(.colon, "':' after the field name");
                    try fields.append(p.a, .{ .name = name, .ty = try p.parseTypeNoComma() });
                    if (!p.at(.comma)) break;
                    _ = p.advance();
                }
                _ = try p.expect(.rbrace, "'}' or ','");
                return p.new(Type, .{ .record = .{ .fields = fields.items, .ext = ext } });
            },
            .qlower, .int, .float, .string, .char, .rparen, .lbrack, .rbrack, .rbrace, .comma, .colon, .equals, .arrow, .fat_arrow, .bar, .dot_field, .double_dot, .op, .question, .kw_fn, .kw_if, .kw_then, .kw_else, .kw_case, .kw_of, .kw_type, .kw_alias, .kw_var, .kw_for, .kw_in, .kw_while, .kw_return, .kw_crash, .kw_dbg, .kw_expect, .kw_as, .kw_header, .eof => {},
        }
        return p.errAt(t, "expected a type but found '{s}'", .{describe(t)});
    }
};

// Emitter

/// camelCase -> snake_case for lower identifiers. `toUTF8` -> `to_utf8`,
/// `keepIf!` -> `keep_if!`. Already snake_case names are unchanged.
pub fn snake(a: Allocator, name: []const u8) Allocator.Error![]const u8 {
    var needs = false;
    for (name) |c| if (std.ascii.isUpper(c)) {
        needs = true;
    };
    if (!needs) return name;
    var out: std.ArrayList(u8) = .empty;
    for (name, 0..) |c, i| {
        if (std.ascii.isUpper(c)) {
            if (i > 0) {
                const prev = name[i - 1];
                const next_lower = i + 1 < name.len and std.ascii.isLower(name[i + 1]);
                if (std.ascii.isLower(prev) or std.ascii.isDigit(prev) or (std.ascii.isUpper(prev) and next_lower)) {
                    try out.append(a, '_');
                }
            }
            try out.append(a, std.ascii.toLower(c));
        } else try out.append(a, c);
    }
    return out.items;
}

/// Qualified lower names: only the last segment is converted (List.keepIf -> List.keep_if).
fn snakeQualified(a: Allocator, name: []const u8) Allocator.Error![]const u8 {
    const dot = std.mem.findScalarLast(u8, name, '.') orelse return snake(a, name);
    return std.fmt.allocPrint(a, "{s}{s}", .{ name[0 .. dot + 1], try snake(a, name[dot + 1 ..]) });
}

const Emitter = struct {
    a: Allocator,
    diag: *Diagnostic,
    buf: std.ArrayList(u8) = .empty,
    indent: u32 = 0,
    vars: std.ArrayList([]const u8) = .empty,
    /// Names in scope, innermost last, with the arity of the function they
    /// hold when the emitter knows it (null: not a known function).
    scope: std.ArrayList(Binding) = .empty,
    /// Counter for the names of generated lambda parameters.
    fresh: u32 = 0,

    const Binding = struct { name: []const u8, arity: ?u8, anno: bool = false };

    fn w(e: *Emitter, s: []const u8) Error!void {
        try e.buf.appendSlice(e.a, s);
    }

    fn nl(e: *Emitter) Error!void {
        try e.w("\n");
        var i: u32 = 0;
        while (i < e.indent) : (i += 1) try e.w("    ");
    }

    fn comments(e: *Emitter, cs: []const []const u8) Error!void {
        for (cs) |c| {
            try e.w(c);
            try e.nl();
        }
    }

    /// A module file starts with an Elm-style header, `module Name exposing (..)`.
    /// Roc wants a type module instead: `Name := [].{ ... }` with the
    /// definitions inside the block. When the module declares `type Name`,
    /// that type carries the block.
    fn emitModule(e: *Emitter, items: []Item) Error!void {
        try e.bindItems(items);
        const module_name = moduleHeaderName(items) orelse {
            try e.emitItems(items);
            try e.w("\n");
            return;
        };

        // The header and imports stay at the top level; the rest goes in the block.
        var top: std.ArrayList(Item) = .empty;
        var inner: std.ArrayList(Item) = .empty;
        var own_type: ?Item = null;
        for (items[1..]) |item| {
            switch (item.kind) {
                .raw => |r| if (std.mem.startsWith(u8, r, "import")) {
                    try top.append(e.a, item);
                    continue;
                },
                .type_nominal => |tn| if (own_type == null and std.mem.eql(u8, tn.name, module_name)) {
                    own_type = item;
                    continue;
                },
                .anno, .def, .type_alias, .expect => {},
            }
            try inner.append(e.a, item);
        }

        // The header's own comments (e.g. a module doc comment) go first.
        try e.comments(items[0].comments);
        try e.emitItems(top.items);
        if (top.items.len > 0) try e.w("\n\n");
        if (own_type) |t| {
            try e.comments(t.comments);
            try e.emitItems(&.{.{ .comments = &.{}, .blank_before = false, .kind = t.kind }});
        } else {
            try e.w(module_name);
            try e.w(" := []");
        }
        try e.w(".{");
        e.indent += 1;
        try e.nl();
        try e.emitItems(inner.items);
        e.indent -= 1;
        try e.w("\n}\n");
    }

    fn moduleHeaderName(items: []Item) ?[]const u8 {
        if (items.len == 0) return null;
        const raw = switch (items[0].kind) {
            .raw => |r| r,
            .anno, .def, .type_alias, .type_nominal, .expect => return null,
        };
        if (!std.mem.startsWith(u8, raw, "module ")) return null;
        const rest = std.mem.trimStart(u8, raw["module ".len..], " ");
        const end = std.mem.findAny(u8, rest, " \n") orelse rest.len;
        if (end == 0 or !std.ascii.isUpper(rest[0])) return null;
        return rest[0..end];
    }

    fn emitItems(e: *Emitter, items: []const Item) Error!void {
        for (items, 0..) |item, i| {
            if (i > 0) {
                if (item.blank_before) try e.w("\n");
                try e.nl();
            }
            try e.comments(item.comments);
            switch (item.kind) {
                .raw => |r| try e.w(r),
                .anno => |an| {
                    try e.w(try snake(e.a, an.name));
                    try e.w(" : ");
                    try e.emitType(an.ty, false);
                },
                .def => |d| try e.emitDef(d.pat, d.body),
                .type_alias => |ta| {
                    try e.emitTypeHead(ta.name, ta.params);
                    try e.w(" : ");
                    try e.emitType(ta.ty, false);
                },
                .type_nominal => |tn| {
                    try e.emitTypeHead(tn.name, tn.params);
                    try e.w(" := [");
                    for (tn.alts, 0..) |alt, j| {
                        if (j > 0) try e.w(", ");
                        try e.emitType(alt, false);
                    }
                    try e.w("]");
                },
                .expect => |b| {
                    try e.w("expect ");
                    try e.emitBody(b);
                },
            }
            for (item.trailing_comments) |c| {
                try e.nl();
                try e.w(c);
            }
        }
    }

    fn emitTypeHead(e: *Emitter, name: []const u8, params: [][]const u8) Error!void {
        try e.w(name);
        if (params.len == 0) return;
        try e.w("(");
        for (params, 0..) |prm, i| {
            if (i > 0) try e.w(", ");
            try e.w(try snake(e.a, prm));
        }
        try e.w(")");
    }

    // blocks

    /// A body that is only an expression is written inline; otherwise as a
    /// `{ ... }` block.
    fn emitBody(e: *Emitter, b: *Block) Error!void {
        if (b.stmts.len == 0) {
            if (b.result) |r| return e.emitExpr(r);
        }
        try e.w("{");
        try e.emitBlockLines(b);
        try e.nl();
        try e.w("}");
    }

    /// Writes each statement on its own line, one level deeper. The caller
    /// writes the braces.
    fn emitBlockLines(e: *Emitter, b: *Block) Error!void {
        const vars_mark = e.vars.items.len;
        defer e.vars.items.len = vars_mark;
        const scope_mark = e.scope.items.len;
        defer e.scope.items.len = scope_mark;
        e.indent += 1;
        defer e.indent -= 1;
        for (b.stmts) |s| {
            if (s.blank_before) try e.w("\n");
            try e.nl();
            for (s.comments) |c| {
                try e.w(c);
                try e.nl();
            }
            try e.emitStmt(s);
        }
        if (b.result) |r| {
            if (b.result_blank_before) try e.w("\n");
            try e.nl();
            try e.emitExpr(r);
        }
    }

    fn emitStmt(e: *Emitter, s: Stmt) Error!void {
        switch (s.kind) {
            .def => |d| {
                try e.bindDef(d.pat, d.body);
                try e.emitDef(d.pat, d.body);
            },
            .var_def => |v| {
                const name = try snake(e.a, v.name);
                try e.w("var $");
                try e.w(name);
                try e.w(" = ");
                try e.emitBody(v.body);
                try e.vars.append(e.a, name);
            },
            .anno => |an| {
                try e.scope.append(e.a, .{ .name = try snake(e.a, an.name), .arity = typeArity(an.ty), .anno = true });
                try e.w(try snake(e.a, an.name));
                try e.w(" : ");
                try e.emitType(an.ty, false);
            },
            .for_ => |f| {
                try e.w("for ");
                try e.emitPattern(f.pat);
                try e.w(" in ");
                try e.emitExpr(f.iter);
                const scope_mark = e.scope.items.len;
                defer e.scope.items.len = scope_mark;
                try e.bindPattern(f.pat);
                try e.w(" {");
                try e.emitBlockLines(f.body);
                try e.nl();
                try e.w("}");
            },
            .while_ => |wh| {
                try e.w("while ");
                try e.emitExpr(wh.cond);
                try e.w(" {");
                try e.emitBlockLines(wh.body);
                try e.nl();
                try e.w("}");
            },
            .expect => |b| {
                try e.w("expect ");
                try e.emitBody(b);
            },
            .expr => |x| try e.emitExpr(x),
        }
    }

    // expressions

    fn isVar(e: *Emitter, name: []const u8) bool {
        var i = e.vars.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, e.vars.items[i], name)) return true;
        }
        return false;
    }

    fn emitIdent(e: *Emitter, raw: []const u8) Error!void {
        const name = stdlib.rocName(try snakeQualified(e.a, raw));
        if (e.isVar(name)) try e.w("$");
        try e.w(name);
    }

    // currying

    /// Binds the top-level definitions before anything is emitted, so a
    /// function can be partially applied above its definition.
    fn bindItems(e: *Emitter, items: []const Item) Error!void {
        for (items) |item| switch (item.kind) {
            .anno => |an| try e.scope.append(e.a, .{ .name = try snake(e.a, an.name), .arity = typeArity(an.ty), .anno = true }),
            .def => |d| try e.bindDef(d.pat, d.body),
            .raw, .type_alias, .type_nominal, .expect => {},
        };
    }

    /// Binds the names a definition introduces. A definition without an
    /// arity of its own (`f = g`) keeps the arity of its annotation.
    fn bindDef(e: *Emitter, pat: *Pattern, body: *Block) Error!void {
        if (pat.* != .ident) return e.bindPattern(pat);
        const name = try snake(e.a, pat.ident);
        var arity: ?u8 = null;
        if (body.stmts.len == 0) if (body.result) |r| {
            arity = try e.exprArity(r);
        };
        const anno = e.annoArity(name);
        if (arity == null or (try e.etaExtra(pat, body)) > 0) arity = anno;
        try e.scope.append(e.a, .{ .name = name, .arity = arity });
    }

    /// The arity of the annotation in scope for `name`, if any.
    fn annoArity(e: *Emitter, name: []const u8) ?u8 {
        var i = e.scope.items.len;
        while (i > 0) {
            i -= 1;
            const b = e.scope.items[i];
            if (b.anno and std.mem.eql(u8, b.name, name)) return b.arity;
        }
        return null;
    }

    /// How many parameters a function definition lacks compared to its
    /// annotation: `pick : Bool -> I64 -> I64 -> I64` with
    /// `pick = fn useAdd -> ...` lacks two.
    fn etaExtra(e: *Emitter, pat: *Pattern, body: *Block) Error!usize {
        if (pat.* != .ident or body.stmts.len != 0) return 0;
        const r = body.result orelse return 0;
        if (r.* != .lambda) return 0;
        const anno = e.annoArity(try snake(e.a, pat.ident)) orelse return 0;
        const own = (try e.flatLambda(r)).params.len;
        return if (anno > own) anno - own else 0;
    }

    /// A definition. A function that takes fewer parameters than its
    /// annotation gets the rest as extra parameters, passed on to what it
    /// returns, so Roc sees the arity of the annotation.
    fn emitDef(e: *Emitter, pat: *Pattern, body: *Block) Error!void {
        try e.emitPattern(pat);
        try e.w(" = ");
        const extra = try e.etaExtra(pat, body);
        if (extra == 0) return e.emitBody(body);

        const flat = try e.flatLambda(body.result.?);
        const scope_mark = e.scope.items.len;
        defer e.scope.items.len = scope_mark;
        var args: std.ArrayList(*Expr) = .empty;
        try e.w("|");
        for (flat.params, 0..) |prm, i| {
            if (i > 0) try e.w(", ");
            try e.emitPattern(prm);
            try e.bindPattern(prm);
        }
        for (0..extra) |_| {
            e.fresh += 1;
            const name = try std.fmt.allocPrint(e.a, "punk_a{d}", .{e.fresh});
            try e.w(", ");
            try e.w(name);
            try args.append(e.a, try e.newExpr(.{ .ident_raw = name }));
        }
        try e.w("| ");
        const result = flat.body.result orelse return e.errAt0("a function body must end in an expression");
        const call = try e.newExpr(.{ .app = .{ .func = try e.newExpr(.{ .paren = result }), .args = args.items } });
        var block = Block{ .stmts = flat.body.stmts, .result = call, .result_blank_before = flat.body.result_blank_before };
        try e.emitBody(&block);
    }

    fn errAt0(e: *Emitter, message: []const u8) Error {
        e.diag.message = message;
        return error.ParseError;
    }

    /// Binds every name in a pattern as a value of unknown arity, which also
    /// hides outer functions of the same name.
    fn bindPattern(e: *Emitter, pat: *Pattern) Error!void {
        switch (pat.*) {
            .ident => |n| try e.scope.append(e.a, .{ .name = try snake(e.a, n), .arity = null }),
            .tag => |t| for (t.args) |sub| try e.bindPattern(sub),
            .record => |fields| for (fields) |f| {
                if (f.pat) |sub| try e.bindPattern(sub) else try e.scope.append(e.a, .{ .name = try snake(e.a, f.name), .arity = null });
            },
            .list, .tuple => |items| for (items) |sub| try e.bindPattern(sub),
            .rest => |n| if (n) |name| try e.scope.append(e.a, .{ .name = try snake(e.a, name), .arity = null }),
            .as_ => |as_| {
                try e.bindPattern(as_.pat);
                try e.scope.append(e.a, .{ .name = try snake(e.a, as_.name), .arity = null });
            },
            .underscore, .literal, .string, .unit => {},
        }
    }

    fn lookup(e: *Emitter, name: []const u8) ?u8 {
        var i = e.scope.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, e.scope.items[i].name, name)) return e.scope.items[i].arity;
        }
        return null;
    }

    const Callee = struct { f: stdlib.Fn, builtin: bool };

    /// What the emitter knows about the function an expression names.
    fn calleeArity(e: *Emitter, x: *const Expr) Error!?Callee {
        switch (x.*) {
            .ident => |raw| {
                const name = stdlib.rocName(try snakeQualified(e.a, raw));
                if (std.mem.findScalar(u8, name, '.') != null) {
                    const f = stdlib.lookup(name) orelse return null;
                    return .{ .f = f, .builtin = true };
                }
                const n = e.lookup(name) orelse return null;
                return .{ .f = .{ .arity = n, .order = .none }, .builtin = false };
            },
            .paren => |inner| return e.calleeArity(inner),
            .ident_raw, .upper, .literal, .string, .unit, .underscore, .field, .app, .binop, .neg, .not, .try_, .lambda, .if_, .case, .list, .tuple, .record, .kw => return null,
        }
    }

    /// How many more arguments an expression takes before it is evaluated,
    /// when the emitter can tell.
    fn exprArity(e: *Emitter, x: *Expr) Error!?u8 {
        switch (x.*) {
            .lambda => return @intCast((try e.flatLambda(x)).params.len),
            .paren => |inner| return e.exprArity(inner),
            .app => {
                const call = try e.flatCall(x.app.func, x.app.args);
                const callee = try e.calleeArity(call.func) orelse return null;
                if (call.args.len >= callee.f.arity) return null;
                return @intCast(callee.f.arity - call.args.len);
            },
            .ident => return if (try e.calleeArity(x)) |c| c.f.arity else null,
            .ident_raw, .upper, .literal, .string, .unit, .underscore, .field, .binop, .neg, .not, .try_, .if_, .case, .list, .tuple, .record, .kw => return null,
        }
    }

    const FlatLambda = struct { params: []*Pattern, body: *Block };

    /// `fn a -> fn b -> body` as one lambda with parameters `a, b`.
    fn flatLambda(e: *Emitter, x: *Expr) Error!FlatLambda {
        var params: std.ArrayList(*Pattern) = .empty;
        var cur = x;
        while (true) {
            try params.appendSlice(e.a, cur.lambda.params);
            const body = cur.lambda.body;
            if (body.stmts.len == 0) if (body.result) |r| if (r.* == .lambda) {
                cur = r;
                continue;
            };
            return .{ .params = params.items, .body = body };
        }
    }

    const FlatCall = struct { func: *Expr, args: []*Expr };

    /// `(f a) b` is `f a b`, and `f ()` passes no arguments.
    fn flatCall(e: *Emitter, func: *Expr, args: []*Expr) Error!FlatCall {
        var f = func;
        var all: []*Expr = if (args.len == 1 and args[0].* == .unit) &.{} else args;
        while (true) {
            const inner = if (f.* == .paren) f.paren else f;
            if (inner.* != .app) break;
            const inner_args: []*Expr = if (inner.app.args.len == 1 and inner.app.args[0].* == .unit) &.{} else inner.app.args;
            all = try std.mem.concat(e.a, *Expr, &.{ inner_args, all });
            f = inner.app.func;
        }
        return .{ .func = f, .args = all };
    }

    /// A call. Known functions get exactly their arity: extra arguments go
    /// to the function they return, missing ones make a lambda. Builtins get
    /// their arguments in Roc's order. Unknown functions get all arguments.
    fn emitCall(e: *Emitter, func_in: *Expr, args_in: []*Expr) Error!void {
        const call = try e.flatCall(func_in, args_in);
        const func = call.func;
        const args = call.args;
        const callee = try e.calleeArity(func) orelse {
            try e.emitCallee(func);
            return e.emitArgs(args, null);
        };
        const n: usize = callee.f.arity;
        if (args.len >= n) {
            try e.emitCallee(func);
            try e.emitArgs(args[0..n], callee.f);
            if (args.len > n) try e.emitArgs(args[n..], null);
            return;
        }

        // Partial application: arguments that are not plain values are
        // computed once, before the lambda, as Elm would.
        var full: std.ArrayList(*Expr) = .empty;
        var bound: std.ArrayList(struct { name: []const u8, value: *Expr }) = .empty;
        for (args) |arg| {
            if (try e.isPlain(arg)) {
                try full.append(e.a, arg);
                continue;
            }
            e.fresh += 1;
            const name = try std.fmt.allocPrint(e.a, "punk_v{d}", .{e.fresh});
            try bound.append(e.a, .{ .name = name, .value = arg });
            try full.append(e.a, try e.newExpr(.{ .ident_raw = name }));
        }
        var params: std.ArrayList([]const u8) = .empty;
        for (args.len..n) |_| {
            e.fresh += 1;
            const name = try std.fmt.allocPrint(e.a, "punk_a{d}", .{e.fresh});
            try params.append(e.a, name);
            try full.append(e.a, try e.newExpr(.{ .ident_raw = name }));
        }
        if (bound.items.len > 0) {
            try e.w("{");
            e.indent += 1;
            for (bound.items) |b| {
                try e.nl();
                try e.w(b.name);
                try e.w(" = ");
                try e.emitExpr(b.value);
            }
            try e.nl();
        }
        try e.w("|");
        for (params.items, 0..) |prm, i| {
            if (i > 0) try e.w(", ");
            try e.w(prm);
        }
        try e.w("| ");
        try e.emitCallee(func);
        try e.emitArgs(full.items, callee.f);
        if (bound.items.len > 0) {
            e.indent -= 1;
            try e.nl();
            try e.w("}");
        }
    }

    fn newExpr(e: *Emitter, v: Expr) Error!*Expr {
        const x = try e.a.create(Expr);
        x.* = v;
        return x;
    }

    /// Values that are cheap to compute again: these go into a partial
    /// application's lambda as they are. A partial application is itself a
    /// lambda, so it is plain when its arguments are.
    fn isPlain(e: *Emitter, x: *Expr) Error!bool {
        return switch (x.*) {
            .ident, .ident_raw, .upper, .literal, .unit, .underscore, .lambda => true,
            .string => |s| std.mem.find(u8, s, "${") == null,
            .field => |f| e.isPlain(f.target),
            .paren => |inner| e.isPlain(inner),
            .app => |app| {
                if (try e.exprArity(x) == null) return false;
                for (app.args) |arg| if (!try e.isPlain(arg)) return false;
                return true;
            },
            .binop, .neg, .not, .try_, .if_, .case, .list, .tuple, .record, .kw => false,
        };
    }

    fn emitCallee(e: *Emitter, func: *Expr) Error!void {
        const f = if (func.* == .paren and func.paren.* == .ident) func.paren else func;
        if (f.* == .ident) return e.emitIdent(f.ident);
        if (f.* == .lambda or !isAtomic(f)) {
            try e.w("(");
            try e.emitExpr(f);
            try e.w(")");
        } else try e.emitExpr(f);
    }

    /// `(a, b)`, in Roc's order when `order` is a builtin's.
    fn emitArgs(e: *Emitter, args: []*Expr, order: ?stdlib.Fn) Error!void {
        try e.w("(");
        for (0..args.len) |i| {
            if (i > 0) try e.w(", ");
            const src = if (order) |f| f.source(i) else i;
            try e.emitItem(args[src]);
        }
        try e.w(")");
    }

    /// The number of arguments a function type takes. `A -> B -> C` takes
    /// two: types are curried, as in Elm.
    fn typeArity(t: *const Type) ?u8 {
        var cur = t;
        var n: usize = 0;
        var is_func = false;
        while (true) {
            while (cur.* == .paren) cur = cur.paren;
            if (cur.* != .func) break;
            const f = cur.func;
            is_func = true;
            if (!(f.args.len == 1 and f.args[0].* == .unit)) n += f.args.len;
            cur = f.ret;
        }
        if (!is_func) return null;
        return @intCast(n);
    }

    fn isAtomic(x: *const Expr) bool {
        return switch (x.*) {
            .ident, .ident_raw, .upper, .literal, .string, .unit, .underscore, .field, .app, .list, .tuple, .paren, .record, .try_ => true,
            .binop, .neg, .not, .lambda, .if_, .case, .kw => false,
        };
    }

    fn emitAtomic(e: *Emitter, x: *Expr) Error!void {
        if (isAtomic(x)) return e.emitExpr(x);
        try e.w("(");
        try e.emitExpr(x);
        try e.w(")");
    }

    fn rocOp(op: []const u8) []const u8 {
        if (std.mem.eql(u8, op, "&&")) return "and";
        if (std.mem.eql(u8, op, "||")) return "or";
        if (std.mem.eql(u8, op, "/=")) return "!=";
        return op;
    }

    fn emitBinopChild(e: *Emitter, child: *Expr, parent_prec: u8, right_side: bool) Error!void {
        const needs = switch (child.*) {
            .binop => |b| blk: {
                const info = Parser.opInfo(b.op).?;
                break :blk info.prec < parent_prec or (info.prec == parent_prec and right_side);
            },
            .lambda, .if_, .case, .kw => true,
            .ident, .ident_raw, .upper, .literal, .string, .unit, .underscore, .field, .app, .neg, .not, .try_, .list, .tuple, .paren, .record => false,
        };
        if (needs) try e.w("(");
        try e.emitExpr(child);
        if (needs) try e.w(")");
    }

    /// In comma-separated positions (arguments, list items, record fields)
    /// parentheses written for punkroc's sake are not needed in Roc.
    fn emitItem(e: *Emitter, x: *Expr) Error!void {
        if (x.* == .paren) return e.emitItem(x.paren);
        return e.emitExpr(x);
    }

    fn emitExpr(e: *Emitter, x: *Expr) Error!void {
        switch (x.*) {
            .ident => |name| {
                // A builtin whose arguments punkroc reorders, used as a value
                // (`List.map` on its own): a lambda that reorders them.
                if (try e.calleeArity(x)) |callee| {
                    if (callee.builtin and callee.f.order != .none and callee.f.arity >= 2) {
                        return e.emitCall(x, &.{});
                    }
                }
                try e.emitIdent(name);
            },
            .ident_raw, .upper, .literal => |s| try e.w(s),
            .string => |s| try e.emitString(s),
            .unit => try e.w("{}"),
            .underscore => try e.w("_"),
            .field => |f| {
                try e.emitAtomic(f.target);
                try e.w(".");
                try e.w(try snake(e.a, f.name));
            },
            .app => |app| try e.emitCall(app.func, app.args),
            .binop => |b| {
                const info = Parser.opInfo(b.op).?;
                if (std.mem.eql(u8, b.op, "++")) {
                    try e.emitAtomic(b.lhs);
                    try e.w(".concat(");
                    try e.emitExpr(b.rhs);
                    try e.w(")");
                    return;
                }
                // Roc writes ranges without spaces: 1..<5
                const gap: []const u8 = if (std.mem.startsWith(u8, b.op, "..")) "" else " ";
                try e.emitBinopChild(b.lhs, info.prec, false);
                try e.w(gap);
                try e.w(rocOp(b.op));
                try e.w(gap);
                try e.emitBinopChild(b.rhs, info.prec, true);
            },
            .neg => |inner| {
                try e.w("-");
                try e.emitAtomic(inner);
            },
            .not => |inner| {
                try e.w("!");
                try e.emitAtomic(inner);
            },
            .try_ => |inner| {
                try e.emitAtomic(inner);
                try e.w("?");
            },
            .lambda => {
                // `fn a -> fn b -> body` is one function of two arguments.
                const flat = try e.flatLambda(x);
                const scope_mark = e.scope.items.len;
                defer e.scope.items.len = scope_mark;
                try e.w("|");
                for (flat.params, 0..) |prm, i| {
                    if (i > 0) try e.w(", ");
                    try e.emitPattern(prm);
                    try e.bindPattern(prm);
                }
                try e.w("| ");
                try e.emitBody(flat.body);
            },
            .if_ => |f| {
                try e.w("if ");
                try e.emitExpr(f.cond);
                try e.w(" {");
                try e.emitBlockLines(f.then);
                try e.nl();
                const else_ = f.else_ orelse return e.w("}");
                try e.w("} else ");
                if (else_.stmts.len == 0 and else_.result != null and else_.result.?.* == .if_) {
                    try e.emitExpr(else_.result.?);
                    return;
                }
                try e.w("{");
                try e.emitBlockLines(else_);
                try e.nl();
                try e.w("}");
            },
            .case => |c| {
                try e.w("match ");
                try e.emitExpr(c.subject);
                try e.w(" {");
                e.indent += 1;
                for (c.arms) |arm| {
                    const scope_mark = e.scope.items.len;
                    defer e.scope.items.len = scope_mark;
                    try e.nl();
                    for (arm.pats, 0..) |pat, i| {
                        if (i > 0) try e.w(" | ");
                        try e.emitPattern(pat);
                        try e.bindPattern(pat);
                    }
                    if (arm.guard) |g| {
                        try e.w(" if ");
                        try e.emitExpr(g);
                    }
                    try e.w(" => ");
                    try e.emitBody(arm.body);
                }
                e.indent -= 1;
                try e.nl();
                try e.w("}");
            },
            .list => |items| {
                try e.w("[");
                for (items, 0..) |item, i| {
                    if (i > 0) try e.w(", ");
                    try e.emitItem(item);
                }
                try e.w("]");
            },
            .tuple => |items| {
                try e.w("(");
                for (items, 0..) |item, i| {
                    if (i > 0) try e.w(", ");
                    try e.emitItem(item);
                }
                try e.w(")");
            },
            .paren => |inner| {
                if (isAtomic(inner)) return e.emitExpr(inner);
                try e.w("(");
                try e.emitExpr(inner);
                try e.w(")");
            },
            .record => |r| {
                if (r.fields.len == 0 and r.base == null) return e.w("{}");
                try e.w("{ ");
                if (r.base) |b| {
                    try e.w("..");
                    try e.emitExpr(b);
                    try e.w(", ");
                }
                for (r.fields, 0..) |f, i| {
                    if (i > 0) try e.w(", ");
                    const name = try snake(e.a, f.name);
                    if (f.value) |v| {
                        try e.w(name);
                        try e.w(": ");
                        try e.emitItem(v);
                    } else try e.emitIdent(f.name);
                }
                try e.w(" }");
            },
            .kw => |k| {
                try e.w(k.kw);
                try e.w(" ");
                try e.emitExpr(k.arg);
            },
        }
    }

    /// Strings are copied as-is, except that `${ ... }` parts are translated.
    fn emitString(e: *Emitter, raw: []const u8) Error!void {
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                try e.w(raw[i .. i + 2]);
                i += 2;
                continue;
            }
            if (raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
                var depth: u32 = 1;
                var j = i + 2;
                while (j < raw.len and depth > 0) : (j += 1) {
                    if (raw[j] == '{') depth += 1;
                    if (raw[j] == '}') depth -= 1;
                }
                const inner = raw[i + 2 .. j - 1];
                const toks = try lex(e.a, inner, e.diag);
                var p = Parser{ .a = e.a, .src = inner, .toks = toks, .diag = e.diag, .stop_col = 0 };
                const parsed = try p.parseExpr();
                if (p.tok().tag != .eof) return p.errAt(p.tok(), "unexpected '{s}' in string interpolation", .{describe(p.tok())});
                try e.w("${");
                try e.emitExpr(parsed);
                try e.w("}");
                i = j;
                continue;
            }
            try e.buf.append(e.a, raw[i]);
            i += 1;
        }
    }

    fn describe(t: Token) []const u8 {
        return Parser.describe(t);
    }

    // patterns

    fn emitPattern(e: *Emitter, pat: *Pattern) Error!void {
        switch (pat.*) {
            .ident => |name| try e.emitIdent(name),
            .underscore => |name| try e.w(try snake(e.a, name)),
            .tag => |t| {
                try e.w(t.name);
                if (t.args.len > 0) {
                    try e.w("(");
                    for (t.args, 0..) |arg, i| {
                        if (i > 0) try e.w(", ");
                        try e.emitPattern(arg);
                    }
                    try e.w(")");
                }
            },
            .literal, .string => |s| try e.w(s),
            .unit => try e.w("{}"),
            .record => |fields| {
                if (fields.len == 0) return e.w("{}");
                try e.w("{ ");
                for (fields, 0..) |f, i| {
                    if (i > 0) try e.w(", ");
                    try e.w(try snake(e.a, f.name));
                    if (f.pat) |sub| {
                        try e.w(": ");
                        try e.emitPattern(sub);
                    }
                }
                try e.w(" }");
            },
            .list, .tuple => |items| {
                try e.w(if (pat.* == .list) "[" else "(");
                for (items, 0..) |item, i| {
                    if (i > 0) try e.w(", ");
                    try e.emitPattern(item);
                }
                try e.w(if (pat.* == .list) "]" else ")");
            },
            .rest => |name| {
                try e.w("..");
                if (name) |n| {
                    try e.w(" as ");
                    try e.w(try snake(e.a, n));
                }
            },
            .as_ => |as_| {
                try e.emitPattern(as_.pat);
                try e.w(" as ");
                try e.w(try snake(e.a, as_.name));
            },
        }
    }

    // types

    fn emitType(e: *Emitter, t: *Type, in_args: bool) Error!void {
        switch (t.*) {
            .name => |n| try e.w(if (std.ascii.isLower(n[0])) try snake(e.a, n) else n),
            .app => |app| {
                try e.w(if (std.mem.eql(u8, app.head, "Result")) "Try" else app.head);
                try e.w("(");
                for (app.args, 0..) |arg, i| {
                    if (i > 0) try e.w(", ");
                    try e.emitType(arg, false);
                }
                try e.w(")");
            },
            .func => {
                // Curried: `A -> B -> C` (and `A -> (B -> C)`) is Roc's `A, B -> C`.
                if (in_args) try e.w("(");
                var cur = t;
                var first = true;
                var effectful = false;
                while (true) {
                    while (cur.* == .paren and cur.paren.* == .func) cur = cur.paren;
                    if (cur.* != .func) break;
                    const f = cur.func;
                    if (!(f.args.len == 1 and f.args[0].* == .unit)) for (f.args) |arg| {
                        if (!first) try e.w(", ");
                        first = false;
                        try e.emitType(arg, true);
                    };
                    effectful = f.effectful;
                    cur = f.ret;
                }
                if (first) try e.w("()");
                try e.w(if (effectful) " => " else " -> ");
                try e.emitType(cur, false);
                if (in_args) try e.w(")");
            },
            .record => |r| {
                if (r.fields.len == 0 and r.ext == null) return e.w("{}");
                try e.w("{ ");
                for (r.fields, 0..) |f, i| {
                    if (i > 0) try e.w(", ");
                    try e.w(try snake(e.a, f.name));
                    try e.w(" : ");
                    try e.emitType(f.ty, false);
                }
                if (r.ext) |ext| {
                    if (r.fields.len > 0) try e.w(", ");
                    try e.w("..");
                    try e.w(try snake(e.a, ext));
                }
                try e.w(" }");
            },
            .tuple => |items| {
                try e.w("(");
                for (items, 0..) |item, i| {
                    if (i > 0) try e.w(", ");
                    try e.emitType(item, false);
                }
                try e.w(")");
            },
            .unit => try e.w("{}"),
            .union_ => |u| {
                try e.w("[");
                for (u.tags, 0..) |tag, i| {
                    if (i > 0) try e.w(", ");
                    try e.emitType(tag, false);
                }
                if (u.ext) |ext| {
                    if (u.tags.len > 0) try e.w(", ");
                    try e.w("..");
                    try e.w(try snake(e.a, ext));
                }
                try e.w("]");
            },
            .paren => |inner| try e.emitType(inner, in_args or inner.* == .func),
        }
    }
};
