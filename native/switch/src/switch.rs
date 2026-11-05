//! Explicit-file, stopped-client transaction. No environment or credential discovery.
//! The caller supplies and retains native process ownership through every gate.
//! A gate callback is an integration seam, NOT proof supplied by a frontend boolean.
//! No runtime bridge or UI command is registered by this crate.
use crate::{
    core::{AccountSnapshot, CredentialDocument, SwitchPlan, MAX_DOCUMENT_BYTES},
    native::NativeCipher,
    zcode_file_lock::{unique_token, FileLock},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    time::Duration,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SwitchError {
    NativeContextUnavailable,
    WritersActive,
    SourceChanged,
    UnsafePath,
    InvalidCredential,
    LockBusy,
    Storage,
    RecoveryChanged,
    CommitUncertain,
}
/// Constructed only by an authenticated native capture; contains no public token DTO.
pub struct SavedAccount {
    pub(crate) snapshot: AccountSnapshot,
}
pub struct Capture {
    pub account: SavedAccount,
    pub revision: [u8; 32],
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Switched,
    Unchanged,
    Restored,
}
/// Local recovery location. Do not send backup files or paths to remote services.
pub struct Receipt {
    pub operation_dir: Option<PathBuf>,
    pub outcome: Outcome,
}
impl std::fmt::Debug for Receipt {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ZcodeReceipt")
            .field("outcome", &self.outcome)
            .field("backup_retained", &self.operation_dir.is_some())
            .finish()
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Intent {
    version: u8,
    source: PathBuf,
    before: [u8; 32],
    after: [u8; 32],
}
struct Image {
    bytes: Vec<u8>,
    stamp: [u64; 7],
    _file: File,
}
fn hash(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}
fn stamp(m: &fs::Metadata) -> [u64; 7] {
    [
        m.dev(),
        m.ino(),
        m.len(),
        m.mtime() as u64,
        m.mtime_nsec() as u64,
        m.ctime() as u64,
        m.ctime_nsec() as u64,
    ]
}
fn directory(path: &Path, private: bool) -> Result<[u64; 2], SwitchError> {
    if !path.is_absolute()
        || path.components().any(|p| {
            matches!(
                p,
                std::path::Component::ParentDir | std::path::Component::CurDir
            )
        })
        || fs::canonicalize(path).map_err(|_| SwitchError::UnsafePath)? != path
    {
        return Err(SwitchError::UnsafePath);
    }
    let m = fs::symlink_metadata(path).map_err(|_| SwitchError::UnsafePath)?;
    if !m.is_dir()
        || m.uid() != unsafe { libc::geteuid() }
        || m.mode() & if private { 0o077 } else { 0o022 } != 0
    {
        return Err(SwitchError::UnsafePath);
    }
    Ok([m.dev(), m.ino()])
}
fn parent(path: &Path) -> Result<&Path, SwitchError> {
    path.parent()
        .filter(|p| !p.as_os_str().is_empty())
        .ok_or(SwitchError::UnsafePath)
}
fn read(path: &Path) -> Result<Image, SwitchError> {
    directory(parent(path)?, false)?;
    if fs::canonicalize(path).map_err(|_| SwitchError::UnsafePath)? != path {
        return Err(SwitchError::UnsafePath);
    }
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)
        .map_err(|_| SwitchError::UnsafePath)?;
    let m = file.metadata().map_err(|_| SwitchError::Storage)?;
    // Mirror native 0600 publication. Never tighten an existing user's file.
    if !m.is_file()
        || m.nlink() != 1
        || m.uid() != unsafe { libc::geteuid() }
        || m.mode() & 0o777 != 0o600
        || m.len() > MAX_DOCUMENT_BYTES as u64
    {
        return Err(SwitchError::UnsafePath);
    }
    let mut bytes = Vec::new();
    (&mut file)
        .take(MAX_DOCUMENT_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| SwitchError::Storage)?;
    let after = file.metadata().map_err(|_| SwitchError::Storage)?;
    let named = fs::symlink_metadata(path).map_err(|_| SwitchError::SourceChanged)?;
    if bytes.len() > MAX_DOCUMENT_BYTES
        || stamp(&m) != stamp(&after)
        || stamp(&after) != stamp(&named)
    {
        return Err(SwitchError::SourceChanged);
    }
    Ok(Image {
        bytes,
        stamp: stamp(&after),
        _file: file,
    })
}
fn unchanged(path: &Path, image: &Image) -> Result<(), SwitchError> {
    let now = read(path)?;
    if image.stamp != now.stamp || image.bytes != now.bytes {
        return Err(SwitchError::SourceChanged);
    }
    Ok(())
}
fn sync_dir(path: &Path) -> Result<(), SwitchError> {
    File::open(path)
        .and_then(|f| f.sync_all())
        .map_err(|_| SwitchError::Storage)
}
fn fresh(path: &Path, bytes: &[u8]) -> Result<(), SwitchError> {
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| SwitchError::Storage)?;
    f.write_all(bytes)
        .and_then(|_| f.sync_all())
        .map_err(|_| SwitchError::Storage)?;
    if read(path)?.bytes != bytes {
        return Err(SwitchError::RecoveryChanged);
    }
    Ok(())
}
fn document(
    image: &Image,
    native: &NativeCipher,
) -> Result<(CredentialDocument, AccountSnapshot), SwitchError> {
    let doc =
        CredentialDocument::parse(&image.bytes).map_err(|_| SwitchError::InvalidCredential)?;
    let account = native
        .inspect(&doc)
        .map_err(|_| SwitchError::InvalidCredential)?;
    Ok((doc, account))
}
fn lock(source: &Path) -> Result<FileLock, SwitchError> {
    FileLock::acquire(source, Duration::ZERO).map_err(|_| SwitchError::LockBusy)
}
fn owned(lock: &FileLock) -> Result<(), SwitchError> {
    if lock.is_owned() {
        Ok(())
    } else {
        Err(SwitchError::LockBusy)
    }
}
/// Capture only an explicitly selected private file in the caller's verified
/// context. Native AES-GCM authentication proves local identity, not remote validity.
pub fn capture(
    source: &Path,
    native: &NativeCipher,
    gate: &mut impl FnMut() -> Result<(), SwitchError>,
) -> Result<Capture, SwitchError> {
    gate()?;
    let root = directory(parent(source)?, false)?;
    let _admit = read(source)?;
    let owner = lock(source)?;
    gate()?;
    let image = read(source)?;
    let (_, snapshot) = document(&image, native)?;
    owned(&owner)?;
    if directory(parent(source)?, false)? != root {
        return Err(SwitchError::SourceChanged);
    }
    unchanged(source, &image)?;
    Ok(Capture {
        account: SavedAccount { snapshot },
        revision: hash(&image.bytes),
    })
}
/// Commit a whole-account merge while the client is stopped. All recoverable
/// files are retained, even on errors; no recursive cleanup or automatic rollback.
/// If any write may have published, return CommitUncertain, never report rollback.
pub fn switch(
    source: &Path,
    root: &Path,
    revision: [u8; 32],
    target: &SavedAccount,
    native: &NativeCipher,
    gate: &mut impl FnMut() -> Result<(), SwitchError>,
) -> Result<Receipt, SwitchError> {
    gate()?;
    let native_root = directory(parent(source)?, false)?;
    let backup_root = directory(root, true)?;
    let _admit = read(source)?;
    let owner = lock(source)?;
    gate()?;
    let before = read(source)?;
    if hash(&before.bytes) != revision {
        return Err(SwitchError::SourceChanged);
    }
    let (doc, current) = document(&before, native)?;
    let checked = native
        .inspect(&target.snapshot.scoped_document())
        .map_err(|_| SwitchError::InvalidCredential)?;
    if checked.identity() != target.snapshot.identity() {
        return Err(SwitchError::InvalidCredential);
    }
    let plan = SwitchPlan::prepare(&doc, current.identity(), &target.snapshot)
        .map_err(|_| SwitchError::InvalidCredential)?;
    if plan.is_noop() {
        owned(&owner)?;
        if directory(parent(source)?, false)? != native_root {
            return Err(SwitchError::SourceChanged);
        }
        unchanged(source, &before)?;
        return Ok(Receipt {
            operation_dir: None,
            outcome: Outcome::Unchanged,
        });
    }
    let after = plan
        .apply(&doc)
        .and_then(|d| d.to_bytes())
        .map_err(|_| SwitchError::InvalidCredential)?;
    let verify = CredentialDocument::parse(&after).map_err(|_| SwitchError::InvalidCredential)?;
    if native
        .inspect(&verify)
        .map_err(|_| SwitchError::InvalidCredential)?
        .identity()
        != target.snapshot.identity()
    {
        return Err(SwitchError::InvalidCredential);
    }
    let op = root.join(format!("zcode-switch-{}", unique_token()));
    fs::DirBuilder::new()
        .mode(0o700)
        .create(&op)
        .map_err(|_| SwitchError::Storage)?;
    fresh(&op.join("before.json"), &before.bytes)?;
    fresh(&op.join("after.json"), &after)?;
    let intent = Intent {
        version: 1,
        source: source.to_path_buf(),
        before: hash(&before.bytes),
        after: hash(&after),
    };
    fresh(
        &op.join("intent.json"),
        &serde_json::to_vec(&intent).map_err(|_| SwitchError::Storage)?,
    )?;
    sync_dir(&op)?;
    sync_dir(root)?;
    gate()?;
    owned(&owner)?;
    if directory(parent(source)?, false)? != native_root || directory(root, true)? != backup_root {
        return Err(SwitchError::SourceChanged);
    }
    unchanged(source, &before)?;
    // Reverify recovery images immediately before publication; do not consume them.
    verify_intent(source, &op)?;
    publish(source, &before, &after, &owner)?;
    // A missing receipt after rename is an uncertain outcome, recoverable by images.
    fresh(&op.join("committed.json"), b"{\"committed\":true}")
        .map_err(|_| SwitchError::CommitUncertain)?;
    sync_dir(&op).map_err(|_| SwitchError::CommitUncertain)?;
    Ok(Receipt {
        operation_dir: Some(op),
        outcome: Outcome::Switched,
    })
}
fn verify_intent(source: &Path, op: &Path) -> Result<(Image, Image), SwitchError> {
    directory(op, true)?;
    let raw = read(&op.join("intent.json"))?;
    let intent: Intent =
        serde_json::from_slice(&raw.bytes).map_err(|_| SwitchError::RecoveryChanged)?;
    if intent.version != 1 || intent.source != source {
        return Err(SwitchError::RecoveryChanged);
    }
    let before = read(&op.join("before.json"))?;
    let after = read(&op.join("after.json"))?;
    if hash(&before.bytes) != intent.before || hash(&after.bytes) != intent.after {
        return Err(SwitchError::RecoveryChanged);
    }
    CredentialDocument::parse(&before.bytes).map_err(|_| SwitchError::RecoveryChanged)?;
    CredentialDocument::parse(&after.bytes).map_err(|_| SwitchError::RecoveryChanged)?;
    Ok((before, after))
}
fn publish(
    source: &Path,
    before: &Image,
    bytes: &[u8],
    owner: &FileLock,
) -> Result<(), SwitchError> {
    let p = parent(source)?;
    let root = directory(p, false)?;
    let temp = p.join(format!(".loongpass-zcode-{}.tmp", unique_token()));
    fresh(&temp, bytes)?;
    owned(owner)?;
    if directory(p, false)? != root {
        return Err(SwitchError::SourceChanged);
    }
    unchanged(source, before)?;
    // Cooperative native writers use this same lock. A malicious same-UID process
    // can still race the final comparison and rename; that is not this threat model.
    fs::rename(&temp, source).map_err(|_| SwitchError::Storage)?;
    sync_dir(p).map_err(|_| SwitchError::CommitUncertain)?;
    if read(source)
        .map_err(|_| SwitchError::CommitUncertain)?
        .bytes
        != bytes
    {
        return Err(SwitchError::CommitUncertain);
    }
    Ok(())
}
/// Explicit conditional restore. Works after a lost commit receipt by comparing
/// exact before/after images. Never overwrites a later native token refresh.
/// Native process ownership must be re-established; this is not an auto-recovery job.
pub fn restore(
    source: &Path,
    operation: &Path,
    gate: &mut impl FnMut() -> Result<(), SwitchError>,
) -> Result<Receipt, SwitchError> {
    gate()?;
    let native_root = directory(parent(source)?, false)?;
    let op_root = directory(operation, true)?;
    let (original, staged) = verify_intent(source, operation)?;
    let _admit = read(source)?;
    // Recovery alone may reclaim an exactly verified dead owner. Live, malformed,
    // ownerless and replaced locks are preserved by the reused native protocol.
    let owner = FileLock::acquire_recoverable(source, Duration::from_millis(250))
        .map_err(|_| SwitchError::LockBusy)?;
    gate()?;
    let current = read(source)?;
    if current.bytes == original.bytes {
        owned(&owner)?;
        if directory(parent(source)?, false)? != native_root
            || directory(operation, true)? != op_root
        {
            return Err(SwitchError::SourceChanged);
        }
        unchanged(source, &current)?;
        return Ok(Receipt {
            operation_dir: Some(operation.to_path_buf()),
            outcome: Outcome::Unchanged,
        });
    }
    if current.bytes != staged.bytes {
        return Err(SwitchError::SourceChanged);
    }
    gate()?;
    owned(&owner)?;
    if directory(parent(source)?, false)? != native_root || directory(operation, true)? != op_root {
        return Err(SwitchError::SourceChanged);
    }
    unchanged(source, &current)?;
    let (again_before, again_after) = verify_intent(source, operation)?;
    if again_before.bytes != original.bytes || again_after.bytes != staged.bytes {
        return Err(SwitchError::RecoveryChanged);
    }
    publish(source, &current, &original.bytes, &owner)?;
    Ok(Receipt {
        operation_dir: Some(operation.to_path_buf()),
        outcome: Outcome::Restored,
    })
}
