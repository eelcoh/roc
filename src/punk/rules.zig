//! The design rules the punk check layer enforces on top of Roc, each with a
//! stable error code. The code starts the error message (`P101: ...`) and is
//! in `Diagnostic.code`, so tools and agents can recognise an error without
//! reading its text. A code never changes meaning; a rule that goes away
//! keeps its number unused.
//!
//! | Code | Rule |
//! |------|------|
//! | P001 | any other punkroc syntax error (given by `punk check --json`, src/cli/punk_json.zig) |
//! | P101 | `crash` only inside an `expect` test |
//! | P102 | `dbg` only inside an `expect` test |
//! | P201 | what a module exposes has a type annotation |
//! | P301 | the SQL of `Sql.query` is text written in the program |
//! | P401 | a `table` has a row type that can be stored, a key it has, and says who may read, insert, update and delete |
//! | P402 | a query is a pipeline from a table, and its functions can run in the database |
//! | P403 | a query uses columns the table has, with values of their type |
//! | P404 | a query only does what the table's policy allows |

/// One rule of the punk check layer.
pub const Rule = enum {
    crash_outside_test,
    dbg_outside_test,
    exposed_without_annotation,
    sql_not_literal,
    table_decl,
    not_in_database,
    query_type,
    not_allowed,

    /// The rule's stable code, such as `P101`.
    pub fn code(r: Rule) []const u8 {
        return switch (r) {
            .crash_outside_test => "P101",
            .dbg_outside_test => "P102",
            .exposed_without_annotation => "P201",
            .sql_not_literal => "P301",
            .table_decl => "P401",
            .not_in_database => "P402",
            .query_type => "P403",
            .not_allowed => "P404",
        };
    }
};
