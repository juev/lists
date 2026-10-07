//! WebDAV as dumb file storage: GET, PUT, DELETE, HEAD, MKCOL and a depth-1 PROPFIND.

use std::io::Read;
use std::time::Duration;

use base64::Engine;

use super::remote::Remote;
use crate::error::{AppError, Result};
use crate::model::ConnectionCheck;

const PROPFIND_BODY: &str = r#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>"#;

/// Upper bound for one downloaded file; attachments larger than this are not synced.
const MAX_BODY: u64 = 512 * 1024 * 1024;

pub struct WebDavRemote {
    agent: ureq::Agent,
    /// Collection URL ending in `/`.
    base: String,
    auth: Option<String>,
}

impl WebDavRemote {
    pub fn new(url: &str, user: &str, password: &str) -> Result<Self> {
        let url = url.trim();
        if !(url.starts_with("https://") || url.starts_with("http://")) {
            return Err(AppError::sync("the address must start with https:// or http://"));
        }
        let auth = (!user.is_empty()).then(|| {
            format!(
                "Basic {}",
                base64::engine::general_purpose::STANDARD.encode(format!("{user}:{password}"))
            )
        });
        Ok(WebDavRemote {
            agent: ureq::AgentBuilder::new()
                .timeout_connect(Duration::from_secs(15))
                .timeout(Duration::from_secs(120))
                .build(),
            base: format!("{}/", url.trim_end_matches('/')),
            auth,
        })
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}", self.base, path)
    }

    fn request(&self, method: &str, url: &str) -> ureq::Request {
        let request = self.agent.request(method, url);
        match &self.auth {
            Some(auth) => request.set("Authorization", auth),
            None => request,
        }
    }

    /// Asks whether sync could work here without writing anything (S26).
    pub fn check(&self) -> Result<ConnectionCheck> {
        if self.answers(&self.base)? {
            return Ok(ConnectionCheck::Ready);
        }
        // Sync creates the last collection of the address itself, but not the ones above it.
        let above = self.base.trim_end_matches('/').rsplit_once('/').map(|(up, _)| up);
        match above {
            Some(up) if !up.ends_with('/') && self.answers(&format!("{up}/"))? => Ok(ConnectionCheck::WillCreate),
            _ => Err(AppError::sync("nothing is found at this address (HTTP 404)")),
        }
    }

    /// Whether a collection exists at `url`; an error when the answer is not the one WebDAV gives.
    fn answers(&self, url: &str) -> Result<bool> {
        let result = self
            .request("PROPFIND", url)
            .set("Depth", "0")
            .set("Content-Type", "application/xml")
            .send_string(PROPFIND_BODY);
        match status(result, "PROPFIND")? {
            207 => Ok(true),
            404 => Ok(false),
            code @ (401 | 403) => Err(fail("PROPFIND", url, code)),
            code => Err(AppError::sync(format!(
                "the server does not answer as WebDAV (HTTP {code})"
            ))),
        }
    }

    /// Creates every collection on the way to `path`.
    fn make_parents(&self, path: &str) -> Result<()> {
        let mut dir = String::new();
        // The base collection itself may be missing too.
        status(self.request("MKCOL", &self.base).call(), "MKCOL")?;
        let parts: Vec<&str> = path.split('/').collect();
        for part in &parts[..parts.len().saturating_sub(1)] {
            dir.push_str(part);
            dir.push('/');
            // 405: already exists. Anything else that matters surfaces on the retried PUT.
            status(self.request("MKCOL", &self.url(&dir)).call(), "MKCOL")?;
        }
        Ok(())
    }
}

/// Collapses a response into its status code, turning transport failures into errors.
fn status(result: std::result::Result<ureq::Response, ureq::Error>, what: &str) -> Result<u16> {
    match result {
        Ok(response) => Ok(response.status()),
        Err(ureq::Error::Status(code, _)) => Ok(code),
        Err(e) => Err(AppError::sync(format!("{what}: {e}"))),
    }
}

fn fail(what: &str, path: &str, code: u16) -> AppError {
    let hint = match code {
        401 | 403 => " (check the user name and password)",
        507 => " (the storage is full)",
        _ => "",
    };
    AppError::sync(format!("{what} {path}: HTTP {code}{hint}"))
}

impl Remote for WebDavRemote {
    fn id(&self) -> String {
        self.base.clone()
    }

    fn list(&self, dir: &str) -> Result<Vec<String>> {
        let url = self.url(&format!("{dir}/"));
        let result = self
            .request("PROPFIND", &url)
            .set("Depth", "1")
            .set("Content-Type", "application/xml")
            .send_string(PROPFIND_BODY);
        let response = match result {
            Ok(r) => r,
            Err(ureq::Error::Status(404, _)) => return Ok(vec![]),
            Err(ureq::Error::Status(code, _)) => return Err(fail("PROPFIND", dir, code)),
            Err(e) => return Err(AppError::sync(format!("PROPFIND: {e}"))),
        };
        let body = response
            .into_string()
            .map_err(|e| AppError::sync(format!("PROPFIND: {e}")))?;
        parse_listing(&body)
    }

    fn get(&self, path: &str) -> Result<Option<Vec<u8>>> {
        match self.request("GET", &self.url(path)).call() {
            Ok(response) => {
                let mut data = Vec::new();
                response
                    .into_reader()
                    .take(MAX_BODY)
                    .read_to_end(&mut data)
                    .map_err(|e| AppError::sync(format!("GET {path}: {e}")))?;
                Ok(Some(data))
            }
            Err(ureq::Error::Status(404, _)) => Ok(None),
            Err(ureq::Error::Status(code, _)) => Err(fail("GET", path, code)),
            Err(e) => Err(AppError::sync(format!("GET {path}: {e}"))),
        }
    }

    fn put(&self, path: &str, data: &[u8]) -> Result<()> {
        let send = || status(self.request("PUT", &self.url(path)).send_bytes(data), "PUT");
        let mut code = send()?;
        if matches!(code, 404 | 409) {
            self.make_parents(path)?;
            code = send()?;
        }
        if (200..300).contains(&code) {
            Ok(())
        } else {
            Err(fail("PUT", path, code))
        }
    }

    fn delete(&self, path: &str) -> Result<()> {
        match status(self.request("DELETE", &self.url(path)).call(), "DELETE")? {
            200..=299 | 404 => Ok(()),
            code => Err(fail("DELETE", path, code)),
        }
    }

    fn exists(&self, path: &str) -> Result<bool> {
        match status(self.request("HEAD", &self.url(path)).call(), "HEAD")? {
            200..=299 => Ok(true),
            404 => Ok(false),
            code => Err(fail("HEAD", path, code)),
        }
    }
}

/// File names from a multistatus body. Collections, including the listed one, are skipped.
fn parse_listing(body: &str) -> Result<Vec<String>> {
    let doc = roxmltree::Document::parse(body).map_err(|e| AppError::sync(format!("PROPFIND answer: {e}")))?;
    let mut names = Vec::new();
    for response in doc.descendants().filter(|n| n.tag_name().name() == "response") {
        let is_collection = response.descendants().any(|n| n.tag_name().name() == "collection");
        let href = response
            .descendants()
            .find(|n| n.tag_name().name() == "href")
            .and_then(|n| n.text())
            .unwrap_or("")
            .trim();
        if is_collection || href.ends_with('/') || href.is_empty() {
            continue;
        }
        if let Some(name) = href.rsplit('/').next() {
            names.push(percent_decode(name));
        }
    }
    Ok(names)
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let hex = (bytes[i] == b'%').then(|| s.get(i + 1..i + 3)).flatten();
        match hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
            Some(byte) => {
                out.push(byte);
                i += 3;
            }
            None => {
                out.push(bytes[i]);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn listing_skips_collections_and_decodes_names() {
        let body = r#"<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/dav/lists/v1/log/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
  <d:response><d:href>/dav/lists/v1/log/aaaaaaaaaaaa-0000000001.jsonl</d:href>
    <d:propstat><d:prop><d:resourcetype/></d:prop></d:propstat></d:response>
  <D:response xmlns:D="DAV:"><D:href>http://host/dav/lists/v1/log/a%20b.jsonl</D:href></D:response>
</d:multistatus>"#;
        assert_eq!(
            parse_listing(body).unwrap(),
            vec!["aaaaaaaaaaaa-0000000001.jsonl", "a b.jsonl"]
        );
    }
}
