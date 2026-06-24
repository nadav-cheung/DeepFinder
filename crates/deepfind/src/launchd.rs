// SPDX-License-Identifier: MIT
//! `launchd` integration — render and install a **user** LaunchAgent so the
//! daemon auto-starts at login and is restarted on crash. macOS only; the plist
//! lives in `~/Library/LaunchAgents/`. Pure rendering + path logic is unit-tested
//! here; the `load` flag gates the actual `launchctl` subprocess (off in tests).

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Reverse-DNS label for the user domain `deepfind.nadav.com.cn`
/// (also the plist filename stem).
pub const LABEL: &str = "cn.com.nadav.deepfind";

/// Where the plist is written: `~/Library/LaunchAgents/<LABEL>.plist`.
pub fn plist_path(home: &Path) -> PathBuf {
    home.join("Library")
        .join("LaunchAgents")
        .join(format!("{LABEL}.plist"))
}

/// Resolve the `deepfindd` binary as a sibling of the running `deepfind` (same
/// directory — both land in `~/.cargo/bin/` after `cargo install`). `None` if
/// no such file sits next to `exe`.
pub fn resolve_daemon_bin(exe: &Path) -> Option<PathBuf> {
    let candidate = exe.parent()?.join("deepfindd");
    candidate.is_file().then_some(candidate)
}

/// Render the LaunchAgent plist XML for a daemon at `bin`, rooted at `home`.
/// `watch` injects `DEEPFIND_WATCH=1` so df-watch incremental hot-swap is on.
pub fn render_plist(bin: &Path, home: &Path, watch: bool) -> String {
    let out = home.join(".deep-finder/logs/daemon.out.log");
    let err = home.join(".deep-finder/logs/daemon.err.log");
    let env = if watch {
        "\t<key>EnvironmentVariables</key>\n\t<dict>\n\t\t<key>DEEPFIND_WATCH</key>\n\t\t<string>1</string>\n\t</dict>\n"
    } else {
        ""
    };
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n\t<key>Label</key>\n\t<string>{LABEL}</string>\n\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>{bin}</string>\n\t</array>\n\t<key>RunAtLoad</key>\n\t<true/>\n\t<key>KeepAlive</key>\n\t<true/>\n\t<key>ProcessType</key>\n\t<string>Background</string>\n{env}\t<key>StandardOutPath</key>\n\t<string>{out}</string>\n\t<key>StandardErrorPath</key>\n\t<string>{err}</string>\n</dict>\n</plist>\n",
        bin = bin.display(),
        out = out.display(),
        err = err.display(),
    )
}

/// Write the plist (creating `~/Library/LaunchAgents/` and the log dir) and,
/// when `load`, register it with launchd. `load = false` is for tests.
pub fn install(home: &Path, exe: &Path, watch: bool, load: bool) -> Result<(), String> {
    let bin = resolve_daemon_bin(exe)
        .ok_or_else(|| format!("deepfindd not found next to {}", exe.display()))?;
    let path = plist_path(home);
    fs::create_dir_all(path.parent().unwrap_or(home))
        .map_err(|e| format!("create LaunchAgents dir: {e}"))?;
    fs::create_dir_all(home.join(".deep-finder/logs"))
        .map_err(|e| format!("create log dir: {e}"))?;
    fs::write(&path, render_plist(&bin, home, watch)).map_err(|e| format!("write plist: {e}"))?;
    if load {
        let status = Command::new("launchctl")
            .args(["load", &path.to_string_lossy()])
            .status()
            .map_err(|e| format!("spawn launchctl load: {e}"))?;
        if !status.success() {
            return Err(format!("launchctl load failed (exit {:?})", status.code()));
        }
    }
    Ok(())
}

/// Unregister (when `load`) and delete the plist. A missing file is not an error.
pub fn uninstall(home: &Path, load: bool) -> Result<(), String> {
    let path = plist_path(home);
    if load {
        // Not-loaded is fine (e.g. already uninstalled) — ignore the exit code.
        let _ = Command::new("launchctl")
            .args(["unload", &path.to_string_lossy()])
            .status();
    }
    if path.exists() {
        fs::remove_file(&path).map_err(|e| format!("remove plist: {e}"))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    #[test]
    fn plist_path_is_under_launchagents_with_label() {
        let home = PathBuf::from("/Users/example");
        assert_eq!(
            plist_path(&home),
            PathBuf::from("/Users/example/Library/LaunchAgents/cn.com.nadav.deepfind.plist"),
        );
    }

    #[test]
    fn resolve_daemon_bin_finds_sibling() {
        let tmp = tempdir().unwrap();
        let exe = tmp.path().join("deepfind");
        fs::write(&exe, b"#!/bin/sh\n").unwrap();
        fs::write(tmp.path().join("deepfindd"), b"#!/bin/sh\n").unwrap();
        assert_eq!(resolve_daemon_bin(&exe), Some(tmp.path().join("deepfindd")));
    }

    #[test]
    fn resolve_daemon_bin_none_when_missing() {
        let tmp = tempdir().unwrap();
        let exe = tmp.path().join("deepfind");
        fs::write(&exe, b"#!/bin/sh\n").unwrap();
        assert_eq!(resolve_daemon_bin(&exe), None);
    }

    #[test]
    fn render_plist_contains_bin_label_keepalive_and_logs_without_watch() {
        let home = PathBuf::from("/Users/example");
        let bin = PathBuf::from("/Users/example/.cargo/bin/deepfindd");
        let xml = render_plist(&bin, &home, false);
        assert!(
            xml.contains("<string>cn.com.nadav.deepfind</string>"),
            "missing label"
        );
        assert!(
            xml.contains(&format!("<string>{}</string>", bin.display())),
            "missing absolute bin path"
        );
        assert!(xml.contains("<key>RunAtLoad</key>"), "missing RunAtLoad");
        assert!(xml.contains("<true/>"), "missing <true/>");
        assert!(xml.contains("<key>KeepAlive</key>"), "missing KeepAlive");
        assert!(
            xml.contains("/Users/example/.deep-finder/logs/daemon.out.log"),
            "missing out log"
        );
        assert!(
            xml.contains("/Users/example/.deep-finder/logs/daemon.err.log"),
            "missing err log"
        );
        assert!(
            !xml.contains("DEEPFIND_WATCH"),
            "watch env must be absent when watch=false"
        );
    }

    #[test]
    fn render_plist_with_watch_includes_env() {
        let home = PathBuf::from("/Users/example");
        let bin = PathBuf::from("/Users/example/.cargo/bin/deepfindd");
        let xml = render_plist(&bin, &home, true);
        assert!(xml.contains("DEEPFIND_WATCH"), "watch env must be present");
        assert!(xml.contains("<string>1</string>"), "watch value must be 1");
    }

    #[test]
    fn install_writes_plist_referencing_sibling_daemon_and_creates_log_dir() {
        let tmp = tempdir().unwrap();
        let home = tmp.path().to_path_buf();
        let exe = home.join(".cargo/bin/deepfind");
        fs::create_dir_all(exe.parent().unwrap()).unwrap();
        fs::write(&exe, b"x").unwrap();
        fs::write(home.join(".cargo/bin/deepfindd"), b"x").unwrap();

        install(&home, &exe, true, false).unwrap();

        let content = fs::read_to_string(plist_path(&home)).unwrap();
        assert!(
            content.contains("cn.com.nadav.deepfind"),
            "plist missing label"
        );
        let daemon = home.join(".cargo/bin/deepfindd");
        assert!(
            content.contains(&format!("<string>{}</string>", daemon.display())),
            "plist must reference the resolved deepfindd path"
        );
        assert!(
            content.contains("DEEPFIND_WATCH"),
            "watch=true should be in plist"
        );
        assert!(
            home.join(".deep-finder/logs").is_dir(),
            "log dir should be created"
        );
    }

    #[test]
    fn install_errors_when_daemon_binary_missing() {
        let tmp = tempdir().unwrap();
        let home = tmp.path().to_path_buf();
        let exe = home.join("deepfind");
        fs::write(&exe, b"x").unwrap(); // no deepfindd sibling
        let err = install(&home, &exe, true, false).unwrap_err();
        assert!(
            err.contains("deepfindd"),
            "error should mention deepfindd: {err}"
        );
    }

    #[test]
    fn uninstall_removes_plist() {
        let tmp = tempdir().unwrap();
        let home = tmp.path().to_path_buf();
        fs::create_dir_all(home.join("Library/LaunchAgents")).unwrap();
        fs::write(plist_path(&home), b"<plist/>").unwrap();
        assert!(plist_path(&home).exists());

        uninstall(&home, false).unwrap();
        assert!(!plist_path(&home).exists(), "plist should be removed");
    }

    #[test]
    fn uninstall_ok_when_no_plist() {
        let tmp = tempdir().unwrap();
        uninstall(tmp.path(), false).unwrap();
    }
}
