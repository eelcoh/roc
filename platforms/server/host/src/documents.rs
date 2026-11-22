//! The document database capability: what `Mongo.all!`, `Mongo.insert!`, ... of
//! `platforms/server/Mongo.roc` reach. The wiring hands the app a [`Documents`] with
//! [`App::with_documents`](crate::App::with_documents); an app without one gets an error for
//! every operation. The real one is in the crate `punk-server-mongo`.
//!
//! The app never writes a query in Mongo's own language. It hands over a [`Filter`] and
//! [`Change`]s made by `Filter.roc` and `Update.roc`, and the store writes the operators
//! (`$eq`, `$set`, ...) for them. A value is always data: a key that starts with `$` is refused
//! wherever it is, so a value from a request can't become an operator, and there is no `$where`.

use crate::DbError;

/// A value of a document.
#[derive(Debug, Clone, PartialEq)]
pub enum Doc {
    Null,
    Text(String),
    Int(i64),
    Float(f64),
    Bool(bool),
    List(Vec<Doc>),
    /// The keys and their values, in order.
    Object(Vec<(String, Doc)>),
    /// Mongo's ObjectId, as 24 lowercase hexadecimal digits.
    ObjectId(String),
    /// A date, in milliseconds since 1970.
    Time(i64),
    /// A value of a type punk doesn't read (a binary, a decimal, a regex, ...), described. The
    /// app can't send one.
    Other(String),
}

/// Which documents an operation is about.
#[derive(Debug, Clone, PartialEq)]
pub enum Filter {
    /// All of these hold (none: every document).
    All(Vec<Filter>),
    /// At least one of these holds (none: no document).
    Any(Vec<Filter>),
    /// The field compared with the value.
    Compare {
        field: String,
        op: Comparison,
        value: Doc,
    },
    /// The document has the field (`true`), or doesn't.
    Exists { field: String, exists: bool },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Comparison {
    Equals,
    NotEquals,
    LessThan,
    AtMost,
    GreaterThan,
    AtLeast,
    /// The value is a list; the field has one of its values.
    OneOf,
}

/// One change of `Mongo.update!`.
#[derive(Debug, Clone, PartialEq)]
pub enum Change {
    Set(String, Doc),
    Unset(String),
    Increment(String, i64),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Order {
    Ascending,
    Descending,
}

/// A search: the filter, the order (the first field decides first), how many documents to
/// leave out and at most how many to give.
#[derive(Debug, Clone, PartialEq)]
pub struct Search {
    pub filter: Filter,
    pub sort: Vec<(String, Order)>,
    pub skip: u64,
    pub limit: Option<u64>,
}

/// A document database the app may use. One app, one database: which one, and which of its
/// collections the app may read or change, is up to the wiring. Errors carry Mongo's error code
/// as text ("11000" for a duplicate key).
pub trait Documents: Send + Sync + 'static {
    fn find(&self, collection: &str, search: &Search) -> Result<Vec<Doc>, DbError>;
    fn count(&self, collection: &str, search: &Search) -> Result<u64, DbError>;
    /// Adds an object. An `_id` that is taken is error "11000".
    fn insert(&self, collection: &str, document: &Doc) -> Result<(), DbError>;
    /// Changes the documents the filter holds for; gives how many it matched.
    fn update(&self, collection: &str, filter: &Filter, changes: &[Change])
    -> Result<u64, DbError>;
    /// Removes the documents the filter holds for; gives how many.
    fn delete(&self, collection: &str, filter: &Filter) -> Result<u64, DbError>;
}

impl<T: Documents + ?Sized> Documents for std::sync::Arc<T> {
    fn find(&self, collection: &str, search: &Search) -> Result<Vec<Doc>, DbError> {
        (**self).find(collection, search)
    }
    fn count(&self, collection: &str, search: &Search) -> Result<u64, DbError> {
        (**self).count(collection, search)
    }
    fn insert(&self, collection: &str, document: &Doc) -> Result<(), DbError> {
        (**self).insert(collection, document)
    }
    fn update(
        &self,
        collection: &str,
        filter: &Filter,
        changes: &[Change],
    ) -> Result<u64, DbError> {
        (**self).update(collection, filter, changes)
    }
    fn delete(&self, collection: &str, filter: &Filter) -> Result<u64, DbError> {
        (**self).delete(collection, filter)
    }
}

/// The document database of an app the wiring gave none: every operation fails.
pub(crate) struct NoDocuments;

fn no_documents() -> DbError {
    DbError::new("6", "this app was given no document database")
}

impl Documents for NoDocuments {
    fn find(&self, _: &str, _: &Search) -> Result<Vec<Doc>, DbError> {
        Err(no_documents())
    }
    fn count(&self, _: &str, _: &Search) -> Result<u64, DbError> {
        Err(no_documents())
    }
    fn insert(&self, _: &str, _: &Doc) -> Result<(), DbError> {
        Err(no_documents())
    }
    fn update(&self, _: &str, _: &Filter, _: &[Change]) -> Result<u64, DbError> {
        Err(no_documents())
    }
    fn delete(&self, _: &str, _: &Filter) -> Result<u64, DbError> {
        Err(no_documents())
    }
}

// --- Checks ---------------------------------------------------------------------------------

/// Error "2" (BadValue) of Mongo.
fn bad(message: impl Into<String>) -> DbError {
    DbError::new("2", message)
}

/// A field name of a filter, a change or an order: one or more keys joined by dots
/// (`address.city`), none empty, none starting with `$`. punk only takes field names written in
/// the program (rule P302); this is the host's own check.
pub fn check_field(field: &str) -> Result<(), DbError> {
    if field.is_empty()
        || field
            .split('.')
            .any(|key| key.is_empty() || key.starts_with('$'))
        || field.contains('\0')
    {
        return Err(bad(format!("{field:?} is not a field name")));
    }
    Ok(())
}

/// A key of an object: not starting with `$` (Mongo would read it as an operator), no NUL.
pub fn check_key(key: &str) -> Result<(), DbError> {
    if key.starts_with('$') || key.contains('\0') {
        return Err(bad(format!(
            "the key {key:?} can't be stored: a key can't start with '$'"
        )));
    }
    Ok(())
}

/// A collection name: not empty, no `$` or NUL, not one of Mongo's own (`system.`).
pub fn check_collection(name: &str) -> Result<(), DbError> {
    if name.is_empty() || name.contains('$') || name.contains('\0') || name.starts_with("system.") {
        return Err(DbError::new(
            "73",
            format!("{name:?} is not a collection name"),
        ));
    }
    Ok(())
}

// --- Through the C ABI ----------------------------------------------------------------------

/// The kinds of `Bson.Node`.
pub(crate) mod kind {
    pub const NULL: u8 = 0;
    pub const TEXT: u8 = 1;
    pub const INT: u8 = 2;
    pub const FLOAT: u8 = 3;
    pub const BOOL: u8 = 4;
    pub const LIST: u8 = 5;
    pub const OBJECT: u8 = 6;
    pub const OBJECT_ID: u8 = 7;
    pub const TIME: u8 = 8;
    pub const OTHER: u8 = 9;
    pub const ALL: u8 = 20;
    pub const ANY: u8 = 21;
    pub const COMPARE: u8 = 22;
    pub const EXISTS: u8 = 23;
    pub const SET: u8 = 30;
    pub const UNSET: u8 = 31;
    pub const INCREMENT: u8 = 32;
    pub const ASCENDING: u8 = 40;
    pub const DESCENDING: u8 = 41;
}

/// A `Bson.Node` as plain Rust: its kind, the key it has in an object, how many nodes after it
/// are inside it, and its text.
#[derive(Debug, Clone, PartialEq)]
pub struct Node {
    pub kind: u8,
    pub name: String,
    pub size: u64,
    pub text: String,
}

impl Node {
    fn leaf(kind: u8, text: impl Into<String>) -> Self {
        Self {
            kind,
            name: String::new(),
            size: 0,
            text: text.into(),
        }
    }
}

/// Reads the nodes one value or filter at a time.
struct Reader<'a> {
    nodes: &'a [Node],
    at: usize,
}

impl<'a> Reader<'a> {
    fn next(&mut self) -> Result<&'a Node, DbError> {
        let node = self
            .nodes
            .get(self.at)
            .ok_or_else(|| bad("the nodes end too soon"))?;
        self.at += 1;
        Ok(node)
    }

    /// The index just after the `size` nodes inside `node`.
    fn end_of(&self, node: &Node) -> Result<usize, DbError> {
        let end = self.at.checked_add(node.size as usize);
        match end {
            Some(end) if end <= self.nodes.len() => Ok(end),
            _ => Err(bad("a node says it holds more nodes than there are")),
        }
    }

    fn value(&mut self) -> Result<Doc, DbError> {
        let node = self.next()?;
        Ok(match node.kind {
            kind::NULL => Doc::Null,
            kind::TEXT => Doc::Text(node.text.clone()),
            kind::INT => Doc::Int(node.text.parse().map_err(|_| bad("a broken int"))?),
            kind::FLOAT => Doc::Float(node.text.parse().map_err(|_| bad("a broken float"))?),
            kind::BOOL => Doc::Bool(node.text == "true"),
            kind::OBJECT_ID => {
                let hex = node.text.to_ascii_lowercase();
                if hex.len() != 24 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
                    return Err(bad(format!("{:?} is not an ObjectId", node.text)));
                }
                Doc::ObjectId(hex)
            }
            kind::TIME => Doc::Time(node.text.parse().map_err(|_| bad("a broken date"))?),
            kind::LIST => {
                let end = self.end_of(node)?;
                let mut items = Vec::new();
                while self.at < end {
                    items.push(self.value()?);
                }
                Doc::List(items)
            }
            kind::OBJECT => {
                let end = self.end_of(node)?;
                let mut fields = Vec::new();
                while self.at < end {
                    let key = self.nodes[self.at].name.clone();
                    check_key(&key)?;
                    fields.push((key, self.value()?));
                }
                Doc::Object(fields)
            }
            other => return Err(bad(format!("a node of kind {other} is not a value"))),
        })
    }

    fn filter(&mut self) -> Result<Filter, DbError> {
        let node = self.next()?;
        Ok(match node.kind {
            kind::ALL | kind::ANY => {
                let end = self.end_of(node)?;
                let mut filters = Vec::new();
                while self.at < end {
                    filters.push(self.filter()?);
                }
                if node.kind == kind::ALL {
                    Filter::All(filters)
                } else {
                    Filter::Any(filters)
                }
            }
            kind::COMPARE => {
                check_field(&node.name)?;
                let op = match node.text.as_str() {
                    "equals" => Comparison::Equals,
                    "not_equals" => Comparison::NotEquals,
                    "less_than" => Comparison::LessThan,
                    "at_most" => Comparison::AtMost,
                    "greater_than" => Comparison::GreaterThan,
                    "at_least" => Comparison::AtLeast,
                    "one_of" => Comparison::OneOf,
                    other => return Err(bad(format!("no comparison {other:?}"))),
                };
                let value = self.value()?;
                if op == Comparison::OneOf && !matches!(value, Doc::List(_)) {
                    return Err(bad("one_of needs a list"));
                }
                Filter::Compare {
                    field: node.name.clone(),
                    op,
                    value,
                }
            }
            kind::EXISTS => {
                check_field(&node.name)?;
                Filter::Exists {
                    field: node.name.clone(),
                    exists: node.text == "true",
                }
            }
            other => return Err(bad(format!("a node of kind {other} is not a filter"))),
        })
    }

    fn change(&mut self) -> Result<Change, DbError> {
        let node = self.next()?;
        check_field(&node.name)?;
        Ok(match node.kind {
            kind::SET => Change::Set(node.name.clone(), self.value()?),
            kind::UNSET => Change::Unset(node.name.clone()),
            kind::INCREMENT => match self.value()? {
                Doc::Int(n) => Change::Increment(node.name.clone(), n),
                _ => return Err(bad("increment needs an int")),
            },
            other => return Err(bad(format!("a node of kind {other} is not a change"))),
        })
    }

    fn done(&self) -> Result<(), DbError> {
        if self.at == self.nodes.len() {
            Ok(())
        } else {
            Err(bad("nodes left over"))
        }
    }
}

/// The one value the nodes hold.
pub fn value_from_nodes(nodes: &[Node]) -> Result<Doc, DbError> {
    let mut reader = Reader { nodes, at: 0 };
    let value = reader.value()?;
    reader.done()?;
    Ok(value)
}

/// The filter the nodes hold; no nodes is every document.
pub fn filter_from_nodes(nodes: &[Node]) -> Result<Filter, DbError> {
    if nodes.is_empty() {
        return Ok(Filter::All(Vec::new()));
    }
    let mut reader = Reader { nodes, at: 0 };
    let filter = reader.filter()?;
    reader.done()?;
    Ok(filter)
}

/// The changes the nodes hold, one after the other.
pub fn changes_from_nodes(nodes: &[Node]) -> Result<Vec<Change>, DbError> {
    let mut reader = Reader { nodes, at: 0 };
    let mut changes = Vec::new();
    while reader.at < nodes.len() {
        changes.push(reader.change()?);
    }
    Ok(changes)
}

/// The order the nodes say.
pub fn sort_from_nodes(nodes: &[Node]) -> Result<Vec<(String, Order)>, DbError> {
    nodes
        .iter()
        .map(|node| {
            check_field(&node.name)?;
            let order = match node.kind {
                kind::ASCENDING => Order::Ascending,
                kind::DESCENDING => Order::Descending,
                other => return Err(bad(format!("a node of kind {other} is not an order"))),
            };
            Ok((node.name.clone(), order))
        })
        .collect()
}

/// The value as nodes, as `Doc.roc` reads them.
pub fn value_to_nodes(value: &Doc, name: &str, out: &mut Vec<Node>) {
    let mut node = match value {
        Doc::Null => Node::leaf(kind::NULL, ""),
        Doc::Text(s) => Node::leaf(kind::TEXT, s.clone()),
        Doc::Int(n) => Node::leaf(kind::INT, n.to_string()),
        Doc::Float(x) => Node::leaf(kind::FLOAT, float_text(*x)),
        Doc::Bool(b) => Node::leaf(kind::BOOL, if *b { "true" } else { "false" }),
        Doc::ObjectId(hex) => Node::leaf(kind::OBJECT_ID, hex.clone()),
        Doc::Time(ms) => Node::leaf(kind::TIME, ms.to_string()),
        Doc::Other(what) => Node::leaf(kind::OTHER, what.clone()),
        Doc::List(items) => {
            let at = out.len();
            out.push(Node::leaf(kind::LIST, ""));
            out[at].name = name.to_owned();
            for item in items {
                value_to_nodes(item, "", out);
            }
            out[at].size = (out.len() - at - 1) as u64;
            return;
        }
        Doc::Object(fields) => {
            let at = out.len();
            out.push(Node::leaf(kind::OBJECT, ""));
            out[at].name = name.to_owned();
            for (key, item) in fields {
                value_to_nodes(item, key, out);
            }
            out[at].size = (out.len() - at - 1) as u64;
            return;
        }
    };
    node.name = name.to_owned();
    out.push(node);
}

/// `x` as text Roc's `F64.from_str` reads back exactly.
fn float_text(x: f64) -> String {
    if x.is_nan() {
        "NaN".to_owned()
    } else if x.is_infinite() {
        if x > 0.0 { "inf" } else { "-inf" }.to_owned()
    } else {
        format!("{x:?}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn object(fields: Vec<(&str, Doc)>) -> Doc {
        Doc::Object(fields.into_iter().map(|(k, v)| (k.to_owned(), v)).collect())
    }

    #[test]
    fn values_go_back_and_forth() {
        let value = object(vec![
            ("_id", Doc::ObjectId("0123456789abcdef01234567".into())),
            ("url", Doc::Text("https://x.test/?a=\"b\"".into())),
            ("n", Doc::Int(i64::MIN)),
            ("x", Doc::Float(0.1)),
            ("ok", Doc::Bool(true)),
            ("none", Doc::Null),
            ("at", Doc::Time(1_700_000_000_000)),
            (
                "tags",
                Doc::List(vec![
                    Doc::Text("a".into()),
                    object(vec![("b", Doc::Int(1))]),
                ]),
            ),
        ]);
        let mut nodes = Vec::new();
        value_to_nodes(&value, "", &mut nodes);
        assert_eq!(value_from_nodes(&nodes), Ok(value));
    }

    #[test]
    fn a_key_with_a_dollar_is_refused() {
        let value = object(vec![(
            "url",
            object(vec![("$ne", Doc::Text(String::new()))]),
        )]);
        let mut nodes = Vec::new();
        value_to_nodes(&value, "", &mut nodes);
        assert_eq!(value_from_nodes(&nodes).unwrap_err().code, "2");
    }

    #[test]
    fn filters_are_read() {
        let mut nodes = vec![
            Node {
                kind: kind::ALL,
                name: String::new(),
                size: 3,
                text: String::new(),
            },
            Node {
                kind: kind::COMPARE,
                name: "owner".into(),
                size: 1,
                text: "equals".into(),
            },
        ];
        value_to_nodes(&Doc::Text("u1".into()), "", &mut nodes);
        nodes.push(Node {
            kind: kind::EXISTS,
            name: "url".into(),
            size: 0,
            text: "false".into(),
        });
        assert_eq!(
            filter_from_nodes(&nodes),
            Ok(Filter::All(vec![
                Filter::Compare {
                    field: "owner".into(),
                    op: Comparison::Equals,
                    value: Doc::Text("u1".into())
                },
                Filter::Exists {
                    field: "url".into(),
                    exists: false
                },
            ]))
        );
    }

    #[test]
    fn broken_nodes_are_errors() {
        let too_big = [Node {
            kind: kind::LIST,
            name: String::new(),
            size: 5,
            text: String::new(),
        }];
        assert!(value_from_nodes(&too_big).is_err());
        let operator = [Node {
            kind: kind::EXISTS,
            name: "$where".into(),
            size: 0,
            text: "true".into(),
        }];
        assert!(filter_from_nodes(&operator).is_err());
        assert!(check_field("a..b").is_err());
        assert!(check_field("address.city").is_ok());
        assert!(check_collection("system.users").is_err());
        let bad_id = [Node::leaf(kind::OBJECT_ID, "xyz")];
        assert!(value_from_nodes(&bad_id).is_err());
    }
}
