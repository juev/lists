//! Sign-in through OpenID Connect against a provider played by a small HTTP server.

use std::sync::{Arc, Mutex};

use base64::Engine;
use lists_core::SyncConfig;
use lists_web::{start, Config, OidcConfig};
use serde_json::{json, Value};
use tiny_http::{Header, Response, Server};

/// What the provider will put into the next ID token.
#[derive(Clone)]
struct Identity {
    email: String,
    verified: bool,
    nonce: Option<String>,
    audience: String,
    expires_in: i64,
}

struct Provider {
    issuer: String,
    identity: Arc<Mutex<Identity>>,
    /// Form bodies the token endpoint received.
    seen: Arc<Mutex<Vec<String>>>,
}

fn provider() -> Provider {
    let server = Server::http("127.0.0.1:0").unwrap();
    let issuer = format!("http://127.0.0.1:{}", server.server_addr().to_ip().unwrap().port());
    let identity = Arc::new(Mutex::new(Identity {
        email: "me@example.org".into(),
        verified: true,
        nonce: None,
        audience: "lists".into(),
        expires_in: 300,
    }));
    let seen = Arc::new(Mutex::new(Vec::new()));
    let (iss, who, log) = (issuer.clone(), identity.clone(), seen.clone());
    std::thread::spawn(move || {
        for mut request in server.incoming_requests() {
            let json_header = Header::from_bytes("Content-Type", "application/json").unwrap();
            let body = match request.url().split('?').next().unwrap() {
                "/.well-known/openid-configuration" => {
                    json!({ "issuer": iss, "authorization_endpoint": format!("{iss}/authorize"), "token_endpoint": format!("{iss}/token") })
                }
                "/token" => {
                    let mut form = String::new();
                    request.as_reader().read_to_string(&mut form).unwrap();
                    log.lock().unwrap().push(form);
                    let id = who.lock().unwrap().clone();
                    let now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap()
                        .as_secs() as i64;
                    let claims = json!({ "iss": iss, "aud": id.audience, "sub": "subject-1", "email": id.email, "email_verified": id.verified, "nonce": id.nonce, "exp": now + id.expires_in });
                    let b64 = |v: &Value| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(v.to_string());
                    json!({ "access_token": "at", "token_type": "Bearer", "id_token": format!("{}.{}.sig", b64(&json!({ "alg": "RS256" })), b64(&claims)) })
                }
                _ => json!({ "error": "not found" }),
            };
            request
                .respond(Response::from_string(body.to_string()).with_header(json_header))
                .unwrap();
        }
    });
    Provider { issuer, identity, seen }
}

struct Web {
    base: String,
    _dir: tempfile::TempDir,
}

fn web(provider: &Provider, allow: &[&str]) -> Web {
    let dir = tempfile::tempdir().unwrap();
    let running = start(Config {
        data_dir: dir.path().to_string_lossy().into_owned(),
        listen: "127.0.0.1:0".into(),
        password: None,
        oidc: Some(OidcConfig {
            issuer: provider.issuer.clone(),
            client_id: "lists".into(),
            client_secret: "client-secret".into(),
            public_url: "https://lists.example.org".into(),
            allow: allow.iter().map(|s| s.to_string()).collect(),
        }),
        sync: SyncConfig::Off,
        sync_password: None,
        push_server: None,
    })
    .unwrap();
    Web {
        base: format!("http://{}", running.addr),
        _dir: dir,
    }
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new().redirects(0).build()
}

fn param(url: &str, name: &str) -> String {
    url.split(['?', '&'])
        .find_map(|p| p.strip_prefix(&format!("{name}=")))
        .unwrap_or_default()
        .to_string()
}

/// Starts a sign-in and returns the `state` and `nonce` the server sent to the provider.
fn begin(web: &Web) -> (String, String) {
    let response = agent().get(&format!("{}/auth/login", web.base)).call().unwrap();
    assert_eq!(response.status(), 302);
    let location = response.header("Location").unwrap().to_string();
    assert!(
        location.contains("/authorize?")
            && location.contains("code_challenge_method=S256")
            && location.contains("scope=openid%20email")
    );
    assert!(location.contains("redirect_uri=https%3A%2F%2Flists.example.org%2Fauth%2Fcallback"));
    (param(&location, "state"), param(&location, "nonce"))
}

fn callback(web: &Web, state: &str) -> Result<String, (u16, String)> {
    match agent()
        .get(&format!("{}/auth/callback?state={state}&code=the-code", web.base))
        .call()
    {
        Ok(r) => Ok(r
            .header("Set-Cookie")
            .unwrap_or_default()
            .split(';')
            .next()
            .unwrap_or_default()
            .to_string()),
        Err(ureq::Error::Status(code, r)) => Err((code, r.into_string().unwrap_or_default())),
        Err(e) => panic!("{e}"),
    }
}

fn overview_status(web: &Web, cookie: &str) -> u16 {
    match ureq::get(&format!("{}/api/overview", web.base))
        .set("Cookie", cookie)
        .call()
    {
        Ok(r) => r.status(),
        Err(ureq::Error::Status(code, _)) => code,
        Err(e) => panic!("{e}"),
    }
}

#[test]
fn allowed_user_signs_in_and_gets_a_session() {
    let idp = provider();
    let web = web(&idp, &["Me@Example.org"]);
    assert_eq!(overview_status(&web, ""), 401, "OIDC alone already closes the API");
    let methods: Value = ureq::get(&format!("{}/auth/methods", web.base))
        .call()
        .unwrap()
        .into_json()
        .unwrap();
    assert_eq!(methods, json!({ "password": false, "oidc": true }));
    // Without a password there is no password login to fall back to.
    assert!(ureq::post(&format!("{}/api/login", web.base))
        .send_json(json!({ "password": "" }))
        .is_err());

    let (state, nonce) = begin(&web);
    idp.identity.lock().unwrap().nonce = Some(nonce);
    let cookie = callback(&web, &state).unwrap();
    assert!(cookie.starts_with("lists_session="));
    assert_eq!(overview_status(&web, &cookie), 200);

    let sent = idp.seen.lock().unwrap()[0].clone();
    assert!(
        sent.contains("grant_type=authorization_code")
            && sent.contains("code=the-code")
            && sent.contains("client_secret=client-secret")
    );
    assert!(sent.contains("code_verifier="), "PKCE verifier is sent with the code");

    // The same state cannot be used twice.
    assert_eq!(callback(&web, &state).unwrap_err().0, 403);
}

#[test]
fn everyone_else_is_turned_away() {
    let idp = provider();
    let web = web(&idp, &["me@example.org"]);
    let attempt = |change: &dyn Fn(&mut Identity, String)| {
        let (state, nonce) = begin(&web);
        {
            let mut id = idp.identity.lock().unwrap();
            *id = Identity {
                email: "me@example.org".into(),
                verified: true,
                nonce: None,
                audience: "lists".into(),
                expires_in: 300,
            };
            change(&mut id, nonce);
        }
        callback(&web, &state)
    };
    let refused = |result: Result<String, (u16, String)>, why: &str| {
        let (code, body) = result.unwrap_err();
        assert_eq!(code, 403);
        assert!(body.contains(why), "{body}");
    };
    refused(
        attempt(&|id, nonce| {
            id.nonce = Some(nonce);
            id.email = "stranger@example.org".into()
        }),
        "not allowed",
    );
    refused(
        attempt(&|id, nonce| {
            id.nonce = Some(nonce);
            id.verified = false
        }),
        "not allowed",
    );
    refused(
        attempt(&|id, _| id.nonce = Some("another-attempt".into())),
        "does not belong to this sign-in",
    );
    refused(
        attempt(&|id, nonce| {
            id.nonce = Some(nonce);
            id.audience = "other-client".into()
        }),
        "another client",
    );
    refused(
        attempt(&|id, nonce| {
            id.nonce = Some(nonce);
            id.expires_in = -10
        }),
        "expired",
    );
    refused(callback(&web, "made-up-state"), "unknown or has expired");
    // And the positive control with the same helper.
    assert!(attempt(&|id, nonce| id.nonce = Some(nonce)).is_ok());
}

#[test]
fn error_text_from_the_provider_side_is_escaped() {
    let idp = provider();
    let web = web(&idp, &["me@example.org"]);
    let (state, nonce) = begin(&web);
    {
        let mut id = idp.identity.lock().unwrap();
        id.nonce = Some(nonce);
        id.email = "<script>alert(1)</script>@example.org".into();
    }
    let (_, body) = callback(&web, &state).unwrap_err();
    assert!(
        body.contains("&lt;script&gt;") && !body.contains("<script>alert"),
        "{body}"
    );
}

#[test]
fn configuration_mistakes_stop_the_server_from_starting() {
    let dir = tempfile::tempdir().unwrap();
    let config = |issuer: &str, allow: Vec<String>| Config {
        data_dir: dir.path().to_string_lossy().into_owned(),
        listen: "127.0.0.1:0".into(),
        password: None,
        oidc: Some(OidcConfig {
            issuer: issuer.into(),
            client_id: "lists".into(),
            client_secret: String::new(),
            public_url: "https://x".into(),
            allow,
        }),
        sync: SyncConfig::Off,
        sync_password: None,
        push_server: None,
    };
    assert!(
        start(config("http://id.example.org", vec!["a@b.c".into()])).is_err(),
        "a provider must be reached over TLS"
    );
    assert!(
        start(config("https://id.example.org", vec![])).is_err(),
        "an empty allow list would let every account in"
    );
}
