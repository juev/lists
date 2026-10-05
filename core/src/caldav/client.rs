//! The handful of CalDAV requests the engine needs.

use std::io::Read;
use std::time::Duration;

use base64::Engine;

use crate::error::{AppError, Result};

/// Namespace of the collection property that carries list settings.
pub const NS: &str = "https://evsyukov.org/ns/lists";

const DAV: &str = "DAV:";
const CALDAV: &str = "urn:ietf:params:xml:ns:caldav";
const APPLE: &str = "http://apple.com/ns/ical/";
/// One object with an inline attachment stays far below this.
const MAX_BODY: u64 = 32 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq)]
pub struct Calendar {
    /// Absolute path on the server, ending in `/`.
    pub href: String,
    pub name: String,
    pub color: String,
    /// Raw value of the app's own property, when the server keeps one.
    pub state: Option<String>,
    /// Saved filters, kept on the inbox calendar the same way.
    pub filters: Option<String>,
}

pub enum Condition<'a> {
    /// The object must not exist yet.
    New,
    /// The object must still have this ETag.
    Match(&'a str),
    None,
}

pub enum Written {
    /// The new ETag, when the server reports one.
    Done(Option<String>),
    /// The object changed (or appeared) since it was last read.
    Conflict,
}

pub struct Client {
    agent: ureq::Agent,
    /// `scheme://host[:port]`
    origin: String,
    /// Path of the collection that holds the calendars.
    home: String,
    auth: Option<String>,
}

struct Response {
    href: String,
    collection: bool,
    calendar: bool,
    todo: bool,
    name: String,
    color: String,
    state: Option<String>,
    filters: Option<String>,
    etag: String,
    home: Option<String>,
    principal: Option<String>,
}

fn xml_escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

fn split_url(url: &str) -> Result<(String, String)> {
    let url = url.trim();
    let scheme_end = url
        .find("://")
        .ok_or_else(|| AppError::sync("the address must start with https:// or http://"))?;
    if !matches!(&url[..scheme_end], "http" | "https") {
        return Err(AppError::sync("the address must start with https:// or http://"));
    }
    let rest = &url[scheme_end + 3..];
    let (host, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    if host.is_empty() {
        return Err(AppError::sync("the address has no host"));
    }
    Ok((format!("{}://{}", &url[..scheme_end], host), dir(path)))
}

fn dir(path: &str) -> String {
    if path.ends_with('/') {
        path.to_string()
    } else {
        format!("{path}/")
    }
}

impl Client {
    /// Checks the address without touching the network.
    pub fn validate(url: &str) -> Result<()> {
        split_url(url).map(|_| ())
    }

    /// Connects and finds the collection of calendars: the address itself, or
    /// the calendar home the server names for it or for its principal.
    pub fn connect(url: &str, user: &str, password: &str) -> Result<Client> {
        let (origin, path) = split_url(url)?;
        let auth = (!user.is_empty()).then(|| {
            format!(
                "Basic {}",
                base64::engine::general_purpose::STANDARD.encode(format!("{user}:{password}"))
            )
        });
        let mut client = Client {
            agent: ureq::AgentBuilder::new()
                .timeout_connect(Duration::from_secs(15))
                .timeout(Duration::from_secs(120))
                .build(),
            origin,
            home: path.clone(),
            auth,
        };
        let body = format!(
            r#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="{DAV}" xmlns:c="{CALDAV}"><d:prop><d:current-user-principal/><c:calendar-home-set/></d:prop></d:propfind>"#
        );
        let found = client.propfind(&path, "0", &body)?.unwrap_or_default();
        let own = found.first();
        if let Some(home) = own.and_then(|r| r.home.clone()) {
            client.home = home;
        } else if let Some(principal) = own.and_then(|r| r.principal.clone()) {
            let again = client.propfind(&principal, "0", &body)?.unwrap_or_default();
            if let Some(home) = again.first().and_then(|r| r.home.clone()) {
                client.home = home;
            }
        }
        Ok(client)
    }

    fn request(&self, method: &str, path: &str) -> ureq::Request {
        let request = self.agent.request(method, &format!("{}{}", self.origin, path));
        match &self.auth {
            Some(auth) => request.set("Authorization", auth),
            None => request,
        }
    }

    fn failure(&self, what: &str, path: &str, error: ureq::Error) -> AppError {
        match error {
            ureq::Error::Status(code, _) => {
                let hint = match code {
                    401 | 403 => " (check the user name and password)",
                    507 => " (the storage is full)",
                    _ => "",
                };
                AppError::sync(format!("{what} {path}: HTTP {code}{hint}"))
            }
            other => AppError::sync(format!("{what}: {other}")),
        }
    }

    /// `None` when the collection does not exist.
    fn propfind(&self, path: &str, depth: &str, body: &str) -> Result<Option<Vec<Response>>> {
        let result = self
            .request("PROPFIND", path)
            .set("Depth", depth)
            .set("Content-Type", "application/xml; charset=utf-8")
            .send_string(body);
        let response = match result {
            Ok(r) => r,
            Err(ureq::Error::Status(404, _)) => return Ok(None),
            Err(e) => return Err(self.failure("PROPFIND", path, e)),
        };
        let text = response
            .into_string()
            .map_err(|e| AppError::sync(format!("PROPFIND: {e}")))?;
        Ok(Some(parse_multistatus(&text)?))
    }

    /// Calendars that accept tasks.
    pub fn calendars(&self) -> Result<Vec<Calendar>> {
        let body = format!(
            r#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="{DAV}" xmlns:c="{CALDAV}" xmlns:a="{APPLE}" xmlns:l="{NS}"><d:prop><d:resourcetype/><d:displayname/><a:calendar-color/><c:supported-calendar-component-set/><l:state/><l:filters/></d:prop></d:propfind>"#
        );
        let responses = self
            .propfind(&self.home, "1", &body)?
            .ok_or_else(|| AppError::sync(format!("{} does not exist on the server", self.home)))?;
        Ok(responses
            .into_iter()
            .filter(|r| r.calendar && r.todo && dir(&r.href) != self.home)
            .map(|r| Calendar {
                href: dir(&r.href),
                name: r.name,
                color: r.color,
                state: r.state,
                filters: r.filters,
            })
            .collect())
    }

    /// Creates a calendar for tasks under the home collection and returns its path.
    pub fn make_calendar(&self, slug: &str, name: &str, color: &str) -> Result<String> {
        let href = format!("{}{}/", self.home, slug);
        let color = if color.is_empty() {
            String::new()
        } else {
            format!("<a:calendar-color>{}</a:calendar-color>", xml_escape(color))
        };
        let body = format!(
            r#"<?xml version="1.0" encoding="utf-8"?><c:mkcalendar xmlns:d="{DAV}" xmlns:c="{CALDAV}" xmlns:a="{APPLE}"><d:set><d:prop><d:displayname>{}</d:displayname>{color}<c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set></d:prop></d:set></c:mkcalendar>"#,
            xml_escape(name)
        );
        self.request("MKCALENDAR", &href)
            .set("Content-Type", "application/xml; charset=utf-8")
            .send_string(&body)
            .map_err(|e| self.failure("MKCALENDAR", &href, e))?;
        Ok(href)
    }

    /// Sets the name and colour. The app's own property goes in a separate
    /// request: a server that refuses it must not block the standard ones.
    pub fn set_props(&self, href: &str, name: &str, color: &str, state: Option<&str>) -> Result<()> {
        let color = if color.is_empty() {
            String::new()
        } else {
            format!("<a:calendar-color>{}</a:calendar-color>", xml_escape(color))
        };
        let standard = format!(
            r#"<?xml version="1.0" encoding="utf-8"?><d:propertyupdate xmlns:d="{DAV}" xmlns:a="{APPLE}"><d:set><d:prop><d:displayname>{}</d:displayname>{color}</d:prop></d:set></d:propertyupdate>"#,
            xml_escape(name)
        );
        self.request("PROPPATCH", href)
            .set("Content-Type", "application/xml; charset=utf-8")
            .send_string(&standard)
            .map_err(|e| self.failure("PROPPATCH", href, e))?;
        if let Some(state) = state {
            let own = format!(
                r#"<?xml version="1.0" encoding="utf-8"?><d:propertyupdate xmlns:d="{DAV}" xmlns:l="{NS}"><d:set><d:prop><l:state>{}</l:state></d:prop></d:set></d:propertyupdate>"#,
                xml_escape(state)
            );
            // Best effort by design: see C1 in docs/specs/caldav.md.
            let _ = self
                .request("PROPPATCH", href)
                .set("Content-Type", "application/xml; charset=utf-8")
                .send_string(&own);
        }
        Ok(())
    }

    /// Stores the saved filters on a calendar. Best effort, like the list settings.
    pub fn set_filters(&self, href: &str, value: &str) {
        let body = format!(
            r#"<?xml version="1.0" encoding="utf-8"?><d:propertyupdate xmlns:d="{DAV}" xmlns:l="{NS}"><d:set><d:prop><l:filters>{}</l:filters></d:prop></d:set></d:propertyupdate>"#,
            xml_escape(value)
        );
        let _ = self
            .request("PROPPATCH", href)
            .set("Content-Type", "application/xml; charset=utf-8")
            .send_string(&body);
    }

    /// Objects in a calendar with their ETags.
    pub fn list(&self, calendar: &str) -> Result<Vec<(String, String)>> {
        let body = format!(
            r#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="{DAV}"><d:prop><d:resourcetype/><d:getetag/></d:prop></d:propfind>"#
        );
        let responses = self
            .propfind(calendar, "1", &body)?
            .ok_or_else(|| AppError::sync(format!("{calendar} does not exist on the server")))?;
        Ok(responses
            .into_iter()
            .filter(|r| !r.collection && !r.href.ends_with('/'))
            .map(|r| (r.href, r.etag))
            .collect())
    }

    pub fn get(&self, href: &str) -> Result<Option<(String, String)>> {
        match self.request("GET", href).call() {
            Ok(response) => {
                let etag = response.header("ETag").unwrap_or_default().to_string();
                let mut text = String::new();
                response
                    .into_reader()
                    .take(MAX_BODY)
                    .read_to_string(&mut text)
                    .map_err(|e| AppError::sync(format!("GET {href}: {e}")))?;
                Ok(Some((text, etag)))
            }
            Err(ureq::Error::Status(404, _)) => Ok(None),
            Err(e) => Err(self.failure("GET", href, e)),
        }
    }

    pub fn put(&self, href: &str, body: &str, condition: Condition) -> Result<Written> {
        let request = self
            .request("PUT", href)
            .set("Content-Type", "text/calendar; charset=utf-8");
        let request = match condition {
            Condition::New => request.set("If-None-Match", "*"),
            Condition::Match(etag) => request.set("If-Match", etag),
            Condition::None => request,
        };
        match request.send_string(body) {
            Ok(response) => Ok(Written::Done(response.header("ETag").map(str::to_string))),
            Err(ureq::Error::Status(412, _)) => Ok(Written::Conflict),
            Err(e) => Err(self.failure("PUT", href, e)),
        }
    }

    /// Returns false when the object changed since it was read and was left in place.
    pub fn delete(&self, href: &str, etag: Option<&str>) -> Result<bool> {
        let request = self.request("DELETE", href);
        let request = match etag.filter(|e| !e.is_empty()) {
            Some(etag) => request.set("If-Match", etag),
            None => request,
        };
        match request.call() {
            Ok(_) | Err(ureq::Error::Status(404, _)) => Ok(true),
            Err(ureq::Error::Status(412, _)) => Ok(false),
            Err(e) => Err(self.failure("DELETE", href, e)),
        }
    }
}

/// Reduces an href to a path: servers answer with either form.
fn path_of(href: &str) -> String {
    let href = href.trim();
    match href.find("://") {
        Some(i) => href[i + 3..]
            .find('/')
            .map_or("/".to_string(), |j| href[i + 3 + j..].to_string()),
        None => href.to_string(),
    }
}

fn parse_multistatus(text: &str) -> Result<Vec<Response>> {
    let doc =
        roxmltree::Document::parse(text).map_err(|e| AppError::sync(format!("the server's answer is not XML: {e}")))?;
    let is =
        |n: &roxmltree::Node, ns: &str, name: &str| n.tag_name().name() == name && n.tag_name().namespace() == Some(ns);
    let mut out = Vec::new();
    for response in doc.descendants().filter(|n| is(n, DAV, "response")) {
        let href = response
            .children()
            .find(|n| is(n, DAV, "href"))
            .and_then(|n| n.text())
            .map(path_of)
            .unwrap_or_default();
        let mut r = Response {
            href,
            collection: false,
            calendar: false,
            // A server that does not say which components it takes is assumed to take tasks.
            todo: true,
            name: String::new(),
            color: String::new(),
            state: None,
            filters: None,
            etag: String::new(),
            home: None,
            principal: None,
        };
        for propstat in response.children().filter(|n| is(n, DAV, "propstat")) {
            let ok = propstat
                .children()
                .find(|n| is(n, DAV, "status"))
                .and_then(|n| n.text())
                .is_none_or(|s| s.contains(" 200"));
            if !ok {
                continue;
            }
            for prop in propstat
                .children()
                .filter(|n| is(n, DAV, "prop"))
                .flat_map(|p| p.children())
                .filter(|n| n.is_element())
            {
                let text = || prop.text().unwrap_or_default().trim().to_string();
                let inner_href = || {
                    prop.descendants()
                        .find(|n| is(n, DAV, "href"))
                        .and_then(|n| n.text())
                        .map(|h| dir(&path_of(h)))
                };
                if is(&prop, DAV, "resourcetype") {
                    r.collection = prop.children().any(|n| is(&n, DAV, "collection"));
                    r.calendar = prop.children().any(|n| is(&n, CALDAV, "calendar"));
                } else if is(&prop, DAV, "displayname") {
                    r.name = text();
                } else if is(&prop, APPLE, "calendar-color") {
                    r.color = text();
                } else if is(&prop, CALDAV, "supported-calendar-component-set") {
                    r.todo = prop
                        .children()
                        .any(|n| n.attribute("name").is_some_and(|c| c.eq_ignore_ascii_case("VTODO")));
                } else if is(&prop, NS, "state") {
                    r.state = Some(text()).filter(|s| !s.is_empty());
                } else if is(&prop, NS, "filters") {
                    r.filters = Some(text()).filter(|s| !s.is_empty());
                } else if is(&prop, DAV, "getetag") {
                    r.etag = text();
                } else if is(&prop, CALDAV, "calendar-home-set") {
                    r.home = inner_href();
                } else if is(&prop, DAV, "current-user-principal") {
                    r.principal = inner_href();
                }
            }
        }
        out.push(r);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addresses() {
        assert_eq!(
            split_url("https://cloud.example.org/remote.php/dav/calendars/me").unwrap(),
            (
                "https://cloud.example.org".into(),
                "/remote.php/dav/calendars/me/".into()
            )
        );
        assert_eq!(
            split_url("http://10.0.2.2:8765").unwrap(),
            ("http://10.0.2.2:8765".into(), "/".into())
        );
        assert!(split_url("ftp://x/").is_err());
        assert!(split_url("cloud.example.org").is_err());
    }

    #[test]
    fn multistatus_as_nextcloud_writes_it() {
        let xml = r##"<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:x1="http://apple.com/ns/ical/" xmlns:l="https://evsyukov.org/ns/lists">
 <d:response><d:href>/remote.php/dav/calendars/me/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  <d:propstat><d:prop><d:displayname/><x1:calendar-color/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
 <d:response><d:href>https://cloud.example.org/remote.php/dav/calendars/me/tasks</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/><cal:calendar/></d:resourcetype><d:displayname>Дела</d:displayname>
   <x1:calendar-color>#FF0000FF</x1:calendar-color>
   <cal:supported-calendar-component-set><cal:comp name="VEVENT"/><cal:comp name="VTODO"/></cal:supported-calendar-component-set>
   <l:state>abc</l:state></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/calendars/me/events/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>
   <cal:supported-calendar-component-set><cal:comp name="VEVENT"/></cal:supported-calendar-component-set></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>"##;
        let parsed = parse_multistatus(xml).unwrap();
        assert_eq!(parsed.len(), 3);
        assert!(!parsed[0].calendar && parsed[0].name.is_empty());
        let tasks = &parsed[1];
        assert_eq!(tasks.href, "/remote.php/dav/calendars/me/tasks");
        assert!(tasks.calendar && tasks.todo);
        assert_eq!(
            (tasks.name.as_str(), tasks.color.as_str(), tasks.state.as_deref()),
            ("Дела", "#FF0000FF", Some("abc"))
        );
        assert!(
            parsed[2].calendar && !parsed[2].todo,
            "a calendar for events only is not a list"
        );
    }
}
