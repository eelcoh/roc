//! The counter, compiled from `../Counter.punk` (see build.rs), as an ambit tui app.

use ambit_caps::Clock;

/// The app with its one capability, the clock its timer counts with. It reads no files.
pub fn init(clock: impl Clock) -> punk_tui::App {
    punk_tui::App::new(punk_tui::NoFolder, clock)
}
