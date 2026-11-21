//! What each effect of the punk `cli` platform does, on ambit's capabilities. No unsafe code:
//! `abi.rs` turns Roc's values into the plain Rust ones these functions take.
//!
//! The app gets authority only through what's here (DESIGN.md of ambit): the program's own input
//! and output, the arguments, a clock, randomness, and the files the user named on the command
//! line. Nothing else can be reached from punk.
#![forbid(unsafe_code)]

use std::io::Read;

use ambit_caps::{Clock, Random};
use ambit_caps_dir::{Dir, DirError, DirErrorKind, DirModify, OneFile, RelPath};
use ambit_caps_dir_native::{NativeDir, open};
use ambit_cli::{Args, Io, Named, NamedError};
use ambit_cli_native::{OsRandom, StdClock};

/// Everything the app may use, made by the wiring before the app runs.
pub struct Caps {
    /// The arguments after the program's name.
    pub args: Vec<String>,
    clock: StdClock,
    random: OsRandom,
    /// Files named on the command line, to read.
    read: Named<OneFile>,
    /// The same names, to write: the folder a named file is in, but only that one file in it.
    write: Named<WriteTarget>,
}

struct WriteTarget {
    folder: NativeDir,
    name: RelPath,
}

impl Caps {
    pub fn new(args: &Args) -> Self {
        Self {
            args: args.list().iter().skip(1).cloned().collect(),
            clock: StdClock::new(),
            random: OsRandom,
            read: args.named(open::file),
            write: args.named(open_for_writing),
        }
    }

    pub fn now_millis(&self) -> i64 {
        match self.clock.now().duration_since(std::time::UNIX_EPOCH) {
            Ok(since) => since.as_millis() as i64,
            Err(before) => -(before.duration().as_millis() as i64),
        }
    }

    pub fn elapsed_millis(&self) -> i64 {
        self.clock.elapsed().as_millis() as i64
    }

    pub fn random_u64(&self) -> u64 {
        self.random.u64()
    }

    pub fn read_file(&self, path: &str) -> Result<String, String> {
        let why = |reason: String| format!("could not read {path}: {reason}");
        let file = self.read.open(path).map_err(|e| why(named_reason(e)))?;
        let mut bytes = Vec::new();
        file.open(&file.path())
            .map_err(|e| why(dir_reason(e)))?
            .read_to_end(&mut bytes)
            .map_err(|e| why(e.to_string()))?;
        String::from_utf8(bytes).map_err(|_| why("it is not UTF-8 text".into()))
    }

    pub fn write_file(&self, path: &str, text: &str) -> Result<(), String> {
        let why = |reason: String| format!("could not write {path}: {reason}");
        let target = self.write.open(path).map_err(|e| why(named_reason(e)))?;
        target
            .folder
            .replace(&target.name, text.as_bytes())
            .map_err(|e| why(dir_reason(e)))
    }
}

/// A file named on the command line, to write: its folder, which must be there, and its name.
fn open_for_writing(value: &str) -> Result<WriteTarget, String> {
    let path = std::path::Path::new(value);
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| format!("{value}: not a file name"))?;
    let folder = match path.parent() {
        Some(p) if !p.as_os_str().is_empty() => p,
        _ => std::path::Path::new("."),
    };
    Ok(WriteTarget {
        folder: open::folder(&folder.to_string_lossy())?,
        name: RelPath::new([name]).map_err(|e| e.message)?,
    })
}

fn named_reason(e: NamedError) -> String {
    match e {
        NamedError::NotNamed(_) => "only files named on the command line can be used".into(),
        NamedError::Failed { message, .. } => message,
    }
}

fn dir_reason(e: DirError) -> String {
    match e.kind {
        DirErrorKind::NotFound => "no such file".into(),
        DirErrorKind::Denied => "not allowed".into(),
        DirErrorKind::WrongKind => "it is a folder".into(),
        _ => e.message,
    }
}

// --- Standard input and output ------------------------------------------------------------------

/// A failed write to stdout or stderr (a closed pipe) is not the app's failure, and there is
/// nowhere left to report it, so it is dropped, as ambit's native backend does.
pub fn stdout_write(io: &mut Io<'_>, text: &str) {
    let _ = io.out.write_all(text.as_bytes());
}

pub fn stdout_line(io: &mut Io<'_>, text: &str) {
    let _ = io.out.write_all(text.as_bytes());
    let _ = io.out.write_all(b"\n");
}

pub fn stderr_line(io: &mut Io<'_>, text: &str) {
    // What's written to stdout so far comes first, as a reader of both expects.
    let _ = io.out.flush();
    let _ = io.err.write_all(text.as_bytes());
    let _ = io.err.write_all(b"\n");
}

/// The next line without its line break (`\n` or `\r\n`); empty at the end of the input.
/// Bytes that aren't UTF-8 become U+FFFD: a punk `Str` is always text.
pub fn stdin_line(io: &mut Io<'_>) -> String {
    let mut line = Vec::new();
    let _ = io.input.read_until(b'\n', &mut line);
    if line.last() == Some(&b'\n') {
        line.pop();
        if line.last() == Some(&b'\r') {
            line.pop();
        }
    }
    String::from_utf8_lossy(&line).into_owned()
}

pub fn stdin_read_all(io: &mut Io<'_>) -> String {
    let mut all = Vec::new();
    let _ = io.input.read_to_end(&mut all);
    String::from_utf8_lossy(&all).into_owned()
}
