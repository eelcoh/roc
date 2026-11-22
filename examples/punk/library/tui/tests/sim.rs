//! The library view on ambit's sim: keys in, the screen out as text. The same behaviour as
//! crossload's library list: sorting, marking and searching.

use std::time::UNIX_EPOCH;

use ambit_caps_sim::SimDir;
use ambit_tui::style::Modifier;
use ambit_tui::{Key, KeyCode};
use ambit_tui_sim::{Sim, SimClock};
use punk_tui::App;

const LIBRARY: &str = include_str!("../../library.json");

fn start(folder: SimDir) -> Sim<App> {
    let clock = SimClock::at(UNIX_EPOCH);
    Sim::new(punk_library::init(folder, clock.clone()), clock, 60, 12)
}

fn library() -> (SimDir, Sim<App>) {
    let folder = SimDir::new();
    folder.file("library.json", LIBRARY);
    (folder.clone(), start(folder))
}

/// The titles in the list, top to bottom.
fn titles(sim: &Sim<App>) -> Vec<String> {
    rows(sim).into_iter().map(|(_, title)| title).collect()
}

/// The list's rows: the mark and the title.
fn rows(sim: &Sim<App>) -> Vec<(char, String)> {
    sim.screen()
        .lines()
        .skip(3)
        .filter_map(|l| l.strip_prefix('│'))
        .filter_map(|l| {
            let mark = l.chars().next()?;
            let title: String = l.chars().skip(8).collect();
            let title = title.split("  ").next()?.trim().to_string();
            (!title.is_empty()).then_some((mark, title))
        })
        .collect()
}

/// The title of the highlighted row: the one drawn reversed.
fn highlighted(sim: &Sim<App>) -> Option<String> {
    let buf = sim.buffer();
    let screen = sim.screen();
    let lines: Vec<&str> = screen.lines().collect();
    (3..buf.area.height).find_map(|y| {
        let reversed = buf[(10, y)].modifier.contains(Modifier::REVERSED);
        reversed.then(|| {
            let title: String = lines[y as usize].chars().skip(9).collect();
            title.split("  ").next().unwrap_or("").trim().to_string()
        })
    })
}

#[test]
fn shows_the_books_sorted_by_title() {
    let (_, sim) = library();
    assert_eq!(
        sim.screen(),
        [
            "Crossload · Books",
            "All books  6 of 6 · title ↑",
            "┌ Library · 6 ─────────────────────────────────────────────┐",
            "│  · ● · A Wizard of Earthsea       Ursula K. Le Guin      │",
            "│  ● · · Children of Time           Adrian Tchaikovsky     │",
            "│  ● ● · Dune                       Frank Herbert          │",
            "│  ● ● ● Piranesi                   Susanna Clarke         │",
            "│  ● · · Slow Horses                Mick Herron            │",
            "│  ● · ● The Left Hand of Darkness  Ursula K. Le Guin      │",
            "└──────────────────────────────────────────────────────────┘",
            "",
            "↑↓ move · Space mark · a all · s sort · / search · q quit",
        ]
        .join("\n")
    );
    assert_eq!(highlighted(&sim).as_deref(), Some("A Wizard of Earthsea"));
}

#[test]
fn sorting_cycles_and_keeps_the_highlighted_book() {
    let (_, mut sim) = library();
    sim.key(KeyCode::Down).key('j');
    assert_eq!(highlighted(&sim).as_deref(), Some("Dune"));

    sim.key('s');
    assert!(sim.screen().contains("· author ↑"));
    assert_eq!(
        titles(&sim),
        [
            "Children of Time",
            "Dune",
            "Slow Horses",
            "Piranesi",
            "A Wizard of Earthsea",
            "The Left Hand of Darkness"
        ]
    );
    assert_eq!(highlighted(&sim).as_deref(), Some("Dune"));

    sim.key('s');
    assert!(sim.screen().contains("· series ↑"));
    // A book without a series comes first; then by series.
    assert_eq!(
        titles(&sim),
        [
            "Piranesi",
            "Children of Time",
            "Dune",
            "A Wizard of Earthsea",
            "The Left Hand of Darkness",
            "Slow Horses"
        ]
    );
    assert_eq!(highlighted(&sim).as_deref(), Some("Dune"));

    sim.key('s');
    assert!(sim.screen().contains("· title ↑"));
    assert_eq!(titles(&sim)[0], "A Wizard of Earthsea");
}

#[test]
fn moving_stays_inside_the_list() {
    let (_, mut sim) = library();
    sim.key(KeyCode::Up).key('k');
    assert_eq!(highlighted(&sim).as_deref(), Some("A Wizard of Earthsea"));
    sim.key(KeyCode::End);
    assert_eq!(
        highlighted(&sim).as_deref(),
        Some("The Left Hand of Darkness")
    );
    sim.key(KeyCode::Down).key(KeyCode::PageDown);
    assert_eq!(
        highlighted(&sim).as_deref(),
        Some("The Left Hand of Darkness")
    );
    sim.key(KeyCode::PageUp);
    assert_eq!(highlighted(&sim).as_deref(), Some("A Wizard of Earthsea"));
    sim.key(KeyCode::Down).key(KeyCode::Home);
    assert_eq!(highlighted(&sim).as_deref(), Some("A Wizard of Earthsea"));
}

#[test]
fn space_marks_and_unmarks_the_highlighted_book() {
    let (_, mut sim) = library();
    sim.key('j').key(' ');
    assert_eq!(rows(&sim)[1], ('✓', "Children of Time".to_string()));
    assert!(sim.screen().contains("✓ 1 marked"));
    sim.key(' ');
    assert_eq!(rows(&sim)[1], (' ', "Children of Time".to_string()));
    assert!(!sim.screen().contains("marked"));
}

#[test]
fn a_marks_every_book_shown_then_clears_them() {
    let (_, mut sim) = library();
    sim.key('/').keys("guin").key(KeyCode::Esc).key('a');
    assert_eq!(
        rows(&sim),
        [
            ('✓', "A Wizard of Earthsea".to_string()),
            ('✓', "The Left Hand of Darkness".to_string())
        ]
    );
    assert!(sim.screen().contains("✓ 2 marked"));
    sim.key('a');
    assert!(rows(&sim).iter().all(|(mark, _)| *mark == ' '));
}

#[test]
fn marked_books_stay_marked_when_a_search_hides_them() {
    let (_, mut sim) = library();
    sim.key('j').key('j').key(' ');
    sim.key('/').keys("earthsea").key(KeyCode::Enter);
    assert_eq!(titles(&sim), ["A Wizard of Earthsea"]);
    assert!(sim.screen().contains("✓ 1 marked"));
    sim.key('/').key(Key::ctrl('u')).key(KeyCode::Enter);
    assert_eq!(rows(&sim)[2], ('✓', "Dune".to_string()));
}

#[test]
fn search_matches_any_field_or_the_one_named() {
    let (_, mut sim) = library();
    sim.key('/').keys("le guin");
    assert_eq!(sim.screen().lines().nth(1), Some("/le guin▏"));
    assert_eq!(
        titles(&sim),
        ["A Wizard of Earthsea", "The Left Hand of Darkness"]
    );
    assert!(sim.screen().contains("Library · 2 of 6"));

    sim.key(Key::ctrl('u')).keys("title:dark");
    assert_eq!(titles(&sim), ["The Left Hand of Darkness"]);

    sim.key(Key::ctrl('u')).keys("series:slough");
    assert_eq!(titles(&sim), ["Slow Horses"]);

    // Backspace takes off one character; Esc leaves the search and keeps it.
    sim.key(KeyCode::Backspace)
        .key(KeyCode::Backspace)
        .key(KeyCode::Backspace);
    assert_eq!(sim.screen().lines().nth(1), Some("/series:slo▏"));
    sim.key(KeyCode::Esc);
    assert_eq!(
        sim.screen().lines().nth(1),
        Some("All books · matching series:slo  1 of 6 · title ↑")
    );
    // Out of the search, keys are commands again: q quits.
    sim.key('q');
    assert!(sim.quit());
}

#[test]
fn r_reads_the_library_again() {
    let (folder, mut sim) = library();
    folder.file(
        "library.json",
        r#"[{ "id": "a", "title": "Anathem", "author": "Neal Stephenson", "on": ["kobo"] }]"#,
    );
    assert_eq!(titles(&sim).len(), 6);
    sim.key('r');
    assert_eq!(titles(&sim), ["Anathem"]);
}

#[test]
fn says_so_when_the_library_cant_be_read() {
    let sim = start(SimDir::new());
    assert!(
        sim.screen().contains("The library can't be read:"),
        "{}",
        sim.screen()
    );
    let folder = SimDir::new();
    folder.file("library.json", "[{ \"title\": 3 }]");
    let sim = start(folder);
    assert!(
        sim.screen().contains("The library can't be read:"),
        "{}",
        sim.screen()
    );
}

#[test]
fn q_esc_and_ctrl_c_quit() {
    for key in [Key::from('q'), Key::from(KeyCode::Esc), Key::ctrl('c')] {
        let (_, mut sim) = library();
        sim.key(key);
        assert!(sim.quit(), "{key:?}");
    }
}

#[test]
fn the_list_follows_a_narrower_screen() {
    let (_, mut sim) = library();
    sim.resize(40, 12);
    assert_eq!(
        sim.screen().lines().nth(3),
        Some("│  · ● · A Wizard of Ea… Ursula K. Le …│")
    );
}

#[test]
fn the_app_gives_back_what_it_allocates() {
    let (_, mut sim) = library();
    let step = |sim: &mut Sim<App>| {
        sim.key('j')
            .key(' ')
            .key('s')
            .key('/')
            .keys("du")
            .key(KeyCode::Esc);
    };
    step(&mut sim);
    let before = punk_tui::thread_live_bytes();
    for _ in 0..50 {
        step(&mut sim);
    }
    // The model holds the same after each round (the marks toggle back and forth), so what the
    // app holds may only differ by what one round leaves behind.
    let grown = punk_tui::thread_live_bytes() - before;
    assert!(
        grown.abs() < 4096,
        "the app holds {grown} bytes more after 50 rounds"
    );
}
