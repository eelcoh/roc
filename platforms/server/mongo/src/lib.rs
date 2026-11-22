//! A Mongo database for punkroc's server platform: the official Mongo driver as a
//! [`punk_server::Documents`]. The wiring of an app makes one, says which collections the app
//! may read and which it may change, and hands it to the app with
//! [`punk_server::App::with_documents`]; the app never sees the connection string.
//!
//! - The app's operations come as a [`Filter`], [`Change`]s and plain values, and this crate
//!   writes Mongo's operators for them (`$eq`, `$in`, `$set`, `$inc`, ...). A value is always
//!   data: punk-server refuses a key that starts with `$` anywhere in a value, so a value from a
//!   request can't become an operator, and no operation runs JavaScript (`$where`).
//! - Only the collections the wiring allows ([`Mongo::allow`]): any other is error "13"
//!   (Unauthorized), also when the database user could use it.
//! - The driver keeps a pool of connections and reconnects by itself; an operation that finds
//!   no server within 5 seconds (unless the connection string says otherwise) is error "6"
//!   (HostUnreachable).
//! - Errors carry Mongo's error code as text: "11000" for a duplicate key.

use std::collections::HashMap;
use std::time::Duration;

use ambit_lockdown::{Grant, Grants};
pub use mongodb::bson;
use mongodb::bson::{Bson, Document, doc};
use mongodb::error::{ErrorKind, WriteFailure};
use mongodb::options::{ClientOptions, ServerAddress};
use mongodb::sync::{Client, Database};
use punk_server::{Change, Comparison, DbError, Doc, Documents, Filter, Order, Search};

/// What the app may do with a collection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Access {
    /// `Mongo.all!`, `Mongo.first!` and `Mongo.count!`.
    Read,
    /// Those, and `Mongo.insert!`, `Mongo.insertIfNew!`, `Mongo.update!` and `Mongo.delete!`.
    ReadWrite,
}

/// One Mongo database, and the collections of it the app may use.
pub struct Mongo {
    database: Database,
    allowed: HashMap<String, Access>,
    hosts: Vec<ServerAddress>,
    srv: bool,
}

impl Mongo {
    /// Connects to the database `database` of the server(s) in `uri`
    /// (`mongodb://app:password@localhost:27017`). The app may use no collection until
    /// [`Mongo::allow`] says so. Connecting doesn't wait for the server: an operation does.
    pub fn connect(uri: &str, database: &str) -> Result<Self, DbError> {
        let mut options = ClientOptions::parse(uri)
            .run()
            .map_err(|e| DbError::new("2", format!("bad connection string: {e}")))?;
        options
            .server_selection_timeout
            .get_or_insert(Duration::from_secs(5));
        options
            .connect_timeout
            .get_or_insert(Duration::from_secs(5));
        options.app_name.get_or_insert_with(|| "punk".to_owned());
        let srv = uri.starts_with("mongodb+srv://");
        let hosts = options.hosts.clone();
        let client = Client::with_options(options).map_err(mongo_error)?;
        Ok(Self {
            database: client.database(database),
            allowed: HashMap::new(),
            hosts,
            srv,
        })
    }

    /// Lets the app use the collection, to read or also to change.
    pub fn allow(mut self, collection: &str, access: Access) -> Self {
        self.allowed.insert(collection.to_owned(), access);
        self
    }

    /// The collection as the driver gives it, for the wiring and for tests (indexes, setup,
    /// checks): not limited to what the app may do.
    pub fn collection(&self, name: &str) -> mongodb::sync::Collection<Document> {
        self.database.collection(name)
    }

    /// The driver's database, for the wiring and for tests.
    pub fn database(&self) -> &Database {
        &self.database
    }

    /// Makes sure the collection has a unique index on the field, for the wiring.
    pub fn unique_index(&self, collection: &str, field: &str) -> Result<(), DbError> {
        let index = mongodb::IndexModel::builder()
            .keys(doc! { field: 1 })
            .options(
                mongodb::options::IndexOptions::builder()
                    .unique(true)
                    .build(),
            )
            .build();
        self.collection(collection)
            .create_index(index)
            .run()
            .map(|_| ())
            .map_err(mongo_error)
    }

    fn may(
        &self,
        collection: &str,
        write: bool,
    ) -> Result<mongodb::sync::Collection<Document>, DbError> {
        match self.allowed.get(collection) {
            Some(Access::ReadWrite) => {}
            Some(Access::Read) if !write => {}
            Some(Access::Read) => {
                return Err(DbError::new(
                    "13",
                    format!("the app may read the collection {collection:?}, not change it"),
                ));
            }
            None => {
                return Err(DbError::new(
                    "13",
                    format!("the app may not use the collection {collection:?}"),
                ));
            }
        }
        Ok(self.collection(collection))
    }
}

impl Documents for Mongo {
    fn find(&self, collection: &str, search: &Search) -> Result<Vec<Doc>, DbError> {
        let coll = self.may(collection, false)?;
        let mut find = coll.find(filter_doc(&search.filter)?).skip(search.skip);
        if !search.sort.is_empty() {
            find = find.sort(sort_doc(&search.sort));
        }
        if let Some(limit) = search.limit {
            find = find.limit(i64::try_from(limit).unwrap_or(i64::MAX));
        }
        let cursor = find.run().map_err(mongo_error)?;
        let mut found = Vec::new();
        for document in cursor {
            found.push(from_document(document.map_err(mongo_error)?));
        }
        Ok(found)
    }

    fn count(&self, collection: &str, search: &Search) -> Result<u64, DbError> {
        let coll = self.may(collection, false)?;
        let mut count = coll.count_documents(filter_doc(&search.filter)?);
        if search.skip > 0 {
            count = count.skip(search.skip);
        }
        if let Some(limit) = search.limit {
            count = count.limit(limit);
        }
        count.run().map_err(mongo_error)
    }

    fn insert(&self, collection: &str, document: &Doc) -> Result<(), DbError> {
        let coll = self.may(collection, true)?;
        let Bson::Document(document) = to_bson(document)? else {
            return Err(DbError::new("2", "a document is an object"));
        };
        coll.insert_one(document)
            .run()
            .map(|_| ())
            .map_err(mongo_error)
    }

    fn update(
        &self,
        collection: &str,
        filter: &Filter,
        changes: &[Change],
    ) -> Result<u64, DbError> {
        let coll = self.may(collection, true)?;
        let filter = filter_doc(filter)?;
        if changes.is_empty() {
            return coll.count_documents(filter).run().map_err(mongo_error);
        }
        let mut set = Document::new();
        let mut unset = Document::new();
        let mut inc = Document::new();
        for change in changes {
            match change {
                Change::Set(field, value) => {
                    set.insert(field, to_bson(value)?);
                }
                Change::Unset(field) => {
                    unset.insert(field, "");
                }
                Change::Increment(field, n) => {
                    inc.insert(field, *n);
                }
            }
        }
        let mut update = Document::new();
        for (op, part) in [("$set", set), ("$unset", unset), ("$inc", inc)] {
            if !part.is_empty() {
                update.insert(op, part);
            }
        }
        coll.update_many(filter, update)
            .run()
            .map(|result| result.matched_count)
            .map_err(mongo_error)
    }

    fn delete(&self, collection: &str, filter: &Filter) -> Result<u64, DbError> {
        let coll = self.may(collection, true)?;
        coll.delete_many(filter_doc(filter)?)
            .run()
            .map(|result| result.deleted_count)
            .map_err(mongo_error)
    }
}

/// What the driver reaches: the port of each server in the connection string, and the
/// resolver when one is a name. With `mongodb+srv://` the servers come from DNS, on Mongo's
/// default port.
impl Grants for Mongo {
    fn grants(&self) -> Vec<Grant> {
        let mut grants = Vec::new();
        let mut add = |grant: Grant| {
            if !grants.contains(&grant) {
                grants.push(grant);
            }
        };
        if self.srv {
            add(Grant::Resolve);
            add(Grant::Connect(27017));
        }
        for host in &self.hosts {
            if let ServerAddress::Tcp { host, port } = host {
                add(Grant::Connect(port.unwrap_or(27017)));
                if host.parse::<std::net::IpAddr>().is_err() {
                    add(Grant::Resolve);
                }
            }
        }
        grants
    }
}

// --- Filters and values as BSON -----------------------------------------------------------

/// The filter as Mongo's query document. The operators are written here, never taken from
/// the app.
pub fn filter_doc(filter: &Filter) -> Result<Document, DbError> {
    Ok(match filter {
        Filter::All(filters) if filters.is_empty() => Document::new(),
        Filter::All(filters) => doc! { "$and": filter_list(filters)? },
        // No document has an `_id` in an empty list.
        Filter::Any(filters) if filters.is_empty() => doc! { "_id": { "$in": [] } },
        Filter::Any(filters) => doc! { "$or": filter_list(filters)? },
        Filter::Compare { field, op, value } => {
            let op = match op {
                Comparison::Equals => "$eq",
                Comparison::NotEquals => "$ne",
                Comparison::LessThan => "$lt",
                Comparison::AtMost => "$lte",
                Comparison::GreaterThan => "$gt",
                Comparison::AtLeast => "$gte",
                Comparison::OneOf => "$in",
            };
            let mut compare = Document::new();
            compare.insert(op, to_bson(value)?);
            let mut out = Document::new();
            out.insert(field, compare);
            out
        }
        Filter::Exists { field, exists } => {
            let mut out = Document::new();
            out.insert(field, doc! { "$exists": *exists });
            out
        }
    })
}

fn filter_list(filters: &[Filter]) -> Result<Vec<Document>, DbError> {
    filters.iter().map(filter_doc).collect()
}

fn sort_doc(sort: &[(String, Order)]) -> Document {
    let mut out = Document::new();
    for (field, order) in sort {
        out.insert(
            field,
            match order {
                Order::Ascending => 1,
                Order::Descending => -1,
            },
        );
    }
    out
}

/// A value of the app as BSON. An int is an int64, a time a date.
pub fn to_bson(value: &Doc) -> Result<Bson, DbError> {
    Ok(match value {
        Doc::Null => Bson::Null,
        Doc::Text(s) => Bson::String(s.clone()),
        Doc::Int(n) => Bson::Int64(*n),
        Doc::Float(x) => Bson::Double(*x),
        Doc::Bool(b) => Bson::Boolean(*b),
        Doc::List(items) => Bson::Array(items.iter().map(to_bson).collect::<Result<_, _>>()?),
        Doc::Object(fields) => {
            let mut out = Document::new();
            for (key, item) in fields {
                out.insert(key, to_bson(item)?);
            }
            Bson::Document(out)
        }
        Doc::ObjectId(hex) => Bson::ObjectId(
            bson::oid::ObjectId::parse_str(hex)
                .map_err(|_| DbError::new("2", format!("{hex:?} is not an ObjectId")))?,
        ),
        Doc::Time(ms) => Bson::DateTime(bson::DateTime::from_millis(*ms)),
        Doc::Other(what) => {
            return Err(DbError::new("2", format!("can't store {what}")));
        }
    })
}

/// A document Mongo gave, as a value the app's decoders read.
pub fn from_document(document: Document) -> Doc {
    Doc::Object(
        document
            .into_iter()
            .map(|(key, value)| (key, from_bson(value)))
            .collect(),
    )
}

fn from_bson(value: Bson) -> Doc {
    match value {
        Bson::Null | Bson::Undefined => Doc::Null,
        Bson::String(s) => Doc::Text(s),
        Bson::Int32(n) => Doc::Int(n.into()),
        Bson::Int64(n) => Doc::Int(n),
        Bson::Double(x) => Doc::Float(x),
        Bson::Boolean(b) => Doc::Bool(b),
        Bson::Array(items) => Doc::List(items.into_iter().map(from_bson).collect()),
        Bson::Document(document) => from_document(document),
        Bson::ObjectId(id) => Doc::ObjectId(id.to_hex()),
        Bson::DateTime(at) => Doc::Time(at.timestamp_millis()),
        other => Doc::Other(format!("a BSON {:?}", other.element_type())),
    }
}

/// The driver's error as Mongo's error code and message.
fn mongo_error(e: mongodb::error::Error) -> DbError {
    match e.kind.as_ref() {
        ErrorKind::Command(c) => DbError::new(c.code.to_string(), c.message.clone()),
        ErrorKind::Write(WriteFailure::WriteError(w)) => {
            DbError::new(w.code.to_string(), w.message.clone())
        }
        ErrorKind::Write(WriteFailure::WriteConcernError(w)) => {
            DbError::new(w.code.to_string(), w.message.clone())
        }
        ErrorKind::ServerSelection { .. }
        | ErrorKind::Io(_)
        | ErrorKind::ConnectionPoolCleared { .. }
        | ErrorKind::DnsResolve { .. } => DbError::new("6", e.to_string()),
        ErrorKind::Authentication { .. } => DbError::new("18", e.to_string()),
        _ => DbError::new("1", e.to_string()),
    }
}

/// A Mongo database for tests: `PUNK_TEST_MONGO` (a connection string), or none.
pub mod testing {
    use super::*;

    /// A fresh, empty database `name` of the test server, where the app may use these
    /// collections. `None` when there is no test server, unless `PUNK_REQUIRE_MONGO` is set (as
    /// in CI): then it panics.
    pub fn database(name: &str, collections: &[(&str, Access)]) -> Option<Mongo> {
        let Ok(uri) = std::env::var("PUNK_TEST_MONGO") else {
            assert!(
                std::env::var_os("PUNK_REQUIRE_MONGO").is_none(),
                "PUNK_REQUIRE_MONGO is set, but PUNK_TEST_MONGO isn't"
            );
            eprintln!("no PUNK_TEST_MONGO: skipping {name}");
            return None;
        };
        let mut mongo = Mongo::connect(&uri, name).unwrap();
        mongo.database.drop().run().unwrap();
        for (collection, access) in collections {
            mongo = mongo.allow(collection, *access);
        }
        Some(mongo)
    }
}

#[cfg(test)]
mod tests;
