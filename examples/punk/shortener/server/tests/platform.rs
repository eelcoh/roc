//! What the punk platform adds to ambit's spec: the app frees what it allocates, and a broken
//! configuration is an answer, not a crash.

use std::time::{Duration, UNIX_EPOCH};

use ambit_server::Handler;
use ambit_server::http::StatusCode;
use ambit_server_sim::{MemKv, SeededRandom, SimClock, get, post};

fn app() -> impl Handler {
    let clock = SimClock::at(UNIX_EPOCH + Duration::from_secs(1_700_000_000));
    let config = shortener::Config {
        base_url: "https://s.test/with/a/longer/prefix".into(),
        ttl: Duration::from_secs(60),
    };
    shortener::init(clock, SeededRandom::new(5), MemKv::new(), config)
}

#[test]
fn every_request_frees_what_it_allocates() {
    let app = app();
    let before = punk_server::thread_live_bytes();
    for i in 0..100 {
        let url = format!("https://example.com/a/page/with/a/long/enough/path/{i}");
        let created = app.handle(post("/links", url));
        assert_eq!(created.status(), StatusCode::CREATED);
        let short = String::from_utf8(created.into_body()).unwrap();
        let id = short.trim().rsplit('/').next().unwrap().to_owned();
        assert_eq!(app.handle(get(&format!("/{id}"))).status(), StatusCode::FOUND);
        assert_eq!(app.handle(get("/nothing")).status(), StatusCode::NOT_FOUND);
        assert_eq!(app.handle(post("/links", "ftp://x")).status(), StatusCode::BAD_REQUEST);
    }
    assert_eq!(punk_server::thread_live_bytes(), before);
}

#[test]
fn a_broken_configuration_is_a_500() {
    let config = "{\"baseUrl\": 7}";
    let app = punk_server::App::new(SimClock::at(UNIX_EPOCH), SeededRandom::new(1), MemKv::new(), config);
    let response = app.handle(get("/abcdefg"));
    assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
}
