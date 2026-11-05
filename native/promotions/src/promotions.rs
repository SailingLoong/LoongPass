//! Minimal server-offer orchestration, reusing the existing Record and Jobs.
//! No HTTP implementation, credential lookup, daily timer, or native persistence.
use crate::{
    claim::{self, Record, Status},
    claim_queue::Jobs,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
const LIMIT: usize = 64 * 1024;
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Failure {
    Cancelled,
    InvalidContext,
    InvalidResponse,
    Storage,
    Busy,
    Transport,
    Unauthorized,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Endpoint {
    Balance,
    Preview,
    Claim,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    pub endpoint: Endpoint,
    pub plan: Option<String>,
}
/// Native transport owns global zcodejwttoken, the explicitly resolved origin,
/// target version/platform, bounded parsing/redaction and disabled redirects/retries.
pub trait Transport {
    fn send(&mut self, request: Request) -> Result<Value, Failure>;
}
/// Success must mean durable publication AND readback, under cross-process
/// ownership held for this whole round. Read errors must never become absence.
/// The immutable binding is native account+context, not a token or calendar day.
pub trait Store {
    fn load(&mut self, binding: &str) -> Result<Option<Vec<u8>>, Failure>;
    fn persist(&mut self, binding: &str, bytes: &[u8]) -> Result<(), Failure>;
}
#[derive(Debug, Clone, Copy)]
pub enum Mode {
    Preview,
    Claim,
}
#[derive(Clone, Default)]
pub struct Worker {
    jobs: Jobs,
    approved: BTreeSet<String>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Saved {
    version: u8,
    binding: String,
    record: Record,
    confirmed: Vec<Confirmation>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Confirmation {
    plan_id: String,
    ends_at: Option<i64>,
}
type Confirmed = BTreeMap<String, Option<i64>>;
fn id(s: &str) -> bool {
    !s.is_empty() && s.len() <= 256 && s.trim() == s && !s.chars().any(char::is_control)
}
fn field<'a>(v: &'a Value, snake: &str, camel: &str) -> Result<Option<&'a str>, Failure> {
    let a = v.get(snake);
    let b = if snake == camel { None } else { v.get(camel) };
    if a.is_some() && b.is_some() && a != b {
        return Err(Failure::InvalidResponse);
    }
    match a.or(b) {
        None => Ok(None),
        Some(Value::String(s)) if id(s) => Ok(Some(s)),
        _ => Err(Failure::InvalidResponse),
    }
}
fn balance(body: &Value) -> Result<Value, Failure> {
    if matches!(claim::response_code(body), Some(401 | 403)) {
        return Err(Failure::Unauthorized);
    }
    if !matches!(claim::response_code(body), Some(0 | 200)) {
        return Err(Failure::InvalidResponse);
    }
    let mut data = body
        .get("data")
        .filter(|v| v.is_object())
        .cloned()
        .ok_or(Failure::InvalidResponse)?;
    let plans = data
        .get_mut("plans")
        .and_then(Value::as_array_mut)
        .ok_or(Failure::InvalidResponse)?;
    for p in plans.iter_mut() {
        if !p.is_object() {
            return Err(Failure::InvalidResponse);
        }
        let plan = field(p, "plan_id", "planId")?
            .ok_or(Failure::InvalidResponse)?
            .to_owned();
        let instance = field(p, "user_plan_id", "userPlanId")?
            .ok_or(Failure::InvalidResponse)?
            .to_owned();
        field(p, "status", "status")?.ok_or(Failure::InvalidResponse)?;
        for key in ["starts_at", "ends_at"] {
            if p.get(key).is_some_and(|v| v.as_i64().is_none()) {
                return Err(Failure::InvalidResponse);
            }
        }
        let object = p.as_object_mut().ok_or(Failure::InvalidResponse)?;
        object.insert("plan_id".into(), json!(plan));
        object.insert("user_plan_id".into(), json!(instance));
    }
    if data
        .get("server_time")
        .is_some_and(|v| v.as_i64().is_none())
    {
        return Err(Failure::InvalidResponse);
    }
    Ok(data)
}
fn active<'a>(balance: &'a Value, id: &str) -> Option<&'a Value> {
    let now = balance.get("server_time").and_then(Value::as_i64);
    balance.get("plans")?.as_array()?.iter().find(|p| {
        p["plan_id"] == id
            && p["status"] == "active"
            && p.get("ends_at")
                .and_then(Value::as_i64)
                .zip(now)
                .is_none_or(|(end, now)| end > now)
    })
}
fn request(
    transport: &mut impl Transport,
    endpoint: Endpoint,
    plan: Option<String>,
    check: &mut impl FnMut() -> Result<(), Failure>,
) -> Result<Value, Failure> {
    check()?;
    let reply = transport.send(Request { endpoint, plan });
    check()?;
    let body = reply?;
    if serde_json::to_vec(&body)
        .map_err(|_| Failure::InvalidResponse)?
        .len()
        > LIMIT
    {
        return Err(Failure::InvalidResponse);
    }
    Ok(body)
}
fn save(
    store: &mut impl Store,
    binding: &str,
    record: &Record,
    confirmed: &Confirmed,
) -> Result<(), Failure> {
    let bytes = serde_json::to_vec(&Saved {
        version: 1,
        binding: binding.into(),
        record: record.clone(),
        confirmed: confirmed
            .iter()
            .map(|(plan_id, ends_at)| Confirmation {
                plan_id: plan_id.clone(),
                ends_at: *ends_at,
            })
            .collect(),
    })
    .map_err(|_| Failure::Storage)?;
    if bytes.len() > LIMIT {
        return Err(Failure::Storage);
    }
    store.persist(binding, &bytes).map_err(|_| Failure::Storage)
}
fn load(store: &mut impl Store, binding: &str) -> Result<(Record, Confirmed), Failure> {
    let Some(bytes) = store.load(binding)? else {
        return Ok((Record::default(), Confirmed::new()));
    };
    if bytes.len() > LIMIT {
        return Err(Failure::Storage);
    }
    let saved: Saved = serde_json::from_slice(&bytes).map_err(|_| Failure::Storage)?;
    if saved.version != 1
        || saved.binding != binding
        || saved.record.plan_id.as_deref().is_some_and(|v| !id(v))
        || saved.record.prior_plan_ids.iter().any(|v| !id(v))
        || (matches!(
            saved.record.status,
            Status::Claimable
                | Status::Claimed
                | Status::VerificationRequired
                | Status::ResultPending
        ) && saved.record.plan_id.is_none())
    {
        return Err(Failure::Storage);
    }
    let mut confirmed = Confirmed::new();
    for receipt in saved.confirmed {
        if !id(&receipt.plan_id) || confirmed.insert(receipt.plan_id, receipt.ends_at).is_some() {
            return Err(Failure::Storage);
        }
    }
    if saved.record.status == Status::Claimed
        && !saved
            .record
            .plan_id
            .as_ref()
            .is_some_and(|id| confirmed.contains_key(id))
    {
        return Err(Failure::Storage);
    }
    Ok((saved.record, confirmed))
}
fn remember(record: &Record, confirmed: &mut Confirmed) {
    if record.status == Status::Claimed {
        if let Some(id) = &record.plan_id {
            confirmed.insert(id.clone(), record.ends_at);
        }
    }
}
fn update_receipts(balance: &Value, confirmed: &mut Confirmed) {
    // Only the expiry attached to a confirmed receipt can release it. A different
    // historical instance of this same plan cannot supply a missing expiry.
    let now = balance.get("server_time").and_then(Value::as_i64);
    confirmed.retain(|_, end| end.zip(now).is_none_or(|(end, now)| end > now));
}

fn view(r: &Record, approved: &BTreeSet<String>) -> Result<Value, Failure> {
    let mut v = serde_json::to_value(r).map_err(|_| Failure::Storage)?;
    let out = v.as_object_mut().ok_or(Failure::Storage)?;
    out.insert(
        "canClaim".into(),
        json!(
            r.status == Status::Claimable
                && r.plan_id.as_ref().is_some_and(|id| approved.contains(id))
        ),
    );
    out.insert("windowPolicy".into(), json!("serverPreview"));
    out.insert("exactOfferWindow".into(), Value::Null);
    // startsAt/endsAt remain entitlement validity from the official response, not
    // evidence of when the promotion itself opens or closes.
    Ok(v)
}
impl Worker {
    /// These are explicitly selected server plan IDs, not guessed campaign names.
    /// Default Worker has no approved plans and cannot send a claim.
    pub fn approved_plans(ids: impl IntoIterator<Item = String>) -> Result<Self, Failure> {
        let mut approved = BTreeSet::new();
        for value in ids {
            if !id(&value) || !approved.insert(value) || approved.len() > 100 {
                return Err(Failure::InvalidContext);
            }
        }
        Ok(Self {
            jobs: Jobs::default(),
            approved,
        })
    }
    pub fn cancel(&self) {
        self.jobs.cancel();
    }
    pub fn shutdown(&self) {
        self.jobs.shutdown();
    }
    pub fn run(
        &self,
        binding: &str,
        mode: Mode,
        checked_at: u64,
        store: &mut impl Store,
        transport: &mut impl Transport,
        check: &mut impl FnMut() -> Result<(), Failure>,
    ) -> Result<Value, Failure> {
        if binding.len() != 64
            || !binding
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(Failure::InvalidContext);
        }
        let lease = self.jobs.begin().map_err(|e| {
            if e == "busy" {
                Failure::Busy
            } else {
                Failure::Cancelled
            }
        })?;
        let mut checked = || {
            if lease.cancelled() {
                Err(Failure::Cancelled)
            } else {
                check()
            }
        };
        checked()?;
        let (mut r, mut confirmed) = load(store, binding)?;
        r.checked_at = Some(checked_at);
        if r.status == Status::VerificationRequired {
            return view(&r, &self.approved);
        }
        let raw = request(transport, Endpoint::Balance, None, &mut checked);
        if r.status == Status::ResultPending {
            match raw.and_then(|body| balance(&body)) {
                Ok(mut b) => {
                    // Reuse existing reconciliation only after complete prior-instance parsing.
                    // Do not let an already-expired active row certify an uncertain new grant.
                    let now = b.get("server_time").and_then(Value::as_i64);
                    if let Some(plans) = b.get_mut("plans").and_then(Value::as_array_mut) {
                        plans.retain(|p| match p.get("ends_at").and_then(Value::as_i64) {
                            None => true,
                            Some(end) => now.is_some_and(|now| end > now),
                        });
                    }
                    r.reconcile(&b);
                }
                Err(e) => r.preflight_failed(if e == Failure::Unauthorized {
                    "loginExpired"
                } else {
                    "confirmResult"
                }),
            }
            remember(&r, &mut confirmed);
            save(store, binding, &r, &confirmed)?;
            return view(&r, &self.approved);
        }
        let b = balance(&raw?)?;
        update_receipts(&b, &mut confirmed);
        let prior = claim::prior_plan_ids(&b).ok_or(Failure::InvalidResponse)?;
        let preview = request(transport, Endpoint::Preview, None, &mut checked)?;
        let raw_plans = preview
            .pointer("/data/plans")
            .and_then(Value::as_array)
            .ok_or(Failure::InvalidResponse)?;
        let mut ids = BTreeSet::new();
        for p in raw_plans {
            let id = field(p, "plan_id", "planId")?.ok_or(Failure::InvalidResponse)?;
            if !ids.insert(id) {
                return Err(Failure::InvalidResponse);
            }
        }
        let plans = claim::preview(&preview).map_err(|_| Failure::InvalidResponse)?;
        let selected = plans
            .iter()
            .find(|p| {
                self.approved.contains(&p.id)
                    && !confirmed.contains_key(&p.id)
                    && active(&b, &p.id).is_none()
            })
            .cloned();
        r = Record {
            plans,
            prior_plan_ids: prior,
            checked_at: Some(checked_at),
            ..Record::default()
        };
        let Some(selected) = selected else {
            r.status = Status::NoClaim;
            r.reason = Some(
                if r.plans.iter().any(|p| self.approved.contains(&p.id)) {
                    "notDue"
                } else if r.plans.is_empty() {
                    "noServerOffer"
                } else {
                    "activitySelectionRequired"
                }
                .into(),
            );
            save(store, binding, &r, &confirmed)?;
            return view(&r, &self.approved);
        };
        r.status = Status::Claimable;
        r.plan_id = Some(selected.id.clone());
        r.plan_name = selected.name;
        if matches!(mode, Mode::Preview) {
            save(store, binding, &r, &confirmed)?;
            return view(&r, &self.approved);
        }
        checked()?;
        r.mark_submitted();
        save(store, binding, &r, &confirmed)?;
        match request(
            transport,
            Endpoint::Claim,
            Some(selected.id.clone()),
            &mut checked,
        ) {
            Ok(reply) => {
                let is_valid_success = claim::response_code(&reply) != Some(0)
                    || reply.pointer("/data/plan").is_some_and(|p| {
                        field(p, "plan_id", "planId").ok().flatten() == Some(selected.id.as_str())
                    });
                if is_valid_success {
                    r.apply_reply(&reply);
                }
            }
            Err(Failure::Unauthorized) => {
                r.reason = Some("loginExpired".into());
            }
            Err(_) => {} // Pending is retained after every possibly sent/unknown request.
        }
        remember(&r, &mut confirmed);
        save(store, binding, &r, &confirmed)?;
        view(&r, &self.approved)
    }
}
