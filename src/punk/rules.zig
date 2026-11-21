//! The design rules the punk check layer enforces on top of Roc, each with a
//! stable error code. The code starts the error message (`P101: ...`) and is
//! in `Diagnostic.code`, so tools and agents can recognise an error without
//! reading its text. A code never changes meaning; a rule that goes away
//! keeps its number unused.
//!
//! | Code | Rule |
//! |------|------|
//! | P101 | `crash` only inside an `expect` test |
//! | P102 | `dbg` only inside an `expect` test |
//! | P201 | what a module exposes has a type annotation |

/// One rule of the punk check layer.
pub const Rule = enum {
    crash_outside_test,
    dbg_outside_test,
    exposed_without_annotation,

    /// The rule's stable code, such as `P101`.
    pub fn code(r: Rule) []const u8 {
        return switch (r) {
            .crash_outside_test => "P101",
            .dbg_outside_test => "P102",
            .exposed_without_annotation => "P201",
        };
    }
};
