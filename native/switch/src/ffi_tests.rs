use super::*;
use crate::{
    core::OAuthFamily,
    native::tests::{native_document, TEST_CONTEXT, TEST_SECRET},
};
use std::{
    ffi::CStr,
    fs,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    sync::atomic::{AtomicBool, Ordering},
};
unsafe extern "C" fn stopped(userdata: *mut c_void) -> i32 {
    if (&*(userdata as *const AtomicBool)).load(Ordering::SeqCst) {
        0
    } else {
        1
    }
}
struct Fixture {
    root: tempfile::TempDir,
    source: PathBuf,
    target: PathBuf,
    backup: PathBuf,
    gate: Box<AtomicBool>,
    session: u64,
}
impl Fixture {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let source = root.path().join("credentials.json");
        let target = root.path().join("saved.json");
        let backup = root.path().join("backups");
        fs::create_dir(&backup).unwrap();
        fs::set_permissions(&backup, fs::Permissions::from_mode(0o700)).unwrap();
        for (path, id) in [(&source, "ffi-a"), (&target, "ffi-b")] {
            fs::write(
                path,
                native_document(OAuthFamily::Zai, id, "synthetic")
                    .to_bytes()
                    .unwrap(),
            )
            .unwrap();
            fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
        }
        let gate = Box::new(AtomicBool::new(true));
        let config=serde_json::to_vec(&serde_json::json!({"source":source,"backupRoot":backup,"context":TEST_CONTEXT,"secret":TEST_SECRET})).unwrap();
        let session = unsafe {
            lp_zcode_open(
                config.as_ptr(),
                config.len(),
                Some(stopped),
                (&*gate as *const AtomicBool).cast_mut().cast(),
            )
        };
        assert_ne!(session, 0, "explicit native context must open");
        Self {
            root,
            source,
            target,
            backup,
            gate,
            session,
        }
    }
    fn call(&self, request: serde_json::Value) -> serde_json::Value {
        call(self.session, request)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        lp_zcode_close(self.session);
    }
}
fn call(session: u64, request: serde_json::Value) -> serde_json::Value {
    let input = serde_json::to_vec(&request).unwrap();
    unsafe {
        let response = lp_zcode_call(session, input.as_ptr(), input.len());
        assert!(!response.is_null());
        let bytes = CStr::from_ptr(response).to_bytes().to_vec();
        lp_zcode_free(response);
        serde_json::from_slice(&bytes).unwrap()
    }
}
#[test]
fn abi_switches_and_restores_without_exposing_credentials_or_paths() {
    let f = Fixture::new();
    let original = fs::read(&f.source).unwrap();
    let current = f.call(serde_json::json!({"method":"captureCurrent"}));
    let target = f.call(serde_json::json!({"method":"captureSelected","path":f.target}));
    assert_eq!(current["family"], "zai");
    assert_eq!(target["label"], "ffi-b");
    assert_eq!(current["revision"].as_str().unwrap().len(), 64);
    let switched=f.call(serde_json::json!({"method":"switchAccount","accountId":target["accountId"],"expectedRevision":current["revision"]}));
    assert_eq!(switched["outcome"], "switched");
    let restored =
        f.call(serde_json::json!({"method":"restore","operationId":switched["operationId"]}));
    assert_eq!(restored["outcome"], "restored");
    assert_eq!(fs::read(&f.source).unwrap(), original);
    for reply in [current, target, switched, restored] {
        let text = reply.to_string();
        for forbidden in [
            "SYNTHETIC_CANARY",
            "enc:v1:",
            TEST_SECRET,
            f.root.path().to_str().unwrap(),
        ] {
            assert!(!text.contains(forbidden));
        }
    }
}
#[test]
fn missing_context_or_active_writer_stays_blocked() {
    assert_eq!(
        unsafe { lp_zcode_open(b"{}".as_ptr(), 2, None, std::ptr::null_mut()) },
        0
    );
    assert_eq!(
        call(0, serde_json::json!({"method":"captureCurrent"}))["error"],
        "NativeContextUnavailable"
    );
    let f = Fixture::new();
    let original = fs::read(&f.source).unwrap();
    f.gate.store(false, Ordering::SeqCst);
    assert_eq!(
        f.call(serde_json::json!({"method":"status"})),
        serde_json::json!({"available":false,"reason":"WritersActive"})
    );
    assert_eq!(
        f.call(serde_json::json!({"method":"captureCurrent"}))["error"],
        "WritersActive"
    );
    assert_eq!(fs::read(&f.source).unwrap(), original);
}
#[test]
fn stale_unknown_or_injected_native_command_is_rejected() {
    let f = Fixture::new();
    let original = fs::read(&f.source).unwrap();
    for request in [
        serde_json::json!({"method":"captureCurrent","stopped":true}),
        serde_json::json!({"method":"configure","secret":"not-permitted"}),
        serde_json::json!({"method":"restore","operationId":"../foreign"}),
    ] {
        assert_eq!(f.call(request)["error"], "InvalidArguments");
    }
    assert_eq!(f.call(serde_json::json!({"method":"switchAccount","accountId":"0".repeat(64),"expectedRevision":"0".repeat(64)}))["error"],"UnknownAccount");
    assert_eq!(fs::read(&f.source).unwrap(), original);
}
#[test]
fn explicit_native_selected_recovery_survives_session_restart() {
    let f = Fixture::new();
    let original = fs::read(&f.source).unwrap();
    let a = f.call(serde_json::json!({"method":"captureCurrent"}));
    let b = f.call(serde_json::json!({"method":"captureSelected","path":f.target}));
    let r=f.call(serde_json::json!({"method":"switchAccount","accountId":b["accountId"],"expectedRevision":a["revision"]}));
    assert_eq!(r["outcome"], "switched");
    let op = fs::read_dir(&f.backup)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    lp_zcode_close(f.session);
    assert_eq!(
        f.call(serde_json::json!({"method":"restore","operationId":r["operationId"]}))["error"],
        "NativeContextUnavailable"
    );
    let config=serde_json::to_vec(&serde_json::json!({"source":f.source,"backupRoot":f.backup,"context":TEST_CONTEXT,"secret":TEST_SECRET})).unwrap();
    let session = unsafe {
        lp_zcode_open(
            config.as_ptr(),
            config.len(),
            Some(stopped),
            (&*f.gate as *const AtomicBool).cast_mut().cast(),
        )
    };
    assert_ne!(session, 0);
    let restored = call(
        session,
        serde_json::json!({"method":"restoreSelected","path":op}),
    );
    lp_zcode_close(session);
    assert_eq!(restored["outcome"], "restored");
    assert_eq!(fs::read(&f.source).unwrap(), original);
}
#[test]
fn native_context_errors_are_not_misreported_as_running_app() {
    unsafe extern "C" fn changed(_: *mut c_void) -> i32 {
        2
    }
    unsafe extern "C" fn unknown(_: *mut c_void) -> i32 {
        3
    }
    let f = Fixture::new();
    let config = serde_json::to_vec(&serde_json::json!({"source":f.source,"backupRoot":f.backup,"context":TEST_CONTEXT,"secret":TEST_SECRET})).unwrap();
    for (gate, code) in [
        (changed as Gate, "SourceChanged"),
        (unknown as Gate, "NativeContextUnavailable"),
    ] {
        let session = unsafe {
            lp_zcode_open(
                config.as_ptr(),
                config.len(),
                Some(gate),
                std::ptr::null_mut(),
            )
        };
        assert_ne!(session, 0);
        assert_eq!(
            call(session, serde_json::json!({"method":"status"}))["reason"],
            code
        );
        assert_eq!(
            call(session, serde_json::json!({"method":"captureCurrent"}))["error"],
            code
        );
        lp_zcode_close(session);
    }
}
#[test]
fn configured_backend_does_not_claim_ready_before_explicit_source_capture() {
    let f = Fixture::new();
    assert_eq!(
        f.call(serde_json::json!({"method":"status"})),
        serde_json::json!({"available":false,"reason":"NativeCaptureRequired"})
    );
    f.call(serde_json::json!({"method":"captureSelected","path":f.target}));
    assert_eq!(
        f.call(serde_json::json!({"method":"status"}))["available"],
        false
    );
    f.call(serde_json::json!({"method":"captureCurrent"}));
    assert_eq!(
        f.call(serde_json::json!({"method":"status"})),
        serde_json::json!({"available":true,"reason":null})
    );
}
#[test]
fn full_snapshot_table_still_refreshes_existing_account() {
    let f = Fixture::new();
    for i in 0..128 {
        let bytes = native_document(OAuthFamily::Zai, &format!("ffi-account-{i}"), "snapshot")
            .to_bytes()
            .unwrap();
        fs::write(&f.target, bytes).unwrap();
        let response = f.call(serde_json::json!({"method":"captureSelected","path":f.target}));
        assert!(response.get("accountId").is_some(), "{response}");
    }
    let refreshed = f.call(serde_json::json!({"method":"captureSelected","path":f.target}));
    assert!(refreshed.get("accountId").is_some(), "{refreshed}");
    assert_eq!(
        f.call(serde_json::json!({"method":"captureCurrent"}))["error"],
        "Storage"
    );
}
#[test]
fn panic_is_contained_per_session_and_close_still_drops_the_owner() {
    let f = Fixture::new();
    let result = std::panic::catch_unwind(|| {
        with_session(f.session, |_| panic!("synthetic internal failure"))
    });
    assert!(
        result.is_ok(),
        "panic escaped and poisoned the owner registry"
    );
    assert_eq!(
        result.unwrap(),
        serde_json::json!({"error":"CommitUncertain","outcome":"unknown"})
    );
    assert_eq!(
        f.call(serde_json::json!({"method":"status"}))["reason"],
        "CommitUncertain"
    );
    lp_zcode_close(f.session);
    assert_eq!(
        f.call(serde_json::json!({"method":"captureCurrent"}))["error"],
        "NativeContextUnavailable"
    );
}
#[test]
fn restoring_bytes_does_not_claim_that_a_new_key_context_is_authenticated() {
    let f = Fixture::new();
    let a = f.call(serde_json::json!({"method":"captureCurrent"}));
    let b = f.call(serde_json::json!({"method":"captureSelected","path":f.target}));
    assert_eq!(f.call(serde_json::json!({"method":"switchAccount","accountId":b["accountId"],"expectedRevision":a["revision"]}))["outcome"],"switched");
    let op = fs::read_dir(&f.backup)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    let config=serde_json::to_vec(&serde_json::json!({"source":f.source,"backupRoot":f.backup,"context":TEST_CONTEXT,"secret":"wrong-explicit-key"})).unwrap();
    let session = unsafe {
        lp_zcode_open(
            config.as_ptr(),
            config.len(),
            Some(stopped),
            (&*f.gate as *const AtomicBool).cast_mut().cast(),
        )
    };
    assert_ne!(session, 0);
    assert_eq!(
        call(
            session,
            serde_json::json!({"method":"restoreSelected","path":op})
        )["outcome"],
        "restored"
    );
    assert_eq!(
        call(session, serde_json::json!({"method":"status"})),
        serde_json::json!({"available":false,"reason":"NativeCaptureRequired"})
    );
    assert_eq!(
        call(session, serde_json::json!({"method":"captureCurrent"}))["error"],
        "InvalidCredential"
    );
    lp_zcode_close(session);
}
#[test]
fn abi_input_bounds_and_idempotent_close_fail_without_touching_source() {
    let f = Fixture::new();
    let original = fs::read(&f.source).unwrap();
    for (ptr, len) in [
        (std::ptr::null(), 1),
        (b"x".as_ptr(), 0),
        (b"x".as_ptr(), INPUT_LIMIT + 1),
    ] {
        unsafe {
            assert_eq!(
                lp_zcode_open(
                    ptr,
                    len,
                    Some(stopped),
                    (&*f.gate as *const AtomicBool).cast_mut().cast()
                ),
                0
            );
            let response = lp_zcode_call(f.session, ptr, len);
            assert!(!response.is_null());
            assert_eq!(
                serde_json::from_slice::<serde_json::Value>(CStr::from_ptr(response).to_bytes())
                    .unwrap()["error"],
                "InvalidArguments"
            );
            lp_zcode_free(response);
        }
    }
    unsafe {
        lp_zcode_free(std::ptr::null_mut());
    }
    lp_zcode_close(f.session);
    lp_zcode_close(f.session);
    assert_eq!(fs::read(&f.source).unwrap(), original);
}
