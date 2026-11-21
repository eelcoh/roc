// ambit's spec for its shortener (eelcoh/ambit spec/tests/shortener.rs at the commit in
// Cargo.toml), with the key-value store replaced by Postgres: the same tests and the same
// answers. Where ambit's spec makes the store fail (`MemKv::fail`), these tests make the table
// go away or refuse writes.
//
// The database is `PUNK_TEST_POSTGRES` (a connection string); each test gets its own schema.
// Without it the tests say so and pass, unless `PUNK_REQUIRE_POSTGRES` is set (as in CI).

use std::time::{Duration, UNIX_EPOCH};

use ambit_server::Handler;
use ambit_server::http::{StatusCode, header};
use ambit_server_sim::{SeededRandom, SimClock, get, post};
use punk_server::{Database, Value};
use punk_server_postgres::Postgres;

const TTL: Duration = Duration::from_secs(3600);

/// The test database with a fresh, empty schema `name` holding the shortener's table, or `None`
/// when there is no test database.
fn database(name: &str) -> Option<std::sync::Arc<Postgres>> {
    let Ok(url) = std::env::var("PUNK_TEST_POSTGRES") else {
        assert!(
            std::env::var_os("PUNK_REQUIRE_POSTGRES").is_none(),
            "PUNK_REQUIRE_POSTGRES is set, but PUNK_TEST_POSTGRES isn't"
        );
        eprintln!("no PUNK_TEST_POSTGRES: skipping {name}");
        return None;
    };
    let schema = format!("punk_shortener_{name}");
    Postgres::new(&url, 1)
        .unwrap()
        .batch(&format!(
            "DROP SCHEMA IF EXISTS {schema} CASCADE; CREATE SCHEMA {schema};"
        ))
        .unwrap();
    let url = if url.contains("://") {
        let separator = if url.contains('?') { "&" } else { "?" };
        format!("{url}{separator}options=-c%20search_path%3D{schema}")
    } else {
        format!("{url} options='-c search_path={schema}'")
    };
    let db = Postgres::new(&url, 2).unwrap();
    db.batch(shortener::SCHEMA).unwrap();
    Some(std::sync::Arc::new(db))
}

fn setup(name: &str, seed: u64) -> Option<(impl Handler, SimClock, std::sync::Arc<Postgres>)> {
    let db = database(name)?;
    let clock = SimClock::at(UNIX_EPOCH + Duration::from_secs(1_700_000_000));
    let config = shortener::Config {
        base_url: "https://s.test".into(),
        ttl: TTL,
    };
    let app = shortener::init(clock.clone(), SeededRandom::new(seed), db.clone(), config);
    Some((app, clock, db))
}

/// How many links are stored.
fn stored(db: &Postgres) -> i64 {
    match db.run("SELECT count(*) AS n FROM links", &[]).unwrap().rows[0][0] {
        Value::Int(n) => n,
        ref other => panic!("count gave {other:?}"),
    }
}

/// Creates a link; returns the id.
fn create(app: &impl Handler, url: &str) -> String {
    let response = app.handle(post("/links", url));
    assert_eq!(response.status(), StatusCode::CREATED);
    let short = String::from_utf8(response.into_body()).unwrap();
    short
        .trim()
        .strip_prefix("https://s.test/")
        .expect("short url uses base_url")
        .to_owned()
}

#[test]
fn created_link_redirects() {
    let Some((app, _, _)) = setup("redirects", 1) else {
        return;
    };
    let id = create(&app, "https://example.com/some/page?q=1");
    let response = app.handle(get(&format!("/{id}")));
    assert_eq!(response.status(), StatusCode::FOUND);
    assert_eq!(
        response.headers()[header::LOCATION],
        "https://example.com/some/page?q=1"
    );
}

#[test]
fn unknown_link_is_404() {
    let Some((app, _, _)) = setup("unknown", 1) else {
        return;
    };
    assert_eq!(app.handle(get("/zzzzzzz")).status(), StatusCode::NOT_FOUND);
    assert_eq!(app.handle(get("/")).status(), StatusCode::NOT_FOUND);
}

#[test]
fn link_expires_after_ttl() {
    let Some((app, clock, _)) = setup("expires", 1) else {
        return;
    };
    let id = create(&app, "https://example.com");
    clock.advance(TTL - Duration::from_secs(1));
    assert_eq!(
        app.handle(get(&format!("/{id}"))).status(),
        StatusCode::FOUND
    );
    clock.advance(Duration::from_secs(1));
    assert_eq!(
        app.handle(get(&format!("/{id}"))).status(),
        StatusCode::GONE
    );
}

#[test]
fn invalid_url_is_rejected_and_not_stored() {
    let Some((app, _, db)) = setup("invalid", 1) else {
        return;
    };
    for body in [
        "",
        "not a url",
        "javascript:alert(1)",
        "https://x\r\nSet-Cookie: a=b",
    ] {
        assert_eq!(
            app.handle(post("/links", body)).status(),
            StatusCode::BAD_REQUEST,
            "{body:?}"
        );
    }
    assert_eq!(stored(&db), 0);
}

#[test]
fn a_url_with_sql_in_it_is_just_a_url() {
    let Some((app, _, db)) = setup("injection", 1) else {
        return;
    };
    let url = "https://example.com/?q=';DROP TABLE links;--";
    let id = create(&app, url);
    let response = app.handle(get(&format!("/{id}")));
    assert_eq!(response.status(), StatusCode::FOUND);
    assert_eq!(response.headers()[header::LOCATION], url);
    assert_eq!(stored(&db), 1);
}

#[test]
fn ids_are_unique() {
    let Some((app, _, db)) = setup("unique", 7) else {
        return;
    };
    let ids: std::collections::HashSet<_> = (0..200)
        .map(|i| create(&app, &format!("https://example.com/{i}")))
        .collect();
    assert_eq!(ids.len(), 200);
    assert_eq!(stored(&db), 200);
}

#[test]
fn a_taken_id_is_skipped() {
    // Two apps with the same seed pick the same ids; the second finds them taken.
    let Some((a, _, db)) = setup("taken", 3) else {
        return;
    };
    let clock = SimClock::at(UNIX_EPOCH + Duration::from_secs(1_700_000_000));
    let config = shortener::Config {
        base_url: "https://s.test".into(),
        ttl: TTL,
    };
    let b = shortener::init(clock, SeededRandom::new(3), db.clone(), config);
    let first = create(&a, "https://example.com/a");
    let second = create(&b, "https://example.com/b");
    assert_ne!(first, second);
    assert_eq!(stored(&db), 2);
}

#[test]
fn same_seed_same_ids() {
    let Some((a, _, _)) = setup("seed_a", 3) else {
        return;
    };
    let Some((b, _, _)) = setup("seed_b", 3) else {
        return;
    };
    assert_eq!(
        create(&a, "https://example.com"),
        create(&b, "https://example.com")
    );
}

#[test]
fn storage_down_is_503_and_recovers() {
    let Some((app, _, db)) = setup("down", 1) else {
        return;
    };
    let id = create(&app, "https://example.com");
    db.batch("ALTER TABLE links RENAME TO links_away").unwrap();
    assert_eq!(
        app.handle(post("/links", "https://example.org")).status(),
        StatusCode::SERVICE_UNAVAILABLE
    );
    assert_eq!(
        app.handle(get(&format!("/{id}"))).status(),
        StatusCode::SERVICE_UNAVAILABLE
    );
    db.batch("ALTER TABLE links_away RENAME TO links").unwrap();
    assert_eq!(
        app.handle(get(&format!("/{id}"))).status(),
        StatusCode::FOUND
    );
}

#[test]
fn no_database_is_503() {
    let db = Postgres::new("host=127.0.0.1 port=1 user=nobody connect_timeout=2", 1).unwrap();
    let clock = SimClock::at(UNIX_EPOCH + Duration::from_secs(1_700_000_000));
    let config = shortener::Config {
        base_url: "https://s.test".into(),
        ttl: TTL,
    };
    let app = shortener::init(clock, SeededRandom::new(1), db, config);
    assert_eq!(
        app.handle(post("/links", "https://example.org")).status(),
        StatusCode::SERVICE_UNAVAILABLE
    );
    assert_eq!(
        app.handle(get("/abcdefg")).status(),
        StatusCode::SERVICE_UNAVAILABLE
    );
}

#[test]
fn failed_write_creates_nothing_but_reads_still_work() {
    let Some((app, _, db)) = setup("writes", 1) else {
        return;
    };
    let id = create(&app, "https://example.com");
    db.batch(
        "CREATE FUNCTION refuse() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'writes fail'; END $$;
         CREATE TRIGGER refuse BEFORE INSERT ON links FOR EACH ROW EXECUTE FUNCTION refuse();",
    )
    .unwrap();
    assert_eq!(
        app.handle(post("/links", "https://example.org")).status(),
        StatusCode::SERVICE_UNAVAILABLE
    );
    assert_eq!(stored(&db), 1);
    assert_eq!(
        app.handle(get(&format!("/{id}"))).status(),
        StatusCode::FOUND
    );
}

#[test]
fn a_row_that_does_not_fit_is_500() {
    let Some((app, _, db)) = setup("misfit", 1) else {
        return;
    };
    db.batch("ALTER TABLE links ALTER COLUMN created TYPE text; INSERT INTO links VALUES ('abcdefg', 'https://x.org', '7');")
        .unwrap();
    assert_eq!(
        app.handle(get("/abcdefg")).status(),
        StatusCode::INTERNAL_SERVER_ERROR
    );
}

#[test]
fn every_request_frees_what_it_allocates() {
    let Some((app, _, _)) = setup("leaks", 5) else {
        return;
    };
    let before = punk_server::thread_live_bytes();
    for i in 0..50 {
        let id = create(
            &app,
            &format!("https://example.com/a/page/with/a/long/enough/path/{i}"),
        );
        assert_eq!(
            app.handle(get(&format!("/{id}"))).status(),
            StatusCode::FOUND
        );
        assert_eq!(app.handle(get("/nothing")).status(), StatusCode::NOT_FOUND);
        assert_eq!(app.handle(get("/abcdefg")).status(), StatusCode::NOT_FOUND);
    }
    assert_eq!(punk_server::thread_live_bytes(), before);
}
