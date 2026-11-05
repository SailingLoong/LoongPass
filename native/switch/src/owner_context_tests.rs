use crate::owner_context::*;
use crate::native::NativeCipher;

fn app() -> AppIdentity {
    AppIdentity { bundle_id: "dev.zcode.app".into(), bundle_path: "/synthetic/ZCode.app".into(),
        executable_path: "/synthetic/ZCode.app/Contents/MacOS/ZCode".into(), device: 1, inode: 2 }
}
fn facts() -> ContextFacts {
    ContextFacts { app: app(), runtime_data_dir: Fact::Unset, environment_data_dir: Fact::Unset,
        effective_home: Fact::Value("/synthetic/home".into()), credential_secret: Fact::Unset,
        platform: Fact::Value("darwin".into()), username: Fact::Value("synthetic-user".into()), runtime_facts: None }
}
fn process(pid: i32, helper: bool) -> ProcessIdentity {
    ProcessIdentity { pid, uid: 501, started_seconds: 100, started_microseconds: 1,
        executable_path: if helper { "/synthetic/ZCode.app/Contents/Frameworks/ZCode Helper.app/Contents/MacOS/ZCode Helper".into() }
        else { app().executable_path } }
}
fn binding() -> Binding {
    Binding { app: app(), context_id: "verified-context".into(), uid: 501, main: Some(process(42, false)), runtime_context: None }
}
fn snapshot() -> Snapshot {
    Snapshot { app: app(), context_id: "verified-context".into(), complete: true,
        other_writers: false, processes: Vec::new(), runtime_context: None }
}
#[test]
fn owner_context_known_fallback_uses_exact_native_seed_and_cipher() {
    let context = resolve_context(&facts()).unwrap();
    assert_eq!(context.source.to_str().unwrap(), "/synthetic/home/.zcode/v2/credentials.json");
    assert_eq!(context.seed.as_str(), "zcode-credential-fallback:darwin:/synthetic/home:synthetic-user");
    let cipher = NativeCipher::new(&context.context_id, &context.seed).unwrap();
    let upstream = NativeCipher::new(&context.context_id,
        "zcode-credential-fallback:darwin:/synthetic/home:synthetic-user").unwrap();
    assert_eq!(cipher.decrypt(&upstream.encrypt("synthetic payload").unwrap()).unwrap().as_str(), "synthetic payload");
}
#[test]
fn owner_context_runtime_precedes_env_and_home_without_needing_lower_values() {
    let mut f = facts();
    f.runtime_data_dir = Fact::Value("/synthetic/runtime".into());
    f.environment_data_dir = Fact::Unknown;
    f.effective_home = Fact::Unknown;
    f.credential_secret = Fact::Value("native-only-secret".into());
    assert_eq!(resolve_context(&f).unwrap().source.to_str().unwrap(), "/synthetic/runtime/.zcode/v2/credentials.json");
}
#[test]
fn owner_context_environment_precedes_home_and_empty_secret_uses_fallback() {
    let mut f = facts();
    f.environment_data_dir = Fact::Value("/synthetic/env".into());
    f.credential_secret = Fact::Value(String::new());
    assert_eq!(resolve_context(&f).unwrap().source.to_str().unwrap(), "/synthetic/env/.zcode/v2/credentials.json");
    assert!(resolve_context(&f).unwrap().seed.starts_with("zcode-credential-fallback:"));
}
#[test]
fn owner_context_unknown_never_means_unset() {
    for field in 0..6 {
        let mut f = facts();
        match field { 0 => f.runtime_data_dir = Fact::Unknown, 1 => f.environment_data_dir = Fact::Unknown,
            2 => f.effective_home = Fact::Unknown, 3 => f.credential_secret = Fact::Unknown,
            4 => f.platform = Fact::Unknown, _ => f.username = Fact::Unknown }
        assert!(matches!(resolve_context(&f), Err(OwnerError::NativeContextUnavailable)));
    }
}
#[test]
fn owner_context_secret_is_not_trimmed_and_app_update_does_not_change_account_context() {
    let mut f = facts();
    f.credential_secret = Fact::Value("  ".into());
    let first = resolve_context(&f).unwrap();
    assert_eq!(first.seed.as_str(), "  ");
    f.credential_secret = Fact::Value("other".into());
    assert_ne!(first.context_id, resolve_context(&f).unwrap().context_id);
    let second = resolve_context(&f).unwrap();
    f.app.inode += 1;
    assert_eq!(second.context_id, resolve_context(&f).unwrap().context_id);
}
#[test]
fn owner_context_unsafe_or_ambiguous_path_is_not_resolved() {
    for value in ["", "relative", "/synthetic/../other", "/synthetic//other", "/synthetic/./other", "/synthetic/other/"] {
        let mut f = facts(); f.runtime_data_dir = Fact::Value(value.into());
        assert!(resolve_context(&f).is_err(), "accepted path {value:?}");
    }
    let mut f = facts(); f.app.bundle_id = "other.app".into();
    assert!(resolve_context(&f).is_err());
}
#[test]
fn owner_context_stopped_requires_complete_snapshot_and_no_helpers() {
    let b = binding(); let mut s = snapshot();
    assert_eq!(decide(Action::CheckStopped, &b, &s, None), Ok(Decision::Stopped));
    s.processes.push(process(43, true));
    assert_eq!(decide(Action::CheckStopped, &b, &s, None), Err(OwnerError::WritersActive));
    s.processes.clear(); s.complete = false;
    assert_eq!(decide(Action::CheckStopped, &b, &s, None), Err(OwnerError::NativeContextUnavailable));
    s.complete = true; s.other_writers = true;
    assert_eq!(decide(Action::CheckStopped, &b, &s, None), Err(OwnerError::WritersActive));
}
#[test]
fn owner_context_stop_only_targets_the_exact_bound_main() {
    let b = binding(); let mut s = snapshot(); s.processes.push(process(42, false));
    assert_eq!(decide(Action::Stop, &b, &s, None), Ok(Decision::Terminate { target: process(42, false) }));
    s.processes[0].started_seconds += 1;
    assert_eq!(decide(Action::Stop, &b, &s, None), Err(OwnerError::SourceChanged));
    s.processes = vec![process(43, true)];
    assert_eq!(decide(Action::Stop, &b, &s, None), Err(OwnerError::WritersActive));
    let mut unbound = b.clone(); unbound.main = None;
    s.processes = vec![process(42, false)];
    assert_eq!(decide(Action::Stop, &unbound, &s, None), Err(OwnerError::NativeContextUnavailable));
}
#[test]
fn owner_context_app_or_context_drift_blocks_even_empty_process_list() {
    let b = binding(); let mut s = snapshot(); s.app.inode += 1;
    assert_eq!(decide(Action::CheckStopped, &b, &s, None), Err(OwnerError::SourceChanged));
    s = snapshot(); s.context_id = "different-context".into();
    assert_eq!(decide(Action::CheckStopped, &b, &s, None), Err(OwnerError::SourceChanged));
}
#[test]
fn owner_context_reopen_requires_explicit_matching_launch_contract() {
    let b = binding(); let mut s = snapshot();
    assert_eq!(decide(Action::Reopen, &b, &s, None), Err(OwnerError::NativeContextUnavailable));
    assert_eq!(decide(Action::Reopen, &b, &s, Some("wrong")), Err(OwnerError::SourceChanged));
    assert_eq!(decide(Action::Reopen, &b, &s, Some(&b.context_id)), Ok(Decision::Reopen));
    s.processes.push(process(43, true));
    assert_eq!(decide(Action::Reopen, &b, &s, Some(&b.context_id)), Err(OwnerError::WritersActive));
}
#[test]
fn owner_context_running_requires_exact_new_instance_not_a_surviving_helper() {
    let b = binding(); let mut s = snapshot(); s.processes.push(process(43, true));
    assert_eq!(decide(Action::CheckRunning, &b, &s, None), Err(OwnerError::NativeContextUnavailable));
    s.processes.push(process(42, false));
    assert_eq!(decide(Action::CheckRunning, &b, &s, None), Ok(Decision::Running));
    s.processes[1].uid += 1;
    assert_eq!(decide(Action::CheckRunning, &b, &s, None), Err(OwnerError::SourceChanged));
}

unsafe fn ffi_reply(pointer: *mut std::ffi::c_char) -> serde_json::Value {
    assert!(!pointer.is_null());
    let result = serde_json::from_slice(std::ffi::CStr::from_ptr(pointer).to_bytes()).unwrap();
    crate::ffi::lp_zcode_free(pointer);
    result
}
#[test]
fn owner_context_native_metadata_and_decision_abi_share_real_rules_without_secret_output() {
    use crate::owner_context_ffi::*;
    let f = facts(); let data = serde_json::to_vec(&f).unwrap();
    let value = unsafe { ffi_reply(lp_zcode_owner_metadata(data.as_ptr(), data.len())) };
    assert_eq!(value["source"], "/synthetic/home/.zcode/v2/credentials.json");
    assert_eq!(value.as_object().unwrap().len(), 2);
    assert!(!value.to_string().contains("zcode-credential-fallback"));
    let b = binding(); let mut s = snapshot(); s.processes = vec![process(43, true)];
    let request = serde_json::to_vec(&serde_json::json!({"action":"checkStopped","binding":b,"snapshot":s})).unwrap();
    let result = unsafe { ffi_reply(lp_zcode_owner_decide(request.as_ptr(), request.len())) };
    assert_eq!(result, serde_json::json!({"error":"WritersActive"}));
    s.context_id = "changed".into();
    let request = serde_json::to_vec(&serde_json::json!({"action":"checkStopped","binding":binding(),"snapshot":s})).unwrap();
    assert_eq!(unsafe { ffi_reply(lp_zcode_owner_decide(request.as_ptr(), request.len())) }, serde_json::json!({"error":"SourceChanged"}));
}
#[test]
fn owner_context_abi_refuses_unknown_extra_fields_null_and_oversize() {
    use crate::owner_context_ffi::*;
    let f = facts(); let mut value = serde_json::to_value(&f).unwrap(); value["guessFromHost"] = true.into();
    let data = serde_json::to_vec(&value).unwrap();
    assert_eq!(unsafe { ffi_reply(lp_zcode_owner_metadata(data.as_ptr(), data.len())) }["error"], "InvalidArguments");
    assert_eq!(unsafe { ffi_reply(lp_zcode_owner_metadata(std::ptr::null(), 1)) }["error"], "InvalidArguments");
    assert_eq!(unsafe { ffi_reply(lp_zcode_owner_decide(data.as_ptr(), 65_537)) }["error"], "InvalidArguments");
}
#[test]
fn owner_context_native_open_reuses_session_without_files_or_raw_secret_return() {
    use crate::owner_context_ffi::*;
    unsafe extern "C" fn stopped(_: *mut std::ffi::c_void) -> i32 { 0 }
    let f = facts(); let data = serde_json::to_vec(&f).unwrap();
    let options = br#"{"backupRoot":"/synthetic/backups"}"#;
    let handle = unsafe { lp_zcode_owner_open(data.as_ptr(), data.len(), options.as_ptr(), options.len(), Some(stopped), std::ptr::null_mut()) };
    assert_ne!(handle, 0);
    let status = br#"{"method":"status"}"#;
    let reply = unsafe { ffi_reply(crate::ffi::lp_zcode_call(handle, status.as_ptr(), status.len())) };
    assert_eq!(reply["reason"], "NativeCaptureRequired");
    crate::ffi::lp_zcode_close(handle);
    let mut unknown = facts(); unknown.runtime_data_dir = Fact::Unknown;
    let data = serde_json::to_vec(&unknown).unwrap();
    assert_eq!(unsafe { lp_zcode_owner_open(data.as_ptr(), data.len(), options.as_ptr(), options.len(), Some(stopped), std::ptr::null_mut()) }, 0);
}

#[test]
fn owner_context_snapshot_rejects_duplicate_pid_and_malformed_identity() {
    let b = binding(); let mut s = snapshot();
    s.processes = vec![process(42, false), process(42, false)];
    assert_eq!(decide(Action::CheckStopped, &b, &s, None), Err(OwnerError::NativeContextUnavailable));
    s.processes = vec![process(42, false)]; s.processes[0].started_microseconds = 1_000_000;
    assert_eq!(decide(Action::Stop, &b, &s, None), Err(OwnerError::NativeContextUnavailable));
    s = snapshot(); s.processes = vec![process(42, false), process(99, false)];
    assert_eq!(decide(Action::Stop, &b, &s, None), Err(OwnerError::WritersActive));
}
#[test]
fn owner_context_stop_does_not_signal_unrelated_reused_pid_or_path_prefix_sibling() {
    let b = binding(); let mut s = snapshot();
    let mut unrelated = process(42, false);
    unrelated.executable_path = "/synthetic/ZCode.app-copy/Contents/MacOS/ZCode".into();
    s.processes = vec![unrelated];
    assert_eq!(decide(Action::CheckStopped, &b, &s, None), Ok(Decision::Stopped));
    assert_eq!(decide(Action::Stop, &b, &s, None), Ok(Decision::Stopped));
}
#[test]
fn owner_context_unknown_or_changed_context_precedes_writers_active_gate() {
    let b = binding(); let mut s = snapshot(); s.processes = vec![process(42, false)];
    s.complete = false;
    assert_eq!(decide(Action::CheckStopped, &b, &s, None), Err(OwnerError::NativeContextUnavailable));
    s.context_id = "changed".into();
    assert_eq!(decide(Action::CheckStopped, &b, &s, None), Err(OwnerError::SourceChanged));
}
#[test]
fn owner_context_options_unknown_fields_and_nonabsolute_roots_never_open() {
    use crate::owner_context_ffi::*;
    unsafe extern "C" fn stopped(_: *mut std::ffi::c_void) -> i32 { 0 }
    let data = serde_json::to_vec(&facts()).unwrap();
    for options in [
        r#"{"backupRoot":"/synthetic/backups","unexpected":true}"#,
        r#"{"backupRoot":"relative"}"#,
        r#"{"backupRoot":"/synthetic/backups","promotionStoreRoot":"relative"}"#,
        r#"{"backupRoot":"/synthetic/backups","promotionPlanIds":[123]}"#,
    ] {
        assert_eq!(unsafe { lp_zcode_owner_open(data.as_ptr(), data.len(), options.as_ptr(), options.len(), Some(stopped), std::ptr::null_mut()) }, 0);
    }
}

#[test]
fn owner_context_final_reopen_decision_rejects_app_or_context_replacement() {
    let b = binding(); let mut s = snapshot();
    assert_eq!(decide(Action::Reopen, &b, &s, Some(&b.context_id)), Ok(Decision::Reopen));
    s.app.inode += 1;
    assert_eq!(decide(Action::Reopen, &b, &s, Some(&b.context_id)), Err(OwnerError::SourceChanged));
    s = snapshot(); s.context_id = "replaced-data-or-key".into();
    assert_eq!(decide(Action::Reopen, &b, &s, Some(&b.context_id)), Err(OwnerError::SourceChanged));
}

// These fixtures describe explicit synthetic native facts, never host discovery.
fn runtime_facts_json() -> serde_json::Value {
    serde_json::json!({
        "zcodeEnv":{"state":"unset"}, "baseUrl":{"state":"unset"},
        "endpointOrigin":{"state":"unset"}, "productionBaseUrl":{"state":"unset"},
        "testBaseUrl":{"state":"unset"}, "overrideOrigin":{"state":"unset"},
        "processArch":{"state":"value","value":"arm64"}
    })
}
fn runtime_context_json(origin: &str, architecture: &str) -> serde_json::Value {
    serde_json::json!({"origin":origin,"credentialPlatform":"darwin","requestPlatform":format!("darwin-{architecture}")})
}
fn metadata_json(value: &serde_json::Value) -> serde_json::Value {
    let data = serde_json::to_vec(value).unwrap();
    unsafe { ffi_reply(crate::owner_context_ffi::lp_zcode_owner_metadata(data.as_ptr(), data.len())) }
}
#[test]
fn runtimefacts_origin_defaults_and_two_platforms_are_resolved_from_explicit_facts() {
    let mut value = serde_json::to_value(facts()).unwrap();
    value["runtimeFacts"] = runtime_facts_json();
    let result = metadata_json(&value);
    assert_eq!(result["runtimeContext"], runtime_context_json("https://zcode.z.ai", "arm64"));
    assert_eq!(result["source"], "/synthetic/home/.zcode/v2/credentials.json");
}
#[test]
fn runtimefacts_promotion_open_requires_proven_runtime_even_with_explicit_options() {
    unsafe extern "C" fn stopped(_: *mut std::ffi::c_void) -> i32 { 0 }
    let data = serde_json::to_vec(&facts()).unwrap();
    let options = br#"{"backupRoot":"/synthetic/backups","promotionStoreRoot":"/synthetic/promotions","promotionPlanIds":["synthetic-event"],"appVersion":"3.17.2","promotionOrigin":"https://zcode.z.ai","promotionPlatform":"darwin-arm64"}"#;
    let handle = unsafe { crate::owner_context_ffi::lp_zcode_owner_open(data.as_ptr(), data.len(), options.as_ptr(), options.len(), Some(stopped), std::ptr::null_mut()) };
    if handle != 0 { crate::ffi::lp_zcode_close(handle); }
    assert_eq!(handle, 0, "Unproven runtime must not configure a promotion owner");
}
#[test]
fn runtimefacts_endpoint_drift_is_detected_before_running_writer_classification() {
    let mut b = serde_json::to_value(binding()).unwrap();
    let mut s = serde_json::to_value(snapshot()).unwrap();
    b["runtimeContext"] = runtime_context_json("https://zcode.z.ai", "arm64");
    s["runtimeContext"] = runtime_context_json("https://zcode.chatglm.site", "arm64");
    s["processes"] = serde_json::json!([process(42, false)]);
    let request = serde_json::to_vec(&serde_json::json!({"action":"checkStopped","binding":b,"snapshot":s})).unwrap();
    let result = unsafe { ffi_reply(crate::owner_context_ffi::lp_zcode_owner_decide(request.as_ptr(), request.len())) };
    assert_eq!(result, serde_json::json!({"error":"SourceChanged"}));
}

#[test]
fn runtimefacts_origin_precedence_normalization_and_test_override_match_source() {
    use serde_json::json;
    let cases = [
        (json!({"zcodeEnv":{"state":"value","value":" TeSt "}}), "https://zcode.chatglm.site"),
        (json!({"zcodeEnv":{"state":"value","value":"TEST"},"baseUrl":{"state":"value","value":"https://base.invalid"},"overrideOrigin":{"state":"value","value":" https://User:Pass@Override.Invalid:443/path?q=x#part "}}), "https://override.invalid"),
        (json!({"overrideOrigin":{"state":"unknown"}}), "https://zcode.z.ai"),
        (json!({"baseUrl":{"state":"value","value":"https://BASE.invalid:8443/path?q=x"},"endpointOrigin":{"state":"unknown"},"productionBaseUrl":{"state":"unknown"}}), "https://base.invalid:8443"),
        (json!({"baseUrl":{"state":"value","value":" \u{feff}"},"endpointOrigin":{"state":"value","value":"http://endpoint.invalid/path"}}), "http://endpoint.invalid"),
        (json!({"productionBaseUrl":{"state":"value","value":"https://production.invalid"},"testBaseUrl":{"state":"unknown"}}), "https://production.invalid"),
        (json!({"zcodeEnv":{"state":"value","value":"test"},"testBaseUrl":{"state":"value","value":"https://test.invalid"},"productionBaseUrl":{"state":"unknown"}}), "https://test.invalid"),
        (json!({"zcodeEnv":{"state":"value","value":"production"},"overrideOrigin":{"state":"value","value":"ftp://ignored.invalid"}}), "https://zcode.z.ai"),
    ];
    for (changes, expected) in cases {
        let mut value = serde_json::to_value(facts()).unwrap();
        let mut runtime = runtime_facts_json();
        for (key, item) in changes.as_object().unwrap() { runtime[key] = item.clone(); }
        value["runtimeFacts"] = runtime;
        assert_eq!(metadata_json(&value)["runtimeContext"]["origin"], expected);
    }
}

#[test]
fn runtimefacts_unknown_required_invalid_origin_and_architecture_fail_closed() {
    use serde_json::json;
    let cases = [
        json!({"zcodeEnv":{"state":"unknown"}}),
        json!({"baseUrl":{"state":"unknown"}}),
        json!({"endpointOrigin":{"state":"unknown"}}),
        json!({"productionBaseUrl":{"state":"unknown"}}),
        json!({"zcodeEnv":{"state":"value","value":"test"},"overrideOrigin":{"state":"unknown"}}),
        json!({"processArch":{"state":"unknown"}}),
        json!({"processArch":{"state":"unset"}}),
        json!({"processArch":{"state":"value","value":"darwin-arm64"}}),
        json!({"processArch":{"state":"value","value":""}}),
        json!({"baseUrl":{"state":"value","value":"not-a-url"},"endpointOrigin":{"state":"value","value":"https://must-not-fallback.invalid"}}),
        json!({"baseUrl":{"state":"value","value":"file:///tmp/synthetic"}}),
    ];
    for changes in cases {
        let mut value = serde_json::to_value(facts()).unwrap();
        let mut runtime = runtime_facts_json();
        for (key, item) in changes.as_object().unwrap() { runtime[key] = item.clone(); }
        value["runtimeFacts"] = runtime;
        assert_eq!(metadata_json(&value)["error"], "NativeContextUnavailable");
    }
}

#[test]
fn runtimefacts_x64_uses_darwin_seed_and_preserves_persistent_credential_identity() {
    let baseline = serde_json::to_value(facts()).unwrap();
    let old = metadata_json(&baseline);
    let mut value = baseline;
    value["runtimeFacts"] = runtime_facts_json();
    value["runtimeFacts"]["processArch"] = serde_json::json!({"state":"value","value":"x64"});
    let new = metadata_json(&value);
    assert_eq!(new["runtimeContext"], runtime_context_json("https://zcode.z.ai", "x64"));
    assert_eq!(new["contextId"], old["contextId"]);
    // A supplied key does not authorize guessing the target process platform.
    value["credentialSecret"] = serde_json::json!({"state":"value","value":"SYNTHETIC"});
    value["platform"] = serde_json::json!({"state":"unknown"});
    assert_eq!(metadata_json(&value)["error"], "NativeContextUnavailable");
}

#[test]
fn runtimefacts_unknown_or_architecture_drift_blocks_every_lifecycle_action() {
    use serde_json::json;
    for action in ["checkStopped", "stop", "reopen", "checkRunning"] {
        for observed in [serde_json::Value::Null, runtime_context_json("https://zcode.z.ai", "x64")] {
            let mut b = serde_json::to_value(binding()).unwrap();
            let mut s = serde_json::to_value(snapshot()).unwrap();
            b["runtimeContext"] = runtime_context_json("https://zcode.z.ai", "arm64");
            s["runtimeContext"] = observed.clone();
            let request = serde_json::to_vec(&json!({"action":action,"binding":b,"snapshot":s,"launchContextId":"verified-context"})).unwrap();
            let result = unsafe { ffi_reply(crate::owner_context_ffi::lp_zcode_owner_decide(request.as_ptr(), request.len())) };
            let expected = if observed.is_null() { "NativeContextUnavailable" } else { "SourceChanged" };
            assert_eq!(result["error"], expected);
        }
    }
}

#[test]
fn runtimefacts_matching_proven_options_open_and_mismatched_options_do_not() {
    use serde_json::json;
    unsafe extern "C" fn stopped(_: *mut std::ffi::c_void) -> i32 { 0 }
    let mut value = serde_json::to_value(facts()).unwrap();
    value["runtimeFacts"] = runtime_facts_json();
    let data = serde_json::to_vec(&value).unwrap();
    for (origin, platform, expected_open) in [
        ("https://zcode.z.ai", "darwin-arm64", true),
        ("https://zcode.chatglm.site", "darwin-arm64", false),
        ("https://zcode.z.ai", "darwin-x64", false),
        ("https://zcode.z.ai/path", "darwin-arm64", false),
    ] {
        let options = serde_json::to_vec(&json!({"backupRoot":"/synthetic/backups",
            "promotionStoreRoot":"/synthetic/promotions","promotionPlanIds":["synthetic-event"],
            "appVersion":"3.17.2","promotionOrigin":origin,"promotionPlatform":platform})).unwrap();
        let handle = unsafe { crate::owner_context_ffi::lp_zcode_owner_open(data.as_ptr(), data.len(), options.as_ptr(), options.len(), Some(stopped), std::ptr::null_mut()) };
        if handle != 0 { crate::ffi::lp_zcode_close(handle); }
        assert_eq!(handle != 0, expected_open);
    }
}

#[test]
fn runtimefacts_matching_runtime_retains_existing_writer_and_stopped_rules() {
    use crate::runtime_context::RuntimeContext;
    let runtime: RuntimeContext = serde_json::from_value(runtime_context_json("https://zcode.z.ai", "arm64")).unwrap();
    let mut b = binding(); let mut s = snapshot();
    b.runtime_context = Some(runtime.clone()); s.runtime_context = Some(runtime);
    assert_eq!(decide(Action::CheckStopped, &b, &s, None), Ok(Decision::Stopped));
    s.processes.push(process(42, false));
    assert_eq!(decide(Action::CheckStopped, &b, &s, None), Err(OwnerError::WritersActive));
    s.runtime_context.as_mut().unwrap().origin = "https://other.invalid".into();
    assert_eq!(decide(Action::CheckStopped, &b, &s, None), Err(OwnerError::SourceChanged));
    s.runtime_context = b.runtime_context.clone();
    assert_eq!(decide(Action::CheckStopped, &b, &s, None), Err(OwnerError::WritersActive));
}
#[test]
fn owner_context_open_forwards_promotion_options_into_same_captured_session() {
    use crate::{core::OAuthFamily, native::tests::native_document_with_context, owner_context_ffi::*};
    use std::{fs, os::unix::fs::PermissionsExt};
    unsafe extern "C" fn stopped(_: *mut std::ffi::c_void) -> i32 { 0 }
    let root = tempfile::tempdir().unwrap();
    fs::set_permissions(root.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let mut f = facts(); f.runtime_data_dir = Fact::Value(root.path().to_str().unwrap().into());
    let mut runtime = runtime_facts_json();
    runtime["baseUrl"] = serde_json::json!({"state":"value","value":"https://synthetic.zcode.invalid"});
    f.runtime_facts = Some(serde_json::from_value(runtime).unwrap());
    let context = resolve_context(&f).unwrap();
    fs::create_dir_all(context.source.parent().unwrap()).unwrap();
    fs::set_permissions(context.source.parent().unwrap(), fs::Permissions::from_mode(0o700)).unwrap();
    let document = native_document_with_context(&context.context_id, &context.seed, OAuthFamily::Zai, "synthetic-owner-promotion", "fixture");
    fs::write(&context.source, document.to_bytes().unwrap()).unwrap();
    fs::set_permissions(&context.source, fs::Permissions::from_mode(0o600)).unwrap();
    let data = serde_json::to_vec(&f).unwrap();
    let options = serde_json::to_vec(&serde_json::json!({"backupRoot":root.path(),
        "promotionStoreRoot":root.path(), "promotionPlanIds":["synthetic-event"], "appVersion":"3.17.2",
        "promotionOrigin":"https://synthetic.zcode.invalid", "promotionPlatform":"darwin-arm64"})).unwrap();
    let handle = unsafe { lp_zcode_owner_open(data.as_ptr(), data.len(), options.as_ptr(), options.len(), Some(stopped), std::ptr::null_mut()) };
    assert_ne!(handle, 0);
    let call = |method: &str| {
        let request = serde_json::to_vec(&serde_json::json!({"method":method})).unwrap();
        unsafe { ffi_reply(crate::ffi::lp_zcode_call(handle, request.as_ptr(), request.len())) }
    };
    assert_eq!(call("promotionStatus")["available"], false);
    assert!(call("captureCurrent").get("accountId").is_some());
    assert_eq!(call("promotionStatus")["available"], true);
    crate::ffi::lp_zcode_close(handle);
}

#[test]
fn owner_context_unresolved_bootstrap_cannot_fall_through_to_home_or_environment() {
    let mut f = facts();
    // A missing live producer is not evidence that setting.json dataBaseDir is absent.
    f.runtime_data_dir = Fact::Unknown;
    assert!(matches!(resolve_context(&f), Err(OwnerError::NativeContextUnavailable)));
    f.environment_data_dir = Fact::Value("/synthetic/environment".into());
    assert!(matches!(resolve_context(&f), Err(OwnerError::NativeContextUnavailable)));
    // The verified effective runtime value already incorporates bootstrap/ready.
    f.runtime_data_dir = Fact::Value("/synthetic/bootstrap-effective".into());
    assert_eq!(resolve_context(&f).unwrap().source.to_str().unwrap(),
        "/synthetic/bootstrap-effective/.zcode/v2/credentials.json");
}
