//! Explicit native facts only: no environment, settings, processes or file reads.
use serde::{Deserialize, Serialize};
use std::path::{Component, Path, PathBuf};
use sha2::{Digest, Sha256};
use zeroize::{Zeroize, Zeroizing};
use crate::runtime_context::{RuntimeFacts, RuntimeContext, resolve_runtime, verify_runtime_binding};

#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "state", content = "value", rename_all = "camelCase", deny_unknown_fields)]
pub enum Fact { Unknown, Unset, Value(String) }
impl Drop for Fact {
    fn drop(&mut self) {
        if let Self::Value(value) = self { value.zeroize(); }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AppIdentity {
    pub bundle_id: String,
    pub bundle_path: PathBuf,
    pub executable_path: PathBuf,
    // Physical identity of the selected executable, not merely its parent directory.
    pub device: u64,
    pub inode: u64,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ContextFacts {
    pub app: AppIdentity,
    // These values belong to the selected ZCode context, never LoongPass's env.
    // Runtime data must include applyEarlyDataBaseDirBootstrap from default
    // ~/.zcode/v2/setting.json AND the later ready-time settings application.
    // Unresolved bootstrap/ready state is Unknown, never Unset. This is not
    // a new fallback priority; bootstrap is a producer of the runtime override.
    pub runtime_data_dir: Fact,
    pub environment_data_dir: Fact,
    pub effective_home: Fact,
    pub credential_secret: Fact,
    pub platform: Fact,
    pub username: Fact,
    #[serde(default)]
    pub runtime_facts: Option<RuntimeFacts>,
}
pub struct ResolvedContext {
    pub source: PathBuf,
    pub context_id: String,
    pub(crate) seed: Zeroizing<String>,
    pub runtime_context: Option<RuntimeContext>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OwnerError { NativeContextUnavailable, SourceChanged, WritersActive, InvalidArguments }
impl OwnerError {
    pub fn code(self) -> &'static str {
        match self {
            Self::NativeContextUnavailable => "NativeContextUnavailable",
            Self::SourceChanged => "SourceChanged",
            Self::WritersActive => "WritersActive",
            Self::InvalidArguments => "InvalidArguments",
        }
    }
}
fn clean_absolute(path: &Path) -> bool {
    let Some(text) = path.to_str() else { return false; };
    if !path.is_absolute() || text.contains('\0') { return false; }
    let mut rebuilt = PathBuf::new();
    for component in path.components() {
        match component {
            Component::RootDir | Component::Normal(_) => rebuilt.push(component.as_os_str()),
            _ => return false,
        }
    }
    rebuilt.as_os_str() == path.as_os_str() && !text.contains("//")
        && (text == "/" || !text.ends_with('/')) && !text.split('/').any(|p| p == "." || p == "..")
}
fn valid_app(app: &AppIdentity) -> bool {
    app.bundle_id == "dev.zcode.app" && app.inode != 0
        && clean_absolute(&app.bundle_path) && clean_absolute(&app.executable_path)
        && app.executable_path.starts_with(app.bundle_path.join("Contents/MacOS"))
        && app.executable_path != app.bundle_path.join("Contents/MacOS")
}
fn required(fact: &Fact) -> Result<&str, OwnerError> {
    match fact {
        Fact::Value(value) if !value.is_empty() && !value.contains('\0') => Ok(value),
        _ => Err(OwnerError::NativeContextUnavailable),
    }
}
pub fn resolve_context(facts: &ContextFacts) -> Result<ResolvedContext, OwnerError> {
    if !valid_app(&facts.app) { return Err(OwnerError::NativeContextUnavailable); }
    let base = match &facts.runtime_data_dir {
        Fact::Unknown => return Err(OwnerError::NativeContextUnavailable),
        Fact::Value(value) => value.as_str(),
        Fact::Unset => match &facts.environment_data_dir {
            Fact::Unknown => return Err(OwnerError::NativeContextUnavailable),
            Fact::Value(value) => value.as_str(),
            Fact::Unset => required(&facts.effective_home)?,
        },
    };
    if !clean_absolute(Path::new(base)) { return Err(OwnerError::NativeContextUnavailable); }
    let seed = match &facts.credential_secret {
        Fact::Unknown => return Err(OwnerError::NativeContextUnavailable),
        Fact::Value(value) if !value.is_empty() => Zeroizing::new(value.clone()),
        _ => {
            let platform = required(&facts.platform)?;
            let home = required(&facts.effective_home)?;
            let username = required(&facts.username)?;
            if platform != "darwin" || !clean_absolute(Path::new(home)) {
                return Err(OwnerError::NativeContextUnavailable);
            }
            Zeroizing::new(format!("zcode-credential-fallback:{platform}:{home}:{username}"))
        }
    };
    let source = Path::new(base).join(".zcode/v2/credentials.json");
    // An equality binding only, not a signature, approval or source-discovery proof.
    let identity = serde_json::to_vec(&source)
        .map_err(|_| OwnerError::NativeContextUnavailable)?;
    let mut digest = Sha256::new();
    digest.update((identity.len() as u64).to_be_bytes());
    digest.update(&identity);
    digest.update((seed.len() as u64).to_be_bytes());
    digest.update(seed.as_bytes());
    let context_id = digest.finalize().iter().map(|byte| format!("{byte:02x}")).collect();
    let runtime_context = facts.runtime_facts.as_ref().map(|runtime| resolve_runtime(runtime, &facts.platform)).transpose()?;
    Ok(ResolvedContext { source, context_id, seed, runtime_context })
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProcessIdentity {
    pub pid: i32,
    pub uid: u32,
    pub started_seconds: u64,
    pub started_microseconds: u32,
    pub executable_path: PathBuf,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Binding {
    pub app: AppIdentity,
    pub context_id: String,
    pub uid: u32,
    pub main: Option<ProcessIdentity>,
    #[serde(default)]
    pub runtime_context: Option<RuntimeContext>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Snapshot {
    pub app: AppIdentity,
    pub context_id: String,
    // Complete must cover all selected-bundle processes, including orphan helpers,
    // and all other possible writers to the selected credential data directory.
    pub complete: bool,
    pub other_writers: bool,
    pub processes: Vec<ProcessIdentity>,
    #[serde(default)]
    pub runtime_context: Option<RuntimeContext>,
}
#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Action { CheckStopped, Stop, Reopen, CheckRunning }
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "decision", rename_all = "camelCase", deny_unknown_fields)]
pub enum Decision { Stopped, Terminate { target: ProcessIdentity }, Reopen, Running }
pub fn decide(action: Action, binding: &Binding, snapshot: &Snapshot,
              launch_context_id: Option<&str>) -> Result<Decision, OwnerError> {
    // Gate 1 means context IS verified but writers remain. Check identity first.
    if snapshot.app != binding.app || snapshot.context_id != binding.context_id {
        return Err(OwnerError::SourceChanged);
    }
    // This check must precede WritersActive: gate 1 permits network-only work.
    verify_runtime_binding(binding.runtime_context.as_ref(), snapshot.runtime_context.as_ref())?;
    if !valid_app(&binding.app) || binding.context_id.is_empty() || !snapshot.complete {
        return Err(OwnerError::NativeContextUnavailable);
    }
    let mut pids = std::collections::BTreeSet::new();
    for process in &snapshot.processes {
        if process.pid <= 0 || process.started_seconds == 0 || process.started_microseconds >= 1_000_000
            || !clean_absolute(&process.executable_path) || !pids.insert(process.pid) {
            return Err(OwnerError::NativeContextUnavailable);
        }
    }
    let writers: Vec<_> = snapshot.processes.iter()
        .filter(|process| process.executable_path.starts_with(&binding.app.bundle_path)).collect();
    let stopped = writers.is_empty() && !snapshot.other_writers;
    match action {
        Action::CheckStopped => if stopped { Ok(Decision::Stopped) } else { Err(OwnerError::WritersActive) },
        Action::Reopen => {
            let launch = launch_context_id.ok_or(OwnerError::NativeContextUnavailable)?;
            if launch != binding.context_id { return Err(OwnerError::SourceChanged); }
            if stopped { Ok(Decision::Reopen) } else { Err(OwnerError::WritersActive) }
        }
        Action::Stop | Action::CheckRunning => {
            if matches!(action, Action::Stop) && stopped { return Ok(Decision::Stopped); }
            let expected = binding.main.as_ref().ok_or(OwnerError::NativeContextUnavailable)?;
            if expected.uid != binding.uid || expected.executable_path != binding.app.executable_path {
                return Err(OwnerError::SourceChanged);
            }
            let actual = snapshot.processes.iter().find(|process| process.pid == expected.pid);
            match actual {
                Some(actual) if actual != expected => Err(OwnerError::SourceChanged),
                Some(_) if matches!(action, Action::CheckRunning) => Ok(Decision::Running),
                Some(_) => {
                    if snapshot.other_writers || writers.iter().any(|p|
                        p.executable_path == binding.app.executable_path && p.pid != expected.pid) {
                        return Err(OwnerError::WritersActive);
                    }
                    Ok(Decision::Terminate { target: expected.clone() })
                }
                None if matches!(action, Action::Stop) => Err(OwnerError::WritersActive),
                None => Err(OwnerError::NativeContextUnavailable),
            }
        }
    }
}
