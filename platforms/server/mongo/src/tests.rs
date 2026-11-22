//! Against a real Mongo: `PUNK_TEST_MONGO` (as `mongodb://localhost:27017`). Without it these
//! tests say so and pass, unless `PUNK_REQUIRE_MONGO` is set (as in CI).

use super::testing;
use super::*;

fn text(s: &str) -> Doc {
    Doc::Text(s.to_owned())
}

fn object(fields: &[(&str, Doc)]) -> Doc {
    Doc::Object(
        fields
            .iter()
            .map(|(k, v)| ((*k).to_owned(), v.clone()))
            .collect(),
    )
}

fn equals(field: &str, value: Doc) -> Filter {
    Filter::Compare {
        field: field.to_owned(),
        op: Comparison::Equals,
        value,
    }
}

fn every() -> Search {
    Search {
        filter: Filter::All(vec![]),
        sort: vec![],
        skip: 0,
        limit: None,
    }
}

fn link(id: &str, url: &str, created: i64) -> Doc {
    object(&[
        ("_id", text(id)),
        ("url", text(url)),
        ("created", Doc::Int(created)),
    ])
}

#[test]
fn documents_go_in_and_come_back() {
    let Some(db) = testing::database("punk_mongo_roundtrip", &[("things", Access::ReadWrite)])
    else {
        return;
    };
    let thing = object(&[
        ("_id", Doc::ObjectId("0123456789abcdef01234567".into())),
        ("name", text("lamp")),
        ("n", Doc::Int(i64::MAX)),
        ("x", Doc::Float(0.25)),
        ("on", Doc::Bool(false)),
        ("none", Doc::Null),
        ("at", Doc::Time(1_700_000_000_123)),
        (
            "tags",
            Doc::List(vec![text("a"), object(&[("b", Doc::Int(1))])]),
        ),
    ]);
    db.insert("things", &thing).unwrap();
    assert_eq!(db.find("things", &every()).unwrap(), vec![thing]);
}

#[test]
fn filters_sort_and_page() {
    let Some(db) = testing::database("punk_mongo_find", &[("links", Access::ReadWrite)]) else {
        return;
    };
    for (i, id) in ["a", "b", "c", "d"].iter().enumerate() {
        db.insert(
            "links",
            &link(id, &format!("https://{id}.test"), i as i64 * 10),
        )
        .unwrap();
    }
    let search = Search {
        filter: Filter::All(vec![
            Filter::Compare {
                field: "created".into(),
                op: Comparison::AtLeast,
                value: Doc::Int(10),
            },
            Filter::Exists {
                field: "url".into(),
                exists: true,
            },
        ]),
        sort: vec![("created".into(), Order::Descending)],
        skip: 1,
        limit: Some(1),
    };
    let found = db.find("links", &search).unwrap();
    assert_eq!(found, vec![link("c", "https://c.test", 20)]);
    assert_eq!(db.count("links", &search).unwrap(), 1);
    let one_of = Search {
        filter: Filter::Compare {
            field: "_id".into(),
            op: Comparison::OneOf,
            value: Doc::List(vec![text("a"), text("d"), text("x")]),
        },
        ..every()
    };
    assert_eq!(db.count("links", &one_of).unwrap(), 2);
    let none = Search {
        filter: Filter::Any(vec![]),
        ..every()
    };
    assert_eq!(db.count("links", &none).unwrap(), 0);
}

#[test]
fn a_value_is_never_an_operator() {
    let Some(db) = testing::database("punk_mongo_injection", &[("links", Access::ReadWrite)])
    else {
        return;
    };
    db.insert("links", &link("a", "https://a.test", 1)).unwrap();
    // What an attacker would send as `{"$ne": ""}`, through the only door there is: a value.
    // punk-server refuses it before it gets here; even so, `$eq` compares it as data.
    let search = Search {
        filter: equals("url", object(&[("$ne", text(""))])),
        ..every()
    };
    assert_eq!(db.find("links", &search).unwrap(), vec![]);
}

#[test]
fn updates_and_deletes_count_what_they_matched() {
    let Some(db) = testing::database("punk_mongo_change", &[("links", Access::ReadWrite)]) else {
        return;
    };
    db.insert("links", &link("a", "https://a.test", 1)).unwrap();
    db.insert("links", &link("b", "https://b.test", 2)).unwrap();
    let changed = db
        .update(
            "links",
            &equals("_id", text("a")),
            &[
                Change::Set("url".into(), text("https://new.test")),
                Change::Increment("visits".into(), 2),
                Change::Unset("created".into()),
            ],
        )
        .unwrap();
    assert_eq!(changed, 1);
    let found = db
        .find(
            "links",
            &Search {
                filter: equals("_id", text("a")),
                ..every()
            },
        )
        .unwrap();
    assert_eq!(
        found,
        vec![object(&[
            ("_id", text("a")),
            ("url", text("https://new.test")),
            ("visits", Doc::Int(2))
        ])]
    );
    assert_eq!(db.delete("links", &Filter::All(vec![])).unwrap(), 2);
}

#[test]
fn a_taken_id_is_11000() {
    let Some(db) = testing::database("punk_mongo_duplicate", &[("links", Access::ReadWrite)])
    else {
        return;
    };
    db.insert("links", &link("a", "https://a.test", 1)).unwrap();
    let e = db
        .insert("links", &link("a", "https://b.test", 2))
        .unwrap_err();
    assert_eq!(e.code, "11000");
}

#[test]
fn only_the_allowed_collections() {
    let Some(db) = testing::database("punk_mongo_access", &[("public", Access::Read)]) else {
        return;
    };
    assert_eq!(db.find("public", &every()).unwrap(), vec![]);
    assert_eq!(
        db.insert("public", &link("a", "x", 1)).unwrap_err().code,
        "13"
    );
    assert_eq!(db.find("secrets", &every()).unwrap_err().code, "13");
}

#[test]
fn no_server_is_6() {
    if std::env::var_os("PUNK_TEST_MONGO").is_none() {
        return;
    }
    let db = Mongo::connect("mongodb://127.0.0.1:1/?serverSelectionTimeoutMS=200", "x")
        .unwrap()
        .allow("links", Access::Read);
    assert_eq!(db.find("links", &every()).unwrap_err().code, "6");
}
