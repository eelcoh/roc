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
        let mut config: postgres::Config = url.parse().map_err(|e: postgres::Error| {
            DbError::new("08000", format!("bad connection string: {e}"))
        })?;
        if config.get_connect_timeout().is_none() {
            config.connect_timeout(Duration::from_secs(5));
        }
        Ok(Self {
            config,
            max: max.max(1),
            wait: Duration::from_secs(5),
            state: Mutex::new(State {
                idle: Vec::new(),
                open: 0,
            }),
            freed: Condvar::new(),
        })
    }

    /// Runs SQL that isn't the app's: the wiring's schema, for instance. Several statements,
    /// separated by `;`, without parameters.
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
                return match self.config.connect(NoTls) {
                    Ok(client) => Ok(Connection {
                        client,
                        statements: HashMap::new(),
                    }),
                    Err(e) => {
                        self.closed();
                        Err(db_error(e))
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
        let mut conn = self.take()?;
        let result = run(&mut conn, sql, params);
        self.give_back(conn);
        result
    }
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
