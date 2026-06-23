// SPDX-License-Identifier: MIT
//! Named-DB registry: a human-editable TOML file (`<data_dir>/dbs.toml`) mapping
//! a DB name → its root + index paths. `db add/remove/list` manage it; the daemon
//! loads every registered DB and the default DB into a `DbSet`.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::Result;

/// One registered named DB.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DbRecord {
    pub name: String,
    /// The indexed root (informational; the build source).
    pub root: PathBuf,
    /// Path to `index.dfdb`.
    pub db_path: PathBuf,
    /// Directory holding the content shards + MANIFEST.
    pub content_dir: PathBuf,
}

/// The on-disk TOML shape.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct RegistryFile {
    #[serde(default)]
    pub dbs: Vec<DbRecord>,
}

/// The named-DB registry, read from / written to `<dir>/dbs.toml`.
pub struct Registry {
    path: PathBuf,
    pub records: Vec<DbRecord>,
}

impl Registry {
    /// Load the registry from `<dir>/dbs.toml`. Empty (no records) if absent.
    pub fn load(dir: &Path) -> Self {
        let path = dir.join("dbs.toml");
        let records = match std::fs::read_to_string(&path) {
            Ok(s) => toml::from_str::<RegistryFile>(&s)
                .map(|f| f.dbs)
                .unwrap_or_default(),
            Err(_) => Vec::new(),
        };
        Self { path, records }
    }

    /// Write the registry atomically to `<dir>/dbs.toml`.
    pub fn save(&self) -> Result<()> {
        let file = RegistryFile {
            dbs: self.records.clone(),
        };
        let s = toml::to_string_pretty(&file)
            .map_err(|e| crate::IndexError::Other(format!("toml encode: {e}")))?;
        crate::atomic_write_public(&self.path, s.as_bytes())
    }

    /// Look up a record by name.
    pub fn get(&self, name: &str) -> Option<&DbRecord> {
        self.records.iter().find(|r| r.name == name)
    }

    /// Insert or replace a record by name.
    pub fn upsert(&mut self, rec: DbRecord) {
        if let Some(existing) = self.records.iter_mut().find(|r| r.name == rec.name) {
            *existing = rec;
        } else {
            self.records.push(rec);
        }
    }

    /// Remove a record by name. True if it was present.
    pub fn remove(&mut self, name: &str) -> bool {
        let before = self.records.len();
        self.records.retain(|r| r.name != name);
        self.records.len() != before
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_missing_is_empty() {
        let tmp = tempfile::tempdir().unwrap();
        let reg = Registry::load(tmp.path());
        assert!(reg.records.is_empty());
    }

    #[test]
    fn upsert_get_remove_roundtrip() {
        let tmp = tempfile::tempdir().unwrap();
        let mut reg = Registry::load(tmp.path());
        let rec = DbRecord {
            name: "proj".into(),
            root: PathBuf::from("/tmp/proj"),
            db_path: PathBuf::from("/tmp/proj.db"),
            content_dir: PathBuf::from("/tmp/proj_content"),
        };
        reg.upsert(rec.clone());
        assert_eq!(reg.get("proj"), Some(&rec));

        // upsert replaces, does not duplicate.
        let mut rec2 = rec.clone();
        rec2.root = PathBuf::from("/tmp/proj2");
        reg.upsert(rec2.clone());
        assert_eq!(reg.records.len(), 1);
        assert_eq!(reg.get("proj").unwrap().root, PathBuf::from("/tmp/proj2"));

        reg.save().unwrap();
        let reloaded = Registry::load(tmp.path());
        assert_eq!(reloaded.records, vec![rec2]);

        assert!(reg.remove("proj"));
        assert!(!reg.remove("proj"));
        assert!(reg.records.is_empty());
    }
}
