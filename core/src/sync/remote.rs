//! What sync needs from storage: read, write, list and delete files by relative path.

use std::fs;
use std::path::PathBuf;

use crate::error::{AppError, Result};

pub trait Remote: Send + Sync {
    /// Tells one storage from another within a process.
    fn id(&self) -> String;
    /// File names directly inside `dir`. A missing directory is empty.
    fn list(&self, dir: &str) -> Result<Vec<String>>;
    fn get(&self, path: &str) -> Result<Option<Vec<u8>>>;
    /// Creates parent directories as needed and replaces an existing file.
    fn put(&self, path: &str, data: &[u8]) -> Result<()>;
    /// Deleting a missing file is not an error.
    fn delete(&self, path: &str) -> Result<()>;
    fn exists(&self, path: &str) -> Result<bool>;
}

/// A plain folder: a mounted share, a folder synced by another tool, or a test directory.
pub struct DirRemote {
    root: PathBuf,
}

impl DirRemote {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        DirRemote { root: root.into() }
    }

    fn resolve(&self, path: &str) -> Result<PathBuf> {
        if path
            .split('/')
            .any(|part| part.is_empty() || part == "." || part == "..")
        {
            return Err(AppError::sync(format!("bad path: {path}")));
        }
        Ok(self.root.join(path))
    }
}

impl Remote for DirRemote {
    fn id(&self) -> String {
        self.root.to_string_lossy().into_owned()
    }

    fn list(&self, dir: &str) -> Result<Vec<String>> {
        let entries = match fs::read_dir(self.resolve(dir)?) {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(vec![]),
            Err(e) => return Err(e.into()),
        };
        let mut names = Vec::new();
        for entry in entries {
            let entry = entry?;
            if entry.file_type()?.is_file() {
                names.push(entry.file_name().to_string_lossy().into_owned());
            }
        }
        Ok(names)
    }

    fn get(&self, path: &str) -> Result<Option<Vec<u8>>> {
        match fs::read(self.resolve(path)?) {
            Ok(data) => Ok(Some(data)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    fn put(&self, path: &str, data: &[u8]) -> Result<()> {
        let target = self.resolve(path)?;
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        // Readers never see a half-written file: write aside, then rename.
        let tmp = target.with_extension("part");
        fs::write(&tmp, data)?;
        fs::rename(&tmp, &target)?;
        Ok(())
    }

    fn delete(&self, path: &str) -> Result<()> {
        match fs::remove_file(self.resolve(path)?) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    fn exists(&self, path: &str) -> Result<bool> {
        Ok(self.resolve(path)?.is_file())
    }
}
