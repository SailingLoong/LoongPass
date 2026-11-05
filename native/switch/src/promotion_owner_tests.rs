use super::*;
use crate::native::tests::{TEST_CONTEXT, TEST_SECRET};
use crate::ffi::{lp_zcode_open, lp_zcode_call, lp_zcode_close, lp_zcode_free};
use std::ffi::{CStr, c_void};

unsafe extern "C" fn context_ok(_: *mut c_void) -> i32 { 0 }

fn call_native(handle: u64, input: Value) -> Value {
    let bytes = serde_json::to_vec(&input).unwrap();
    unsafe {
        let result = lp_zcode_call(handle, bytes.as_ptr(), bytes.len());
        let value = serde_json::from_slice(CStr::from_ptr(result).to_bytes()).unwrap();
        lp_zcode_free(result);
        value
    }
}

#[test]
fn promotions_default_to_disabled_without_native_configuration() {
    let dir = tempfile::tempdir().unwrap();
    let input = serde_json::to_vec(&json!({
        "source":dir.path().join("credentials.json"), "backupRoot":dir.path(),
        "context":TEST_CONTEXT, "secret":TEST_SECRET
    })).unwrap();
    let handle = unsafe { lp_zcode_open(input.as_ptr(), input.len(), Some(context_ok), std::ptr::null_mut()) };
    assert_ne!(handle, 0);
    let result = call_native(handle, json!({"method":"promotionStatus"}));
    lp_zcode_close(handle);
    assert_eq!(result, json!({"available":false,"reason":"NativeContextUnavailable"}));
}

use crate::{core::{AccountIdentity, AccountSnapshot, CredentialDocument, OAuthFamily}, native::tests::{native_document, encrypt_synthetic}};
use std::{collections::VecDeque, os::unix::fs::PermissionsExt, sync::atomic::{AtomicI32, Ordering}};
const ORIGIN: &str = "https://synthetic-origin.example";
const ALTERNATE_ORIGIN: &str = "https://alternate-origin.example:8443";
const PLATFORM: &str = "darwin-synthetic-arch";

struct Fixture { root: tempfile::TempDir, native: NativeCipher, account: SavedAccount }
impl Fixture {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let native = NativeCipher::new(TEST_CONTEXT, TEST_SECRET).unwrap();
        let account = SavedAccount { snapshot: native.inspect(&native_document(OAuthFamily::Zai, "promotion-fixture", "SYNTHETIC_PROMOTION_SECRET")).unwrap() };
        Self { root, native, account }
    }
    fn owner(&self) -> Owner { self.owner_for(ORIGIN) }
    fn owner_for(&self, origin: &str) -> Owner { Owner::new(self.root.path().to_owned(), "3.17.2".into(), origin.into(), PLATFORM.into(), vec!["synthetic-event".into()]).unwrap() }
    fn binding(&self) -> String { self.owner().receipt_binding(&self.account) }
    fn legacy_binding(&self) -> String { self.account.snapshot.identity().opaque_id() }
    fn legacy_file(&self) -> PathBuf { self.root.path().join(format!("zcode-promotions-{}.enc", self.legacy_binding())) }
    fn file(&self) -> PathBuf { self.root.path().join(format!("zcode-promotions-{}.enc", self.binding())) }
    fn run(&self, wire: &mut impl Transport, mode: Mode) -> Result<Value, Failure> {
        self.owner().run_with_transport(&self.native, &self.account, mode, 100, wire, &mut || Ok(()))
    }
}
struct Wire { replies: VecDeque<Result<Value, Failure>>, calls: Vec<Request> }
impl Wire {
    fn new(replies: Vec<Result<Value, Failure>>) -> Self { Self { replies: replies.into(), calls: vec![] } }
    fn posts(&self) -> usize { self.calls.iter().filter(|c| c.endpoint == Endpoint::Claim).count() }
}
impl Transport for Wire {
    fn send(&mut self, request: Request) -> Result<Value, Failure> {
        self.calls.push(request);
        self.replies.pop_front().expect("unexpected synthetic HTTP request")
    }
}
fn empty_balance() -> Value { json!({"code":0,"data":{"server_time":100,"plans":[]}}) }
fn offer() -> Value { json!({"code":0,"data":{"plans":[{"plan_id":"synthetic-event","name":"Synthetic weekend","priority":1}]}}) }
fn success() -> Value { json!({"code":0,"data":{"plan":{"plan_id":"synthetic-event","user_plan_id":"synthetic-instance","starts_at":100,"ends_at":500}}}) }

// Real owner, real durable store, real lifecycle decision; only network and
// authoritative native observation are synthetic. Changes occur at send boundaries.
#[test]
fn runtime_guard_rechecks_after_each_get_and_sends_zero_posts_on_drift() {
    use crate::{owner_context::{Action, AppIdentity, Binding, Snapshot, decide}, runtime_context::RuntimeContext};
    use std::{cell::RefCell, rc::Rc};
    struct ChangingWire {
        wire: Wire, observed: Rc<RefCell<Option<RuntimeContext>>>,
        change_after: usize, replacement: Option<RuntimeContext>,
    }
    impl Transport for ChangingWire {
        fn send(&mut self, request: Request) -> Result<Value, Failure> {
            let result = self.wire.send(request);
            if self.wire.calls.len() == self.change_after { *self.observed.borrow_mut() = self.replacement.clone(); }
            result
        }
    }
    let runtime = RuntimeContext { origin: ORIGIN.into(), credential_platform: "darwin".into(), request_platform: "darwin-arm64".into() };
    for after in [1, 2] {
        for replacement in [None,
            Some(RuntimeContext { origin: ALTERNATE_ORIGIN.into(), ..runtime.clone() }),
            Some(RuntimeContext { request_platform: "darwin-x64".into(), ..runtime.clone() })] {
            let f = Fixture::new();
            let app = AppIdentity { bundle_id:"dev.zcode.app".into(), bundle_path:"/synthetic/ZCode.app".into(),
                executable_path:"/synthetic/ZCode.app/Contents/MacOS/ZCode".into(),device:1,inode:2 };
            let binding = Binding { app:app.clone(),context_id:"synthetic-runtime-guard".into(),uid:501,main:None,runtime_context:Some(runtime.clone()) };
            let observed = Rc::new(RefCell::new(Some(runtime.clone())));
            let mut gate = || {
                let snapshot = Snapshot { app:app.clone(),context_id:binding.context_id.clone(),complete:true,
                    other_writers:false,processes:vec![],runtime_context:observed.borrow().clone() };
                decide(Action::CheckStopped, &binding, &snapshot, None).map(|_| ()).map_err(|_| Failure::InvalidContext)
            };
            let mut wire = ChangingWire { wire:Wire::new(vec![Ok(empty_balance()),Ok(offer()),Ok(success())]),
                observed:Rc::clone(&observed),change_after:after,replacement };
            let owner = Owner::new(f.root.path().into(), "3.17.2".into(), ORIGIN.into(), "darwin-arm64".into(), vec!["synthetic-event".into()]).unwrap();
            let result = owner.run_with_transport(&f.native, &f.account, Mode::Claim, 100, &mut wire, &mut gate);
            assert_eq!(result, Err(Failure::InvalidContext));
            assert_eq!(wire.wire.calls.len(), after);
            assert_eq!(wire.wire.posts(), 0);
            assert!(!f.file().exists(), "Drift before claim must not invent a durable receipt");
        }
    }
}

#[test]
fn owner_restarts_pending_from_encrypted_store_without_reposting() {
    let f = Fixture::new();
    let mut first = Wire::new(vec![Ok(empty_balance()), Ok(offer()), Err(Failure::Transport)]);
    assert_eq!(f.run(&mut first, Mode::Claim).unwrap()["status"], "resultPending");
    assert_eq!(first.posts(), 1);
    let encrypted = fs::read_to_string(f.file()).unwrap();
    assert!(encrypted.starts_with("enc:v1:"));
    assert!(!encrypted.contains("synthetic-event"));
    assert!(!encrypted.contains("resultPending"));
    assert_eq!(fs::metadata(f.file()).unwrap().mode() & 0o777, 0o600);
    let plain = f.native.decrypt(&encrypted).unwrap();
    assert_eq!(serde_json::from_str::<Value>(&plain).unwrap()["record"]["status"], "resultPending");
    let mut restarted = Wire::new(vec![Ok(empty_balance())]);
    assert_eq!(f.run(&mut restarted, Mode::Claim).unwrap()["status"], "resultPending");
    assert_eq!(restarted.calls.len(), 1);
    assert_eq!(restarted.calls[0].endpoint, Endpoint::Balance);
    assert_eq!(restarted.posts(), 0);
}

#[test]
fn confirmed_receipt_survives_restart_and_suppresses_duplicate_claim() {
    let f = Fixture::new();
    let mut first = Wire::new(vec![Ok(empty_balance()), Ok(offer()), Ok(success())]);
    assert_eq!(f.run(&mut first, Mode::Claim).unwrap()["status"], "claimed");
    let clear = f.native.decrypt(&fs::read_to_string(f.file()).unwrap()).unwrap();
    let saved: Value = serde_json::from_str(&clear).unwrap();
    assert_eq!(saved["confirmed"][0]["plan_id"], "synthetic-event");
    let before = fs::read(f.file()).unwrap();
    assert!(f.owner().probe(&f.native, &f.account, &mut || Ok(())).is_ok());
    assert_eq!(fs::read(f.file()).unwrap(), before, "readiness never rewrites receipts");
    let mut next = Wire::new(vec![Ok(empty_balance()), Ok(offer())]);
    assert_eq!(f.run(&mut next, Mode::Claim).unwrap()["status"], "noClaim");
    assert_eq!(next.posts(), 0);
}

#[test]
fn unknown_campaign_ids_are_not_guessed_or_claimed() {
    let f = Fixture::new();
    let owner = Owner::new(f.root.path().to_owned(), "3.17.2".into(), ORIGIN.into(), PLATFORM.into(), vec![]).unwrap();
    let mut wire = Wire::new(vec![Ok(empty_balance()), Ok(offer())]);
    let result = owner.run_with_transport(&f.native, &f.account, Mode::Claim, 100, &mut wire, &mut || Ok(())).unwrap();
    assert_eq!(result["reason"], "activitySelectionRequired");
    assert_eq!(wire.posts(), 0);
}

#[test]
fn physical_lock_spans_every_network_request_and_pending_is_durable_before_post() {
    let f = Fixture::new();
    struct InspectWire<'a> { fixture: &'a Fixture, wire: Wire }
    impl Transport for InspectWire<'_> {
        fn send(&mut self, request: Request) -> Result<Value, Failure> {
            assert!(matches!(PersistentStore::acquire(self.fixture.root.path(), &self.fixture.binding(), &self.fixture.legacy_binding(), &self.fixture.native), Err(Failure::Busy)));
            if request.endpoint == Endpoint::Claim {
                let encoded = fs::read_to_string(self.fixture.file()).unwrap();
                let clear = self.fixture.native.decrypt(&encoded).unwrap();
                let saved: Value = serde_json::from_str(&clear).unwrap();
                assert_eq!(saved["record"]["status"], "resultPending");
            }
            self.wire.send(request)
        }
    }
    let mut wire = InspectWire { fixture: &f, wire: Wire::new(vec![Ok(empty_balance()), Ok(offer()), Ok(success())]) };
    assert_eq!(f.run(&mut wire, Mode::Claim).unwrap()["status"], "claimed");
    assert_eq!(wire.wire.posts(), 1);
    assert!(PersistentStore::acquire(f.root.path(), &f.binding(), &f.legacy_binding(), &f.native).is_ok(), "lock released after entire round");
}

#[test]
fn malformed_encrypted_receipt_is_not_reset_or_reported_available() {
    let f = Fixture::new();
    let wrong = f.native.encrypt(&json!({"version":1,"binding":f.binding(),"record":{"status":"bogus"},"confirmed":[]}).to_string()).unwrap();
    fs::write(f.file(), &wrong).unwrap();
    fs::set_permissions(f.file(), fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(f.owner().probe(&f.native, &f.account, &mut || Ok(())), Err(Failure::Storage));
    let mut wire = Wire::new(vec![]);
    assert_eq!(f.run(&mut wire, Mode::Claim), Err(Failure::Storage));
    assert!(wire.calls.is_empty());
    assert_eq!(fs::read_to_string(f.file()).unwrap(), wrong);
}

#[test]
fn unreadable_invalid_or_symlink_receipts_never_become_absence() {
    let f = Fixture::new();
    fs::write(f.file(), "not-native-ciphertext").unwrap();
    fs::set_permissions(f.file(), fs::Permissions::from_mode(0o600)).unwrap();
    let mut wire = Wire::new(vec![]);
    assert_eq!(f.run(&mut wire, Mode::Claim), Err(Failure::Storage));
    fs::set_permissions(f.file(), fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!(f.run(&mut wire, Mode::Claim), Err(Failure::Storage));
    let target = f.root.path().join("retained-corrupt");
    fs::rename(f.file(), &target).unwrap();
    std::os::unix::fs::symlink(&target, f.file()).unwrap();
    assert_eq!(f.run(&mut wire, Mode::Claim), Err(Failure::Storage));
    assert!(wire.calls.is_empty());
    assert_eq!(fs::read_to_string(target).unwrap(), "not-native-ciphertext");
}

#[test]
fn lost_receipt_publication_retains_pending_and_next_round_only_reconciles() {
    let f = Fixture::new();
    struct FailReceipt<'a> { fixture: &'a Fixture, wire: Wire }
    impl Transport for FailReceipt<'_> {
        fn send(&mut self, request: Request) -> Result<Value, Failure> {
            if request.endpoint == Endpoint::Claim {
                fs::set_permissions(self.fixture.file(), fs::Permissions::from_mode(0o400)).unwrap();
            }
            self.wire.send(request)
        }
    }
    let mut wire = FailReceipt { fixture: &f, wire: Wire::new(vec![Ok(empty_balance()), Ok(offer()), Ok(success())]) };
    assert_eq!(f.run(&mut wire, Mode::Claim), Err(Failure::Storage));
    assert_eq!(wire.wire.posts(), 1);
    fs::set_permissions(f.file(), fs::Permissions::from_mode(0o600)).unwrap();
    let mut next = Wire::new(vec![Ok(empty_balance())]);
    assert_eq!(f.run(&mut next, Mode::Claim).unwrap()["status"], "resultPending");
    assert_eq!(next.posts(), 0);
}

#[test]
fn verified_3172_requires_global_jwt_and_never_substitutes_derived_start_or_coding_keys() {
    let native = NativeCipher::new(TEST_CONTEXT, TEST_SECRET).unwrap();
    for family in [OAuthFamily::Zai, OAuthFamily::BigModel] {
        let identity = AccountIdentity::new(TEST_CONTEXT, family, "promotion-user").unwrap();
        let keys = identity.credential_keys();
        let mut fields: Value = serde_json::from_slice(&native_document(family, "promotion-user", "fixture").to_bytes().unwrap()).unwrap();
        fields[&keys[4]] = json!(encrypt_synthetic(" global-start-jwt "));
        fields[&keys[5]] = json!(encrypt_synthetic("never-use-coding"));
        fields[&keys[6]] = json!(encrypt_synthetic("never-use-derived-start"));
        let account = |fields: &Value| SavedAccount { snapshot: AccountSnapshot::capture(identity.clone(), &CredentialDocument::parse(&serde_json::to_vec(fields).unwrap()).unwrap()).unwrap() };
        let credentials = Credentials::load(&native, &account(&fields)).unwrap();
        assert_eq!(credentials.jwt.as_str(), "global-start-jwt");
        let mut echoes = json!({"coding":"never-use-coding", "start":"never-use-derived-start"});
        scrub(&mut echoes, &credentials.values);
        assert_eq!(echoes, json!({"coding":null, "start":null}));
        for invalid in ["bad\nheader", "", " "] {
            fields[&keys[4]] = json!(encrypt_synthetic(invalid));
            assert!(matches!(Credentials::load(&native, &account(&fields)), Err(Failure::Unauthorized)));
        }
        fields.as_object_mut().unwrap().remove(&keys[4]);
        assert!(matches!(Credentials::load(&native, &account(&fields)), Err(Failure::Unauthorized)), "derived Start and coding keys cannot replace global JWT");
        fields.as_object_mut().unwrap().remove(&keys[6]);
        assert!(matches!(Credentials::load(&native, &account(&fields)), Err(Failure::Unauthorized)), "coding key alone cannot replace global JWT");
        fields.as_object_mut().unwrap().remove(&keys[5]);
        fields[&keys[6]] = json!(encrypt_synthetic("never-use-derived-start"));
        assert!(matches!(Credentials::load(&native, &account(&fields)), Err(Failure::Unauthorized)), "derived Start key alone cannot replace global JWT");
        let f = Fixture::new();
        let missing_global = account(&fields);
        let mut wire = Wire::new(vec![]);
        for mode in [Mode::Preview, Mode::Claim] {
            assert_eq!(f.owner().run_with_transport(&native, &missing_global, mode, 100, &mut wire, &mut || Ok(())), Err(Failure::Unauthorized));
        }
        assert!(wire.calls.is_empty());
        assert!(fs::read_dir(f.root.path()).unwrap().next().is_none());
    }
}

#[test]
fn context_change_or_key_change_blocks_before_transport_or_store_reset() {
    let f = Fixture::new();
    let mut wire = Wire::new(vec![]);
    let changed = NativeCipher::new("other-native-context", TEST_SECRET).unwrap();
    assert_eq!(f.owner().run_with_transport(&changed, &f.account, Mode::Claim, 100, &mut wire, &mut || Ok(())), Err(Failure::InvalidContext));
    assert_eq!(f.owner().run_with_transport(&f.native, &f.account, Mode::Claim, 100, &mut wire, &mut || Err(Failure::InvalidContext)), Err(Failure::InvalidContext));
    assert!(wire.calls.is_empty());
    assert!(!f.file().exists());
}

#[test]
fn transport_output_and_persisted_record_never_include_urls_or_native_secrets() {
    let f = Fixture::new();
    let credentials = Credentials::load(&f.native, &f.account).unwrap();
    for bad_name in [format!("echo {}", credentials.jwt.as_str()), "https://sensitive.example/account?token=canary".into()] {
        let mut preview = offer();
        preview["data"]["plans"][0]["name"] = json!(bad_name);
        let mut wire = Wire::new(vec![Ok(empty_balance()), Ok(preview)]);
        let result = f.run(&mut wire, Mode::Preview).unwrap();
        assert!(!result.to_string().contains(&bad_name));
        let clear = f.native.decrypt(&fs::read_to_string(f.file()).unwrap()).unwrap();
        assert!(!clear.contains(&bad_name));
        assert!(!result.to_string().contains("enc:v1:"));
        assert!(!result.to_string().contains(f.root.path().to_str().unwrap()));
    }
}

#[test]
fn verified_3172_requests_use_supplied_origin_platform_and_fifteen_second_timeout() {
    for origin in [ORIGIN, ALTERNATE_ORIGIN, "http://synthetic-local.example:8080"] {
        let http = Http::new("3.17.2".into(), origin.into(), PLATFORM.into(), Some(Zeroizing::new("synthetic-http-secret".into()))).unwrap();
        for endpoint in [Endpoint::Balance, Endpoint::Preview, Endpoint::Claim] {
            let req = http.build_request(Request { endpoint, plan: (endpoint == Endpoint::Claim).then(|| "synthetic-event".into()) }).unwrap();
            assert_eq!(req.url().origin().ascii_serialization(), origin);
            assert!(!req.headers().contains_key("X-Title"));
            assert!(!req.headers().contains_key("User-Agent"));
            assert_eq!(req.timeout(), Some(&Duration::from_secs(15)));
            assert_eq!(req.headers()["authorization"], "Bearer synthetic-http-secret");
            assert!(req.headers()["authorization"].is_sensitive());
            assert!(!format!("{req:?}").contains("synthetic-http-secret"));
            assert!(!req.headers().contains_key("X-Aliyun-Captcha-Verify-Param"));
            if endpoint == Endpoint::Claim {
                assert_eq!(req.method(), reqwest::Method::POST);
                assert_eq!(req.url().as_str(), format!("{origin}/api/v1/zcode-plan/billing/claim"));
                assert_eq!(req.headers()["X-ZCode-App-Version"], "3.17.2");
                assert_eq!(req.headers()["X-Platform"], PLATFORM);
                let body: Value = serde_json::from_slice(req.body().unwrap().as_bytes().unwrap()).unwrap();
                assert_eq!(body, json!({"plan_id":"synthetic-event"}));
            } else {
                assert_eq!(req.method(), reqwest::Method::GET);
                let suffix = if endpoint == Endpoint::Preview { "preview?app_version=3.17.2&platform=darwin-synthetic-arch" } else { "balance?app_version=3.17.2" };
                assert_eq!(req.url().as_str(), format!("{origin}/api/v1/zcode-plan/billing/{suffix}"));
                assert!(!req.headers().contains_key("X-ZCode-App-Version"));
                assert!(!req.headers().contains_key("X-Platform"));
            }
        }
        assert!(http.build_request(Request { endpoint: Endpoint::Claim, plan: None }).is_err());
        assert!(http.build_request(Request { endpoint: Endpoint::Preview, plan: Some("not-allowed".into()) }).is_err());
    }
}

#[test]
fn preview_bearer_is_optional_but_balance_and_claim_require_it() {
    let http = Http::new("3.17.2".into(), ORIGIN.into(), PLATFORM.into(), None).unwrap();
    let req = http.build_request(Request { endpoint: Endpoint::Preview, plan: None }).unwrap();
    assert!(!req.headers().contains_key("authorization"));
    for endpoint in [Endpoint::Balance, Endpoint::Claim] {
        assert!(matches!(http.build_request(Request { endpoint, plan: (endpoint == Endpoint::Claim).then(|| "synthetic-event".into()) }), Err(Failure::Unauthorized)));
    }
}

#[test]
fn invalid_origin_platform_or_version_never_falls_back_to_a_default() {
    let f = Fixture::new();
    for origin in ["", "relative.example", "https:relative.example", "ftp://synthetic.example", "https://user@synthetic.example", "https://@synthetic.example", "https://synthetic.example/path", "https://synthetic.example/..", "https://synthetic.example?token=x", "https://synthetic.example#fragment", "https://synthetic.example\\path"] {
        assert!(matches!(Owner::new(f.root.path().to_owned(), "3.17.2".into(), origin.into(), PLATFORM.into(), vec![]), Err(Failure::InvalidContext)), "accepted invalid origin: {origin}");
    }
    for platform in ["", " darwin-arm64", "darwin arm64", "darwin-arm64\r\ninjected", "darwin/arm64"] {
        assert!(matches!(Owner::new(f.root.path().to_owned(), "3.17.2".into(), ORIGIN.into(), platform.into(), vec![]), Err(Failure::InvalidContext)));
    }
    assert!(matches!(Owner::new(f.root.path().to_owned(), "bad\r\nheader".into(), ORIGIN.into(), PLATFORM.into(), vec![]), Err(Failure::InvalidContext)));
    let canonical = f.owner_for("http://synthetic-local.example");
    let normalized = f.owner_for("  http://SYNTHETIC-local.example:80/  ");
    assert_eq!(canonical.receipt_binding(&f.account), normalized.receipt_binding(&f.account));
    assert!(fs::read_dir(f.root.path()).unwrap().next().is_none());
}

#[test]
fn alternate_origin_receipts_are_separate_and_original_pending_survives() {
    let f = Fixture::new();
    let mut first = Wire::new(vec![Ok(empty_balance()), Ok(offer()), Err(Failure::Transport)]);
    assert_eq!(f.run(&mut first, Mode::Claim).unwrap()["status"], "resultPending");
    let original_pending = fs::read(f.file()).unwrap();
    let alternate = f.owner_for(ALTERNATE_ORIGIN);
    let alternate_binding = alternate.receipt_binding(&f.account);
    assert_ne!(f.binding(), alternate_binding);
    assert_ne!(f.binding(), f.legacy_binding());
    let alternate_file = f.root.path().join(format!("zcode-promotions-{alternate_binding}.enc"));
    let mut claim_alternate = Wire::new(vec![Ok(empty_balance()), Ok(offer()), Ok(success())]);
    assert_eq!(alternate.run_with_transport(&f.native, &f.account, Mode::Claim, 100, &mut claim_alternate, &mut || Ok(())).unwrap()["status"], "claimed");
    assert_eq!(claim_alternate.posts(), 1);
    assert!(alternate_file.is_file());
    assert_eq!(fs::read(f.file()).unwrap(), original_pending);
    let mut original_again = Wire::new(vec![Ok(empty_balance())]);
    assert_eq!(f.run(&mut original_again, Mode::Claim).unwrap()["status"], "resultPending");
    assert_eq!(original_again.posts(), 0);
    let mut alternate_again = Wire::new(vec![Ok(empty_balance()), Ok(offer())]);
    assert_eq!(alternate.run_with_transport(&f.native, &f.account, Mode::Claim, 100, &mut alternate_again, &mut || Ok(())).unwrap()["status"], "noClaim");
    assert_eq!(alternate_again.posts(), 0);
}

#[test]
fn receipt_namespace_also_binds_account_context_and_origin_port() {
    let f = Fixture::new();
    let other_account = SavedAccount { snapshot: f.native.inspect(&native_document(OAuthFamily::Zai, "other-promotion-user", "SYNTHETIC_PROMOTION_SECRET")).unwrap() };
    assert_ne!(f.owner().receipt_binding(&f.account), f.owner().receipt_binding(&other_account));
    let other_context_native = NativeCipher::new("different-native-context", TEST_SECRET).unwrap();
    let other_context_account = SavedAccount { snapshot: other_context_native.inspect(&native_document(OAuthFamily::Zai, "promotion-fixture", "SYNTHETIC_PROMOTION_SECRET")).unwrap() };
    assert_ne!(f.owner().receipt_binding(&f.account), f.owner().receipt_binding(&other_context_account));
    assert_ne!(f.owner().receipt_binding(&f.account), f.owner_for("https://synthetic-origin.example:8443").receipt_binding(&f.account));
    assert_ne!(f.owner().receipt_binding(&f.account), f.owner_for("http://synthetic-origin.example").receipt_binding(&f.account));
}

#[test]
fn legacy_unscoped_pending_is_preserved_and_blocks_every_origin() {
    let f = Fixture::new();
    let mut first = Wire::new(vec![Ok(empty_balance()), Ok(offer()), Err(Failure::Transport)]);
    assert_eq!(f.run(&mut first, Mode::Claim).unwrap()["status"], "resultPending");
    let mut legacy: Value = serde_json::from_str(&f.native.decrypt(&fs::read_to_string(f.file()).unwrap()).unwrap()).unwrap();
    legacy["binding"] = json!(f.legacy_binding());
    let encrypted = f.native.encrypt(&legacy.to_string()).unwrap();
    fs::write(f.legacy_file(), &encrypted).unwrap();
    fs::set_permissions(f.legacy_file(), fs::Permissions::from_mode(0o600)).unwrap();
    let pending = fs::read(f.file()).unwrap();
    for owner in [f.owner(), f.owner_for(ALTERNATE_ORIGIN)] {
        assert_eq!(owner.probe(&f.native, &f.account, &mut || Ok(())), Err(Failure::Storage));
        let mut wire = Wire::new(vec![]);
        assert_eq!(owner.run_with_transport(&f.native, &f.account, Mode::Claim, 100, &mut wire, &mut || Ok(())), Err(Failure::Storage));
        assert!(wire.calls.is_empty());
    }
    assert_eq!(fs::read(f.file()).unwrap(), pending);
    assert_eq!(fs::read_to_string(f.legacy_file()).unwrap(), encrypted);
}

#[test]
fn legacy_symlink_or_live_writer_is_not_treated_as_absence() {
    let f = Fixture::new();
    let retained = f.root.path().join("legacy-evidence");
    fs::write(&retained, "retained synthetic legacy bytes").unwrap();
    std::os::unix::fs::symlink(&retained, f.legacy_file()).unwrap();
    let mut wire = Wire::new(vec![]);
    assert_eq!(f.run(&mut wire, Mode::Claim), Err(Failure::Storage));
    assert!(wire.calls.is_empty());
    assert_eq!(fs::read_to_string(retained).unwrap(), "retained synthetic legacy bytes");
    let other = Fixture::new();
    let _old_writer = FileLock::acquire_recoverable(&other.legacy_file(), Duration::from_millis(250)).unwrap();
    assert_eq!(other.run(&mut wire, Mode::Claim), Err(Failure::Busy));
    assert!(wire.calls.is_empty());
}

unsafe extern "C" fn contextual_gate(userdata: *mut c_void) -> i32 { (&*(userdata as *const AtomicI32)).load(Ordering::SeqCst) }
#[test]
fn ffi_promotion_readiness_allows_verified_live_writer_but_not_changed_context() {
    let f = Fixture::new();
    let source = f.root.path().join("credentials.json");
    fs::write(&source, f.account.snapshot.scoped_document().to_bytes().unwrap()).unwrap();
    fs::set_permissions(&source, fs::Permissions::from_mode(0o600)).unwrap();
    let gate = AtomicI32::new(0);
    let config = serde_json::to_vec(&json!({"source":source,"backupRoot":f.root.path(),"context":TEST_CONTEXT,"secret":TEST_SECRET,"promotionStoreRoot":f.root.path(),"promotionPlanIds":[],"appVersion":"3.17.2","promotionOrigin":ORIGIN,"promotionPlatform":PLATFORM})).unwrap();
    let handle = unsafe { lp_zcode_open(config.as_ptr(), config.len(), Some(contextual_gate), (&gate as *const AtomicI32).cast_mut().cast()) };
    assert_ne!(handle, 0);
    assert_eq!(call_native(handle, json!({"method":"promotionStatus"}))["available"], false);
    assert!(call_native(handle, json!({"method":"captureCurrent"})).get("accountId").is_some());
    gate.store(1, Ordering::SeqCst);
    assert_eq!(call_native(handle, json!({"method":"status"}))["available"], false);
    assert_eq!(call_native(handle, json!({"method":"promotionStatus"}))["available"], true);
    for state in [2, 3, -1, 9] {
        gate.store(state, Ordering::SeqCst);
        let result = call_native(handle, json!({"method":"promotionStatus"}));
        assert_eq!(result["available"], false);
        assert_eq!(result["reason"], "NativeContextUnavailable");
    }
    lp_zcode_close(handle);
}

#[test]
#[ignore = "Launched only by synthetic promotion crash-recovery parent"]
fn promotion_crash_fixture_child() {
    let mut root = String::new();
    std::io::stdin().read_line(&mut root).unwrap();
    let root = PathBuf::from(root.trim_end());
    let native = NativeCipher::new(TEST_CONTEXT, TEST_SECRET).unwrap();
    let account = SavedAccount { snapshot: native.inspect(&native_document(OAuthFamily::Zai, "promotion-fixture", "SYNTHETIC_PROMOTION_SECRET")).unwrap() };
    let owner = Owner::new(root, "3.17.2".into(), ORIGIN.into(), PLATFORM.into(), vec!["synthetic-event".into()]).unwrap();
    struct CrashWire;
    impl Transport for CrashWire {
        fn send(&mut self, request: Request) -> Result<Value, Failure> {
            match request.endpoint {
                Endpoint::Balance => Ok(empty_balance()),
                Endpoint::Preview => Ok(offer()),
                Endpoint::Claim => std::process::exit(79), // pending durable, lock Drop does not run
            }
        }
    }
    let _ = owner.run_with_transport(&native, &account, Mode::Claim, 100, &mut CrashWire, &mut || Ok(()));
    panic!("crash hook was not reached");
}

#[test]
fn real_crash_retained_lock_is_recovered_only_after_owner_exit_and_only_balance_runs() {
    let f = Fixture::new();
    let mut child = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "promotion_owner::tests::promotion_crash_fixture_child", "--ignored", "--nocapture"])
        .stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped()).spawn().unwrap();
    child.stdin.take().unwrap().write_all(format!("{}\n", f.root.path().display()).as_bytes()).unwrap();
    let output = child.wait_with_output().unwrap();
    assert_eq!(output.status.code(), Some(79));
    let lock = PathBuf::from(format!("{}.lock", f.file().display()));
    assert!(lock.is_dir(), "real abrupt exit retains physical ownership files");
    let pending = fs::read(f.file()).unwrap();
    let mut wire = Wire::new(vec![Ok(empty_balance())]);
    assert_eq!(f.run(&mut wire, Mode::Claim).unwrap()["status"], "resultPending");
    assert_eq!(wire.calls.iter().map(|r| r.endpoint).collect::<Vec<_>>(), vec![Endpoint::Balance]);
    assert!(!lock.exists());
    assert!(f.native.decrypt(std::str::from_utf8(&pending).unwrap()).unwrap().contains("resultPending"));
}

#[test]
fn replaced_physical_lock_blocks_next_request_and_preserves_unknown_new_owner() {
    let f = Fixture::new();
    struct ReplaceLock<'a> { fixture: &'a Fixture, calls: usize }
    impl Transport for ReplaceLock<'_> {
        fn send(&mut self, request: Request) -> Result<Value, Failure> {
            self.calls += 1;
            assert_eq!(request.endpoint, Endpoint::Balance);
            let lock = PathBuf::from(format!("{}.lock", self.fixture.file().display()));
            fs::rename(&lock, self.fixture.root.path().join("retained-lock")).unwrap();
            fs::create_dir(&lock).unwrap();
            Ok(empty_balance())
        }
    }
    let mut wire = ReplaceLock { fixture: &f, calls: 0 };
    assert_eq!(f.run(&mut wire, Mode::Claim), Err(Failure::Busy));
    assert_eq!(wire.calls, 1);
    assert!(!f.file().exists());
    assert!(f.root.path().join("retained-lock").is_dir());
    let unknown = PathBuf::from(format!("{}.lock", f.file().display()));
    assert!(unknown.is_dir());
    assert_eq!(fs::read_dir(unknown).unwrap().count(), 0);
}

#[test]
fn captcha_verification_state_survives_restart_without_any_automatic_retry() {
    let f = Fixture::new();
    let mut first = Wire::new(vec![Ok(empty_balance()), Ok(offer()), Ok(json!({"code":3007,"message":"captcha required"}))]);
    let result = f.run(&mut first, Mode::Claim).unwrap();
    assert_eq!(result["status"], "verificationRequired");
    assert_eq!(first.posts(), 1);
    let before = fs::read(f.file()).unwrap();
    assert!(f.owner().probe(&f.native, &f.account, &mut || Ok(())).is_ok());
    assert_eq!(before, fs::read(f.file()).unwrap());
    let mut next = Wire::new(vec![]);
    assert_eq!(f.run(&mut next, Mode::Claim).unwrap()["status"], "verificationRequired");
    assert!(next.calls.is_empty());
}

#[test]
fn http_response_boundaries_reject_bad_status_shape_size_and_scrub_secret_echoes() {
    let jwt = Zeroizing::new("synthetic-http-canary".into());
    assert_eq!(parse_response(401, b"untrusted", Some(&jwt)), Err(Failure::Unauthorized));
    assert_eq!(parse_response(403, b"untrusted", Some(&jwt)), Err(Failure::Unauthorized));
    assert_eq!(parse_response(302, b"https://untrusted.example", Some(&jwt)), Err(Failure::Transport));
    assert_eq!(parse_response(500, b"error containing secret", Some(&jwt)), Err(Failure::Transport));
    for body in [&b"[]"[..], &b"not json"[..], &b"null"[..]] {
        assert_eq!(parse_response(200, body, Some(&jwt)), Err(Failure::InvalidResponse));
    }
    assert_eq!(parse_response(200, &vec![b' '; MAX_PLAIN + 1], Some(&jwt)), Err(Failure::InvalidResponse));
    let response = json!({"code":0,"data":{"name":"echo synthetic-http-canary","url":"https://sensitive.example","synthetic-http-canary":"untrusted"}});
    let parsed = parse_response(200, &serde_json::to_vec(&response).unwrap(), Some(&jwt)).unwrap();
    assert!(!parsed.to_string().contains("synthetic-http-canary"));
    assert!(!parsed.to_string().contains("https://"));
    for error in [Failure::InvalidResponse, Failure::Transport, Failure::Unauthorized, Failure::Storage] {
        assert!(!error_code(error).contains("/"));
    }
}
