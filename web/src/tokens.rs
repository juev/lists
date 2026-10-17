//! Tokens for scripts and automation: what they may do and how often. Rules: R150–R152 in
//! docs/specs/product.md.

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use lists_core::AppError;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

const FILE: &str = "api-tokens.json";
/// What every token starts with, so that it is recognised in a configuration or a leak.
const PREFIX: &str = "lists_";
/// R152: requests one token may make within `WINDOW`.
pub const LIMIT: usize = 600;
pub const WINDOW: Duration = Duration::from_secs(60);
/// A list this long is not one person's scripts; it only bounds the file.
const MAX_TOKENS: usize = 100;
const MAX_NAME: usize = 100;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Scope {
    Read,
    Write,
}

impl Scope {
    fn name(self) -> &'static str {
        match self {
            Scope::Read => "read",
            Scope::Write => "write",
        }
    }

    fn parse(text: &str) -> Option<Scope> {
        match text {
            "read" => Some(Scope::Read),
            "write" => Some(Scope::Write),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
struct Token {
    id: String,
    name: String,
    scope: Scope,
    /// SHA-256 of the token, in hex: the token itself is not kept.
    hash: String,
    /// `YYYY-MM-DDTHH:MM`, UTC.
    created: String,
    used: Option<String>,
}

impl Token {
    fn to_json(&self) -> Value {
        json!({ "id": self.id, "name": self.name, "scope": self.scope.name(), "hash": self.hash, "created": self.created, "used": self.used })
    }

    fn from_json(v: &Value) -> Option<Token> {
        Some(Token {
            id: v["id"].as_str()?.to_string(),
            name: v["name"].as_str()?.to_string(),
            scope: Scope::parse(v["scope"].as_str()?)?,
            hash: v["hash"].as_str().filter(|h| h.len() == 64)?.to_string(),
            created: v["created"].as_str()?.to_string(),
            used: v["used"].as_str().map(str::to_string),
        })
    }

    /// What the page shows: everything but the hash.
    fn shown(&self) -> Value {
        json!({ "id": self.id, "name": self.name, "scope": self.scope.name(), "created": self.created, "used": self.used })
    }
}

/// The token a request carried and found valid.
#[derive(Clone, Debug, PartialEq)]
pub struct Caller {
    pub id: String,
    pub name: String,
    pub scope: Scope,
}

fn digest(secret: &str) -> String {
    Sha256::digest(secret.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn minute() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M").to_string()
}

pub struct Tokens {
    file: PathBuf,
    list: Mutex<Vec<Token>>,
    /// Token id → when its requests within `WINDOW` were, oldest first.
    recent: Mutex<HashMap<String, VecDeque<Instant>>>,
}

impl Tokens {
    pub fn open(dir: &Path) -> Result<Tokens, String> {
        let file = dir.join(FILE);
        let list = match std::fs::read(&file) {
            Ok(bytes) => {
                let v: Value =
                    serde_json::from_slice(&bytes).map_err(|e| format!("cannot read {}: {e}", file.display()))?;
                v["tokens"]
                    .as_array()
                    .map(|a| a.iter().filter_map(Token::from_json).collect())
                    .unwrap_or_default()
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(format!("cannot read {}: {e}", file.display())),
        };
        Ok(Tokens {
            file,
            list: Mutex::new(list),
            recent: Mutex::new(HashMap::new()),
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Token>> {
        self.list.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// R150: a new token. The answer carries the token itself, which is never shown again.
    pub fn create(&self, args: &Value) -> Result<Value, AppError> {
        let invalid = |msg: &str| AppError::Invalid { msg: msg.into() };
        let name = args["name"].as_str().map(str::trim).unwrap_or_default();
        if name.is_empty() || name.chars().count() > MAX_NAME || name.chars().any(char::is_control) {
            return Err(invalid("a token needs a name of at most 100 characters"));
        }
        let scope = args["scope"]
            .as_str()
            .and_then(Scope::parse)
            .ok_or_else(|| invalid("the scope is read or write"))?;
        let secret = format!(
            "{PREFIX}{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        let token = Token {
            id: uuid::Uuid::new_v4().to_string(),
            name: name.to_string(),
            scope,
            hash: digest(&secret),
            created: minute(),
            used: None,
        };
        let mut list = self.lock();
        if list.len() >= MAX_TOKENS {
            return Err(invalid("too many tokens; revoke some first"));
        }
        list.push(token.clone());
        self.save(&list)?;
        let mut shown = token.shown();
        shown["token"] = json!(secret);
        Ok(shown)
    }

    pub fn list(&self) -> Value {
        Value::Array(self.lock().iter().map(Token::shown).collect())
    }

    /// R150: true when there was such a token.
    pub fn revoke(&self, id: &str) -> Result<bool, AppError> {
        let mut list = self.lock();
        let before = list.len();
        list.retain(|t| t.id != id);
        if list.len() == before {
            return Ok(false);
        }
        self.recent.lock().unwrap_or_else(|p| p.into_inner()).remove(id);
        self.save(&list)?;
        Ok(true)
    }

    /// R151: the token `secret` stands for, if any. Notes the minute of use, writing the file at
    /// most once a minute for each token.
    pub fn check(&self, secret: &str) -> Option<Caller> {
        if !secret.starts_with(PREFIX) {
            return None;
        }
        let hash = digest(secret);
        let mut list = self.lock();
        // Compared as hashes of a random token: the time it takes tells nothing about the token.
        let token = list.iter_mut().find(|t| t.hash == hash)?;
        let caller = Caller {
            id: token.id.clone(),
            name: token.name.clone(),
            scope: token.scope,
        };
        let now = minute();
        if token.used.as_deref() != Some(now.as_str()) {
            token.used = Some(now);
            if let Err(e) = self.save(&list) {
                eprintln!("lists-web: {e}");
            }
        }
        Some(caller)
    }

    /// R152: counts a request of the token; `Err` with the time it is still refused.
    pub fn allow(&self, id: &str) -> Result<(), Duration> {
        let mut recent = self.recent.lock().unwrap_or_else(|p| p.into_inner());
        let times = recent.entry(id.to_string()).or_default();
        while times.front().is_some_and(|t| t.elapsed() >= WINDOW) {
            times.pop_front();
        }
        if times.len() >= LIMIT {
            return Err(WINDOW.saturating_sub(times[0].elapsed()));
        }
        times.push_back(Instant::now());
        Ok(())
    }

    /// A new file replaces the old one, readable by its owner only.
    fn save(&self, list: &[Token]) -> Result<(), AppError> {
        let text = json!({ "tokens": list.iter().map(Token::to_json).collect::<Vec<_>>() }).to_string();
        let tmp = self.file.with_extension("json.tmp");
        let _ = std::fs::remove_file(&tmp);
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let written = options.open(&tmp).and_then(|mut f| {
            use std::io::Write;
            f.write_all(text.as_bytes())?;
            f.sync_all()
        });
        written
            .and_then(|_| std::fs::rename(&tmp, &self.file))
            .map_err(|e| AppError::Storage {
                msg: format!("cannot write {}: {e}", self.file.display()),
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn r150_a_token_is_kept_as_its_hash_and_survives_a_restart() {
        let dir = tempfile::tempdir().unwrap();
        let tokens = Tokens::open(dir.path()).unwrap();
        let made = tokens.create(&json!({ "name": " скрипт ", "scope": "read" })).unwrap();
        let secret = made["token"].as_str().unwrap().to_string();
        assert!(secret.starts_with(PREFIX) && secret.len() == PREFIX.len() + 64);
        assert_eq!(made["name"], "скрипт");
        let file = std::fs::read_to_string(dir.path().join(FILE)).unwrap();
        assert!(!file.contains(&secret[PREFIX.len()..]), "the file holds no token");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(dir.path().join(FILE)).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
        assert!(tokens.list()[0].get("hash").is_none(), "the page gets no hash");
        assert!(tokens.list()[0]["used"].is_null());

        let again = Tokens::open(dir.path()).unwrap();
        let caller = again.check(&secret).unwrap();
        assert_eq!((caller.name.as_str(), caller.scope), ("скрипт", Scope::Read));
        assert!(again.list()[0]["used"].is_string(), "the minute of use is noted");
        assert_eq!(again.check(&format!("{secret}x")), None);
        assert_eq!(again.check(&secret[PREFIX.len()..]), None);

        assert!(again.revoke(&caller.id).unwrap());
        assert!(!again.revoke(&caller.id).unwrap());
        assert_eq!(again.check(&secret), None);
        assert_eq!(
            Tokens::open(dir.path()).unwrap().check(&secret),
            None,
            "and stays revoked"
        );
    }

    #[test]
    fn r150_names_and_scopes_are_checked() {
        let dir = tempfile::tempdir().unwrap();
        let tokens = Tokens::open(dir.path()).unwrap();
        assert!(tokens.create(&json!({ "name": "", "scope": "read" })).is_err());
        assert!(tokens.create(&json!({ "name": "a\nb", "scope": "read" })).is_err());
        assert!(tokens
            .create(&json!({ "name": "x".repeat(101), "scope": "read" }))
            .is_err());
        assert!(tokens.create(&json!({ "name": "x", "scope": "admin" })).is_err());
        let made = tokens.create(&json!({ "name": "x", "scope": "write" })).unwrap();
        assert_eq!(
            tokens.check(made["token"].as_str().unwrap()).unwrap().scope,
            Scope::Write
        );
    }

    #[test]
    fn r152_a_token_makes_600_requests_a_minute() {
        let dir = tempfile::tempdir().unwrap();
        let tokens = Tokens::open(dir.path()).unwrap();
        for _ in 0..LIMIT {
            tokens.allow("a").unwrap();
        }
        let wait = tokens.allow("a").unwrap_err();
        assert!(wait > Duration::ZERO && wait <= WINDOW);
        assert!(tokens.allow("b").is_ok(), "each token has a limit of its own");
    }
}
