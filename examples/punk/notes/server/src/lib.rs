//! Notes per user, written in punk: `../Notes.punk` is the app, `../schema.sql` its table with
//! its row-level security policies. Who the user is comes from the header `x-user`, which a
//! proxy in front of the app sets once it has signed the user in.
//!
//! - `POST /notes` with the text as body: a new note of the user, `201` with its id.
//! - `GET /notes`: the notes the user may read, one per line: `id public|private text`.
//! - `POST /notes/<id>/publish`: makes the user's note public; `404` for another's.
//! - `DELETE /notes/<id>`: removes the user's note; `404` for another's.

use ambit_caps::{Clock, Random};
use ambit_server::Handler;
use punk_server::Database;

/// The table the app needs, with its policies; the wiring applies it as the table's owner.
pub const SCHEMA: &str = include_str!("../../schema.sql");

/// The app's capabilities: randomness for the ids, and a database. The clock is not used.
pub fn init(clock: impl Clock, random: impl Random, database: impl Database) -> impl Handler {
    punk_server::App::new(clock, random, NoKv, "{}".to_owned()).with_database(database)
}

/// The key-value store of an app that has a database instead.
struct NoKv;

impl ambit_caps::Kv for NoKv {
    fn get(&self, _: &[u8]) -> Result<Option<Vec<u8>>, ambit_caps::KvError> {
        Err(no_kv())
    }
    fn put(&self, _: &[u8], _: &[u8]) -> Result<(), ambit_caps::KvError> {
        Err(no_kv())
    }
    fn delete(&self, _: &[u8]) -> Result<(), ambit_caps::KvError> {
        Err(no_kv())
    }
    fn scan(&self, _: &[u8]) -> Result<Vec<ambit_caps::Entry>, ambit_caps::KvError> {
        Err(no_kv())
    }
}

fn no_kv() -> ambit_caps::KvError {
    ambit_caps::KvError::new("this app has no key-value store")
}
