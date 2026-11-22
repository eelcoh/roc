// Notes kept apart by row-level security: each test gets its own schema of `PUNK_TEST_POSTGRES`
// with the app's table and policies (`../schema.sql`), and the app connects as a role that keeps
// to them. Without a test database the tests say so and pass, unless `PUNK_REQUIRE_POSTGRES` is
// set (as in CI).

use std::time::{Duration, UNIX_EPOCH};

use ambit_server::Handler;
use ambit_server::http::{HeaderValue, Request, StatusCode};
use ambit_server_sim::{SeededRandom, SimClock, request};
use punk_server::{Database, Value};
use punk_server_postgres::{Owner, Postgres, testing};

fn setup(name: &str) -> Option<(impl Handler, std::sync::Arc<Postgres>, Owner)> {
    let (owner, db) = testing::database(&format!("punk_notes_{name}"), notes::SCHEMA)?;
    let db = std::sync::Arc::new(db);
    let clock = SimClock::at(UNIX_EPOCH + Duration::from_secs(1_700_000_000));
    let app = notes::init(clock, SeededRandom::new(1), db.clone());
    Some((app, db, owner))
}

/// A request of `user`; `None` is a request without a user.
fn by(user: Option<&str>, method: &str, uri: &str, body: &str) -> Request<Vec<u8>> {
    let mut req = request(method, uri, body.as_bytes().to_vec());
    if let Some(user) = user {
        req.headers_mut()
            .insert("x-user", HeaderValue::from_str(user).unwrap());
    }
    req
}

fn send(app: &impl Handler, req: Request<Vec<u8>>) -> (StatusCode, String) {
    let response = app.handle(req);
    let status = response.status();
    (status, String::from_utf8(response.into_body()).unwrap())
}

/// Makes a note of `user`; returns its id.
fn add(app: &impl Handler, user: &str, text: &str) -> String {
    let (status, body) = send(app, by(Some(user), "POST", "/notes", text));
    assert_eq!(status, StatusCode::CREATED, "{body}");
    body.trim().to_owned()
}

/// The texts of the notes `user` reads, sorted.
fn texts(app: &impl Handler, user: Option<&str>) -> Vec<String> {
    let (status, body) = send(app, by(user, "GET", "/notes", ""));
    assert_eq!(status, StatusCode::OK, "{body}");
    let mut texts: Vec<String> = body
        .lines()
        .map(|line| line.splitn(3, ' ').skip(1).collect::<Vec<_>>().join(" "))
        .collect();
    texts.sort();
    texts
}

#[test]
fn each_user_reads_their_own_notes() {
    let Some((app, _, _)) = setup("own") else {
        return;
    };
    add(&app, "ann", "ann's plan");
    add(&app, "bob", "bob's list");
    assert_eq!(texts(&app, Some("ann")), ["private ann's plan"]);
    assert_eq!(texts(&app, Some("bob")), ["private bob's list"]);
    assert!(texts(&app, None).is_empty());
}

#[test]
fn a_public_note_is_read_by_everyone() {
    let Some((app, _, _)) = setup("public") else {
        return;
    };
    let id = add(&app, "ann", "hello all");
    add(&app, "ann", "just mine");
    let (status, _) = send(
        &app,
        by(Some("ann"), "POST", &format!("/notes/{id}/publish"), ""),
    );
    assert_eq!(status, StatusCode::OK);
    assert_eq!(texts(&app, Some("bob")), ["public hello all"]);
    assert_eq!(texts(&app, None), ["public hello all"]);
    assert_eq!(
        texts(&app, Some("ann")),
        ["private just mine", "public hello all"]
    );
}

#[test]
fn nobody_changes_or_removes_another_users_note() {
    let Some((app, _, _)) = setup("others") else {
        return;
    };
    let id = add(&app, "ann", "ann's plan");
    for user in [Some("bob"), None] {
        let publish = by(user, "POST", &format!("/notes/{id}/publish"), "");
        assert_eq!(send(&app, publish).0, StatusCode::NOT_FOUND);
        let delete = by(user, "DELETE", &format!("/notes/{id}"), "");
        assert_eq!(send(&app, delete).0, StatusCode::NOT_FOUND);
    }
    assert_eq!(texts(&app, Some("ann")), ["private ann's plan"]);
    let delete = by(Some("ann"), "DELETE", &format!("/notes/{id}"), "");
    assert_eq!(send(&app, delete).0, StatusCode::OK);
    assert!(texts(&app, Some("ann")).is_empty());
}

#[test]
fn without_a_user_nothing_is_written() {
    let Some((app, db, _)) = setup("nobody") else {
        return;
    };
    // The note would be nobody's ("" as owner): the insert policy refuses it.
    assert_eq!(
        send(&app, by(None, "POST", "/notes", "who am I")).0,
        StatusCode::FORBIDDEN
    );
    let rows = db.run("SELECT count(*) AS n FROM notes", &[]).unwrap();
    assert_eq!(rows.rows, vec![vec![Value::Int(0)]]);
}

#[test]
fn sql_outside_the_app_keeps_to_the_policies_too() {
    let Some((app, db, owner)) = setup("raw") else {
        return;
    };
    add(&app, "ann", "ann's plan");
    // The app's role, without a user: the database itself leaves the note out.
    let rows = db.run("SELECT id FROM notes", &[]).unwrap();
    assert!(rows.rows.is_empty());
    // As the user, it is there.
    let rows = db
        .run_as(
            &[("punk.user_id".to_owned(), "ann".to_owned())],
            "SELECT body FROM notes",
            &[],
        )
        .unwrap();
    assert_eq!(rows.rows, vec![vec![Value::Text("ann's plan".into())]]);
    // The owner of the table may look (the test database's owner is a superuser).
    owner.batch("SELECT 1 FROM notes").unwrap();
}

#[test]
fn a_pinned_note_is_not_removed() {
    let Some((app, _, _)) = setup("pinned") else {
        return;
    };
    let id = add(&app, "ann", "keep me");
    let pin = by(Some("ann"), "POST", &format!("/notes/{id}/pin"), "");
    assert_eq!(send(&app, pin).0, StatusCode::OK);
    let delete = by(Some("ann"), "DELETE", &format!("/notes/{id}"), "");
    assert_eq!(send(&app, delete).0, StatusCode::NOT_FOUND);
    assert_eq!(texts(&app, Some("ann")), ["private keep me"]);
}

#[test]
fn notes_from_before_version_2_are_kept() {
    // A database that has version 1 of the schema, with a note in it.
    let v1 = &notes::SCHEMA[..notes::SCHEMA.find("\n-- punk version 2").unwrap()];
    let Some((owner, db)) = testing::database("punk_notes_v1", v1) else {
        return;
    };
    owner
        .batch("INSERT INTO notes (id, owner, text, public) VALUES ('n1', 'ann', 'from before', false)")
        .unwrap();
    // The wiring brings it to the last version: `text` is `body`, and the
    // note isn't pinned.
    assert_eq!(owner.migrate(notes::SCHEMA).unwrap(), [2, 3]);
    assert!(owner.migrate(notes::SCHEMA).unwrap().is_empty());
    let db = std::sync::Arc::new(db);
    let clock = SimClock::at(UNIX_EPOCH + Duration::from_secs(1_700_000_000));
    let app = notes::init(clock, SeededRandom::new(1), db.clone());
    assert_eq!(texts(&app, Some("ann")), ["private from before"]);
    assert!(texts(&app, Some("bob")).is_empty());
    let delete = by(Some("ann"), "DELETE", "/notes/n1", "");
    assert_eq!(send(&app, delete).0, StatusCode::OK);
}

#[test]
fn public_notes_come_with_the_names_of_their_writers() {
    let Some((app, _, _)) = setup("names") else {
        return;
    };
    let name = |user: Option<&str>, name: &str| send(&app, by(user, "PUT", "/me", name)).0;
    assert_eq!(name(Some("ann"), "Ann"), StatusCode::CREATED);
    assert_eq!(name(Some("ann"), "Ann B"), StatusCode::OK);
    assert_eq!(name(Some("bob"), "Bob"), StatusCode::CREATED);
    // Nobody has no name to give.
    assert_eq!(name(None, "Who"), StatusCode::FORBIDDEN);
    let publish = |user: &str, text: &str| {
        let id = add(&app, user, text);
        let req = by(Some(user), "POST", &format!("/notes/{id}/publish"), "");
        assert_eq!(send(&app, req).0, StatusCode::OK);
    };
    publish("bob", "b1");
    publish("ann", "a2");
    publish("ann", "a1");
    add(&app, "ann", "secret");
    // Carl has no name: the join leaves his note out.
    publish("carl", "c1");
    let (status, body) = send(&app, by(None, "GET", "/public", ""));
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, "Ann B: a1\nAnn B: a2\nBob: b1\n");
}

#[test]
fn one_pinned_note_per_user_in_a_transaction() {
    let Some((app, _, _)) = setup("pin_one") else {
        return;
    };
    let first = add(&app, "ann", "first");
    let second = add(&app, "ann", "second");
    let pin = |user: &str, id: &str| {
        send(
            &app,
            by(Some(user), "POST", &format!("/notes/{id}/pin"), ""),
        )
        .0
    };
    let delete = |id: &str| send(&app, by(Some("ann"), "DELETE", &format!("/notes/{id}"), "")).0;
    assert_eq!(pin("ann", &first), StatusCode::OK);
    assert_eq!(pin("ann", &second), StatusCode::OK);
    // A note that isn't there, or isn't hers: the unpinning rolls back with it.
    assert_eq!(pin("ann", "nope"), StatusCode::NOT_FOUND);
    assert_eq!(pin("bob", &second), StatusCode::NOT_FOUND);
    assert_eq!(delete(&second), StatusCode::NOT_FOUND);
    // The first lost its pin when the second got one.
    assert_eq!(delete(&first), StatusCode::OK);
    assert_eq!(texts(&app, Some("ann")), ["private second"]);
}
