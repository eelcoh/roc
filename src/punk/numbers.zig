//! How punk's numbers behave where Roc's would crash. This is the one place
//! that decides it, so the choice can change without touching the rest of
//! the translator.
//!
//! The choice for now (PROVISIONAL, roadmap decision 4): Elm's behaviour.
//! Dividing an integer by zero gives 0 instead of crashing: `7 // 0 == 0`,
//! `7 % 0 == 0`, `modBy 0 7 == 0`, `remainderBy 0 7 == 0`. (Elm itself
//! crashes on `modBy 0`; punk does not.)
//!
//! Not done yet: wrapping on overflow of `+`, `-` and `*`. The translator
//! does not know the types of values, and only Roc's integer types have
//! `plus_wrap`, so `a + b` keeps Roc's meaning, which crashes on overflow.
//!
//! The alternative later on is `Result`: set `policy` to `.roc` to get Roc's
//! own behaviour back (crash on division by zero), the starting point for a
//! `Result`-returning version.

const std = @import("std");
const elm = @import("elm.zig");

pub const Policy = enum {
    /// Elm's behaviour: division by zero gives 0.
    elm,
    /// Roc's behaviour: division by zero crashes.
    roc,
};

/// The behaviour punk uses.
pub const policy: Policy = .elm;

/// The helper an arithmetic operator becomes (`a // b` is
/// `punk_int_div(a, b)`), or null when it stays Roc's operator.
pub fn operator(op: []const u8) ?elm.Helper {
    if (policy != .elm) return null;
    if (std.mem.eql(u8, op, "//")) return int_div;
    if (std.mem.eql(u8, op, "%")) return int_rem;
    return null;
}

/// The helper for one of Elm's number functions (`mod_by`, in Roc's
/// spelling), or null.
pub fn helper(snake_name: []const u8) ?elm.Helper {
    if (std.mem.eql(u8, snake_name, "mod_by")) return mod_by;
    if (std.mem.eql(u8, snake_name, "remainder_by")) return remainder_by;
    return null;
}

/// The helper called `name` (`punk_int_div`), or null.
pub fn helperByName(name: []const u8) ?elm.Helper {
    for ([_]elm.Helper{ int_div, int_rem, mod_by, remainder_by }) |h| if (std.mem.eql(u8, h.name, name)) return h;
    return null;
}

/// `if b == 0 { 0 } else { ... }` with policy `.elm`, nothing with `.roc`.
fn guard(comptime divisor: []const u8, comptime body: []const u8) []const u8 {
    return if (policy == .elm) "if " ++ divisor ++ " == 0 { 0 } else { " ++ body ++ " }" else body;
}

const int_div: elm.Helper = .{ .name = "punk_int_div", .arity = 2, .def = "punk_int_div = |a, b| " ++ guard("b", "a // b") };
const int_rem: elm.Helper = .{ .name = "punk_int_rem", .arity = 2, .def = "punk_int_rem = |a, b| " ++ guard("b", "a % b") };

/// Elm's `modBy n x`: the result has the sign of `n`, `modBy 3 -1 == 2`.
const mod_by: elm.Helper = .{
    .name = "punk_mod_by",
    .arity = 2,
    .def = "punk_mod_by = |n, x| " ++ guard("n", "if x % n != 0 and (x % n < 0) != (n < 0) { x % n + n } else { x % n }"),
};

/// Elm's `remainderBy n x`: the result has the sign of `x`, `remainderBy 3 -1 == -1`.
const remainder_by: elm.Helper = .{ .name = "punk_remainder_by", .arity = 2, .def = "punk_remainder_by = |n, x| " ++ guard("n", "x % n") };
