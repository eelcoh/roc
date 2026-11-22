//! The counter on ambit's sim: keys and time in, the screen out as text.

use std::time::{Duration, UNIX_EPOCH};

use ambit_tui_sim::{Sim, SimClock};
use punk_counter::init;
use punk_tui::App;

fn start() -> Sim<App> {
    let clock = SimClock::at(UNIX_EPOCH);
    Sim::new(init(clock.clone()), clock, 20, 5)
}

#[test]
fn counts_keys_and_seconds() {
    let mut sim = start();
    assert_eq!(
        sim.screen(),
        "Counter\n┌Count─────────────┐\n│0                 │\n│                  │\n└──────────────────┘"
    );
    sim.keys("ab");
    assert_eq!(sim.screen().lines().nth(2), Some("│2                 │"));
    sim.advance(Duration::from_millis(999));
    assert_eq!(sim.screen().lines().nth(2), Some("│2                 │"));
    sim.advance(Duration::from_millis(1));
    assert_eq!(sim.screen().lines().nth(2), Some("│12                │"));
    // Each tick asks for the next one.
    sim.advance(Duration::from_millis(2000));
    assert_eq!(sim.screen().lines().nth(2), Some("│32                │"));
    assert_eq!(sim.pending_timers(), 1);
}

#[test]
fn q_quits() {
    let mut sim = start();
    sim.key('q');
    assert!(sim.quit());
    // After quitting, nothing reaches the app any more.
    sim.key('a');
    assert_eq!(sim.screen().lines().nth(2), Some("│0                 │"));
}
