//! Bounded native-only C ABI. Flutter receives handles and non-secret metadata.
//! Caller owns callback lifetime and must not reenter this ABI from that callback.
use crate::{
    core::OAuthFamily,
    native::NativeCipher,
    switch::{self, Outcome, SavedAccount, SwitchError},
    promotion_owner::Owner as PromotionOwner,
};
use loongpass_zcode_promotions_candidate::promotions::Mode as PromotionMode;
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    ffi::{c_char, c_void, CString},
    panic::{catch_unwind, AssertUnwindSafe},
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex, OnceLock,
    },
};
use zeroize::Zeroizing;
const INPUT_LIMIT: usize = 65_536;
pub type Gate = unsafe extern "C" fn(*mut c_void) -> i32;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Config {
    source: PathBuf,
    backup_root: PathBuf,
    context: String,
    secret: String,
    #[serde(default)]
    promotion_store_root: Option<PathBuf>,
    #[serde(default)]
    promotion_plan_ids: Vec<String>,
    #[serde(default)]
    app_version: Option<String>,
    #[serde(default)]
    promotion_origin: Option<String>,
    #[serde(default)]
    promotion_platform: Option<String>,
}
#[derive(Deserialize)]
#[serde(
    tag = "method",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum Command {
    Status {},
    PromotionStatus {},
    PreviewPromotions { account_id: String },
    ClaimPromotions { account_id: String, automatic: bool },
    CaptureCurrent {},
    CaptureSelected {
        path: PathBuf,
    },
    SwitchAccount {
        account_id: String,
        expected_revision: String,
    },
    Restore {
        operation_id: String,
    },
    RestoreSelected {
        path: PathBuf,
    },
}
struct Session {
    source: PathBuf,
    backup_root: PathBuf,
    native: NativeCipher,
    gate: Gate,
    userdata: usize,
    accounts: BTreeMap<String, SavedAccount>,
    operations: BTreeMap<String, PathBuf>,
    uncertain: bool,
    current_verified: bool,
    promotions: Option<PromotionOwner>,
}
fn sessions() -> &'static Mutex<BTreeMap<u64, Session>> {
    static S: OnceLock<Mutex<BTreeMap<u64, Session>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(BTreeMap::new()))
}
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn revision(raw: &str) -> Result<[u8; 32], &'static str> {
    if raw.len() != 64
        || !raw
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err("InvalidArguments");
    }
    let mut bytes = [0; 32];
    for (i, b) in bytes.iter_mut().enumerate() {
        *b = u8::from_str_radix(&raw[i * 2..i * 2 + 2], 16).map_err(|_| "InvalidArguments")?;
    }
    Ok(bytes)
}
fn native_error(e: SwitchError) -> &'static str {
    match e {
        SwitchError::NativeContextUnavailable => "NativeContextUnavailable",
        SwitchError::WritersActive => "WritersActive",
        SwitchError::SourceChanged => "SourceChanged",
        SwitchError::UnsafePath => "UnsafePath",
        SwitchError::InvalidCredential => "InvalidCredential",
        SwitchError::LockBusy => "LockBusy",
        SwitchError::Storage => "Storage",
        SwitchError::RecoveryChanged => "RecoveryChanged",
        SwitchError::CommitUncertain => "CommitUncertain",
    }
}
fn check(gate: Gate, userdata: usize) -> Result<(), SwitchError> {
    match unsafe { gate(userdata as *mut c_void) } {
        0 => Ok(()),
        1 => Err(SwitchError::WritersActive),
        2 => Err(SwitchError::SourceChanged),
        _ => Err(SwitchError::NativeContextUnavailable),
    }
}
// Native gate contract: verify the exact effective context FIRST. Only then
// may 1 report live writers. Network-only promotions do not need writers stopped.
fn check_promotion(gate: Gate, userdata: usize) -> Result<(), loongpass_zcode_promotions_candidate::promotions::Failure> {
    use loongpass_zcode_promotions_candidate::promotions::Failure;
    match unsafe { gate(userdata as *mut c_void) } {
        0 | 1 => Ok(()),
        _ => Err(Failure::InvalidContext),
    }
}
fn error(code: &str) -> Value {
    if code == "CommitUncertain" {
        json!({"error":code,"outcome":"unknown"})
    } else {
        json!({"error":code})
    }
}
impl Session {
    fn execute(&mut self, command: Command) -> Result<Value, &'static str> {
        if matches!(command, Command::PromotionStatus { .. } | Command::PreviewPromotions { .. } | Command::ClaimPromotions { .. }) {
            return self.execute_promotion(command);
        }
        if matches!(command, Command::Status { .. }) {
            return Ok(if self.uncertain {
                json!({"available":false,"reason":"CommitUncertain"})
            } else if let Err(problem) = check(self.gate, self.userdata) {
                json!({"available":false,"reason":native_error(problem)})
            } else if self.current_verified {
                json!({"available":true,"reason":null})
            } else {
                json!({"available":false,"reason":"NativeCaptureRequired"})
            });
        }
        if self.uncertain
            && !matches!(
                command,
                Command::Restore { .. } | Command::RestoreSelected { .. }
            )
        {
            return Err("CommitUncertain");
        }
        let is_switch = matches!(command, Command::SwitchAccount { .. });
        let gate = self.gate;
        let userdata = self.userdata;
        let mut stopped = || check(gate, userdata);
        let receipt = match command {
            Command::CaptureCurrent { .. } | Command::CaptureSelected { .. } => {
                let is_current = matches!(command, Command::CaptureCurrent { .. });
                if is_current {
                    self.current_verified = false;
                }
                let path = if let Command::CaptureSelected { path } = command {
                    path
                } else {
                    self.source.clone()
                };
                let captured =
                    switch::capture(&path, &self.native, &mut stopped).map_err(native_error)?;
                let id = captured.account.snapshot.identity().opaque_id();
                if self.accounts.len() >= 128 && !self.accounts.contains_key(&id) {
                    return Err("Storage");
                }
                let family = match captured.account.snapshot.identity().family() {
                    OAuthFamily::Zai => "zai",
                    OAuthFamily::BigModel => "bigmodel",
                };
                let label = self
                    .native
                    .profile_label(&captured.account.snapshot)
                    .map_err(|_| "InvalidCredential")?;
                let value = json!({"accountId":id,"revision":hex(&captured.revision),"family":family,"label":label});
                self.accounts.insert(id, captured.account);
                if is_current {
                    self.current_verified = true;
                }
                return Ok(value);
            }
            Command::SwitchAccount {
                account_id,
                expected_revision,
            } => {
                revision(&account_id)?;
                let revision = revision(&expected_revision)?;
                let target = self.accounts.get(&account_id).ok_or("UnknownAccount")?;
                switch::switch(
                    &self.source,
                    &self.backup_root,
                    revision,
                    target,
                    &self.native,
                    &mut stopped,
                )
            }
            Command::Restore { operation_id } => {
                revision(&operation_id)?;
                let path = self
                    .operations
                    .get(&operation_id)
                    .ok_or("UnknownOperation")?;
                switch::restore(&self.source, path, &mut stopped)
            }
            Command::RestoreSelected { path } => {
                // Backend-selected persisted operation for explicit recovery after restart.
                // This path is never accepted from Flutter method arguments by the Swift owner.
                if path.parent() != Some(self.backup_root.as_path())
                    || !path
                        .file_name()
                        .is_some_and(|name| name.to_string_lossy().starts_with("zcode-switch-"))
                {
                    return Err("InvalidArguments");
                }
                switch::restore(&self.source, &path, &mut stopped)
            }
            Command::Status { .. } => unreachable!(),
            Command::PromotionStatus { .. } | Command::PreviewPromotions { .. } | Command::ClaimPromotions { .. } => unreachable!(),
        };
        let receipt = match receipt {
            Ok(r) => r,
            Err(e) => {
                self.current_verified = false;
                if e == SwitchError::CommitUncertain {
                    self.uncertain = true;
                }
                return Err(native_error(e));
            }
        };
        let outcome = match receipt.outcome {
            Outcome::Switched => "switched",
            Outcome::Unchanged => "unchanged",
            Outcome::Restored => "restored",
        };
        let operation_id = receipt.operation_dir.map(|path| {
            let id = hex(&Sha256::digest(path.as_os_str().as_encoded_bytes()));
            self.operations.insert(id.clone(), path);
            id
        });
        self.uncertain = false;
        // Restore verifies durable images, not the configured decryption key.
        // Require explicit captureCurrent before advertising readiness again.
        self.current_verified = is_switch;
        Ok(json!({"outcome":outcome,"operationId":operation_id}))
    }
    fn execute_promotion(&mut self, command: Command) -> Result<Value, &'static str> {
        let status = matches!(command, Command::PromotionStatus { .. });
        let perform = || -> Result<Value, &'static str> {
            let owner = self.promotions.as_ref().ok_or("NativeContextUnavailable")?;
            if self.uncertain { return Err("CommitUncertain"); }
            let mut gate = || check_promotion(self.gate, self.userdata);
            gate().map_err(crate::promotion_owner::error_code)?;
            if status {
                if self.accounts.is_empty() { return Err("NativeCaptureRequired"); }
                let mut failure = "InvalidCredential";
                for account in self.accounts.values() {
                    match owner.probe(&self.native, account, &mut gate) {
                        Ok(()) => return Ok(json!({"available":true,"reason":null})),
                        Err(error) => failure = crate::promotion_owner::error_code(error),
                    }
                }
                return Err(failure);
            }
            let (account_id, mode) = match command {
                Command::PreviewPromotions { account_id } => (account_id, PromotionMode::Preview),
                Command::ClaimPromotions { account_id, automatic } => {
                    // Trigger classification does not alter admission or retry semantics.
                    let _ = automatic;
                    (account_id, PromotionMode::Claim)
                },
                _ => unreachable!(),
            };
            revision(&account_id)?;
            let account = self.accounts.get(&account_id).ok_or("UnknownAccount")?;
            let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
                .map_err(|_| "NativeContextUnavailable")?.as_secs();
            owner.run(&self.native, account, mode, now, &mut gate)
                .map_err(crate::promotion_owner::error_code)
        };
        match perform() {
            Err(reason) if status => Ok(json!({"available":false,"reason":reason})),
            other => other,
        }
    }
}
unsafe fn input<'a>(data: *const u8, len: usize) -> Option<&'a [u8]> {
    if data.is_null() || len == 0 || len > INPUT_LIMIT {
        None
    } else {
        Some(std::slice::from_raw_parts(data, len))
    }
}
/// Opens an explicit backend context; does not access source files or environment.
/// # Safety
/// `config` must refer to `len` readable bytes. Callback/userdata must remain valid
/// until close, be thread-safe, never unwind, and must not reenter this ABI.
#[no_mangle]
pub unsafe extern "C" fn lp_zcode_open(
    config: *const u8,
    len: usize,
    gate: Option<Gate>,
    userdata: *mut c_void,
) -> u64 {
    catch_unwind(AssertUnwindSafe(|| -> Option<u64> {
        let bytes = Zeroizing::new(input(config, len)?.to_vec());
        let mut cfg: Config = serde_json::from_slice(&bytes).ok()?;
        let secret = Zeroizing::new(std::mem::take(&mut cfg.secret));
        let gate = gate?;
        if !cfg.source.is_absolute()
            || cfg.source.file_name()?.to_str()? != "credentials.json"
            || !cfg.backup_root.is_absolute()
        {
            return None;
        }
        let native = NativeCipher::new(&cfg.context, &secret).ok()?;
        let promotions = match (cfg.promotion_store_root, cfg.app_version, cfg.promotion_origin, cfg.promotion_platform) {
            (None, None, None, None) if cfg.promotion_plan_ids.is_empty() => None,
            (Some(root), Some(version), Some(origin), Some(platform)) => Some(PromotionOwner::new(root, version, origin, platform, cfg.promotion_plan_ids).ok()?),
            _ => return None,
        };
        let mut registry = sessions().lock().ok()?;
        if registry.len() >= 64 {
            return None;
        }
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        if id == 0 {
            return None;
        }
        registry.insert(
            id,
            Session {
                source: cfg.source,
                backup_root: cfg.backup_root,
                native,
                gate,
                userdata: userdata as usize,
                accounts: BTreeMap::new(),
                operations: BTreeMap::new(),
                uncertain: false,
                current_verified: false,
                promotions,
            },
        );
        Some(id)
    }))
    .ok()
    .flatten()
    .unwrap_or(0)
}
fn with_session(
    session: u64,
    action: impl FnOnce(&mut Session) -> Result<Value, &'static str>,
) -> Value {
    let mut registry = match sessions().lock() {
        Ok(r) => r,
        Err(_) => return error("Storage"),
    };
    let Some(owner) = registry.get_mut(&session) else {
        return error("NativeContextUnavailable");
    };
    match catch_unwind(AssertUnwindSafe(|| action(owner))) {
        Ok(result) => result.unwrap_or_else(error),
        Err(_) => {
            owner.uncertain = true;
            owner.current_verified = false;
            error("CommitUncertain")
        }
    }
}
/// Executes a bounded native-only command. Returns owned JSON, never credentials.
/// # Safety
/// `request` must refer to `len` readable bytes. The configured callback contract
/// must still hold. Free the returned pointer once with lp_zcode_free.
#[no_mangle]
pub unsafe extern "C" fn lp_zcode_call(
    session: u64,
    request: *const u8,
    len: usize,
) -> *mut c_char {
    let reply = catch_unwind(AssertUnwindSafe(|| -> Value {
        let Some(bytes) = input(request, len) else {
            return error("InvalidArguments");
        };
        let command: Command = match serde_json::from_slice(bytes) {
            Ok(v) => v,
            Err(_) => return error("InvalidArguments"),
        };
        with_session(session, |owner| owner.execute(command))
    }))
    .unwrap_or_else(|_| error("CommitUncertain"));
    CString::new(reply.to_string())
        .expect("JSON escapes interior NUL")
        .into_raw()
}
/// Close only after all queued native calls are complete; drops the native key.
#[no_mangle]
pub extern "C" fn lp_zcode_close(session: u64) {
    // Even an earlier poisoned registry must not strand the native key on close.
    let mut registry = sessions()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    registry.remove(&session);
}
/// # Safety
/// `response` must be null or an unfreed pointer returned by lp_zcode_call.
#[no_mangle]
pub unsafe extern "C" fn lp_zcode_free(response: *mut c_char) {
    if !response.is_null() {
        drop(CString::from_raw(response));
    }
}
#[cfg(test)]
#[path = "ffi_tests.rs"]
mod tests;
