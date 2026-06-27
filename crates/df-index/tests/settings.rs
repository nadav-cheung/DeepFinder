// SPDX-License-Identifier: MIT
//! Integration tests for `df_index::settings` — the `settings.json` ignore list.

use df_index::Settings;
use std::path::PathBuf;

#[test]
fn load_missing_is_default() {
    let tmp = tempfile::tempdir().unwrap();
    let s = Settings::load(tmp.path());
    assert!(s.ignore.is_empty());
}

#[test]
fn load_valid_roundtrip() {
    let tmp = tempfile::tempdir().unwrap();
    let s = Settings {
        ignore: vec!["node_modules".into(), "*.log".into()],
    };
    Settings::save(tmp.path(), &s).unwrap();
    let loaded = Settings::load(tmp.path());
    assert_eq!(loaded.ignore, s.ignore);
}

#[test]
fn load_malformed_is_default() {
    let tmp = tempfile::tempdir().unwrap();
    let path = Settings::settings_path(tmp.path());
    std::fs::write(path, b"{ this is not json").unwrap();
    let s = Settings::load(tmp.path());
    assert!(s.ignore.is_empty());
}

#[test]
fn serde_unknown_key_ignored() {
    let tmp = tempfile::tempdir().unwrap();
    let path = Settings::settings_path(tmp.path());
    std::fs::write(
        path,
        b"{\"ignore\":[\"foo\"],\"future_field\":42,\"nested\":{\"a\":1}}",
    )
    .unwrap();
    let s = Settings::load(tmp.path());
    assert_eq!(s.ignore, vec!["foo".to_string()]);
}

#[test]
fn serde_missing_ignore_key_defaults() {
    let tmp = tempfile::tempdir().unwrap();
    let path = Settings::settings_path(tmp.path());
    std::fs::write(path, b"{}").unwrap();
    let s = Settings::load(tmp.path());
    assert!(s.ignore.is_empty());
}

#[test]
fn settings_path_is_data_dir_join_settings_json() {
    let dir = PathBuf::from("/tmp/whatever");
    assert_eq!(Settings::settings_path(&dir), dir.join("settings.json"));
}

#[test]
fn add_ignore_dedup() {
    let mut s = Settings {
        ignore: vec!["foo".into()],
    };
    s.add_ignore("foo"); // already present → no-op
    s.add_ignore("bar");
    assert_eq!(s.ignore, vec!["foo".to_string(), "bar".to_string()]);
}

#[test]
fn remove_ignore_exact_match() {
    let mut s = Settings {
        ignore: vec!["foo".into(), "bar".into()],
    };
    assert!(s.remove_ignore("foo"));
    assert!(!s.remove_ignore("missing"));
    assert_eq!(s.ignore, vec!["bar".to_string()]);
}

#[test]
fn add_remove_roundtrip_via_save() {
    let tmp = tempfile::tempdir().unwrap();
    let mut s = Settings::load(tmp.path());
    s.add_ignore("**/.venv");
    s.add_ignore("*.log");
    Settings::save(tmp.path(), &s).unwrap();

    let mut loaded = Settings::load(tmp.path());
    assert_eq!(loaded.ignore.len(), 2);
    assert!(loaded.remove_ignore("**/.venv"));
    Settings::save(tmp.path(), &loaded).unwrap();

    let final_s = Settings::load(tmp.path());
    assert_eq!(final_s.ignore, vec!["*.log".to_string()]);
}
