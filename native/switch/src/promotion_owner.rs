//! Native promotion owner, reusing the unchanged promotion Worker and native codec/lock.
//! Request contract statically verified in ZCode 3.17.2 out/host/index.js.
//! This does not establish live service behavior. The native host must explicitly
//! supply its resolved origin, platform, public app version and selected plan IDs.
use crate::{native::NativeCipher, switch::SavedAccount, zcode_file_lock::{FileLock, unique_token}};
use loongpass_zcode_promotions_candidate::promotions::{Endpoint, Failure, Mode, Request, Store, Transport, Worker};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{ffi::CString, fs::{self, File}, io::{Read, Write}, os::{fd::{AsRawFd, FromRawFd}, unix::fs::{MetadataExt, OpenOptionsExt}}, path::{Path, PathBuf}, sync::Arc, time::Duration};
use zeroize::{Zeroize, Zeroizing};
const MAX_PLAIN: usize = 64 * 1024;
const MAX_ENCRYPTED: usize = 128 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);

pub(crate) fn error_code(error: Failure) -> &'static str {
    match error {
        Failure::Cancelled => "Cancelled", Failure::InvalidContext => "NativeContextUnavailable",
        Failure::InvalidResponse => "InvalidResponse", Failure::Storage => "Storage",
        Failure::Busy => "LockBusy", Failure::Transport => "NativeUnavailable", Failure::Unauthorized => "LoginExpired",
    }
}
fn valid_version(version: &str) -> bool {
    !version.is_empty() && version.len() <= 64 && version.bytes().all(|b| b.is_ascii_alphanumeric() || b".-+".contains(&b))
}
fn valid_binding(binding: &str) -> bool {
    binding.len() == 64 && binding.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn valid_plan(plan: &str) -> bool {
    !plan.is_empty() && plan.len() <= 256 && plan.trim() == plan && !plan.chars().any(char::is_control)
}

fn valid_platform(platform: &str) -> bool {
    !platform.is_empty() && platform.len() <= 128
        && platform.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}
fn parse_origin(origin: &str) -> Result<reqwest::Url, Failure> {
    let origin = origin.trim();
    if origin.is_empty() || origin.chars().any(char::is_control) || origin.contains('\\') { return Err(Failure::InvalidContext); }
    let url = reqwest::Url::parse(origin).map_err(|_| Failure::InvalidContext)?;
    let (_, authority_and_path) = origin.split_once("://").ok_or(Failure::InvalidContext)?;
    let (authority, path) = authority_and_path.split_once('/').unwrap_or((authority_and_path, ""));
    // The host resolves target environment configuration. This boundary accepts
    // only that resolved origin, never a path, credentials, query or fallback.
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none()
        || !url.username().is_empty() || url.password().is_some() || authority.contains('@')
        || !path.is_empty() || url.path() != "/" || url.query().is_some() || url.fragment().is_some() {
        return Err(Failure::InvalidContext);
    }
    reqwest::Url::parse(&url.origin().ascii_serialization()).map_err(|_| Failure::InvalidContext)
}

pub(crate) struct Owner { root: PathBuf, version: String, origin: reqwest::Url, platform: String, worker: Worker }
impl Owner {
    pub(crate) fn new(root: PathBuf, version: String, origin: String, platform: String, plans: Vec<String>) -> Result<Self, Failure> {
        if !root.is_absolute() || !valid_version(&version) || !valid_platform(&platform) { return Err(Failure::InvalidContext); }
        Ok(Self { root, version, origin: parse_origin(&origin)?, platform, worker: Worker::approved_plans(plans)? })
    }
    pub(crate) fn receipt_binding(&self, account: &SavedAccount) -> String {
        let mut digest = Sha256::new();
        digest.update(b"zcode-promotion-origin-account-v1\0");
        digest.update(self.origin.as_str().as_bytes());
        digest.update(b"\0");
        // The existing opaque identity already includes native context, family
        // and account. Origin is canonicalized without losing scheme or port.
        digest.update(account.snapshot.identity().opaque_id().as_bytes());
        digest.finalize().iter().map(|byte| format!("{byte:02x}")).collect()
    }
    pub(crate) fn probe(&self, native: &NativeCipher, account: &SavedAccount, check: &mut impl FnMut() -> Result<(), Failure>) -> Result<(), Failure> {
        check()?;
        let _credentials = Credentials::load(native, account)?;
        let binding = self.receipt_binding(account);
        let legacy_binding = account.snapshot.identity().opaque_id();
        let mut store = PersistentStore::acquire(&self.root, &binding, &legacy_binding, native)?;
        // Ask the unchanged Worker to validate its own durable schema, then abort
        // at its first network gate. This adapter NEVER acknowledges a write.
        // Pending reconciliation attempts to save after that abort; the read-only
        // adapter rejects it, and `validated` records only successful prior load.
        let mut validated = false;
        let mut calls = 0;
        let result = self.worker.run(&binding, Mode::Preview, 0,
            &mut ProbeStore(&mut store), &mut NoHttp, &mut || {
                calls += 1;
                if calls == 1 { Ok(()) } else { validated = true; Err(Failure::Cancelled) }
            });
        if !validated && result.is_err() { return Err(Failure::Storage); }
        check()?;
        store.proof.verify()
    }
    pub(crate) fn run(&self, native: &NativeCipher, account: &SavedAccount, mode: Mode, checked_at: u64, check: &mut impl FnMut() -> Result<(), Failure>) -> Result<Value, Failure> {
        check()?;
        let credentials = Credentials::load(native, account)?;
        let mut http = Http::new(self.version.clone(), self.origin.as_str().into(), self.platform.clone(), Some(credentials.jwt.clone()))?;
        self.run_with_transport(native, account, mode, checked_at, &mut http, check)
    }
    pub(crate) fn run_with_transport(&self, native: &NativeCipher, account: &SavedAccount, mode: Mode, checked_at: u64, transport: &mut impl Transport, check: &mut impl FnMut() -> Result<(), Failure>) -> Result<Value, Failure> {
        check()?;
        let credentials = Credentials::load(native, account)?;
        let binding = self.receipt_binding(account);
        let legacy_binding = account.snapshot.identity().opaque_id();
        let mut store = PersistentStore::acquire(&self.root, &binding, &legacy_binding, native)?;
        let proof = Arc::clone(&store.proof);
        let mut owned = || { check()?; proof.verify() };
        let mut safe = RedactingTransport { inner: transport, secrets: &credentials.values };
        let mut result = self.worker.run(&binding, mode, checked_at, &mut store, &mut safe, &mut owned)?;
        scrub(&mut result, &credentials.values);
        Ok(result)
    }
}

// ZCode 3.17.2 authenticated balance/claim requires global zcodejwttoken.
// Derived Start-plan and coding API keys are not substitutes in either family.
struct Credentials { jwt: Zeroizing<String>, values: Vec<Zeroizing<String>> }
impl Credentials {
    fn load(native: &NativeCipher, account: &SavedAccount) -> Result<Self, Failure> {
        let document = account.snapshot.scoped_document();
        let checked = native.inspect(&document).map_err(|_| Failure::Unauthorized)?;
        if checked.identity() != account.snapshot.identity() { return Err(Failure::InvalidContext); }
        let keys = account.snapshot.identity().credential_keys();
        let raw = document.get(&keys[4]).ok_or(Failure::Unauthorized)?;
        let clear = native.decrypt(raw).map_err(|_| Failure::Unauthorized)?;
        let jwt = Zeroizing::new(clear.trim().to_owned());
        if jwt.is_empty() || jwt.len() > 16 * 1024 || jwt.chars().any(char::is_control) { return Err(Failure::Unauthorized); }
        let mut values = vec![jwt.clone()];
        for index in [1, 2, 4, 5, 6] {
            if let Some(raw) = document.get(&keys[index]) {
                let value = native.decrypt(raw).map_err(|_| Failure::Unauthorized)?;
                let value = Zeroizing::new(value.trim().to_owned());
                if !value.is_empty() { values.push(value); }
            }
        }
        Ok(Self { jwt, values })
    }
}
fn unsafe_text(value: &str, secrets: &[Zeroizing<String>]) -> bool {
    secrets.iter().any(|secret| !secret.is_empty() && value.contains(secret.as_str()))
        || value.contains("https://") || value.contains("http://") || value.contains("file://")
}
fn scrub(value: &mut Value, secrets: &[Zeroizing<String>]) {
    match value {
        Value::String(text) if unsafe_text(text, secrets) => { text.zeroize(); *value = Value::Null; },
        Value::Array(items) => items.iter_mut().for_each(|v| scrub(v, secrets)),
        Value::Object(items) => {
            items.retain(|key, _| !unsafe_text(key, secrets));
            items.values_mut().for_each(|v| scrub(v, secrets));
        },
        _ => {},
    }
}
struct RedactingTransport<'a, T> { inner: &'a mut T, secrets: &'a [Zeroizing<String>] }
impl<T: Transport> Transport for RedactingTransport<'_, T> {
    fn send(&mut self, request: Request) -> Result<Value, Failure> {
        let mut value = self.inner.send(request)?;
        scrub(&mut value, self.secrets);
        Ok(value)
    }
}

// No Debug implementation: HTTP errors, request URLs and credentials never
// escape this boundary. No CAPTCHA retries or refresh/login side effects.
struct Http { client: reqwest::Client, runtime: tokio::runtime::Runtime, version: String, origin: reqwest::Url, platform: String, jwt: Option<Zeroizing<String>> }
impl Http {
    fn new(version: String, origin: String, platform: String, jwt: Option<Zeroizing<String>>) -> Result<Self, Failure> {
        if !valid_version(&version) || !valid_platform(&platform) { return Err(Failure::InvalidContext); }
        let origin = parse_origin(&origin)?;
        if jwt.as_ref().is_some_and(|value| value.is_empty() || value.len() > 16 * 1024 || value.chars().any(char::is_control)) { return Err(Failure::Unauthorized); }
        let client = reqwest::Client::builder().no_proxy()
            .redirect(reqwest::redirect::Policy::none()).retry(reqwest::retry::never())
            .timeout(REQUEST_TIMEOUT)
            .build().map_err(|_| Failure::Transport)?;
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|_| Failure::Transport)?;
        Ok(Self { client, runtime, version, origin, platform, jwt })
    }
    fn build_request(&self, request: Request) -> Result<reqwest::Request, Failure> {
        let path = match request.endpoint {
            Endpoint::Preview => "zcode-plan/billing/preview", Endpoint::Balance => "zcode-plan/billing/balance", Endpoint::Claim => "zcode-plan/billing/claim",
        };
        let mut url = self.origin.join(&format!("/api/v1/{path}")).map_err(|_| Failure::InvalidContext)?;
        if matches!(request.endpoint, Endpoint::Balance | Endpoint::Preview) { url.query_pairs_mut().append_pair("app_version", &self.version); }
        if request.endpoint == Endpoint::Preview { url.query_pairs_mut().append_pair("platform", &self.platform); }
        let mut builder = if request.endpoint == Endpoint::Claim { self.client.post(url) } else { self.client.get(url) };
        builder = builder.timeout(REQUEST_TIMEOUT);
        if let Some(jwt) = &self.jwt {
            let mut auth = reqwest::header::HeaderValue::from_str(&Zeroizing::new(format!("Bearer {}", jwt.as_str()))).map_err(|_| Failure::Unauthorized)?;
            auth.set_sensitive(true);
            builder = builder.header(reqwest::header::AUTHORIZATION, auth);
        } else if request.endpoint != Endpoint::Preview {
            return Err(Failure::Unauthorized);
        }
        if request.endpoint == Endpoint::Claim {
            builder = builder.header("X-ZCode-App-Version", &self.version).header("X-Platform", &self.platform);
        }
        match (request.endpoint, request.plan) {
            (Endpoint::Claim, Some(plan)) if valid_plan(&plan) => builder = builder.json(&json!({"plan_id":plan})),
            (Endpoint::Claim, _) | (_, Some(_)) => return Err(Failure::InvalidContext),
            _ => {},
        }
        builder.build().map_err(|_| Failure::InvalidContext)
    }
}
impl Transport for Http {
    fn send(&mut self, request: Request) -> Result<Value, Failure> {
        let outgoing = self.build_request(request)?;
        self.runtime.block_on(async {
            let mut response = self.client.execute(outgoing).await.map_err(|_| Failure::Transport)?;
            let status = response.status().as_u16();
            if matches!(status, 401 | 403) { return Err(Failure::Unauthorized); }
            if !(200..300).contains(&status) { return Err(Failure::Transport); }
            if response.content_length().is_some_and(|size| size > MAX_PLAIN as u64) { return Err(Failure::InvalidResponse); }
            let mut body = Zeroizing::new(Vec::new());
            while let Some(chunk) = response.chunk().await.map_err(|_| Failure::Transport)? {
                if chunk.len() > MAX_PLAIN.saturating_sub(body.len()) { return Err(Failure::InvalidResponse); }
                body.extend_from_slice(&chunk);
            }
            parse_response(status, &body, self.jwt.as_ref())
        })
    }
}

fn parse_response(status: u16, body: &[u8], jwt: Option<&Zeroizing<String>>) -> Result<Value, Failure> {
    if matches!(status, 401 | 403) { return Err(Failure::Unauthorized); }
    if !(200..300).contains(&status) { return Err(Failure::Transport); }
    if body.len() > MAX_PLAIN { return Err(Failure::InvalidResponse); }
    let mut value: Value = serde_json::from_slice(body).map_err(|_| Failure::InvalidResponse)?;
    if !value.is_object() { return Err(Failure::InvalidResponse); }
    scrub(&mut value, jwt.map(std::slice::from_ref).unwrap_or(&[]));
    Ok(value)
}

struct StoreProof { root: PathBuf, directory: File, owner: FileLock, legacy_owner: FileLock, legacy_name: String }
impl StoreProof {
    fn verify(&self) -> Result<(), Failure> {
        if !self.owner.is_owned() || !self.legacy_owner.is_owned() { return Err(Failure::Busy); }
        let named = private_directory(&self.root)?;
        let pinned = self.directory.metadata().map_err(|_| Failure::Storage)?;
        if named.dev() != pinned.dev() || named.ino() != pinned.ino() { return Err(Failure::Storage); }
        // Old receipts cannot be assigned an origin safely. Preserve every kind
        // of evidence, including invalid files and symlinks, and block migration.
        match fs::symlink_metadata(self.root.join(&self.legacy_name)) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            _ => Err(Failure::Storage),
        }
    }
}
fn private_directory(path: &Path) -> Result<fs::Metadata, Failure> {
    if !path.is_absolute() || path.components().any(|p| matches!(p, std::path::Component::ParentDir | std::path::Component::CurDir))
        || fs::canonicalize(path).map_err(|_| Failure::Storage)? != path { return Err(Failure::Storage); }
    let metadata = fs::symlink_metadata(path).map_err(|_| Failure::Storage)?;
    if !metadata.is_dir() || metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o077 != 0 { return Err(Failure::Storage); }
    Ok(metadata)
}
fn stamp(metadata: &fs::Metadata) -> [u64; 7] {
    [metadata.dev(), metadata.ino(), metadata.len(), metadata.mtime() as u64, metadata.mtime_nsec() as u64, metadata.ctime() as u64, metadata.ctime_nsec() as u64]
}
struct PersistentStore<'a> { native: &'a NativeCipher, binding: String, name: String, proof: Arc<StoreProof>, expected: Option<Vec<u8>>, loaded: bool }
impl<'a> PersistentStore<'a> {
    fn acquire(root: &Path, binding: &str, legacy_binding: &str, native: &'a NativeCipher) -> Result<Self, Failure> {
        if !valid_binding(binding) || !valid_binding(legacy_binding) || binding == legacy_binding { return Err(Failure::InvalidContext); }
        private_directory(root)?;
        let directory = fs::OpenOptions::new().read(true).custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC).open(root).map_err(|_| Failure::Storage)?;
        let name = format!("zcode-promotions-{binding}.enc");
        let legacy_name = format!("zcode-promotions-{legacy_binding}.enc");
        // Hold the legacy account lock too: an old-format writer cannot appear
        // between the legacy check and a request or durable scoped write.
        let legacy_owner = FileLock::acquire_recoverable(&root.join(&legacy_name), Duration::from_millis(250)).map_err(|_| Failure::Busy)?;
        // Reuse the existing recovery policy: only a provably exited owner PID
        // may be reclaimed. Live, unknown, malformed and ownerless locks survive.
        // This never resets the encrypted journal; pending still only reconciles.
        let owner = FileLock::acquire_recoverable(&root.join(&name), Duration::from_millis(250)).map_err(|_| Failure::Busy)?;
        let proof = Arc::new(StoreProof { root: root.to_owned(), directory, owner, legacy_owner, legacy_name });
        proof.verify()?;
        Ok(Self { native, binding: binding.into(), name, proof, expected: None, loaded: false })
    }
    fn open(&self, name: &str, flags: i32) -> std::io::Result<File> {
        let name = CString::new(name).map_err(|_| std::io::Error::other("invalid store name"))?;
        let fd = unsafe { libc::openat(self.proof.directory.as_raw_fd(), name.as_ptr(), flags | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK, 0o600) };
        if fd < 0 { Err(std::io::Error::last_os_error()) } else { Ok(unsafe { File::from_raw_fd(fd) }) }
    }
    fn read(&self, name: &str) -> Result<Option<Vec<u8>>, Failure> {
        self.proof.verify()?;
        let mut file = match self.open(name, libc::O_RDONLY) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => { self.proof.verify()?; return Ok(None); },
            Err(_) => return Err(Failure::Storage),
        };
        let before = file.metadata().map_err(|_| Failure::Storage)?;
        if !before.is_file() || before.nlink() != 1 || before.uid() != unsafe { libc::geteuid() }
            || before.mode() & 0o777 != 0o600 || before.len() > MAX_ENCRYPTED as u64 { return Err(Failure::Storage); }
        let mut bytes = Vec::new();
        (&mut file).take(MAX_ENCRYPTED as u64 + 1).read_to_end(&mut bytes).map_err(|_| Failure::Storage)?;
        let after = file.metadata().map_err(|_| Failure::Storage)?;
        let named = fs::symlink_metadata(self.proof.root.join(name)).map_err(|_| Failure::Storage)?;
        self.proof.verify()?;
        if bytes.len() > MAX_ENCRYPTED || stamp(&before) != stamp(&after) || stamp(&after) != stamp(&named) { return Err(Failure::Storage); }
        Ok(Some(bytes))
    }
}
impl Store for PersistentStore<'_> {
    fn load(&mut self, binding: &str) -> Result<Option<Vec<u8>>, Failure> {
        if binding != self.binding { return Err(Failure::InvalidContext); }
        let image = self.read(&self.name)?;
        let clear = image.as_ref().map(|bytes| {
            let encoded = std::str::from_utf8(bytes).map_err(|_| Failure::Storage)?;
            let clear = self.native.decrypt(encoded).map_err(|_| Failure::Storage)?;
            if clear.len() > MAX_PLAIN { return Err(Failure::Storage); }
            Ok(clear.as_bytes().to_vec())
        }).transpose()?;
        self.expected = image;
        self.loaded = true;
        Ok(clear)
    }
    fn persist(&mut self, binding: &str, bytes: &[u8]) -> Result<(), Failure> {
        if binding != self.binding || !self.loaded || bytes.len() > MAX_PLAIN { return Err(Failure::Storage); }
        self.proof.verify()?;
        if self.read(&self.name)? != self.expected { return Err(Failure::Storage); }
        let clear = std::str::from_utf8(bytes).map_err(|_| Failure::Storage)?;
        let encoded = self.native.encrypt(clear).map_err(|_| Failure::Storage)?;
        if encoded.len() > MAX_ENCRYPTED { return Err(Failure::Storage); }
        let stage = format!(".{}.{}.stage", self.name, unique_token());
        let mut file = self.open(&stage, libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL).map_err(|_| Failure::Storage)?;
        file.write_all(encoded.as_bytes()).and_then(|_| file.sync_all()).map_err(|_| Failure::Storage)?;
        if self.read(&stage)?.as_deref() != Some(encoded.as_bytes()) { return Err(Failure::Storage); }
        self.proof.verify()?;
        if self.read(&self.name)? != self.expected { return Err(Failure::Storage); }
        let from = CString::new(stage).map_err(|_| Failure::Storage)?;
        let to = CString::new(self.name.as_str()).map_err(|_| Failure::Storage)?;
        let fd = self.proof.directory.as_raw_fd();
        if unsafe { libc::renameat(fd, from.as_ptr(), fd, to.as_ptr()) } != 0 { return Err(Failure::Storage); }
        self.proof.directory.sync_all().map_err(|_| Failure::Storage)?;
        if self.read(&self.name)?.as_deref() != Some(encoded.as_bytes()) { return Err(Failure::Storage); }
        self.expected = Some(encoded.into_bytes());
        Ok(())
    }
}

// Read-only readiness validation shares the core loader rather than maintaining a
// second receipt schema. NoHttp is unreachable after the validation stop gate.
struct ProbeStore<'a, 'b>(&'a mut PersistentStore<'b>);
impl Store for ProbeStore<'_, '_> {
    fn load(&mut self, binding: &str) -> Result<Option<Vec<u8>>, Failure> { self.0.load(binding) }
    fn persist(&mut self, _: &str, _: &[u8]) -> Result<(), Failure> { Err(Failure::Storage) }
}
struct NoHttp;
impl Transport for NoHttp {
    fn send(&mut self, _: Request) -> Result<Value, Failure> { Err(Failure::Cancelled) }
}
#[cfg(test)]
#[path = "promotion_owner_tests.rs"]
mod tests;
