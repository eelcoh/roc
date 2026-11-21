//! Against a real database: `PUNK_TEST_POSTGRES` is its connection string (CI starts one). Without
//! it the tests say so and pass, unless `PUNK_REQUIRE_POSTGRES` is set (as in CI).

use super::*;

/// A pool on a fresh schema of the test database, or `None` when there is no database.
fn pool(name: &str) -> Option<Postgres> {
    let Ok(url) = std::env::var("PUNK_TEST_POSTGRES") else {
        assert!(
            std::env::var_os("PUNK_REQUIRE_POSTGRES").is_none(),
            "PUNK_REQUIRE_POSTGRES is set, but PUNK_TEST_POSTGRES isn't"
        );
        eprintln!("no PUNK_TEST_POSTGRES: skipping {name}");
        return None;
    };
    let schema = format!("punk_pool_{name}");
    let setup = Postgres::new(&url, 1).unwrap();
    setup
        .batch(&format!(
            "DROP SCHEMA IF EXISTS {schema} CASCADE; CREATE SCHEMA {schema};"
        ))
        .unwrap();
    let separator = if url.contains("://") {
        if url.contains('?') { "&" } else { "?" }
    } else {
        " "
    };
    let url = if url.contains("://") {
        format!("{url}{separator}options=-c%20search_path%3D{schema}")
    } else {
        format!("{url}{separator}options='-c search_path={schema}'")
    };
    Some(Postgres::new(&url, 2).unwrap())
}

#[test]
fn parameters_and_columns_have_their_types() {
    let Some(db) = pool("types") else { return };
    db.batch("CREATE TABLE t (s smallint, i integer, b bigint, r real, d double precision, t text, v varchar(10), f bool, n text)")
        .unwrap();
    let insert = "INSERT INTO t VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)";
    let params = [
        Value::Int(-3),
        Value::Int(70_000),
        Value::Int(i64::MAX),
        Value::Float(0.5),
        Value::Float(0.1),
        Value::Text("hé \"quoted\"".into()),
        Value::Text("short".into()),
        Value::Bool(true),
        Value::Null,
    ];
    assert_eq!(db.run(insert, &params).unwrap().affected, 1);
    let rows = db.run("SELECT * FROM t", &[]).unwrap();
    assert_eq!(rows.columns, ["s", "i", "b", "r", "d", "t", "v", "f", "n"]);
    assert_eq!(rows.rows, vec![params.to_vec()]);
    assert_eq!(rows.affected, 1);
}

#[test]
fn a_wrong_parameter_type_says_what_to_do() {
    let Some(db) = pool("wrong_param") else {
        return;
    };
    db.batch("CREATE TABLE t (n integer)").unwrap();
    let e = db
        .run("INSERT INTO t VALUES ($1)", &[Value::Text("7".into())])
        .unwrap_err();
    assert_eq!(e.code, "42804");
    assert!(e.message.contains("parameter $1 is int4"), "{}", e.message);
    let e = db
        .run("INSERT INTO t VALUES ($1)", &[Value::Int(1 << 40)])
        .unwrap_err();
    assert_eq!(e.code, "22003");
    let e = db.run("INSERT INTO t VALUES ($1)", &[]).unwrap_err();
    assert_eq!(e.code, "08P01");
}

#[test]
fn an_unknown_column_type_says_how_to_convert_it() {
    let Some(db) = pool("column_type") else {
        return;
    };
    let e = db.run("SELECT now() AS created", &[]).unwrap_err();
    assert_eq!(e.code, "0A000");
    assert!(e.message.contains("created::text"), "{}", e.message);
    let rows = db
        .run("SELECT extract(epoch from now())::int8 AS created", &[])
        .unwrap();
    assert!(matches!(rows.rows[0][0], Value::Int(n) if n > 1_700_000_000));
}

#[test]
fn errors_carry_the_sqlstate() {
    let Some(db) = pool("errors") else { return };
    db.batch("CREATE TABLE t (id text PRIMARY KEY)").unwrap();
    db.run("INSERT INTO t VALUES ($1)", &[Value::Text("a".into())])
        .unwrap();
    let e = db
        .run("INSERT INTO t VALUES ($1)", &[Value::Text("a".into())])
        .unwrap_err();
    assert_eq!(e.code, "23505");
    assert_eq!(db.run("SELEC 1", &[]).unwrap_err().code, "42601");
    // The connection is still good after an error.
    assert_eq!(
        db.run("SELECT 1 AS one", &[]).unwrap().rows,
        vec![vec![Value::Int(1)]]
    );
}

#[test]
fn the_pool_shares_its_connections() {
    let Some(db) = pool("threads") else { return };
    db.batch("CREATE TABLE t (n bigint)").unwrap();
    let db = std::sync::Arc::new(db);
    let threads: Vec<_> = (0..8)
        .map(|i| {
            let db = db.clone();
            std::thread::spawn(move || {
                for j in 0..20 {
                    db.run("INSERT INTO t VALUES ($1)", &[Value::Int(i * 100 + j)])
                        .unwrap();
                }
            })
        })
        .collect();
    for t in threads {
        t.join().unwrap();
    }
    let rows = db.run("SELECT count(*) AS n FROM t", &[]).unwrap();
    assert_eq!(rows.rows, vec![vec![Value::Int(160)]]);
    assert!(db.state.lock().unwrap().open <= 2);
}

#[test]
fn no_database_is_an_error_not_a_hang() {
    let db = Postgres::new("host=127.0.0.1 port=1 user=nobody connect_timeout=2", 1).unwrap();
    let e = db.run("SELECT 1", &[]).unwrap_err();
    assert_eq!(e.code, "08000");
    // The failed connection gave its place back.
    assert_eq!(db.state.lock().unwrap().open, 0);
}

#[test]
fn grants_name_the_port_and_the_resolver() {
    let db = Postgres::new("postgres://app@db.internal:6543/links", 1).unwrap();
    assert_eq!(db.grants(), vec![Grant::Connect(6543), Grant::Resolve]);
    let db = Postgres::new("host=127.0.0.1 user=app", 1).unwrap();
    assert_eq!(db.grants(), vec![Grant::Connect(5432)]);
}
