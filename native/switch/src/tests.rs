use crate::{
    core::OAuthFamily,
    native::{
        tests::{native_document, TEST_CONTEXT, TEST_SECRET},
        NativeCipher,
    },
    switch::*,
};
use std::{
    fs,
    os::unix::fs::{symlink, MetadataExt, PermissionsExt},
    path::PathBuf,
};
struct Fixture {
    _root: tempfile::TempDir,
    source: PathBuf,
    target: PathBuf,
    backup: PathBuf,
    native: NativeCipher,
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
        for (path, id) in [(&source, "source-a"), (&target, "target-b")] {
            write(
                path,
                &native_document(OAuthFamily::Zai, id, "v1")
                    .to_bytes()
                    .unwrap(),
            );
        }
        Self {
            _root: root,
            source,
            target,
            backup,
            native: NativeCipher::new(TEST_CONTEXT, TEST_SECRET).unwrap(),
        }
    }
    fn switch(&self) -> Result<Receipt, SwitchError> {
        let a = capture(&self.source, &self.native, &mut || Ok(()))?;
        let b = capture(&self.target, &self.native, &mut || Ok(()))?;
        switch(
            &self.source,
            &self.backup,
            a.revision,
            &b.account,
            &self.native,
            &mut || Ok(()),
        )
    }
}
fn write(path: &std::path::Path, bytes: &[u8]) {
    fs::write(path, bytes).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
}
#[test]
fn switches_seven_fields_and_restores_exact_original_bytes() {
    let f = Fixture::new();
    let original = fs::read(&f.source).unwrap();
    let saved = fs::read(&f.target).unwrap();
    let r = f.switch().unwrap();
    assert_eq!(r.outcome, Outcome::Switched);
    let operation = r.operation_dir.unwrap();
    assert_eq!(fs::read(operation.join("before.json")).unwrap(), original);
    let after: serde_json::Value = serde_json::from_slice(&fs::read(&f.source).unwrap()).unwrap();
    let target: serde_json::Value = serde_json::from_slice(&saved).unwrap();
    assert_eq!(
        after["oauth:zai:access_token"],
        target["oauth:zai:access_token"]
    );
    assert_eq!(after["ssh:unrelated"], "unrelated-opaque-format");
    assert_eq!(fs::metadata(&f.source).unwrap().mode() & 0o777, 0o600);
    assert_eq!(fs::read(&f.target).unwrap(), saved);
    let restored = restore(&f.source, &operation, &mut || Ok(())).unwrap();
    assert_eq!(restored.outcome, Outcome::Restored);
    assert_eq!(fs::read(&f.source).unwrap(), original);
    assert_eq!(fs::read(operation.join("before.json")).unwrap(), original);
}
#[test]
fn same_account_keeps_fresh_bytes_inode_and_creates_no_backup() {
    let f = Fixture::new();
    let a = capture(&f.source, &f.native, &mut || Ok(())).unwrap();
    let bytes = fs::read(&f.source).unwrap();
    let ino = fs::metadata(&f.source).unwrap().ino();
    let r = switch(
        &f.source,
        &f.backup,
        a.revision,
        &a.account,
        &f.native,
        &mut || Ok(()),
    )
    .unwrap();
    assert_eq!(r.outcome, Outcome::Unchanged);
    assert!(r.operation_dir.is_none());
    assert_eq!(fs::read(&f.source).unwrap(), bytes);
    assert_eq!(fs::metadata(&f.source).unwrap().ino(), ino);
    assert_eq!(fs::read_dir(&f.backup).unwrap().count(), 0);
}
#[test]
fn changed_source_revision_is_preserved_without_backup() {
    let f = Fixture::new();
    let a = capture(&f.source, &f.native, &mut || Ok(())).unwrap();
    let b = capture(&f.target, &f.native, &mut || Ok(())).unwrap();
    let fresh = native_document(OAuthFamily::Zai, "source-a", "v2")
        .to_bytes()
        .unwrap();
    write(&f.source, &fresh);
    assert!(matches!(
        switch(
            &f.source,
            &f.backup,
            a.revision,
            &b.account,
            &f.native,
            &mut || Ok(())
        ),
        Err(SwitchError::SourceChanged)
    ));
    assert_eq!(fs::read(&f.source).unwrap(), fresh);
    assert_eq!(fs::read_dir(&f.backup).unwrap().count(), 0);
}
#[test]
fn live_writer_or_unknown_lock_never_overwrites_source() {
    let f = Fixture::new();
    let original = fs::read(&f.source).unwrap();
    assert!(matches!(
        capture(&f.source, &f.native, &mut || Err(
            SwitchError::WritersActive
        )),
        Err(SwitchError::WritersActive)
    ));
    fs::create_dir(f.source.with_extension("json.lock")).unwrap();
    assert!(matches!(
        capture(&f.source, &f.native, &mut || Ok(())),
        Err(SwitchError::LockBusy)
    ));
    assert_eq!(fs::read(&f.source).unwrap(), original);
    assert!(f.source.with_extension("json.lock").is_dir());
}
#[test]
fn rollback_refuses_new_native_refresh_and_keeps_backup() {
    let f = Fixture::new();
    let original = fs::read(&f.source).unwrap();
    let r = f.switch().unwrap();
    let op = r.operation_dir.unwrap();
    let new = native_document(OAuthFamily::Zai, "target-b", "refreshed")
        .to_bytes()
        .unwrap();
    write(&f.source, &new);
    assert!(matches!(
        restore(&f.source, &op, &mut || Ok(())),
        Err(SwitchError::SourceChanged)
    ));
    assert_eq!(fs::read(&f.source).unwrap(), new);
    assert_eq!(fs::read(op.join("before.json")).unwrap(), original);
}
#[test]
fn corrupt_backup_is_not_restored() {
    let f = Fixture::new();
    let r = f.switch().unwrap();
    let op = r.operation_dir.unwrap();
    let current = fs::read(&f.source).unwrap();
    write(&op.join("before.json"), b"{}");
    assert!(matches!(
        restore(&f.source, &op, &mut || Ok(())),
        Err(SwitchError::RecoveryChanged)
    ));
    assert_eq!(fs::read(&f.source).unwrap(), current);
}
#[test]
fn rejects_alias_nonprivate_or_wrong_key_before_modifying_anything() {
    let f = Fixture::new();
    let alias = f.source.with_extension("alias");
    symlink(&f.source, &alias).unwrap();
    assert!(matches!(
        capture(&alias, &f.native, &mut || Ok(())),
        Err(SwitchError::UnsafePath)
    ));
    let wrong = NativeCipher::new(TEST_CONTEXT, "wrong-secret").unwrap();
    assert!(matches!(
        capture(&f.source, &wrong, &mut || Ok(())),
        Err(SwitchError::InvalidCredential)
    ));
    fs::set_permissions(&f.source, fs::Permissions::from_mode(0o644)).unwrap();
    assert!(matches!(
        capture(&f.source, &f.native, &mut || Ok(())),
        Err(SwitchError::UnsafePath)
    ));
}
#[test]
fn gate_recheck_catches_source_rotation_before_rename() {
    let f = Fixture::new();
    let a = capture(&f.source, &f.native, &mut || Ok(())).unwrap();
    let b = capture(&f.target, &f.native, &mut || Ok(())).unwrap();
    let fresh = native_document(OAuthFamily::Zai, "source-a", "rotation")
        .to_bytes()
        .unwrap();
    let mut calls = 0;
    let result = switch(
        &f.source,
        &f.backup,
        a.revision,
        &b.account,
        &f.native,
        &mut || {
            calls += 1;
            if calls == 3 {
                write(&f.source, &fresh);
            }
            Ok(())
        },
    );
    assert!(matches!(result, Err(SwitchError::SourceChanged)));
    assert_eq!(fs::read(&f.source).unwrap(), fresh);
}
#[test]
fn lock_replacement_is_not_treated_as_exclusive_ownership() {
    let f = Fixture::new();
    let original = fs::read(&f.source).unwrap();
    let a = capture(&f.source, &f.native, &mut || Ok(())).unwrap();
    let b = capture(&f.target, &f.native, &mut || Ok(())).unwrap();
    let lock = f.source.with_extension("json.lock");
    let moved = f.source.with_extension("old.lock");
    let mut calls = 0;
    let result = switch(
        &f.source,
        &f.backup,
        a.revision,
        &b.account,
        &f.native,
        &mut || {
            calls += 1;
            if calls == 3 {
                fs::rename(&lock, &moved).unwrap();
                fs::create_dir(&lock).unwrap();
            }
            Ok(())
        },
    );
    assert!(matches!(result, Err(SwitchError::LockBusy)));
    assert_eq!(fs::read(&f.source).unwrap(), original);
    assert!(lock.is_dir());
    assert!(moved.is_dir());
}
#[test]
fn old_same_account_snapshot_does_not_replace_new_refresh() {
    let f = Fixture::new();
    let old = capture(&f.source, &f.native, &mut || Ok(())).unwrap();
    let fresh = native_document(OAuthFamily::Zai, "source-a", "fresh")
        .to_bytes()
        .unwrap();
    write(&f.source, &fresh);
    let current = capture(&f.source, &f.native, &mut || Ok(())).unwrap();
    let r = switch(
        &f.source,
        &f.backup,
        current.revision,
        &old.account,
        &f.native,
        &mut || Ok(()),
    )
    .unwrap();
    assert_eq!(r.outcome, Outcome::Unchanged);
    assert_eq!(fs::read(&f.source).unwrap(), fresh);
    assert_eq!(fs::read_dir(&f.backup).unwrap().count(), 0);
}
#[test]
fn context_and_family_mismatch_are_rejected_without_backup() {
    let f = Fixture::new();
    let current = capture(&f.source, &f.native, &mut || Ok(())).unwrap();
    let other_context = NativeCipher::new("other-context", TEST_SECRET).unwrap();
    let foreign = capture(&f.target, &other_context, &mut || Ok(())).unwrap();
    assert!(matches!(
        switch(
            &f.source,
            &f.backup,
            current.revision,
            &foreign.account,
            &f.native,
            &mut || Ok(())
        ),
        Err(SwitchError::InvalidCredential)
    ));
    write(
        &f.target,
        &native_document(OAuthFamily::BigModel, "target-cn", "v1")
            .to_bytes()
            .unwrap(),
    );
    let cn = capture(&f.target, &f.native, &mut || Ok(())).unwrap();
    assert!(matches!(
        switch(
            &f.source,
            &f.backup,
            current.revision,
            &cn.account,
            &f.native,
            &mut || Ok(())
        ),
        Err(SwitchError::InvalidCredential)
    ));
    assert_eq!(fs::read_dir(&f.backup).unwrap().count(), 0);
}
#[test]
fn legacy_plaintext_and_duplicate_credentials_fail_closed() {
    let f = Fixture::new();
    for bytes in [br#"{"oauth:active_provider":"zai","oauth:zai:access_token":"plaintext","oauth:zai:user_info":"{}"}"#.as_slice(),br#"{"oauth:active_provider":"x","oauth:active_provider":"y"}"#.as_slice()] {
  write(&f.source,bytes); assert!(matches!(capture(&f.source,&f.native,&mut ||Ok(())),Err(SwitchError::InvalidCredential))); assert_eq!(fs::read(&f.source).unwrap(),bytes);
 }
}
#[test]
fn restore_works_without_a_commit_receipt_but_refuses_wrong_target_path() {
    let f = Fixture::new();
    let original = fs::read(&f.source).unwrap();
    let r = f.switch().unwrap();
    let op = r.operation_dir.unwrap();
    fs::remove_file(op.join("committed.json")).unwrap();
    assert!(matches!(
        restore(&f.target, &op, &mut || Ok(())),
        Err(SwitchError::RecoveryChanged)
    ));
    assert_eq!(
        restore(&f.source, &op, &mut || Ok(())).unwrap().outcome,
        Outcome::Restored
    );
    assert_eq!(fs::read(&f.source).unwrap(), original);
    assert_eq!(
        restore(&f.source, &op, &mut || Ok(())).unwrap().outcome,
        Outcome::Unchanged
    );
}
#[test]
fn nonprivate_backup_directory_is_never_tightened_or_used() {
    let f = Fixture::new();
    fs::set_permissions(&f.backup, fs::Permissions::from_mode(0o755)).unwrap();
    let original = fs::read(&f.source).unwrap();
    assert!(matches!(f.switch(), Err(SwitchError::UnsafePath)));
    assert_eq!(fs::read(&f.source).unwrap(), original);
    assert_eq!(fs::metadata(&f.backup).unwrap().mode() & 0o777, 0o755);
    assert_eq!(fs::read_dir(&f.backup).unwrap().count(), 0);
}
#[test]
#[ignore = "Launched only by the synthetic crash-recovery parent"]
fn crash_after_durable_intent_child() {
    let root = PathBuf::from(
        std::env::var_os("LOONGPASS_ZCODE_TEST_DIR").expect("explicit synthetic fixture root"),
    );
    let source = root.join("credentials.json");
    let target = root.join("saved.json");
    let backup = root.join("backups");
    let native = NativeCipher::new(TEST_CONTEXT, TEST_SECRET).unwrap();
    let a = capture(&source, &native, &mut || Ok(())).unwrap();
    let b = capture(&target, &native, &mut || Ok(())).unwrap();
    let mut calls = 0;
    let _ = switch(
        &source,
        &backup,
        a.revision,
        &b.account,
        &native,
        &mut || {
            calls += 1;
            if calls == 3 {
                std::process::exit(0);
            }
            Ok(())
        },
    );
    panic!("crash point not reached");
}
#[test]
fn real_exited_process_preserves_durable_intent_and_can_restore_explicitly() {
    let f = Fixture::new();
    let original = fs::read(&f.source).unwrap();
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "tests::crash_after_durable_intent_child",
            "--ignored",
            "--nocapture",
        ])
        .env("LOONGPASS_ZCODE_TEST_DIR", f.source.parent().unwrap())
        .status()
        .unwrap();
    assert!(status.success());
    let op = fs::read_dir(&f.backup)
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    assert!(op.join("intent.json").is_file());
    assert!(op.join("before.json").is_file());
    assert!(!op.join("committed.json").exists());
    assert!(f.source.with_extension("json.lock").is_dir());
    assert_eq!(
        restore(&f.source, &op, &mut || Ok(())).unwrap().outcome,
        Outcome::Unchanged
    );
    assert_eq!(fs::read(&f.source).unwrap(), original);
    assert!(!f.source.with_extension("json.lock").exists());
    assert_eq!(fs::read(op.join("before.json")).unwrap(), original);
}
#[test]
fn physical_switch_preserves_other_accounts_and_removes_only_absent_target_fields() {
    let f = Fixture::new();
    let mut original: serde_json::Map<String, serde_json::Value> =
        serde_json::from_slice(&fs::read(&f.source).unwrap()).unwrap();
    original.insert(
        "oauth:login_attribution".into(),
        serde_json::json!("opaque-current-attribution"),
    );
    original.insert(
        "oauth:bigmodel:access_token".into(),
        serde_json::json!("opaque-cn-token"),
    );
    original.insert(
        "account-provider:start-plan:account:zai-start-plan:account:target-b:api-key".into(),
        serde_json::json!("stale-target-cache"),
    );
    write(&f.source, &serde_json::to_vec_pretty(&original).unwrap());
    let mut target: serde_json::Map<String, serde_json::Value> =
        serde_json::from_slice(&fs::read(&f.target).unwrap()).unwrap();
    target.remove("oauth:zai:refresh_token");
    target.remove("zcodejwttoken");
    target.remove("account-provider:start-plan:account:zai-start-plan:account:target-b:api-key");
    write(&f.target, &serde_json::to_vec(&target).unwrap());
    let before = fs::read(&f.source).unwrap();
    let r = f.switch().unwrap();
    let after: serde_json::Map<String, serde_json::Value> =
        serde_json::from_slice(&fs::read(&f.source).unwrap()).unwrap();
    for key in [
        "oauth:active_provider",
        "oauth:zai:access_token",
        "oauth:zai:user_info",
        "account-provider:coding-plan:account:zai-individual-coding-plan:account:target-b:api-key",
    ] {
        assert_eq!(after[key], target[key]);
    }
    for key in [
        "oauth:zai:refresh_token",
        "zcodejwttoken",
        "account-provider:start-plan:account:zai-start-plan:account:target-b:api-key",
    ] {
        assert!(!after.contains_key(key));
    }
    for key in [
        "oauth:login_attribution",
        "oauth:bigmodel:access_token",
        "ssh:unrelated",
        "account-provider:coding-plan:account:zai-individual-coding-plan:account:source-a:api-key",
        "account-provider:start-plan:account:zai-start-plan:account:source-a:api-key",
    ] {
        assert_eq!(after[key], original[key]);
    }
    assert_eq!(
        fs::read(r.operation_dir.unwrap().join("before.json")).unwrap(),
        before
    );
}
#[test]
fn restore_gate_recheck_preserves_later_refresh() {
    let f = Fixture::new();
    let r = f.switch().unwrap();
    let op = r.operation_dir.unwrap();
    let fresh = native_document(OAuthFamily::Zai, "target-b", "late-refresh")
        .to_bytes()
        .unwrap();
    let mut calls = 0;
    assert!(matches!(
        restore(&f.source, &op, &mut || {
            calls += 1;
            if calls == 3 {
                write(&f.source, &fresh);
            }
            Ok(())
        }),
        Err(SwitchError::SourceChanged)
    ));
    assert_eq!(fs::read(&f.source).unwrap(), fresh);
}
#[test]
fn errors_and_receipts_do_not_print_paths_or_credentials() {
    let f = Fixture::new();
    let r = f.switch().unwrap();
    let debug = format!("{r:?}");
    assert!(!debug.contains("SYNTHETIC_CANARY"));
    assert!(!debug.contains(f.source.parent().unwrap().to_str().unwrap()));
    assert!(!debug.contains("enc:v1:"));
    assert_eq!(
        format!("{:?}", SwitchError::CommitUncertain),
        "CommitUncertain"
    );
}
#[test]
fn already_restored_source_does_not_report_success_after_losing_lock() {
    let f = Fixture::new();
    let original = fs::read(&f.source).unwrap();
    let op = f.switch().unwrap().operation_dir.unwrap();
    restore(&f.source, &op, &mut || Ok(())).unwrap();
    let lock = f.source.with_extension("json.lock");
    let moved = f.source.with_extension("old.lock");
    let mut calls = 0;
    let result = restore(&f.source, &op, &mut || {
        calls += 1;
        if calls == 2 {
            fs::rename(&lock, &moved).unwrap();
            fs::create_dir(&lock).unwrap();
        }
        Ok(())
    });
    assert!(matches!(result, Err(SwitchError::LockBusy)));
    assert_eq!(fs::read(&f.source).unwrap(), original);
    assert!(lock.is_dir());
    assert!(moved.is_dir());
}
#[test]
fn same_account_noop_rejects_replaced_native_directory() {
    let f = Fixture::new();
    let dir = f.source.parent().unwrap().join("native");
    fs::create_dir(&dir).unwrap();
    let source = dir.join("credentials.json");
    let original = fs::read(&f.source).unwrap();
    write(&source, &original);
    let current = capture(&source, &f.native, &mut || Ok(())).unwrap();
    let moved = f.source.parent().unwrap().join("displaced-native");
    let mut calls = 0;
    let result = switch(
        &source,
        &f.backup,
        current.revision,
        &current.account,
        &f.native,
        &mut || {
            calls += 1;
            if calls == 2 {
                fs::rename(&dir, &moved).unwrap();
                fs::create_dir(&dir).unwrap();
                fs::rename(
                    moved.join("credentials.json.lock"),
                    dir.join("credentials.json.lock"),
                )
                .unwrap();
                write(&source, &original);
            }
            Ok(())
        },
    );
    assert!(
        matches!(result, Err(SwitchError::SourceChanged)),
        "{result:?}"
    );
    assert_eq!(fs::read(&source).unwrap(), original);
    assert_eq!(fs::read(moved.join("credentials.json")).unwrap(), original);
}
