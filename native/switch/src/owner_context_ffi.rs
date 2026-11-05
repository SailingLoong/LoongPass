//! Native-only owner entrypoints. Not a Flutter method or discovery API.
use crate::{ffi::{lp_zcode_open, Gate}, owner_context::*};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{ffi::{c_char, c_void, CString}, panic::{catch_unwind, AssertUnwindSafe}, path::PathBuf};
use zeroize::Zeroizing;
const INPUT_LIMIT: usize = 65_536;

unsafe fn input<'a>(data: *const u8, len: usize) -> Option<&'a [u8]> {
    if data.is_null() || len == 0 || len > INPUT_LIMIT { None }
    else { Some(std::slice::from_raw_parts(data, len)) }
}
fn reply(value: serde_json::Value) -> *mut c_char {
    CString::new(value.to_string()).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}
fn failure(code: &str) -> serde_json::Value { json!({"error": code}) }
unsafe fn facts(data: *const u8, len: usize) -> Option<ContextFacts> {
    let bytes = Zeroizing::new(input(data, len)?.to_vec());
    serde_json::from_slice(&bytes).ok()
}

/// Returns source/contextId and optional non-secret runtimeContext, never seed or key bytes.
/// # Safety
/// facts_data points to facts_len readable bytes. Caller owns/wipes its input.
/// Free returned JSON exactly once using lp_zcode_free.
#[no_mangle]
pub unsafe extern "C" fn lp_zcode_owner_metadata(facts_data: *const u8, facts_len: usize) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let Some(facts) = facts(facts_data, facts_len) else { return failure("InvalidArguments"); };
        match resolve_context(&facts) {
            Ok(context) => {
                let mut value = json!({"source": context.source, "contextId": context.context_id});
                if let Some(runtime) = context.runtime_context { value["runtimeContext"] = json!(runtime); }
                value
            },
            Err(error) => failure(error.code()),
        }
    })).unwrap_or_else(|_| failure("NativeContextUnavailable"));
    reply(result)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Options {
    backup_root: PathBuf,
    #[serde(default)] promotion_store_root: Option<PathBuf>,
    #[serde(default)] promotion_plan_ids: Vec<String>,
    #[serde(default)] app_version: Option<String>,
    #[serde(default)] promotion_origin: Option<String>,
    #[serde(default)] promotion_platform: Option<String>,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Config<'a> {
    source: &'a std::path::Path,
    backup_root: &'a std::path::Path,
    context: &'a str,
    secret: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    promotion_store_root: &'a Option<PathBuf>,
    promotion_plan_ids: &'a [String],
    #[serde(skip_serializing_if = "Option::is_none")]
    app_version: &'a Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    promotion_origin: &'a Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    promotion_platform: &'a Option<String>,
}
/// Resolve native facts and open the existing session without returning a secret.
/// No files/processes/environment are read here. Missing facts do not get defaults.
/// # Safety
/// Both buffers must be readable for the given length. The same gate/userdata
/// lifetime and no-reentry requirements as lp_zcode_open apply. Caller wipes inputs.
#[no_mangle]
pub unsafe extern "C" fn lp_zcode_owner_open(
    facts_data: *const u8, facts_len: usize, options_data: *const u8, options_len: usize,
    gate: Option<Gate>, userdata: *mut c_void,
) -> u64 {
    catch_unwind(AssertUnwindSafe(|| -> Option<u64> {
        let facts = facts(facts_data, facts_len)?;
        let context = resolve_context(&facts).ok()?;
        let options: Options = serde_json::from_slice(input(options_data, options_len)?).ok()?;
        let has_promotions = options.promotion_store_root.is_some() || options.app_version.is_some()
            || options.promotion_origin.is_some() || options.promotion_platform.is_some()
            || !options.promotion_plan_ids.is_empty();
        if has_promotions {
            let runtime = context.runtime_context.as_ref()?;
            if options.promotion_origin.as_deref() != Some(runtime.origin.as_str())
                || options.promotion_platform.as_deref() != Some(runtime.request_platform.as_str()) { return None; }
        }
        if !options.backup_root.is_absolute()
            || options.promotion_store_root.as_ref().is_some_and(|p| !p.is_absolute()) { return None; }
        let config = Config { source: &context.source, backup_root: &options.backup_root,
            context: &context.context_id, secret: &context.seed,
            promotion_store_root: &options.promotion_store_root,
            promotion_plan_ids: &options.promotion_plan_ids, app_version: &options.app_version,
            promotion_origin: &options.promotion_origin, promotion_platform: &options.promotion_platform };
        let bytes = Zeroizing::new(serde_json::to_vec(&config).ok()?);
        Some(lp_zcode_open(bytes.as_ptr(), bytes.len(), gate, userdata))
    })).ok().flatten().unwrap_or(0)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DecisionRequest {
    action: Action,
    binding: Binding,
    snapshot: Snapshot,
    #[serde(default)] launch_context_id: Option<String>,
}
/// Evaluate a native snapshot. It is not a replacement for a real snapshot producer.
/// # Safety
/// request points to len readable bytes. Free result once with lp_zcode_free.
#[no_mangle]
pub unsafe extern "C" fn lp_zcode_owner_decide(request: *const u8, len: usize) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let parsed = input(request, len).and_then(|bytes| serde_json::from_slice::<DecisionRequest>(bytes).ok());
        let Some(request) = parsed else { return failure("InvalidArguments"); };
        match decide(request.action, &request.binding, &request.snapshot, request.launch_context_id.as_deref()) {
            Ok(decision) => serde_json::to_value(decision).unwrap_or_else(|_| failure("NativeContextUnavailable")),
            Err(error) => failure(error.code()),
        }
    })).unwrap_or_else(|_| failure("NativeContextUnavailable"));
    reply(result)
}
