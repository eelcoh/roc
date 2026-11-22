//! The library view of crossload, compiled from `../Library.punk` (see build.rs), as an ambit
//! tui app.

use ambit_caps::Clock;
use ambit_caps_dir::Dir;

/// The app with its capabilities: the folder that holds `library.json` (it can read nothing
/// else), and the clock.
pub fn init(folder: impl Dir, clock: impl Clock) -> punk_tui::App {
    punk_tui::App::new(folder, clock)
}
