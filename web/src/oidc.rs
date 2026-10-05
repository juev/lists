//! Sign-in through an OpenID Connect provider: authorization code flow with
//! PKCE. The server is a confidential or public client of the provider; who
//! may enter is decided here, by an allow list of e-mail addresses or subjects.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use serde_json::Value;
use sha2::{Digest, Sha256};

#[derive(Clone)]
pub struct OidcConfig {
    /// Issuer URL exactly as the provider states it, e.g. `https://id.example.org/realms/home`.
    pub issuer: String,
    pub client_id: String,
    /// Empty for a public client; PKCE is used either way.
    pub client_secret: String,
    /// Address of this server as the browser sees it, e.g. `https://lists.example.org`.
    pub public_url: String,
    /// E-mail addresses or `sub` values that may sign in. Compared case-insensitively.
    pub allow: Vec<String>,
}

struct Endpoints {
    authorization: String,
    token: String,
}

struct Pending {
    nonce: String,
    verifier: String,
    created: Instant,
}

pub struct Oidc {
    config: OidcConfig,
    agent: ureq::Agent,
    endpoints: Mutex<Option<Endpoints>>,
    pending: Mutex<HashMap<String, Pending>>,
}

const PENDING_TTL: Duration = Duration::from_secs(600);

fn random() -> String {
    format!("{}{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple())
}

fn url_encode(value: &str) -> String {
    value
        .bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

fn form(pairs: &[(&str, &str)]) -> String {
    pairs
        .iter()
        .map(|(k, v)| format!("{k}={}", url_encode(v)))
        .collect::<Vec<_>>()
        .join("&")
}

/// The claims of an ID token. The signature is not checked: the token comes
/// straight from the provider's token endpoint over TLS, which OpenID Connect
/// Core (3.1.3.7) accepts in place of signature validation for this flow.
fn claims(id_token: &str) -> Option<Value> {
    let payload = id_token.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .ok()?;
    serde_json::from_slice(&bytes).ok()
}

impl Oidc {
    pub fn new(config: OidcConfig) -> Result<Oidc, String> {
        let local = |url: &str| url.starts_with("http://127.0.0.1") || url.starts_with("http://localhost");
        if !(config.issuer.starts_with("https://") || local(&config.issuer)) {
            return Err("the OIDC issuer must be an https:// address".into());
        }
        if config.client_id.is_empty() || config.public_url.is_empty() {
            return Err("OIDC needs a client id and the public address of this server".into());
        }
        if config.allow.is_empty() {
            return Err(
                "OIDC needs LISTS_OIDC_ALLOW: without it anyone with an account at the provider could sign in".into(),
            );
        }
        Ok(Oidc {
            agent: ureq::AgentBuilder::new()
                .timeout(Duration::from_secs(20))
                .redirects(0)
                .build(),
            config,
            endpoints: Mutex::new(None),
            pending: Mutex::new(HashMap::new()),
        })
    }

    fn redirect_uri(&self) -> String {
        format!("{}/auth/callback", self.config.public_url.trim_end_matches('/'))
    }

    fn discover(&self) -> Result<(String, String), String> {
        let mut cached = self.endpoints.lock().unwrap_or_else(|p| p.into_inner());
        if cached.is_none() {
            let url = format!(
                "{}/.well-known/openid-configuration",
                self.config.issuer.trim_end_matches('/')
            );
            let doc: Value = self
                .agent
                .get(&url)
                .call()
                .map_err(|e| format!("OIDC discovery failed: {e}"))?
                .into_json()
                .map_err(|e| e.to_string())?;
            let text = |key: &str| {
                doc.get(key)
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .ok_or(format!("the provider's configuration has no {key}"))
            };
            // A provider that names another issuer is not the one that was configured.
            if text("issuer")?.trim_end_matches('/') != self.config.issuer.trim_end_matches('/') {
                return Err("the provider's configuration names a different issuer".into());
            }
            *cached = Some(Endpoints {
                authorization: text("authorization_endpoint")?,
                token: text("token_endpoint")?,
            });
        }
        let endpoints = cached.as_ref().expect("just filled");
        Ok((endpoints.authorization.clone(), endpoints.token.clone()))
    }

    /// Where to send the browser to sign in.
    pub fn begin(&self) -> Result<String, String> {
        let (authorization, _) = self.discover()?;
        let (state, nonce, verifier) = (random(), random(), random());
        let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        let query = form(&[
            ("response_type", "code"),
            ("client_id", &self.config.client_id),
            ("redirect_uri", &self.redirect_uri()),
            ("scope", "openid email"),
            ("state", &state),
            ("nonce", &nonce),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
        ]);
        let mut pending = self.pending.lock().unwrap_or_else(|p| p.into_inner());
        pending.retain(|_, p| p.created.elapsed() < PENDING_TTL);
        pending.insert(
            state,
            Pending {
                nonce,
                verifier,
                created: Instant::now(),
            },
        );
        let joiner = if authorization.contains('?') { '&' } else { '?' };
        Ok(format!("{authorization}{joiner}{query}"))
    }

    /// Finishes a sign-in. Returns who it is, or why they are not let in.
    pub fn finish(&self, state: &str, code: &str) -> Result<String, String> {
        // A state is good for one attempt.
        let pending = self.pending.lock().unwrap_or_else(|p| p.into_inner()).remove(state);
        let pending = pending
            .filter(|p| p.created.elapsed() < PENDING_TTL)
            .ok_or("this sign-in attempt is unknown or has expired")?;
        let (_, token) = self.discover()?;
        let redirect = self.redirect_uri();
        let mut pairs = vec![
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirect.as_str()),
            ("client_id", self.config.client_id.as_str()),
            ("code_verifier", pending.verifier.as_str()),
        ];
        if !self.config.client_secret.is_empty() {
            pairs.push(("client_secret", self.config.client_secret.as_str()));
        }
        let answer: Value = self
            .agent
            .post(&token)
            .set("Content-Type", "application/x-www-form-urlencoded")
            .send_string(&form(&pairs))
            .map_err(|e| format!("the provider refused the code: {e}"))?
            .into_json()
            .map_err(|e| e.to_string())?;
        let claims = answer
            .get("id_token")
            .and_then(Value::as_str)
            .and_then(claims)
            .ok_or("the provider returned no ID token")?;

        let text = |key: &str| claims.get(key).and_then(Value::as_str).unwrap_or_default();
        if text("iss").trim_end_matches('/') != self.config.issuer.trim_end_matches('/') {
            return Err("the ID token is from another issuer".into());
        }
        let audience_ok = match claims.get("aud") {
            Some(Value::String(aud)) => *aud == self.config.client_id,
            Some(Value::Array(list)) => list.iter().any(|a| a.as_str() == Some(self.config.client_id.as_str())),
            _ => false,
        };
        if !audience_ok {
            return Err("the ID token is for another client".into());
        }
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        if claims.get("exp").and_then(Value::as_u64).is_none_or(|exp| exp <= now) {
            return Err("the ID token has expired".into());
        }
        if text("nonce") != pending.nonce {
            return Err("the ID token does not belong to this sign-in attempt".into());
        }
        let subject = text("sub").to_string();
        // An address the provider has not verified is not proof of anything.
        let email = if claims.get("email_verified").and_then(Value::as_bool) == Some(false) {
            ""
        } else {
            text("email")
        };
        let allowed = |who: &str| !who.is_empty() && self.config.allow.iter().any(|a| a.eq_ignore_ascii_case(who));
        if allowed(email) {
            Ok(email.to_string())
        } else if allowed(&subject) {
            Ok(subject)
        } else {
            Err(format!(
                "{} is not allowed to use this server",
                if email.is_empty() { subject.as_str() } else { email }
            ))
        }
    }
}
