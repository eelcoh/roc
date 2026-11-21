//! Elm names that Roc's builtins do not have (`List.head`, `Tuple.first`,
//! `String.toInt`, `compare`, ...).
//!
//! A plain rename (`List.filter` is `List.keep_if`) is in `renames`. A name
//! that needs a bit of code is a helper: a small Roc definition the
//! translator adds to the file when the file uses it (`punk_list_head`).
//! Helpers take their arguments in punkroc's (Elm's) order, so the emitter
//! calls them as they are written.
//!
//! Elm's types: `Int` is `I64`, `Float` is `F64`, `Maybe a` is
//! `[Just(a), Nothing]` and `Order` is `[LT, EQ, GT]` (see `typeName`).
//! Functions that are new here count with `Int` (`List.length`,
//! `List.indexedMap`, `String.length`); Roc's own (`List.len`) keep `U64`.
//! `toInt` and `fromInt` turn a `U64` into an `Int` and back.

const std = @import("std");

/// A helper definition. `def` is Roc source for a definition named `name`;
/// `uses` are other helpers it calls.
pub const Helper = struct {
    name: []const u8,
    arity: u8,
    def: []const u8 = "",
    uses: []const []const u8 = &.{},
    /// Written in place instead of defined, with `$0`, `$1` for the
    /// arguments: Roc must see the tuple of `t.0` where it is used.
    tmpl: ?[]const u8 = null,
};

/// The helper for the punkroc name `snake_name` (in Roc's spelling:
/// `List.indexed_map`, `to_int`), if there is one.
pub fn helper(snake_name: []const u8) ?Helper {
    return helpers.get(snake_name);
}

/// The helper called `name` (`punk_list_head`).
pub fn helperByName(name: []const u8) ?Helper {
    for (helpers.values()) |h| if (std.mem.eql(u8, h.name, name)) return h;
    return null;
}

/// The Roc name of an Elm function that Roc has under another name
/// (`List.filter` is `List.keep_if`), or `name` itself.
pub fn rename(name: []const u8) []const u8 {
    return renames.get(name) orelse name;
}

/// The Roc spelling of one of Elm's type names, or null.
pub fn typeName(name: []const u8) ?[]const u8 {
    return types.get(name);
}

/// Roc's spelling of Elm's types that take arguments: `Maybe a` is
/// `[Just(a), Nothing]`. Returns the text before and after the argument.
pub fn typeApp(head: []const u8) ?struct { []const u8, []const u8 } {
    if (std.mem.eql(u8, head, "Maybe")) return .{ "[Just(", "), Nothing]" };
    return null;
}

const types = std.StaticStringMap([]const u8).initComptime(.{
    .{ "Int", "I64" },
    .{ "Float", "F64" },
    .{ "Order", "[LT, EQ, GT]" },
});

const renames = std.StaticStringMap([]const u8).initComptime(.{
    .{ "List.filter", "List.keep_if" },
    .{ "List.foldl", "List.fold" },
    .{ "List.foldr", "List.fold_rev" },
    .{ "List.reverse", "List.rev" },
    .{ "List.member", "List.contains" },
    .{ "List.concat_map", "List.join_map" },
    .{ "List.filter_map", "List.keep_oks" },
    .{ "String.is_empty", "Str.is_empty" },
    .{ "String.trim", "Str.trim" },
    .{ "String.trim_left", "Str.trim_start" },
    .{ "String.trim_right", "Str.trim_end" },
    .{ "String.contains", "Str.contains" },
    .{ "String.starts_with", "Str.starts_with" },
    .{ "String.ends_with", "Str.ends_with" },
    .{ "String.split", "Str.split_on" },
    .{ "String.join", "Str.join_with" },
    .{ "String.to_upper", "Str.with_ascii_uppercased" },
    .{ "String.to_lower", "Str.with_ascii_lowercased" },
    .{ "String.replace", "Str.replace_each" },
});

const helpers = std.StaticStringMap(Helper).initComptime(.{
    // List
    .{ "List.range", Helper{ .name = "punk_list_range", .arity = 2, .def = "punk_list_range = |a, b| List.from_iter(I64.to(a, b))" } },
    .{ "List.head", Helper{ .name = "punk_list_head", .arity = 1, .def = "punk_list_head = |xs| match List.first(xs) { Ok(x) => Just(x), Err(_) => Nothing }" } },
    .{ "List.tail", Helper{ .name = "punk_list_tail", .arity = 1, .def = "punk_list_tail = |xs| if List.is_empty(xs) { Nothing } else { Just(List.drop_first(xs, 1)) }" } },
    .{ "List.maximum", Helper{ .name = "punk_list_maximum", .arity = 1, .def = "punk_list_maximum = |xs| match List.max(xs) { Ok(x) => Just(x), Err(_) => Nothing }" } },
    .{ "List.minimum", Helper{ .name = "punk_list_minimum", .arity = 1, .def = "punk_list_minimum = |xs| match List.min(xs) { Ok(x) => Just(x), Err(_) => Nothing }" } },
    .{ "List.length", Helper{ .name = "punk_list_length", .arity = 1, .def = "punk_list_length = |xs| List.len(xs).to_i64_wrap()" } },
    .{ "List.indexed_map", Helper{ .name = "punk_list_indexed_map", .arity = 2, .def = "punk_list_indexed_map = |f, xs| List.map_with_index(xs, |x, i| f(i.to_i64_wrap(), x))" } },
    .{ "List.sort_with", Helper{ .name = "punk_list_sort_with", .arity = 2, .def = "punk_list_sort_with = |f, xs| List.sort_with(xs, |a, b| match f(a, b) { LT => Before, EQ => Same, GT => After })" } },
    .{ "List.take", Helper{ .name = "punk_list_take", .arity = 2, .def = "punk_list_take = |n, xs| List.take_first(xs, n.to_u64_wrap())" } },
    .{ "List.drop", Helper{ .name = "punk_list_drop", .arity = 2, .def = "punk_list_drop = |n, xs| List.drop_first(xs, n.to_u64_wrap())" } },
    .{ "List.singleton", Helper{ .name = "punk_list_singleton", .arity = 1, .def = "punk_list_singleton = |x| [x]" } },
    .{ "List.is_member", Helper{ .name = "punk_list_is_member", .arity = 2, .def = "punk_list_is_member = |x, xs| List.contains(xs, x)" } },
    // Tuple
    .{ "Tuple.first", Helper{ .name = "punk_tuple_first", .arity = 1, .tmpl = "$0.0" } },
    .{ "Tuple.second", Helper{ .name = "punk_tuple_second", .arity = 1, .tmpl = "$0.1" } },
    .{ "Tuple.pair", Helper{ .name = "punk_tuple_pair", .arity = 2, .def = "punk_tuple_pair = |a, b| (a, b)" } },
    .{ "Tuple.map_first", Helper{ .name = "punk_tuple_map_first", .arity = 2, .tmpl = "($0($1.0), $1.1)" } },
    .{ "Tuple.map_second", Helper{ .name = "punk_tuple_map_second", .arity = 2, .tmpl = "($1.0, $0($1.1))" } },
    // Maybe
    .{ "Maybe.with_default", Helper{ .name = "punk_maybe_with_default", .arity = 2, .def = "punk_maybe_with_default = |d, m| match m { Just(x) => x, Nothing => d }" } },
    .{ "Maybe.map", Helper{ .name = "punk_maybe_map", .arity = 2, .def = "punk_maybe_map = |f, m| match m { Just(x) => Just(f(x)), Nothing => Nothing }" } },
    .{ "Maybe.and_then", Helper{ .name = "punk_maybe_and_then", .arity = 2, .def = "punk_maybe_and_then = |f, m| match m { Just(x) => f(x), Nothing => Nothing }" } },
    .{ "Result.to_maybe", Helper{ .name = "punk_result_to_maybe", .arity = 1, .def = "punk_result_to_maybe = |r| match r { Ok(x) => Just(x), Err(_) => Nothing }" } },
    .{ "Result.from_maybe", Helper{ .name = "punk_result_from_maybe", .arity = 2, .def = "punk_result_from_maybe = |e, m| match m { Just(x) => Ok(x), Nothing => Err(e) }" } },
    // String
    .{ "String.length", Helper{ .name = "punk_string_length", .arity = 1, .def = "punk_string_length = |s| Str.count_utf8_bytes(s).to_i64_wrap()" } },
    .{ "String.lines", Helper{ .name = "punk_string_lines", .arity = 1, .def = "punk_string_lines = |s| Str.split_on(s, \"\\n\")" } },
    .{ "String.words", Helper{ .name = "punk_string_words", .arity = 1, .def = "punk_string_words = |s| List.drop_if(Str.split_on(s, \" \"), Str.is_empty)" } },
    .{ "String.to_int", Helper{ .name = "punk_string_to_int", .arity = 1, .def = "punk_string_to_int = |s| match I64.from_str(s) { Ok(n) => Just(n), Err(_) => Nothing }" } },
    .{ "String.from_int", Helper{ .name = "punk_string_from_int", .arity = 1, .def = "punk_string_from_int = |n| I64.to_str(n)" } },
    .{ "String.append", Helper{ .name = "punk_string_append", .arity = 2, .def = "punk_string_append = |a, b| Str.concat(a, b)" } },
    .{ "String.concat", Helper{ .name = "punk_string_concat", .arity = 1, .def = "punk_string_concat = |ss| Str.join_with(ss, \"\")" } },
    .{ "String.repeat", Helper{ .name = "punk_string_repeat", .arity = 2, .def = "punk_string_repeat = |n, s| Str.repeat(s, n.to_u64_wrap())" } },
    // Basics
    .{ "compare", Helper{ .name = "punk_compare", .arity = 2, .def = "punk_compare = |a, b| if a < b { LT } else if a > b { GT } else { EQ }" } },
    .{ "to_int", Helper{ .name = "punk_to_int", .arity = 1, .def = "punk_to_int = |n| U64.to_i64_wrap(n)" } },
    .{ "from_int", Helper{ .name = "punk_from_int", .arity = 1, .def = "punk_from_int = |n| I64.to_u64_wrap(n)" } },
    .{ "to_float", Helper{ .name = "punk_to_float", .arity = 1, .def = "punk_to_float = |n| I64.to_f64(n)" } },
    .{ "min", Helper{ .name = "punk_min", .arity = 2, .def = "punk_min = |a, b| if a < b { a } else { b }" } },
    .{ "max", Helper{ .name = "punk_max", .arity = 2, .def = "punk_max = |a, b| if a > b { a } else { b }" } },
    .{ "identity", Helper{ .name = "punk_identity", .arity = 1, .def = "punk_identity = |x| x" } },
});
