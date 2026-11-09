// SPDX-License-Identifier: GPL-3.0-or-later
use crate::output::BlockWriter;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{FileTypeExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

pub struct Sink { path: PathBuf, file: Option<File>, timeout: Duration }
impl Sink {
    pub fn new(path: PathBuf, timeout: Duration) -> Self { Self { path, file: None, timeout } }
    fn open(path: &Path) -> io::Result<File> {
        let flags = libc::O_NONBLOCK | libc::O_CLOEXEC | libc::O_NOFOLLOW;
        match fs::symlink_metadata(path) {
            Ok(meta) if meta.file_type().is_fifo() || path == Path::new("/dev/null") => {
                let file = OpenOptions::new().write(true).custom_flags(flags).open(path)?;
                let kind = file.metadata()?.file_type();
                if !kind.is_fifo() && !(path == Path::new("/dev/null") && kind.is_char_device()) {
                    return Err(io::Error::other("output path changed while opening"));
                }
                Ok(file)
            }
            Ok(_) => Err(io::Error::new(io::ErrorKind::AlreadyExists,
                                        "refusing to overwrite output; use a FIFO or a new file")),
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                OpenOptions::new().write(true).create_new(true).mode(0o600)
                    .custom_flags(flags).open(path)
            }
            Err(e) => Err(e),
        }
    }
}
impl BlockWriter for Sink {
    fn write_block(&mut self, data: &[u8], cancel: &AtomicBool) -> io::Result<()> {
        let deadline = Instant::now() + self.timeout;
        while self.file.is_none() {
            if cancel.load(Ordering::Acquire) {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "output cancelled"));
            }
            match Self::open(&self.path) {
                Ok(file) => self.file = Some(file),
                Err(e) if e.raw_os_error() == Some(libc::ENXIO) => {
                    if Instant::now() >= deadline {
                        return Err(io::Error::new(io::ErrorKind::TimedOut, "FIFO has no reader"));
                    }
                    thread::sleep(Duration::from_millis(10));
                }
                Err(e) => return Err(e),
            }
        }
        let file = self.file.as_mut().expect("file opened above");
        let mut offset = 0;
        while offset < data.len() {
            if cancel.load(Ordering::Acquire) {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "output cancelled"));
            }
            if Instant::now() >= deadline {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "output write deadline exceeded"));
            }
            match file.write(&data[offset..]) {
                Ok(0) => return Err(io::Error::new(io::ErrorKind::WriteZero, "zero-length output write")),
                Ok(n) => offset += n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(2));
                }
                Err(e) => return Err(e),
            }
        }
        Ok(())
    }
}
