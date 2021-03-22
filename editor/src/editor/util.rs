use super::ed_error::{EdResult, KeyNotFound, OutOfBounds};
use snafu::OptionExt;
use std::collections::HashMap;
use std::slice::SliceIndex;

// replace HashMap method that returns Option with one that returns Result and proper Error
pub fn map_get<'a, K: ::std::fmt::Debug + std::hash::Hash + std::cmp::Eq, V>(
    hash_map: &'a HashMap<K, V>,
    key: &K,
) -> EdResult<&'a V> {
    let value = hash_map.get(key).context(KeyNotFound {
        key_str: format!("{:?}", key),
    })?;

    Ok(value)
}
