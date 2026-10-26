//! The browsers that asked for notifications, and what is sent to them. Every browser is one more
//! device with the settings of R36; the core decides what is due, this sends it. Rules: R146–R148
//! in docs/specs/product.md.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use chrono::{DateTime, Duration, Offset, TimeZone, Utc};
use lists_core::{AppError, NotificationKind, NotifySettings, PlannedNotification, Store};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::webpush::{b64, encrypt, origin, unb64, Vapid};

const FILE: &str = "web-push.json";
const KEY_FILE: &str = "web-push-key";
/// R148: no zone is further from UTC than fourteen hours.
const MAX_ZONE_MINUTES: i64 = 14 * 60;
/// A list this long is not one person's browsers; it only bounds the file.
const MAX_BROWSERS: usize = 100;
/// A title longer than this many bytes is cut: push services take at most 4096 bytes of body,
/// the header of RFC 8291 and the escapes of JSON included.
const MAX_TITLE: usize = 1500;
/// A notification that could not reach the browser within this time is of no use.
const TTL_SECONDS: &str = "3600";
/// After a long pause, as a machine that slept, only the last minutes are looked at again.
const LONGEST_WINDOW: Duration = Duration::minutes(10);

#[derive(Clone, Debug, PartialEq)]
struct Browser {
    endpoint: String,
    p256dh: Vec<u8>,
    auth: Vec<u8>,
    /// IANA name, as `Europe/Moscow`; `offset` stands in when the name is unknown here.
    zone: Option<String>,
    offset: i32,
    leads: Vec<u32>,
    all_day: Option<String>,
    summary: Option<String>,
}

impl Browser {
    fn settings(&self) -> NotifySettings {
        NotifySettings {
            enabled: true,
            lead_minutes: self.leads.clone(),
            all_day_at: self.all_day.clone(),
            summary_at: self.summary.clone(),
        }
    }

    fn settings_json(&self) -> Value {
        json!({ "leads": self.leads, "allDay": self.all_day, "summary": self.summary })
    }

    fn to_json(&self) -> Value {
        json!({
            "endpoint": self.endpoint, "p256dh": b64(&self.p256dh), "auth": b64(&self.auth),
            "zone": self.zone, "offset": self.offset,
            "leads": self.leads, "allDay": self.all_day, "summary": self.summary,
        })
    }

    fn from_json(v: &Value) -> Option<Browser> {
        Some(Browser {
            endpoint: v["endpoint"].as_str()?.to_string(),
            p256dh: unb64(v["p256dh"].as_str()?)?,
            auth: unb64(v["auth"].as_str()?)?,
            zone: v["zone"].as_str().map(str::to_string),
            offset: v["offset"].as_i64().unwrap_or(0) as i32,
            leads: leads(&v["leads"])?,
            all_day: clock(&v["allDay"])?,
            summary: clock(&v["summary"])?,
        })
    }

    /// Minutes east of UTC at `now`: by the name of the zone when it is known, so that a change of
    /// daylight saving time is followed without the page (R148).
    fn minutes_east(&self, now: DateTime<Utc>) -> i32 {
        self.zone
            .as_deref()
            .and_then(|name| name.parse::<chrono_tz::Tz>().ok())
            .map(|tz| tz.offset_from_utc_datetime(&now.naive_utc()).fix().local_minus_utc() / 60)
            .unwrap_or(self.offset)
    }
}

/// R36: the leads offered are minutes before a due time; anything up to a week is taken.
fn leads(v: &Value) -> Option<Vec<u32>> {
    let mut out = v
        .as_array()?
        .iter()
        .map(|n| n.as_u64().filter(|n| *n <= 7 * 24 * 60).map(|n| n as u32))
        .collect::<Option<Vec<_>>>()?;
    out.sort_unstable();
    out.dedup();
    Some(out)
}

/// `HH:MM`, or null for off. `None` when the value is neither.
fn clock(v: &Value) -> Option<Option<String>> {
    match v {
        Value::Null => Some(None),
        Value::String(s) if s.is_empty() => Some(None),
        Value::String(s) => chrono::NaiveTime::parse_from_str(s, "%H:%M")
            .ok()
            .map(|t| Some(t.format("%H:%M").to_string())),
        _ => None,
    }
}

fn invalid(msg: &str) -> AppError {
    AppError::Invalid { msg: msg.into() }
}

/// What one delivery came to.
#[derive(Debug, PartialEq)]
pub enum Sent {
    Ok,
    /// The push service no longer knows the subscription (404 or 410): it is dropped (R148).
    Gone,
    Failed(String),
}

pub struct Notifier {
    file: PathBuf,
    vapid: Vapid,
    browsers: Mutex<Vec<Browser>>,
    /// The end of the previous window; `None` until the first look.
    last: Mutex<Option<DateTime<Utc>>>,
    agent: ureq::Agent,
    /// The unit tests deliver to a plain HTTP server on the loopback address.
    #[cfg(test)]
    plain_http: bool,
}

impl Notifier {
    /// The browsers and the key kept in `dir`; both are made there when missing. `subject` is the
    /// contact the push services see in the VAPID token.
    pub fn open(dir: &Path, subject: String) -> Result<Notifier, String> {
        let vapid = Vapid::load_or_create(&dir.join(KEY_FILE), subject)?;
        let file = dir.join(FILE);
        let browsers = match std::fs::read(&file) {
            Ok(bytes) => {
                let v: Value =
                    serde_json::from_slice(&bytes).map_err(|e| format!("cannot read {}: {e}", file.display()))?;
                v["browsers"]
                    .as_array()
                    .map(|a| a.iter().filter_map(Browser::from_json).collect())
                    .unwrap_or_default()
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(format!("cannot read {}: {e}", file.display())),
        };
        Ok(Notifier {
            file,
            vapid,
            browsers: Mutex::new(browsers),
            last: Mutex::new(None),
            agent: ureq::AgentBuilder::new()
                .timeout(std::time::Duration::from_secs(20))
                .build(),
            #[cfg(test)]
            plain_http: false,
        })
    }

    pub fn public_key(&self) -> String {
        self.vapid.public_key()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Browser>> {
        self.browsers.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// The audience of a token for `endpoint`: its origin, which must be `https://`.
    fn audience(&self, endpoint: &str) -> Option<String> {
        #[cfg(test)]
        if self.plain_http {
            if let Some(rest) = endpoint.strip_prefix("http://") {
                return rest.split('/').next().map(|host| format!("http://{host}"));
            }
        }
        origin(endpoint)
    }

    /// R146, R148: takes a subscription from the page, or refreshes its zone. Settings that come
    /// along replace the stored ones; without them a new browser gets the defaults of R146 and a
    /// known one keeps its own, also under a new address that `replaces` the old one. Answers
    /// with the settings in force.
    pub fn subscribe(&self, args: &Value) -> Result<Value, AppError> {
        let endpoint = args["endpoint"].as_str().ok_or_else(|| invalid("no endpoint"))?;
        if endpoint.len() > 2048 || origin(endpoint).is_none() {
            return Err(invalid("the endpoint must be an https:// address"));
        }
        let p256dh = args["keys"]["p256dh"]
            .as_str()
            .and_then(unb64)
            .filter(|k| p256::PublicKey::from_sec1_bytes(k).is_ok() && k.len() == 65)
            .ok_or_else(|| invalid("keys.p256dh is not a P-256 public key"))?;
        let auth = args["keys"]["auth"]
            .as_str()
            .and_then(unb64)
            .filter(|k| k.len() == 16)
            .ok_or_else(|| invalid("keys.auth is not 16 bytes"))?;
        let offset = args["offset"]
            .as_i64()
            .filter(|m| m.abs() <= MAX_ZONE_MINUTES)
            .unwrap_or(0) as i32;
        let zone = args["zone"]
            .as_str()
            .filter(|z| z.len() <= 64 && z.parse::<chrono_tz::Tz>().is_ok())
            .map(str::to_string);
        let settings = &args["settings"];
        let given = if settings.is_null() {
            None
        } else {
            Some((
                leads(&settings["leads"]).ok_or_else(|| invalid("settings.leads"))?,
                clock(&settings["allDay"]).ok_or_else(|| invalid("settings.allDay"))?,
                clock(&settings["summary"]).ok_or_else(|| invalid("settings.summary"))?,
            ))
        };
        let mut browsers = self.lock();
        // The browser replaced its subscription: the new one takes over the settings of the old.
        if let Some(old) = args["replaces"].as_str().filter(|old| *old != endpoint) {
            if let Some(i) = browsers.iter().position(|b| b.endpoint == old) {
                let mut moved = browsers.remove(i);
                browsers.retain(|b| b.endpoint != endpoint);
                moved.endpoint = endpoint.to_string();
                browsers.push(moved);
            }
        }
        let known = browsers.iter().position(|b| b.endpoint == endpoint);
        let mut browser = match known {
            Some(i) => browsers[i].clone(),
            None if browsers.len() >= MAX_BROWSERS => return Err(invalid("too many browsers")),
            None => Browser {
                endpoint: endpoint.to_string(),
                p256dh: Vec::new(),
                auth: Vec::new(),
                zone: None,
                offset: 0,
                leads: vec![0],
                all_day: Some("09:00".into()),
                summary: None,
            },
        };
        browser.p256dh = p256dh;
        browser.auth = auth;
        browser.zone = zone;
        browser.offset = offset;
        if let Some((leads, all_day, summary)) = given {
            (browser.leads, browser.all_day, browser.summary) = (leads, all_day, summary);
        }
        let answer = browser.settings_json();
        match known {
            Some(i) => browsers[i] = browser,
            None => browsers.push(browser),
        }
        self.save(&browsers)?;
        Ok(answer)
    }

    /// R148: the browser turned notifications off or signed out. True when it was known.
    pub fn unsubscribe(&self, endpoint: &str) -> Result<bool, AppError> {
        let mut browsers = self.lock();
        let before = browsers.len();
        browsers.retain(|b| b.endpoint != endpoint);
        if browsers.len() == before {
            return Ok(false);
        }
        self.save(&browsers)?;
        Ok(true)
    }

    /// R147: one notification to this browser now, whatever is due.
    pub fn test(&self, endpoint: &str, now: DateTime<Utc>) -> Option<Sent> {
        let browser = self.lock().iter().find(|b| b.endpoint == endpoint).cloned()?;
        let sent = self.send(&browser, &json!({ "key": "test", "kind": "test" }), now);
        if sent == Sent::Gone {
            self.drop_gone(&[browser.endpoint]);
        }
        Some(sent)
    }

    /// R146: sends what came due since the previous look, to each browser in its own zone. The
    /// first look only marks the start: nothing that came due before it is sent.
    pub fn tick(&self, store: &Store, now: DateTime<Utc>) {
        let since = {
            let mut last = self.last.lock().unwrap_or_else(|p| p.into_inner());
            let since = last.unwrap_or(now).max(now - LONGEST_WINDOW);
            *last = Some(now);
            since
        };
        if since >= now {
            return;
        }
        let browsers = self.lock().clone();
        let mut gone = Vec::new();
        for browser in &browsers {
            let minutes = browser.minutes_east(now);
            let local = |at: DateTime<Utc>| (at + Duration::minutes(i64::from(minutes))).naive_utc();
            let (from, until) = (
                local(since).format("%Y-%m-%dT%H:%M:%S").to_string(),
                local(now).format("%Y-%m-%dT%H:%M:%S").to_string(),
            );
            let due = store.in_zone(minutes, || store.due_notifications(browser.settings(), &from, &until));
            let due = match due {
                Ok(due) => due,
                Err(e) => {
                    eprintln!("lists-web: notifications not planned: {e}");
                    return;
                }
            };
            for n in &due {
                match self.send(browser, &payload(n), now) {
                    Sent::Ok => {}
                    Sent::Gone => {
                        gone.push(browser.endpoint.clone());
                        break;
                    }
                    Sent::Failed(e) => eprintln!(
                        "lists-web: a notification to {} was not sent: {e}",
                        origin(&browser.endpoint).unwrap_or_default()
                    ),
                }
            }
        }
        self.drop_gone(&gone);
    }

    fn drop_gone(&self, gone: &[String]) {
        if gone.is_empty() {
            return;
        }
        let mut browsers = self.lock();
        browsers.retain(|b| !gone.contains(&b.endpoint));
        if let Err(e) = self.save(&browsers) {
            eprintln!("lists-web: {e}");
        }
    }

    fn send(&self, browser: &Browser, payload: &Value, now: DateTime<Utc>) -> Sent {
        let Some(audience) = self.audience(&browser.endpoint) else {
            return Sent::Failed("the endpoint is not an https:// address".into());
        };
        let body = match encrypt(&browser.p256dh, &browser.auth, payload.to_string().as_bytes()) {
            Ok(body) => body,
            Err(e) => return Sent::Failed(e),
        };
        let authorization = self.vapid.authorization(&audience, now.timestamp().max(0) as u64);
        // A later message of the same key replaces one the push service still holds.
        let key = payload["key"].as_str().unwrap_or_default();
        let topic = b64(&Sha256::digest(key.as_bytes()))[..32].to_string();
        let result = self
            .agent
            .post(&browser.endpoint)
            .set("TTL", TTL_SECONDS)
            .set("Urgency", "high")
            .set("Topic", &topic)
            .set("Content-Encoding", "aes128gcm")
            .set("Content-Type", "application/octet-stream")
            .set("Authorization", &authorization)
            .send_bytes(&body);
        match result {
            Ok(_) => Sent::Ok,
            Err(ureq::Error::Status(404 | 410, _)) => Sent::Gone,
            Err(ureq::Error::Status(code, response)) => {
                let text: String = response.into_string().unwrap_or_default().chars().take(200).collect();
                Sent::Failed(format!("{code} {text}"))
            }
            // The message of the error names the endpoint, which is the secret of the subscription.
            Err(ureq::Error::Transport(t)) => Sent::Failed(format!("the push service cannot be reached: {}", t.kind())),
        }
    }

    /// The list goes to a new file that replaces the old one, readable by its owner only: it holds
    /// the addresses and the secrets of the subscriptions.
    fn save(&self, browsers: &[Browser]) -> Result<(), AppError> {
        let text = json!({ "browsers": browsers.iter().map(Browser::to_json).collect::<Vec<_>>() }).to_string();
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

/// What the service worker gets: the facts, not the text. The text is made when the notification
/// is shown, so that the day of the due date is named as it is then (R36, #280).
fn payload(n: &PlannedNotification) -> Value {
    let kind = match n.kind {
        NotificationKind::Reminder => "reminder",
        NotificationKind::Due => "due",
        NotificationKind::Summary => "summary",
    };
    let mut end = n.title.len().min(MAX_TITLE);
    while !n.title.is_char_boundary(end) {
        end -= 1;
    }
    let title = &n.title[..end];
    json!({ "key": n.key, "kind": kind, "title": title, "due": n.due, "task": n.task_id, "count": n.count })
}

#[cfg(test)]
mod tests {
    use super::*;
    use lists_core::NewTask;
    use p256::elliptic_curve::sec1::ToSec1Point;
    use p256::elliptic_curve::Generate;
    use p256::SecretKey;
    use std::sync::Arc;

    /// One request the push service got: the path, the body and the headers.
    type Received = (String, Vec<u8>, Vec<(String, String)>);

    /// A push service on the loopback address: keeps what it got, answers with `status`.
    struct Service {
        url: String,
        got: Arc<Mutex<Vec<Received>>>,
        status: Arc<Mutex<u16>>,
    }

    fn service() -> Service {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let url = format!("http://{}/push/one", server.server_addr().to_ip().unwrap());
        let got = Arc::new(Mutex::new(Vec::new()));
        let status = Arc::new(Mutex::new(201u16));
        let (g, s) = (got.clone(), status.clone());
        std::thread::spawn(move || {
            while let Ok(mut request) = server.recv() {
                let mut body = Vec::new();
                std::io::Read::read_to_end(request.as_reader(), &mut body).unwrap();
                let headers = request
                    .headers()
                    .iter()
                    .map(|h| (h.field.to_string(), h.value.to_string()))
                    .collect();
                g.lock().unwrap().push((request.url().to_string(), body, headers));
                let code = *s.lock().unwrap();
                let _ = request.respond(tiny_http::Response::empty(code));
            }
        });
        Service { url, got, status }
    }

    struct Client {
        key: SecretKey,
        auth: [u8; 16],
    }

    impl Client {
        fn new() -> Client {
            Client {
                key: SecretKey::generate(),
                auth: [9; 16],
            }
        }

        fn subscription(&self, endpoint: &str, zone: &str, offset: i32) -> Value {
            json!({
                "endpoint": endpoint,
                "keys": { "p256dh": b64(self.key.public_key().to_sec1_point(false).as_bytes()), "auth": b64(&self.auth) },
                "zone": zone, "offset": offset,
            })
        }

        fn read(&self, body: &[u8]) -> Value {
            serde_json::from_slice(&crate::webpush::decrypt(&self.key, &self.auth, body).unwrap()).unwrap()
        }
    }

    fn at(utc: &str) -> DateTime<Utc> {
        chrono::NaiveDateTime::parse_from_str(utc, "%Y-%m-%dT%H:%M:%S")
            .unwrap()
            .and_utc()
    }

    struct Setup {
        store: Arc<Store>,
        notifier: Notifier,
        dir: tempfile::TempDir,
    }

    fn setup() -> Setup {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path().join("data").to_string_lossy().into_owned()).unwrap();
        let mut notifier = Notifier::open(dir.path(), "mailto:me@example.org".into()).unwrap();
        notifier.plain_http = true;
        Setup { store, notifier, dir }
    }

    /// Subscribes with `subscribe`, which refuses http://, and then points the browser at `url`.
    fn subscribe(s: &Setup, browser: &Client, url: &str, zone: &str, offset: i32) {
        s.notifier
            .subscribe(&browser.subscription("https://push.example.net/x", zone, offset))
            .unwrap();
        s.notifier.lock()[0].endpoint = url.to_string();
    }

    fn task(store: &Store, title: &str, due: Option<&str>, remind: Option<&str>) {
        let t = store
            .create_task(NewTask {
                title: title.into(),
                due: due.map(str::to_string),
                ..NewTask::default()
            })
            .unwrap();
        if let Some(r) = remind {
            store.set_remind(t.id, Some(r.into())).unwrap();
        }
    }

    /// Advances both clocks to `utc` and looks.
    fn tick(s: &Setup, utc: &str) {
        s.store.set_now_for_tests(utc);
        s.notifier.tick(&s.store, at(utc));
    }

    #[test]
    fn r146_each_notification_comes_once_at_its_minute() {
        let s = setup();
        let push = service();
        let browser = Client::new();
        // UTC+3, by the offset alone.
        subscribe(&s, &browser, &push.url, "", 180);
        task(&s.store, "а", None, Some("2026-10-05T10:01"));
        task(&s.store, "б", Some("2026-10-05T10:02"), None);
        task(&s.store, "в", Some("2026-10-06"), None);

        tick(&s, "2026-10-05T07:00:40"); // 10:00:40 in the zone: the first look sends nothing
        assert!(push.got.lock().unwrap().is_empty());
        tick(&s, "2026-10-05T07:01:10");
        tick(&s, "2026-10-05T07:01:40");
        tick(&s, "2026-10-05T07:02:10");
        tick(&s, "2026-10-06T05:59:50");
        tick(&s, "2026-10-06T06:00:20");
        let got = push.got.lock().unwrap();
        let read: Vec<Value> = got.iter().map(|(_, body, _)| browser.read(body)).collect();
        assert_eq!(
            read.iter()
                .map(|v| (v["kind"].as_str().unwrap(), v["title"].as_str().unwrap()))
                .collect::<Vec<_>>(),
            [("reminder", "а"), ("due", "б"), ("due", "в")]
        );
        assert_eq!(read[1]["due"], "2026-10-05T10:02");
        assert!(read[0]["task"].is_string());

        let headers = &got[0].2;
        let header = |name: &str| {
            headers
                .iter()
                .find(|(n, _)| n.eq_ignore_ascii_case(name))
                .map(|(_, v)| v.clone())
                .unwrap_or_default()
        };
        assert_eq!(header("Content-Encoding"), "aes128gcm");
        assert_eq!(header("TTL"), TTL_SECONDS);
        assert!(header("Authorization").starts_with("vapid t="));
        assert!(header("Authorization").ends_with(&format!("k={}", s.notifier.public_key())));
        assert_eq!(header("Topic").len(), 32);
    }

    #[test]
    fn r146_settings_of_the_browser_decide() {
        let s = setup();
        let push = service();
        let browser = Client::new();
        subscribe(&s, &browser, &push.url, "", 0);
        let mut sub = browser.subscription("https://push.example.net/x", "", 0);
        sub["settings"] = json!({ "leads": [15, 0], "allDay": null, "summary": "08:00" });
        // The endpoint differs from the one the browser now has: point it back after this.
        assert_eq!(
            s.notifier.subscribe(&sub).unwrap(),
            json!({ "leads": [0, 15], "allDay": null, "summary": "08:00" })
        );
        s.notifier.lock().retain(|b| b.endpoint == "https://push.example.net/x");
        s.notifier.lock()[0].endpoint = push.url.clone();
        task(&s.store, "г", Some("2026-10-05T11:00"), None);
        task(&s.store, "д", Some("2026-10-05"), None);

        tick(&s, "2026-10-05T07:59:50");
        tick(&s, "2026-10-05T08:00:20");
        tick(&s, "2026-10-05T10:44:50");
        tick(&s, "2026-10-05T10:45:20");
        tick(&s, "2026-10-05T10:59:50");
        tick(&s, "2026-10-05T11:00:20");
        let read: Vec<Value> = push
            .got
            .lock()
            .unwrap()
            .iter()
            .map(|(_, b, _)| browser.read(b))
            .collect();
        assert_eq!(
            read.iter()
                .map(|v| (
                    v["kind"].as_str().unwrap().to_string(),
                    v["title"].as_str().unwrap().to_string(),
                    v["count"].as_u64().unwrap()
                ))
                .collect::<Vec<_>>(),
            [
                ("summary".to_string(), String::new(), 2),
                ("due".to_string(), "г".to_string(), 0),
                ("due".to_string(), "г".to_string(), 0),
            ],
            "no notification at nine for the task due on the day: that setting is off"
        );
    }

    #[test]
    fn r148_the_zone_name_follows_daylight_saving_time() {
        let s = setup();
        let push = service();
        let browser = Client::new();
        // Subscribed in summer, at +2; on 26 October Berlin is at +1.
        subscribe(&s, &browser, &push.url, "Europe/Berlin", 120);
        task(&s.store, "после перевода", None, Some("2026-10-26T10:00"));
        tick(&s, "2026-10-26T08:59:50");
        tick(&s, "2026-10-26T09:00:20");
        let got = push.got.lock().unwrap();
        assert_eq!(got.len(), 1, "10:00 in Berlin is 09:00 UTC in winter");
        assert_eq!(browser.read(&got[0].1)["title"], "после перевода");
    }

    #[test]
    fn r148_a_subscription_the_service_forgot_is_dropped() {
        let s = setup();
        let push = service();
        let browser = Client::new();
        subscribe(&s, &browser, &push.url, "", 0);
        *push.status.lock().unwrap() = 410;
        assert_eq!(s.notifier.test(&push.url, at("2026-10-05T10:00:00")), Some(Sent::Gone));
        assert!(s.notifier.lock().is_empty());
        let kept: Value = serde_json::from_slice(&std::fs::read(s.dir.path().join(FILE)).unwrap()).unwrap();
        assert_eq!(kept["browsers"], json!([]), "and from the file");
        assert_eq!(s.notifier.test(&push.url, at("2026-10-05T10:00:00")), None);
    }

    #[test]
    fn r147_a_test_notification_and_a_failure() {
        let s = setup();
        let push = service();
        let browser = Client::new();
        subscribe(&s, &browser, &push.url, "", 0);
        assert_eq!(s.notifier.test(&push.url, at("2026-10-05T10:00:00")), Some(Sent::Ok));
        assert_eq!(browser.read(&push.got.lock().unwrap()[0].1)["kind"], "test");
        *push.status.lock().unwrap() = 500;
        assert!(matches!(
            s.notifier.test(&push.url, at("2026-10-05T10:00:00")),
            Some(Sent::Failed(_))
        ));
        assert_eq!(s.notifier.lock().len(), 1, "a failure keeps the subscription");
        // Nothing listens on port 1; the page shows the error, which must not give the address away.
        s.notifier.lock()[0].endpoint = "http://127.0.0.1:1/push/secret-token".into();
        match s
            .notifier
            .test("http://127.0.0.1:1/push/secret-token", at("2026-10-05T10:00:00"))
        {
            Some(Sent::Failed(e)) => assert!(!e.contains("secret-token"), "{e}"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn r146_a_long_title_still_fits_a_push_message() {
        let n = PlannedNotification {
            key: "task:x".into(),
            kind: NotificationKind::Reminder,
            at: "2026-10-05T10:00".into(),
            task_id: Some("x".repeat(36)),
            title: "\"😀".repeat(2000),
            due: Some("2026-10-05T10:00".into()),
            count: 0,
        };
        let plain = payload(&n).to_string();
        let browser = Client::new();
        let public = browser.key.public_key().to_sec1_point(false);
        let body = encrypt(public.as_bytes(), &browser.auth, plain.as_bytes()).unwrap();
        assert!(body.len() <= 4096, "{}", body.len());
        assert!(browser.read(&body)["title"].as_str().unwrap().starts_with("\"😀"));
    }

    #[test]
    fn r148_subscriptions_are_checked_kept_and_dropped() {
        let s = setup();
        let browser = Client::new();
        let good = browser.subscription("https://push.example.net/a", "Europe/Moscow", 180);
        assert_eq!(
            s.notifier.subscribe(&good).unwrap(),
            json!({ "leads": [0], "allDay": "09:00", "summary": null }),
            "the defaults of R146"
        );
        let mut changed = good.clone();
        changed["settings"] = json!({ "leads": [60], "allDay": "08:30", "summary": "" });
        s.notifier.subscribe(&changed).unwrap();
        assert_eq!(
            s.notifier.subscribe(&good).unwrap(),
            json!({ "leads": [60], "allDay": "08:30", "summary": null }),
            "a refresh without settings keeps them"
        );

        let mut bad = good.clone();
        bad["endpoint"] = json!("http://push.example.net/a");
        assert!(s.notifier.subscribe(&bad).is_err());
        let mut bad = good.clone();
        bad["keys"]["auth"] = json!("AAAA");
        assert!(s.notifier.subscribe(&bad).is_err());
        let mut bad = good.clone();
        bad["keys"]["p256dh"] = json!(b64(&[4; 65]));
        assert!(s.notifier.subscribe(&bad).is_err());
        let mut bad = good.clone();
        bad["settings"] = json!({ "leads": [0], "allDay": "25:00", "summary": null });
        assert!(s.notifier.subscribe(&bad).is_err());

        // A restart reads the same list back.
        let again = Notifier::open(s.dir.path(), String::new()).unwrap();
        assert_eq!(*again.lock(), *s.notifier.lock());
        assert_eq!(again.public_key(), s.notifier.public_key());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(s.dir.path().join(FILE)).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }

        let mut renewed = browser.subscription("https://push.example.net/b", "Europe/Moscow", 180);
        renewed["replaces"] = json!("https://push.example.net/a");
        assert_eq!(
            s.notifier.subscribe(&renewed).unwrap(),
            json!({ "leads": [60], "allDay": "08:30", "summary": null }),
            "a renewed subscription keeps the settings"
        );
        assert_eq!(s.notifier.lock().len(), 1, "and the old address is gone");

        assert!(s.notifier.unsubscribe("https://push.example.net/b").unwrap());
        assert!(!s.notifier.unsubscribe("https://push.example.net/b").unwrap());
        assert!(s.notifier.lock().is_empty());
    }
}
