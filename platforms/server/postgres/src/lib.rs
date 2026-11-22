//! A Postgres database for punkroc's server platform: a pool of connections that is a
//! [`punk_server::Database`]. The wiring of an app makes one and hands it to the app with
//! [`punk_server::App::with_database`]; the app never sees the connection string.
//!
//! - Each query takes a connection from the pool (it opens one when none is free and there are
//!   fewer than `max`), runs, and gives it back. A broken connection is dropped, and the next
//!   query opens a new one, so the app recovers by itself when the database comes back.
//! - The SQL is prepared once per connection and kept, so each query is one round trip. The SQL
//!   comes from the program (punk rule P301), so there are only as many statements as the
//!   program has.
//! - Each parameter gets the type the statement wants (an `Int` for an `int4` column is sent as
//!   an `int4`); each column is read as bool, int, float or text. Any other type is an error that
//!   says how to convert it in the SQL.
//! - Row-level security holds: the pool refuses a role that skips it (a superuser, or a role
//!   with `BYPASSRLS`), so the app runs as a role that the tables' policies apply to. The tables
//!   and their policies are made by [`Owner`], with a role of its own.
//! - `Db.runAs! user query` runs the query in a transaction whose settings (`punk.user_id`) say
//!   who the user is; the policies read them. They end with the transaction, so the next query
//!   on the connection is nobody's again.
//! - [`Owner::migrate`] applies the versions of a `schema.sql` that the database doesn't have
//!   yet, and refuses one that changed after it was applied.
//! - Without TLS for now: for a database on the same machine or a private network.

use std::collections::HashMap;
use std::error::Error;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

use ambit_lockdown::{Grant, Grants};
use bytes::BytesMut;
use postgres::config::Host;
use postgres::fallible_iterator::FallibleIterator;
use postgres::types::{IsNull, ToSql, Type, to_sql_checked};
use postgres::{Client, NoTls, Statement};

/// A connection string, read with `str::parse` and changed with its setters.
pub use postgres::Config;
use punk_server::{Database, DbError, Rows, Value};

/// How many prepared statements a connection keeps; past that it starts again.
const STATEMENTS: usize = 256;

/// A pool of connections to one Postgres database.
pub struct Postgres {
    config: postgres::Config,
    max: usize,
    wait: Duration,
    state: Mutex<State>,
    freed: Condvar,
}

struct State {
    idle: Vec<Connection>,
    open: usize,
}

struct Connection {
    client: Client,
    statements: HashMap<String, Statement>,
}

impl Postgres {
    /// A pool for the database at `url` (`postgres://user:password@localhost/db`, or
    /// `host=localhost user=app dbname=links`), with at most `max` connections. It connects when
    /// the first query comes, so it can be made while the database is still starting.
    pub fn new(url: &str, max: usize) -> Result<Self, DbError> {
        let config: postgres::Config = url.parse().map_err(|e: postgres::Error| {
            DbError::new("08000", format!("bad connection string: {e}"))
        })?;
        Ok(Self::from_config(config, max))
    }

    /// The same, for a connection string that [`postgres::Config`] already holds (to change its
    /// user, for instance).
    pub fn from_config(mut config: postgres::Config, max: usize) -> Self {
        if config.get_connect_timeout().is_none() {
            config.connect_timeout(Duration::from_secs(5));
        }
        Self {
            config,
            max: max.max(1),
            wait: Duration::from_secs(5),
            state: Mutex::new(State {
                idle: Vec::new(),
                open: 0,
            }),
            freed: Condvar::new(),
        }
    }

    /// Runs SQL that isn't the app's, as the app's role: setting up a test, for instance.
    /// Several statements, separated by `;`, without parameters.
    pub fn batch(&self, sql: &str) -> Result<(), DbError> {
        let mut conn = self.take()?;
        let result = conn.client.batch_execute(sql).map_err(db_error);
        self.give_back(conn);
        result
    }

    fn take(&self) -> Result<Connection, DbError> {
        let deadline = Instant::now() + self.wait;
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        loop {
            if let Some(conn) = state.idle.pop() {
                return Ok(conn);
            }
            if state.open < self.max {
                state.open += 1;
                drop(state);
                return match self
                    .config
                    .connect(NoTls)
                    .map_err(db_error)
                    .and_then(checked)
                {
                    Ok(client) => Ok(Connection {
                        client,
                        statements: HashMap::new(),
                    }),
                    Err(e) => {
                        self.closed();
                        Err(e)
                    }
                };
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(DbError::new(
                    "53300",
                    format!("all {} connections to the database are busy", self.max),
                ));
            }
            state = self
                .freed
                .wait_timeout(state, left)
                .unwrap_or_else(|e| e.into_inner())
                .0;
        }
    }

    fn give_back(&self, conn: Connection) {
        if conn.client.is_closed() {
            drop(conn);
            self.closed();
            return;
        }
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.idle.push(conn);
        drop(state);
        self.freed.notify_one();
    }

    /// A connection went away: there is room for a new one.
    fn closed(&self) {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        state.open -= 1;
        drop(state);
        self.freed.notify_one();
    }
}

impl Database for Postgres {
    fn run(&self, sql: &str, params: &[Value]) -> Result<Rows, DbError> {
        self.run_as(&[], sql, params)
    }

    fn run_as(
        &self,
        settings: &[(String, String)],
        sql: &str,
        params: &[Value],
    ) -> Result<Rows, DbError> {
        let mut conn = self.take()?;
        let result = if settings.is_empty() {
            run(&mut conn, sql, params)
        } else {
            run_with_settings(&mut conn, settings, sql, params)
        };
        self.give_back(conn);
        result
    }
}

/// The query in a transaction with these settings, which end with it.
fn run_with_settings(
    conn: &mut Connection,
    settings: &[(String, String)],
    sql: &str,
    params: &[Value],
) -> Result<Rows, DbError> {
    for (name, _) in settings {
        if !name.starts_with("punk.") {
            return Err(DbError::new(
                "42602",
                format!("the setting {name:?} isn't one of punk's"),
            ));
        }
    }
    conn.client.batch_execute("BEGIN").map_err(db_error)?;
    let result = (|| {
        for (name, value) in settings {
            conn.client
                .execute(
                    "SELECT set_config($1, $2, true)",
                    &[&name.as_str(), &value.as_str()],
                )
                .map_err(db_error)?;
        }
        let rows = run(conn, sql, params)?;
        conn.client.batch_execute("COMMIT").map_err(db_error)?;
        Ok(rows)
    })();
    if result.is_err() && !conn.client.is_closed() {
        // A failed ROLLBACK leaves the connection broken: it is dropped when given back.
        let _ = conn.client.batch_execute("ROLLBACK");
    }
    result
}

/// A new connection, if its role keeps to row-level security: a superuser and a role with
/// `BYPASSRLS` see every row, whatever the policies say.
fn checked(mut client: Client) -> Result<Client, DbError> {
    let row = client
        .query_one(
            "SELECT rolname::text, rolsuper OR rolbypassrls FROM pg_roles WHERE rolname = current_user",
            &[],
        )
        .map_err(db_error)?;
    let role: String = row.get(0);
    let bypasses: bool = row.get(1);
    if bypasses {
        return Err(DbError::new(
            "42501",
            format!(
                "the app connects as the role {role:?}, which skips row-level security (it is a superuser or has BYPASSRLS); give the app a role of its own, and make the tables with `Owner`"
            ),
        ));
    }
    Ok(client)
}

/// The owner of the app's tables: a connection with a role that may make tables and policies,
/// for the wiring, not for the app. It applies the schema punk made (`punk check --schema`) and
/// lets the app's role use the tables; the policies say which rows.
pub struct Owner {
    client: Mutex<Client>,
}

impl Owner {
    pub fn connect(url: &str) -> Result<Self, DbError> {
        let mut config: postgres::Config = url.parse().map_err(|e: postgres::Error| {
            DbError::new("08000", format!("bad connection string: {e}"))
        })?;
        if config.get_connect_timeout().is_none() {
            config.connect_timeout(Duration::from_secs(5));
        }
        let client = config.connect(NoTls).map_err(db_error)?;
        Ok(Self {
            client: Mutex::new(client),
        })
    }

    /// Runs SQL without parameters: the schema, or anything else the wiring sets up.
    pub fn batch(&self, sql: &str) -> Result<(), DbError> {
        let mut client = self.client.lock().unwrap_or_else(|e| e.into_inner());
        client.batch_execute(sql).map_err(db_error)
    }

    /// Brings the database up to the last version of `schema` (the `schema.sql` that
    /// `punk check --schema` makes): applies each version the database doesn't have yet, in
    /// order, each in a transaction of its own, and records it in the table `punk_schema`. A
    /// version that was applied before but reads differently now is an error: the database
    /// would not hold what the program declares. Gives the versions it applied.
    pub fn migrate(&self, schema: &str) -> Result<Vec<u32>, DbError> {
        let versions = versions(schema)?;
        let mut client = self.client.lock().unwrap_or_else(|e| e.into_inner());
        client
            .batch_execute(
                "CREATE TABLE IF NOT EXISTS punk_schema (
                     version integer PRIMARY KEY,
                     sha256 text NOT NULL,
                     applied_at timestamptz NOT NULL DEFAULT now()
                 )",
            )
            .map_err(db_error)?;
        let mut applied = Vec::new();
        for (version, sql) in versions {
            let mut tx = client.transaction().map_err(db_error)?;
            // One wiring at a time: two servers starting at once apply a version once.
            tx.batch_execute("SELECT pg_advisory_xact_lock(707275)")
                .map_err(db_error)?;
            let row = tx
                .query_opt(
                    "SELECT sha256 = encode(sha256(convert_to($2, 'UTF8')), 'hex') FROM punk_schema WHERE version = $1",
                    &[&(version as i32), &sql],
                )
                .map_err(db_error)?;
            match row {
                Some(row) if row.get::<_, bool>(0) => continue,
                Some(_) => {
                    return Err(DbError::new(
                        "P0405",
                        format!(
                            "version {version} of the schema was applied to this database, but schema.sql has another version {version} now; a version can't change once it has been applied: undo the change, and change the tables in the program instead"
                        ),
                    ));
                }
                None => {}
            }
            tx.batch_execute(sql).map_err(|e| {
                let e = db_error(e);
                DbError::new(
                    e.code,
                    format!("version {version} of the schema: {}", e.message),
                )
            })?;
            tx.execute(
                "INSERT INTO punk_schema (version, sha256) VALUES ($1, encode(sha256(convert_to($2, 'UTF8')), 'hex'))",
                &[&(version as i32), &sql],
            )
            .map_err(db_error)?;
            tx.commit().map_err(db_error)?;
            applied.push(version);
        }
        Ok(applied)
    }

    /// Lets `role` read and change the tables of the current schema, now and the ones made later,
    /// as far as their policies allow.
    pub fn grant(&self, role: &str) -> Result<(), DbError> {
        let role = quote_ident(role);
        let schema = self.schema()?;
        self.batch(&format!(
            "GRANT USAGE ON SCHEMA {schema} TO {role};
             GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {schema} TO {role};
             ALTER DEFAULT PRIVILEGES IN SCHEMA {schema} GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {role};"
        ))
    }

    fn schema(&self) -> Result<String, DbError> {
        let mut client = self.client.lock().unwrap_or_else(|e| e.into_inner());
        let row = client
            .query_one("SELECT current_schema()::text", &[])
            .map_err(db_error)?;
        Ok(quote_ident(&row.get::<_, String>(0)))
    }
}

/// For tests against a real database: `PUNK_TEST_POSTGRES` is its connection string, as a role
/// that may make schemas and roles (CI's `postgres`).
pub mod testing {
    use super::*;

    /// The role the app connects as in tests: it keeps to row-level security.
    pub const APP_ROLE: &str = "punk_test_app";

    /// A fresh, empty schema `schema` of the test database, with its owner (who has applied
    /// `schema_sql`: migrated when it is a `schema.sql` of punk, else run as it is) and a pool for the app, as [`APP_ROLE`]. `None` when there is no test
    /// database, unless `PUNK_REQUIRE_POSTGRES` is set (as in CI): then it panics.
    pub fn database(schema: &str, schema_sql: &str) -> Option<(Owner, Postgres)> {
        let Ok(url) = std::env::var("PUNK_TEST_POSTGRES") else {
            assert!(
                std::env::var_os("PUNK_REQUIRE_POSTGRES").is_none(),
                "PUNK_REQUIRE_POSTGRES is set, but PUNK_TEST_POSTGRES isn't"
            );
            eprintln!("no PUNK_TEST_POSTGRES: skipping {schema}");
            return None;
        };
        let setup = Owner::connect(&url).unwrap();
        setup
            .batch(&format!(
                "DROP SCHEMA IF EXISTS {schema} CASCADE; CREATE SCHEMA {schema};
                 DO $$ BEGIN
                     CREATE ROLE {APP_ROLE} LOGIN PASSWORD 'punk';
                 EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL;
                 END $$;"
            ))
            .unwrap();
        let url = with_search_path(&url, schema);
        let owner = Owner::connect(&url).unwrap();
        if schema_sql.contains("-- punk version ") {
            owner.migrate(schema_sql).unwrap();
        } else {
            owner.batch(schema_sql).unwrap();
        }
        owner.grant(APP_ROLE).unwrap();
        let mut config: Config = url.parse().unwrap();
        // Without a database name, Postgres takes the user's: keep the one of the URL.
        if config.get_dbname().is_none() {
            let dbname = config.get_user().unwrap_or("postgres").to_owned();
            config.dbname(&dbname);
        }
        config.user(APP_ROLE).password("punk");
        Some((owner, Postgres::from_config(config, 2)))
    }

    /// `url` with `schema` as its search path.
    fn with_search_path(url: &str, schema: &str) -> String {
        if url.contains("://") {
            let separator = if url.contains('?') { "&" } else { "?" };
            format!("{url}{separator}options=-c%20search_path%3D{schema}")
        } else {
            format!("{url} options='-c search_path={schema}'")
        }
    }
}

/// The versions of a `schema.sql`: each starts at a line `-- punk version N`, and they count up
/// from 1.
fn versions(schema: &str) -> Result<Vec<(u32, &str)>, DbError> {
    const MARK: &str = "-- punk version ";
    let mut starts = Vec::new();
    let mut offset = 0;
    for line in schema.split_inclusive('\n') {
        if let Some(rest) = line.strip_prefix(MARK) {
            let version: u32 = rest.trim().parse().map_err(|_| {
                DbError::new("P0405", format!("schema.sql has a broken line: {line:?}"))
            })?;
            if version as usize != starts.len() + 1 {
                return Err(DbError::new(
                    "P0405",
                    format!(
                        "schema.sql has version {version} where version {} should be",
                        starts.len() + 1
                    ),
                ));
            }
            starts.push((version, offset));
        }
        offset += line.len();
    }
    if starts.is_empty() {
        return Err(DbError::new(
            "P0405",
            "this schema has no versions: give the schema.sql that `punk check --schema` makes",
        ));
    }
    let mut out = Vec::with_capacity(starts.len());
    for (i, &(version, start)) in starts.iter().enumerate() {
        let end = starts.get(i + 1).map_or(schema.len(), |&(_, s)| s);
        // Without the blank lines between versions, which are no part of either.
        out.push((version, schema[start..end].trim_end()));
    }
    Ok(out)
}

/// `name` as an SQL identifier, in double quotes.
fn quote_ident(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

/// What the pool reaches: the port of each host in the connection string, and the resolver when
/// a host is a name.
impl Grants for Postgres {
    fn grants(&self) -> Vec<Grant> {
        let ports = self.config.get_ports();
        let mut grants = Vec::new();
        for (i, host) in self.config.get_hosts().iter().enumerate() {
            let port = ports.get(i).or(ports.first()).copied().unwrap_or(5432);
            if let Host::Tcp(name) = host {
                grants.push(Grant::Connect(port));
                if name.parse::<std::net::IpAddr>().is_err() && !grants.contains(&Grant::Resolve) {
                    grants.push(Grant::Resolve);
                }
            }
        }
        grants
    }
}

fn run(conn: &mut Connection, sql: &str, params: &[Value]) -> Result<Rows, DbError> {
    let statement = match conn.statements.get(sql) {
        Some(statement) => statement.clone(),
        None => {
            let statement = conn.client.prepare(sql).map_err(db_error)?;
            if conn.statements.len() >= STATEMENTS {
                conn.statements.clear();
            }
            conn.statements.insert(sql.to_owned(), statement.clone());
            statement
        }
    };
    check_params(&statement, params)?;
    let mut readers = Vec::with_capacity(statement.columns().len());
    for column in statement.columns() {
        readers.push(reader(column.name(), column.type_())?);
    }
    let args: Vec<Arg<'_>> = params.iter().map(Arg).collect();
    let mut iter = conn.client.query_raw(&statement, args).map_err(db_error)?;
    let mut rows = Vec::new();
    while let Some(row) = iter.next().map_err(db_error)? {
        let mut cells = Vec::with_capacity(readers.len());
        for (i, read) in readers.iter().enumerate() {
            cells.push(read(&row, i).map_err(db_error)?);
        }
        rows.push(cells);
    }
    Ok(Rows {
        columns: statement
            .columns()
            .iter()
            .map(|c| c.name().to_owned())
            .collect(),
        rows,
        affected: iter.rows_affected().unwrap_or(0),
    })
}

fn is_text(ty: &Type) -> bool {
    matches!(
        *ty,
        Type::TEXT | Type::VARCHAR | Type::BPCHAR | Type::NAME | Type::UNKNOWN
    )
}

/// Each parameter fits the type the statement wants for it, or the error says what to do.
fn check_params(statement: &Statement, params: &[Value]) -> Result<(), DbError> {
    let types = statement.params();
    if types.len() != params.len() {
        return Err(DbError::new(
            "08P01",
            format!(
                "the query has {} parameter(s), but was given {}",
                types.len(),
                params.len()
            ),
        ));
    }
    for (i, (ty, value)) in types.iter().zip(params).enumerate() {
        let fits = match value {
            Value::Null => true,
            Value::Text(_) => is_text(ty),
            Value::Int(_) => matches!(*ty, Type::INT2 | Type::INT4 | Type::INT8),
            Value::Float(_) => matches!(*ty, Type::FLOAT4 | Type::FLOAT8),
            Value::Bool(_) => *ty == Type::BOOL,
        };
        if let Value::Int(n) = value {
            let fits_width = match *ty {
                Type::INT2 => i16::try_from(*n).is_ok(),
                Type::INT4 => i32::try_from(*n).is_ok(),
                _ => true,
            };
            if !fits_width {
                return Err(DbError::new(
                    "22003",
                    format!(
                        "parameter ${} is {} in this query, and {n} doesn't fit in it",
                        i + 1,
                        ty.name()
                    ),
                ));
            }
        }
        if !fits {
            let given = match value {
                Value::Null => "NULL",
                Value::Text(_) => "text (Sql.text)",
                Value::Int(_) => "an int (Sql.int)",
                Value::Float(_) => "a float (Sql.float)",
                Value::Bool(_) => "a bool (Sql.bool)",
            };
            return Err(DbError::new(
                "42804",
                format!(
                    "parameter ${} is {} in this query, but the app gives {given}; give the type the query expects, or convert in the SQL (`${}::{}`)",
                    i + 1,
                    ty.name(),
                    i + 1,
                    ty.name()
                ),
            ));
        }
    }
    Ok(())
}

type Reader = fn(&postgres::Row, usize) -> Result<Value, postgres::Error>;

/// How to read a column of this type, or why punk can't.
fn reader(name: &str, ty: &Type) -> Result<Reader, DbError> {
    fn or_null<T>(value: Option<T>, f: impl FnOnce(T) -> Value) -> Value {
        value.map(f).unwrap_or(Value::Null)
    }
    Ok(match *ty {
        Type::BOOL => |row, i| Ok(or_null(row.try_get::<_, Option<bool>>(i)?, Value::Bool)),
        Type::INT2 => |row, i| {
            Ok(or_null(row.try_get::<_, Option<i16>>(i)?, |n| {
                Value::Int(n.into())
            }))
        },
        Type::INT4 => |row, i| {
            Ok(or_null(row.try_get::<_, Option<i32>>(i)?, |n| {
                Value::Int(n.into())
            }))
        },
        Type::INT8 => |row, i| Ok(or_null(row.try_get::<_, Option<i64>>(i)?, Value::Int)),
        Type::FLOAT4 => |row, i| {
            Ok(or_null(row.try_get::<_, Option<f32>>(i)?, |x| {
                Value::Float(x.into())
            }))
        },
        Type::FLOAT8 => |row, i| Ok(or_null(row.try_get::<_, Option<f64>>(i)?, Value::Float)),
        ref t if is_text(t) => {
            |row, i| Ok(or_null(row.try_get::<_, Option<String>>(i)?, Value::Text))
        }
        _ => {
            return Err(DbError::new(
                "0A000",
                format!(
                    "column \"{name}\" is {}; punk reads bool, int, float and text columns, so convert it in the SQL (`{name}::text`, or `extract(epoch from {name})::int8` for a time)",
                    ty.name()
                ),
            ));
        }
    })
}

/// A parameter, sent as the type the statement wants. `check_params` made sure it fits.
#[derive(Debug)]
struct Arg<'a>(&'a Value);

impl ToSql for Arg<'_> {
    fn to_sql(
        &self,
        ty: &Type,
        out: &mut BytesMut,
    ) -> Result<IsNull, Box<dyn Error + Sync + Send>> {
        match self.0 {
            Value::Null => Ok(IsNull::Yes),
            Value::Text(s) => s.as_str().to_sql(ty, out),
            Value::Int(n) => match *ty {
                Type::INT2 => i16::try_from(*n)?.to_sql(ty, out),
                Type::INT4 => i32::try_from(*n)?.to_sql(ty, out),
                _ => n.to_sql(ty, out),
            },
            Value::Float(x) => match *ty {
                Type::FLOAT4 => (*x as f32).to_sql(ty, out),
                _ => x.to_sql(ty, out),
            },
            Value::Bool(b) => b.to_sql(ty, out),
        }
    }

    fn accepts(_: &Type) -> bool {
        true
    }

    to_sql_checked!();
}

fn db_error(e: postgres::Error) -> DbError {
    match e.as_db_error() {
        Some(db) => DbError::new(db.code().code(), db.message()),
        None => DbError::new(e.code().map(|c| c.code()).unwrap_or("08000"), e.to_string()),
    }
}

#[cfg(test)]
mod tests;
