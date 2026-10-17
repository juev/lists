//! Web Push on the wire: the message encrypted for one browser (`aes128gcm`, RFC 8291) and the
//! request signed for the push service (VAPID, RFC 8292). Rules: R146 in docs/specs/product.md.

use std::path::Path;

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes128Gcm, Nonce};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use hkdf::Hkdf;
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};
use p256::elliptic_curve::sec1::ToEncodedPoint;
use p256::{PublicKey, SecretKey};
use rand_core::{OsRng, RngCore};
use serde_json::json;
use sha2::Sha256;

/// One record carries the whole message: the size of the record, tag included.
const RECORD_SIZE: u32 = 4096;
/// A signed request is good for this long; RFC 8292 allows up to a day.
const TOKEN_LIFE: u64 = 12 * 3600;

pub fn b64(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

/// Browsers give the keys of a subscription in base64url, some with padding.
pub fn unb64(text: &str) -> Option<Vec<u8>> {
    URL_SAFE_NO_PAD.decode(text.trim().trim_end_matches('=')).ok()
}

/// The message for the browser whose subscription has the public key `ua_public` (65 bytes,
/// uncompressed) and the secret `auth` (16 bytes). Nobody else can read it, the push service
/// included.
pub fn encrypt(ua_public: &[u8], auth: &[u8], plain: &[u8]) -> Result<Vec<u8>, String> {
    let mut salt = [0u8; 16];
    OsRng.fill_bytes(&mut salt);
    encrypt_with(ua_public, auth, plain, &SecretKey::random(&mut OsRng), salt)
}

/// `encrypt` with the sender's key and the salt given, as the test vector of RFC 8291 needs.
fn encrypt_with(
    ua_public: &[u8],
    auth: &[u8],
    plain: &[u8],
    sender: &SecretKey,
    salt: [u8; 16],
) -> Result<Vec<u8>, String> {
    let ua = PublicKey::from_sec1_bytes(ua_public).map_err(|_| "the browser key is not a P-256 point".to_string())?;
    if auth.len() != 16 {
        return Err("the browser secret is not 16 bytes".into());
    }
    if plain.len() + 1 + 16 > RECORD_SIZE as usize {
        return Err("the message does not fit one record".into());
    }
    let as_public = sender.public_key().to_encoded_point(false);
    let as_public = as_public.as_bytes();
    let shared = p256::ecdh::diffie_hellman(sender.to_nonzero_scalar(), ua.as_affine());

    let mut key_info = b"WebPush: info\0".to_vec();
    key_info.extend_from_slice(ua.to_encoded_point(false).as_bytes());
    key_info.extend_from_slice(as_public);
    let mut ikm = [0u8; 32];
    Hkdf::<Sha256>::new(Some(auth), shared.raw_secret_bytes())
        .expand(&key_info, &mut ikm)
        .map_err(|e| e.to_string())?;
    let prk = Hkdf::<Sha256>::new(Some(&salt), &ikm);
    let mut cek = [0u8; 16];
    let mut nonce = [0u8; 12];
    prk.expand(b"Content-Encoding: aes128gcm\0", &mut cek)
        .map_err(|e| e.to_string())?;
    prk.expand(b"Content-Encoding: nonce\0", &mut nonce)
        .map_err(|e| e.to_string())?;

    // The last record ends with the delimiter 2 and no padding.
    let mut record = plain.to_vec();
    record.push(2);
    let sealed = Aes128Gcm::new(&cek.into())
        .encrypt(Nonce::from_slice(&nonce), record.as_slice())
        .map_err(|e| e.to_string())?;

    let mut out = salt.to_vec();
    out.extend_from_slice(&RECORD_SIZE.to_be_bytes());
    out.push(as_public.len() as u8);
    out.extend_from_slice(as_public);
    out.extend_from_slice(&sealed);
    Ok(out)
}

/// The key pair that signs this server's requests to the push services.
pub struct Vapid {
    key: SigningKey,
    subject: String,
}

impl Vapid {
    /// The key kept in `path`, made there on first start. The file holds the private scalar in
    /// base64url and is readable by its owner only.
    pub fn load_or_create(path: &Path, subject: String) -> Result<Vapid, String> {
        let key = match std::fs::read_to_string(path) {
            Ok(text) => {
                let bytes = unb64(&text).ok_or("the VAPID key file is not base64url")?;
                SigningKey::from_slice(&bytes)
                    .map_err(|_| "the VAPID key file does not hold a P-256 key".to_string())?
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let key = SigningKey::random(&mut OsRng);
                write_private(path, &b64(&key.to_bytes()))?;
                key
            }
            Err(e) => return Err(format!("cannot read {}: {e}", path.display())),
        };
        Ok(Vapid { key, subject })
    }

    /// The `applicationServerKey` a browser subscribes with: the public key, uncompressed, base64url.
    pub fn public_key(&self) -> String {
        b64(self.key.verifying_key().to_encoded_point(false).as_bytes())
    }

    /// The `Authorization` header for a request to the origin `audience` at `now` (seconds since 1970).
    pub fn authorization(&self, audience: &str, now: u64) -> String {
        let header = b64(json!({ "typ": "JWT", "alg": "ES256" }).to_string().as_bytes());
        let claims = b64(json!({ "aud": audience, "exp": now + TOKEN_LIFE, "sub": self.subject })
            .to_string()
            .as_bytes());
        let signed = format!("{header}.{claims}");
        let signature: Signature = self.key.sign(signed.as_bytes());
        format!(
            "vapid t={signed}.{}, k={}",
            b64(&signature.to_bytes()),
            self.public_key()
        )
    }
}

/// `https://host[:port]` of an address, which is what a token is issued for.
pub fn origin(endpoint: &str) -> Option<String> {
    let rest = endpoint.strip_prefix("https://")?;
    let host = rest.split(['/', '?', '#']).next()?;
    (!host.is_empty() && !host.contains('@')).then(|| format!("https://{host}"))
}

#[cfg(unix)]
fn write_private(path: &Path, text: &str) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
    file.write_all(text.as_bytes())
        .map_err(|e| format!("cannot write {}: {e}", path.display()))
}

#[cfg(not(unix))]
fn write_private(path: &Path, text: &str) -> Result<(), String> {
    std::fs::write(path, text).map_err(|e| format!("cannot write {}: {e}", path.display()))
}

/// What a browser does with a message: the reverse of `encrypt`, for the tests.
#[cfg(test)]
pub fn decrypt(ua_private: &SecretKey, auth: &[u8], body: &[u8]) -> Result<Vec<u8>, String> {
    let salt = &body[..16];
    let id_len = body[20] as usize;
    let as_public = PublicKey::from_sec1_bytes(&body[21..21 + id_len]).map_err(|e| e.to_string())?;
    let shared = p256::ecdh::diffie_hellman(ua_private.to_nonzero_scalar(), as_public.as_affine());
    let mut key_info = b"WebPush: info\0".to_vec();
    key_info.extend_from_slice(ua_private.public_key().to_encoded_point(false).as_bytes());
    key_info.extend_from_slice(&body[21..21 + id_len]);
    let mut ikm = [0u8; 32];
    Hkdf::<Sha256>::new(Some(auth), shared.raw_secret_bytes())
        .expand(&key_info, &mut ikm)
        .map_err(|e| e.to_string())?;
    let prk = Hkdf::<Sha256>::new(Some(salt), &ikm);
    let mut cek = [0u8; 16];
    let mut nonce = [0u8; 12];
    prk.expand(b"Content-Encoding: aes128gcm\0", &mut cek)
        .map_err(|e| e.to_string())?;
    prk.expand(b"Content-Encoding: nonce\0", &mut nonce)
        .map_err(|e| e.to_string())?;
    let mut plain = Aes128Gcm::new(&cek.into())
        .decrypt(Nonce::from_slice(&nonce), &body[21 + id_len..])
        .map_err(|e| e.to_string())?;
    if plain.pop() != Some(2) {
        return Err("no delimiter".into());
    }
    Ok(plain)
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::ecdsa::signature::Verifier;
    use p256::ecdsa::VerifyingKey;

    fn d(text: &str) -> Vec<u8> {
        unb64(&text.split_whitespace().collect::<String>()).unwrap()
    }

    #[test]
    fn r146_message_matches_the_example_of_rfc_8291() {
        let ua_public = d("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcx aOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4");
        let sender = SecretKey::from_slice(&d("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")).unwrap();
        let salt: [u8; 16] = d("DGv6ra1nlYgDCS1FRnbzlw").try_into().unwrap();
        let body = encrypt_with(
            &ua_public,
            &d("BTBZMqHH6r4Tts7J_aSIgg"),
            b"When I grow up, I want to be a watermelon",
            &sender,
            salt,
        )
        .unwrap();
        assert_eq!(
            b64(&body),
            "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml\
             mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT\
             pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
        );
        let ua_private = SecretKey::from_slice(&d("q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94")).unwrap();
        assert_eq!(
            decrypt(&ua_private, &d("BTBZMqHH6r4Tts7J_aSIgg"), &body).unwrap(),
            b"When I grow up, I want to be a watermelon"
        );
    }

    #[test]
    fn r146_each_message_has_its_own_key_and_salt() {
        let browser = SecretKey::random(&mut OsRng);
        let public = browser.public_key().to_encoded_point(false);
        let (a, b) = (
            encrypt(public.as_bytes(), &[7; 16], b"x").unwrap(),
            encrypt(public.as_bytes(), &[7; 16], b"x").unwrap(),
        );
        assert_ne!(a[..86], b[..86]);
        assert_eq!(decrypt(&browser, &[7; 16], &a).unwrap(), b"x");
        assert!(encrypt(&public.as_bytes()[1..], &[7; 16], b"x").is_err(), "not a point");
        assert!(encrypt(public.as_bytes(), &[7; 15], b"x").is_err(), "short secret");
        assert!(
            encrypt(public.as_bytes(), &[7; 16], &[0; 4080]).is_err(),
            "more than a record"
        );
    }

    #[test]
    fn r146_the_key_is_made_once_and_signs_for_the_origin() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("key");
        let vapid = Vapid::load_or_create(&path, "mailto:me@example.org".into()).unwrap();
        let again = Vapid::load_or_create(&path, "mailto:me@example.org".into()).unwrap();
        assert_eq!(vapid.public_key(), again.public_key(), "the key survives a restart");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        }

        let audience = origin("https://push.example.net:8443/send/abc?x=1").unwrap();
        let header = vapid.authorization(&audience, 1_000);
        let (token, key) = header.strip_prefix("vapid t=").unwrap().split_once(", k=").unwrap();
        assert_eq!(key, vapid.public_key());
        let parts: Vec<&str> = token.split('.').collect();
        let claims: serde_json::Value = serde_json::from_slice(&unb64(parts[1]).unwrap()).unwrap();
        assert_eq!(
            claims,
            json!({ "aud": "https://push.example.net:8443", "exp": 1_000 + TOKEN_LIFE, "sub": "mailto:me@example.org" })
        );
        let verifying = VerifyingKey::from_sec1_bytes(&unb64(key).unwrap()).unwrap();
        let signature = Signature::from_slice(&unb64(parts[2]).unwrap()).unwrap();
        verifying
            .verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &signature)
            .expect("the signature verifies with the published key");

        assert_eq!(origin("http://push.example.net/x"), None);
        assert_eq!(origin("https://user@push.example.net/x"), None);
        assert_eq!(origin("https:///x"), None);
        std::fs::write(&path, "not a key").unwrap();
        assert!(
            Vapid::load_or_create(&path, String::new()).is_err(),
            "a broken key is not replaced silently"
        );
    }
}
