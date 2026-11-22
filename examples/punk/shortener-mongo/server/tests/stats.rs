// Not in ambit's spec: `GET /stats`, the number of links and the three most visited, which the
// app counts with `Mongo.update!` on each redirect. Against `PUNK_TEST_MONGO`, as tests/spec.rs.

use std::sync::Arc;
use std::time::{Duration, UNIX_EPOCH};

use ambit_server::Handler;
use ambit_server::http::StatusCode;
use ambit_server_sim::{SeededRandom, SimClock, get, post};
use punk_server_mongo::bson::doc;
use punk_server_mongo::{Access, Mongo, testing};

fn setup(name: &str) -> Option<(impl Handler, Arc<Mongo>)> {
    let db = Arc::new(testing::database(
        &format!("punk_shortener_stats_{name}"),
        &[(shortener::COLLECTION, Access::ReadWrite)],
    )?);
    let clock = SimClock::at(UNIX_EPOCH + Duration::from_secs(1_700_000_000));
    let config = shortener::Config {
        base_url: "https://s.test".into(),
        ttl: Duration::from_secs(3600),
    };
    Some((
        shortener::init(clock, SeededRandom::new(1), db.clone(), config),
        db,
    ))
}

fn create(app: &impl Handler, url: &str) -> String {
    let response = app.handle(post("/links", url));
    assert_eq!(response.status(), StatusCode::CREATED);
    let short = String::from_utf8(response.into_body()).unwrap();
    short
        .trim()
        .strip_prefix("https://s.test/")
        .unwrap()
        .to_owned()
}

fn stats(app: &impl Handler) -> String {
    let response = app.handle(get("/stats"));
    assert_eq!(response.status(), StatusCode::OK);
    String::from_utf8(response.into_body()).unwrap()
}

#[test]
fn no_links_no_visits() {
    let Some((app, _)) = setup("empty") else {
        return;
    };
    assert_eq!(stats(&app), "links: 0\n");
}

#[test]
fn the_most_visited_first() {
    let Some((app, db)) = setup("top") else {
        return;
    };
    let ids: Vec<String> = (0..5)
        .map(|i| create(&app, &format!("https://example.com/{i}")))
        .collect();
    for (id, visits) in ids.iter().zip([2, 5, 0, 1, 5]) {
        for _ in 0..visits {
            assert_eq!(
                app.handle(get(&format!("/{id}"))).status(),
                StatusCode::FOUND
            );
        }
    }
    // Equal visits: the smaller id first.
    let (a, b) = if ids[1] < ids[4] {
        (&ids[1], &ids[4])
    } else {
        (&ids[4], &ids[1])
    };
    assert_eq!(
        stats(&app),
        format!(
            "links: 5\nhttps://s.test/{a} 5\nhttps://s.test/{b} 5\nhttps://s.test/{} 2\n",
            ids[0]
        )
    );
    let stored = db
        .collection("links")
        .find_one(doc! { "_id": &ids[1] })
        .run()
        .unwrap()
        .unwrap();
    assert_eq!(stored.get_i64("visits").unwrap(), 5);
}

#[test]
fn an_unknown_link_counts_nothing() {
    let Some((app, db)) = setup("unknown") else {
        return;
    };
    assert_eq!(app.handle(get("/zzzzzzz")).status(), StatusCode::NOT_FOUND);
    assert_eq!(
        db.collection("links")
            .count_documents(doc! {})
            .run()
            .unwrap(),
        0
    );
}
