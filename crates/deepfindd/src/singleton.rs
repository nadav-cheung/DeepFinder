// SPDX-License-Identifier: MIT
//! Single-instance guard for `deepfindd`. A resident daemon owns a Unix socket
//! and the index-build pipeline; two daemons sharing `$HOME` would contend on
//! the socket and race on index writes. We serialize startup with an exclusive
//! advisory `flock` on `<socket dir>/daemon.lock`, held for the daemon's
//! lifetime. Because `flock` is owned by the live open file description, the
//! kernel releases it automatically on crash (no stale lock to clean up) —
//! unlike the socket file, which a crashed daemon leaves behind.
//!
//! macOS/Linux only (`#![cfg(unix)]`); the project targets apple-darwin.

#![cfg(unix)]

use std::fs::{File, OpenOptions};
use std::io;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};

/// File name of the singleton lock, co-located with the daemon's Unix socket.
pub const LOCK_NAME: &str = "daemon.lock";

/// Path of the singleton lock for a daemon whose socket lives at `socket_path`.
pub fn lock_path(socket_path: &Path) -> PathBuf {
    socket_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join(LOCK_NAME)
}

/// Acquire an exclusive, non-blocking advisory lock on `lock_path`. The lock is
/// held for the lifetime of the returned [`File`]; dropping it releases it (and
/// the kernel releases it automatically if the process dies).
///
/// Returns [`Err`] with kind [`io::ErrorKind::WouldBlock`] when another daemon
/// already holds the lock, so the caller can surface a clear "already running"
/// message.
pub fn acquire(lock_path: &Path) -> io::Result<File> {
    if let Some(dir) = lock_path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(lock_path)?;
    // LOCK_EX | LOCK_NB: exclusive, non-blocking. EWOULDBLOCK surfaces as
    // ErrorKind::WouldBlock when another daemon holds the lock.
    // SAFETY: `flock` operates only on the advisory-lock state of an fd we own;
    // no pointers or memory side effects. Return value is checked.
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(file)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn second_acquire_while_held_is_would_block() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join(LOCK_NAME);

        let first = acquire(&p).expect("first acquire");
        let second = acquire(&p);
        assert_eq!(
            second.unwrap_err().kind(),
            io::ErrorKind::WouldBlock,
            "a second daemon must not be able to acquire the lock"
        );
        drop(first);
    }

    #[test]
    fn re_acquire_after_release_succeeds() {
        let tmp = tempfile::tempdir().unwrap();
        let p = tmp.path().join(LOCK_NAME);

        drop(acquire(&p).expect("first acquire"));
        // Released ⇒ a fresh acquire must work (lock not leaked).
        let _again = acquire(&p).expect("re-acquire after release");
    }

    #[test]
    fn lock_path_is_sibling_of_socket() {
        let sock = Path::new("/Users/x/.deep-finder/socket");
        assert_eq!(
            lock_path(sock),
            PathBuf::from("/Users/x/.deep-finder/daemon.lock")
        );
    }
}
