//! Host of punkroc's `tui` platform.
//!
//! roc compiles a punk terminal app to an archive (`libapp.a`) that does no I/O itself. [`App`]
//! is an ambit tui [`ambit_tui::App`]: ambit's platform owns the terminal, the event loop and
//! the worker threads, and calls `update` for every event and `view` to redraw. `App` hands each
//! event to the punk app (`roc_tui_update`), keeps the model the app gives back (a `Box` the host
//! never looks into), draws the view the app describes, and does the work the app's commands
//! ask for, off the screen's thread, with the capabilities the wiring handed to [`App::new`]:
//! the app's folder and the clock. The punk app itself runs only on the screen's thread.
//!
//! The crate of an app links its archive next to this library and decides, in its wiring, which
//! folder the app gets and which backend runs it: ambit's native terminal in its `main`, the
//! deterministic `ambit-tui-sim` in its tests.

use std::ffi::c_void;
use std::sync::Arc;
use std::time::{Duration, UNIX_EPOCH};

use ambit_caps::Clock;
use ambit_caps_dir::{Dir, DirError, DirErrorKind, RelPath};
use ambit_tui::{Buffer, Cmd, Event, Key, KeyCode, Rect};
use punk_roc_abi::RocStr;
pub use punk_roc_abi::{live_bytes, thread_live_bytes};

mod view;
pub use view::View;

/// What every entry point of `platforms/tui/main.roc` gives back (`Step`): the work to do, the
/// app's new state and the screen. Fields of the same alignment are in alphabetical order.
#[repr(C)]
struct RocStep {
    cmds: RocStr,
    state: *mut c_void,
    view: RocStr,
}

unsafe extern "C" {
    fn roc_tui_init() -> RocStep;
    fn roc_tui_update(
        state: *mut c_void,
        kind: u8,
        text: RocStr,
        code: u32,
        mods: u8,
        width: u16,
        height: u16,
    ) -> RocStep;
    fn roc_tui_reply(state: *mut c_void, id: u64, ok: bool, text: RocStr) -> RocStep;
}

/// The answer to a piece of work the app asked for, delivered back on the screen's thread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reply {
    id: u64,
    ok: bool,
    text: String,
}

/// A folder for an app that reads no files: every `File.read` and `File.list` fails.
pub struct NoFolder;

impl Dir for NoFolder {
    fn metadata(&self, _: &RelPath) -> Result<ambit_caps_dir::Meta, DirError> {
        Err(no_folder())
    }

    fn open(&self, _: &RelPath) -> Result<Box<dyn ambit_caps_dir::File>, DirError> {
        Err(no_folder())
    }

    fn list(&self, _: &RelPath) -> Result<Vec<ambit_caps_dir::Entry>, DirError> {
        Err(no_folder())
    }
}

fn no_folder() -> DirError {
    DirError::new(DirErrorKind::Denied, "this app was given no folder")
}

/// A punk terminal app with its capabilities.
pub struct App {
    folder: Arc<dyn Dir>,
    clock: Arc<dyn Clock>,
    /// The app's state, owned here between calls. Null only before `start`.
    state: *mut c_void,
    view: View,
}

impl App {
    /// The app, with everything it may use: `folder` is what `File.read` and `File.list` see,
    /// `clock` what `Clock.now` and `Cmd.after` count with.
    pub fn new(folder: impl Dir, clock: impl Clock) -> Self {
        Self {
            folder: Arc::new(folder),
            clock: Arc::new(clock),
            state: std::ptr::null_mut(),
            view: View::default(),
        }
    }

    /// The screen as the app last described it.
    pub fn view_tree(&self) -> &View {
        &self.view
    }

    fn take(&mut self) -> *mut c_void {
        let state = std::mem::replace(&mut self.state, std::ptr::null_mut());
        assert!(!state.is_null(), "the tui host called the app before start");
        state
    }

    fn step(&mut self, step: RocStep) -> Cmd<Reply> {
        self.state = step.state;
        self.view = View::parse(step.view.as_str());
        Cmd::Batch(
            step.cmds
                .as_str()
                .lines()
                .map(|line| self.command(line))
                .collect(),
        )
    }

    /// One line of `Cmd.to_host`: `quit`, or `<id>\t<kind>\t<arg>`.
    fn command(&self, line: &str) -> Cmd<Reply> {
        if line == "quit" {
            return Cmd::Quit;
        }
        let mut parts = line.splitn(3, '\t');
        let (Some(id), Some(kind), Some(arg)) = (parts.next(), parts.next(), parts.next()) else {
            tracing::error!(line, "the app asked for work the host can't read");
            return Cmd::None;
        };
        let Ok(id) = id.parse::<u64>() else {
            tracing::error!(line, "the app asked for work without an id");
            return Cmd::None;
        };
        let arg = unescape(arg);
        let reply = move |result: Result<String, String>| match result {
            Ok(text) => Reply { id, ok: true, text },
            Err(text) => Reply {
                id,
                ok: false,
                text,
            },
        };
        match kind {
            "after" => {
                let ms = arg.parse::<u64>().unwrap_or(0);
                Cmd::After(Duration::from_millis(ms), reply(Ok(String::new())))
            }
            "now" => {
                let clock = self.clock.clone();
                Cmd::task(move || {
                    let ms = match clock.now().duration_since(UNIX_EPOCH) {
                        Ok(since) => since.as_millis() as i64,
                        Err(before) => -(before.duration().as_millis() as i64),
                    };
                    reply(Ok(ms.to_string()))
                })
            }
            "read" => {
                let folder = self.folder.clone();
                Cmd::task(move || reply(read(&*folder, &arg)))
            }
            "list" => {
                let folder = self.folder.clone();
                Cmd::task(move || reply(list(&*folder, &arg)))
            }
            other => {
                let message = format!("the tui platform can't do \"{other}\"");
                Cmd::task(move || reply(Err(message)))
            }
        }
    }
}

impl ambit_tui::App for App {
    type Msg = Reply;

    fn start(&mut self) -> Cmd<Reply> {
        // SAFETY: the app's entry point takes nothing and gives a step, which we own.
        let step = unsafe { roc_tui_init() };
        self.step(step)
    }

    fn update(&mut self, event: Event<Reply>) -> Cmd<Reply> {
        let state = self.take();
        // SAFETY: `state` is the box the app gave back last, which the app takes back here (it
        // owns it from now on, with the other arguments), and it gives a new step, which we own.
        let step = unsafe {
            match event {
                Event::Key(key) => {
                    let (text, code, mods) = key_to_host(key);
                    roc_tui_update(state, 0, RocStr::new(&text), code, mods, 0, 0)
                }
                Event::Paste(text) => roc_tui_update(state, 1, RocStr::new(&text), 0, 0, 0, 0),
                Event::Resize(width, height) => {
                    roc_tui_update(state, 2, RocStr::empty(), 0, 0, width, height)
                }
                Event::Msg(reply) => {
                    roc_tui_reply(state, reply.id, reply.ok, RocStr::new(&reply.text))
                }
            }
        };
        self.step(step)
    }

    fn view(&self, area: Rect, buf: &mut Buffer) {
        self.view.render(area, buf);
    }
}

/// A key as `Event.from_host` reads it: the character, the key's code and the modifiers.
fn key_to_host(key: Key) -> (String, u32, u8) {
    let mods = if key.mods.ctrl {
        1
    } else if key.mods.alt {
        2
    } else {
        0
    };
    let code = match key.code {
        KeyCode::Char(c) => return (c.to_string(), 0, mods),
        KeyCode::Enter => 1,
        KeyCode::Esc => 2,
        KeyCode::Backspace => 3,
        KeyCode::Delete => 4,
        KeyCode::Tab => 5,
        KeyCode::BackTab => 6,
        KeyCode::Up => 7,
        KeyCode::Down => 8,
        KeyCode::Left => 9,
        KeyCode::Right => 10,
        KeyCode::Home => 11,
        KeyCode::End => 12,
        KeyCode::PageUp => 13,
        KeyCode::PageDown => 14,
        KeyCode::Insert => 15,
        KeyCode::F(n) => 100 + u32::from(n),
    };
    (String::new(), code, mods)
}

/// Undoes `Cmd.escape`.
fn unescape(arg: &str) -> String {
    let mut out = String::with_capacity(arg.len());
    let mut chars = arg.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('t') => out.push('\t'),
            Some(other) => out.push(other),
            None => out.push('\\'),
        }
    }
    out
}

fn path(arg: &str) -> Result<RelPath, String> {
    if arg.is_empty() {
        Ok(RelPath::root())
    } else {
        RelPath::parse(arg).map_err(|e| e.message)
    }
}

fn read(folder: &dyn Dir, arg: &str) -> Result<String, String> {
    use std::io::Read;
    let mut file = folder.open(&path(arg)?).map_err(|e| e.message)?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).map_err(|e| e.to_string())?;
    String::from_utf8(bytes).map_err(|_| format!("{arg} is not UTF-8 text"))
}

fn list(folder: &dyn Dir, arg: &str) -> Result<String, String> {
    let mut names: Vec<String> = folder
        .list(&path(arg)?)
        .map_err(|e| e.message)?
        .into_iter()
        .map(|e| {
            if e.is_dir {
                format!("{}/", e.name)
            } else {
                e.name
            }
        })
        .collect();
    names.sort();
    Ok(names.join("\n"))
}

// --- The runtime: memory and crashes ------------------------------------------------------------

#[unsafe(no_mangle)]
pub extern "C" fn roc_alloc(length: usize, alignment: usize) -> *mut u8 {
    punk_roc_abi::allocate(length, alignment)
}

/// # Safety
/// `ptr` came from `roc_alloc` or `roc_realloc` with this alignment.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn roc_dealloc(ptr: *mut u8, alignment: usize) {
    // SAFETY: by the caller's promise.
    unsafe { punk_roc_abi::deallocate(ptr, alignment) }
}

/// # Safety
/// `ptr` came from `roc_alloc` or `roc_realloc` with this alignment.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn roc_realloc(ptr: *mut u8, new_length: usize, alignment: usize) -> *mut u8 {
    // SAFETY: by the caller's promise.
    unsafe { punk_roc_abi::reallocate(ptr, new_length, alignment) }
}

/// # Safety
/// `bytes` points at `len` bytes.
unsafe fn text<'a>(bytes: *const u8, len: usize) -> std::borrow::Cow<'a, str> {
    // SAFETY: by the caller's promise.
    String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(bytes, len) })
}

/// # Safety
/// `bytes` points at `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn roc_dbg(bytes: *const u8, len: usize) {
    // SAFETY: by the caller's promise.
    tracing::debug!("dbg: {}", unsafe { text(bytes, len) });
}

/// # Safety
/// `bytes` points at `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn roc_expect_failed(bytes: *const u8, len: usize) {
    // SAFETY: by the caller's promise.
    tracing::error!("expect failed: {}", unsafe { text(bytes, len) }.trim());
}

/// A crash can't unwind through the app, and the app's memory is in an unknown state, so the
/// program stops. punk rules out `crash` outside tests (P101), so this is a bug in the app or
/// the compiler.
///
/// # Safety
/// `bytes` points at `len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn roc_crashed(bytes: *const u8, len: usize) {
    // SAFETY: by the caller's promise.
    let message = unsafe { text(bytes, len) };
    tracing::error!("the app crashed: {message}");
    eprintln!("Roc crashed: {message}");
    std::process::abort();
}
