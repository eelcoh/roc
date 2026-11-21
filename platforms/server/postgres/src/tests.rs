//! Against a real database: `PUNK_TEST_POSTGRES` is its connection string (CI starts one). Without
//! it the tests say so and pass, unless `PUNK_REQUIRE_POSTGRES` is set (as in CI).

use super::*;

/// A pool on a fresh schema of the test database with these tables, or `None` when there is no
/// database.
fn pool(name: &str, tables: &str) -> Option<Postgres> {
    testing::database(&format!("punk_pool_{name}"), tables).map(|(_, db)| db)
}

#[test]
fn parameters_and_columns_have_their_types() {
    let Some(db) = pool(
        "types",
        "CREATE TABLE t (s smallint, i integer, b bigint, r real, d double precision, t text, v varchar(10), f bool, n text)",
    ) else {
        return;
    };
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
    let Some(db) = pool("wrong_param", "CREATE TABLE t (n integer)") else {
        return;
    };
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
    let Some(db) = pool("column_type", "") else {
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
    let Some(db) = pool("errors", "CREATE TABLE t (id text PRIMARY KEY)") else {
        return;
    };
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
    let Some(db) = pool("threads", "CREATE TABLE t (n bigint)") else {
        return;
    };
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

/// A table with policies as punk makes them: everyone reads the public notes and their own,
/// and writes only their own.
const NOTES: &str = "
    CREATE TABLE notes (id text PRIMARY KEY, owner text NOT NULL, public boolean NOT NULL);
    ALTER TABLE notes ENABLE ROW LEVEL SECURITY;
    ALTER TABLE notes FORCE ROW LEVEL SECURITY;
    CREATE POLICY notes_read ON notes FOR SELECT USING (public OR owner = NULLIF(current_setting('punk.user_id', true), ''));
    CREATE POLICY notes_insert ON notes FOR INSERT WITH CHECK (owner = NULLIF(current_setting('punk.user_id', true), ''));
    INSERT INTO notes VALUES ('a1', 'ann', false), ('a2', 'ann', true), ('b1', 'bob', false);
";

fn as_user(id: &str) -> Vec<(String, String)> {
    vec![("punk.user_id".to_owned(), id.to_owned())]
}

fn ids(db: &Postgres, settings: &[(String, String)]) -> Vec<Value> {
    let rows = db
        .run_as(settings, "SELECT id FROM notes ORDER BY id", &[])
        .unwrap();
    rows.rows.into_iter().map(|mut r| r.remove(0)).collect()
}

fn text(s: &str) -> Value {
    Value::Text(s.to_owned())
}

#[test]
fn policies_see_the_user_of_the_query() {
    let Some(db) = pool("policies", NOTES) else {
        return;
    };
    assert_eq!(ids(&db, &as_user("ann")), [text("a1"), text("a2")]);
    assert_eq!(ids(&db, &as_user("bob")), [text("a2"), text("b1")]);
    // Without a user, only what is public; the setting of the last query is gone.
    assert_eq!(ids(&db, &[]), [text("a2")]);
    // Bob can't write a note of Ann's: the insert policy refuses it, and nothing is written.
    let e = db
        .run_as(
            &as_user("bob"),
            "INSERT INTO notes VALUES ('x', 'ann', false)",
            &[],
        )
        .unwrap_err();
    assert_eq!(e.code, "42501");
    assert_eq!(
        db.run_as(
            &as_user("bob"),
            "INSERT INTO notes VALUES ('b2', 'bob', false)",
            &[]
        )
        .unwrap()
        .affected,
        1
    );
    // There is no update policy: no row can be changed.
    let rows = db
        .run_as(&as_user("ann"), "UPDATE notes SET public = true", &[])
        .unwrap();
    assert_eq!(rows.affected, 0);
}

#[test]
fn a_failed_query_as_a_user_leaves_the_connection_good() {
    let Some(db) = pool("rollback", NOTES) else {
        return;
    };
    assert!(db.run_as(&as_user("ann"), "SELEC 1", &[]).is_err());
    assert_eq!(ids(&db, &[]), [text("a2")]);
    assert_eq!(ids(&db, &as_user("bob")), [text("a2"), text("b1")]);
}

#[test]
fn only_punk_settings_can_be_given() {
    let Some(db) = pool("settings", NOTES) else {
        return;
    };
    let e = db
        .run_as(
            &[("role".to_owned(), "postgres".to_owned())],
            "SELECT 1 AS one",
            &[],
        )
        .unwrap_err();
    assert_eq!(e.code, "42602");
}

#[test]
fn a_role_that_skips_row_level_security_is_refused() {
    let Ok(url) = std::env::var("PUNK_TEST_POSTGRES") else {
        return;
    };
    // The test database's own role is a superuser.
    let db = Postgres::new(&url, 1).unwrap();
    let e = db.run("SELECT 1 AS one", &[]).unwrap_err();
    assert_eq!(e.code, "42501");
    assert!(e.message.contains("row-level security"), "{}", e.message);
    assert_eq!(db.state.lock().unwrap().open, 0);
}
