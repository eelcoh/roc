//! punkroc's seam with the Roc compiler: everything that connects punk
//! (`src/punk/`, which knows nothing of Roc's code) to the Roc compiler.
//! Roc's own code calls into this module from a few marked places
//! (`// punkroc:`) and knows nothing else about `.punk` files.
//!
//! - `vfs.zig`: the build reads `.punk` files through a layer over its
//!   filesystem that translates them, and finds `Foo.punk` for `import Foo`.
//! - `report.zig`: reports about `.punk` files point at the `.punk` source.
//! - `json.zig`: `punk check --json`.
//! - `cli.zig`: `punk fmt` and `punk check --schema`.

pub const vfs = @import("vfs.zig");
pub const report = @import("report.zig");
pub const json = @import("json.zig");
pub const cli = @import("cli.zig");

/// Makes a build understand `.punk` files. Call once, right after the
/// build is set up and before it starts.
pub const install = vfs.install;
pub const translateRaw = vfs.translateRaw;
