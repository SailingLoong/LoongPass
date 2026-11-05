//! Claim parsing adapted from pjpv/zcode-switch f34225686dfef05d84c256a56f868719248f15ff.
//! Copyright (c) 2026 zcode-switch contributors; MIT, see licenses/zcode-switch-MIT.txt.
//! Activation telemetry and generated device identities are deliberately excluded.
use serde::{Deserialize, Serialize};
use serde_json::Value;
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Grant {
    pub name: String,
    pub units: Option<f64>,
    pub period: String,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Plan {
    pub id: String,
    pub name: Option<String>,
    pub description: Option<String>,
    pub priority: i64,
    pub units: Option<f64>,
    pub grants: Vec<Grant>,
}
fn text(value: &Value, snake: &str, camel: &str) -> Option<String> {
    value
        .get(snake)
        .or_else(|| value.get(camel))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty() && s.len() <= 256 && !s.chars().any(char::is_control))
        .map(String::from)
}
fn number(value: &Value, snake: &str, camel: &str) -> Option<f64> {
    value
        .get(snake)
        .or_else(|| value.get(camel))
        .and_then(Value::as_f64)
        .filter(|n| n.is_finite() && *n >= 0.)
}
// The 3.17.2 claim client accepts numeric codes and digit-only strings.
// JSON 0.0 is the same numeric zero as 0 in the client. Fractional/error-sized
// values cannot become one of the integer protocol codes used by this worker.
pub(crate) fn response_code(body: &Value) -> Option<i64> {
    let code = body.get("code")?;
    code.as_i64().or_else(|| {
        let number = code.as_f64()?;
        (number.is_finite() && number.fract() == 0.0 && number >= i64::MIN as f64
            && number < i64::MAX as f64).then_some(number as i64)
    }).or_else(|| {
        code.as_str()
            .filter(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))?
            .parse()
            .ok()
    })
}
pub(crate) fn preview(body: &Value) -> Result<Vec<Plan>, &'static str> {
    // 3.17.2 preview differs from claim: omitted code is allowed, but a
    // present code must be numeric zero, never a digit string.
    if body.get("code").is_some_and(|code| !code.is_number() || code.as_f64() != Some(0.0)) {
        return Err("rejected");
    }
    let raw = body
        .pointer("/data/plans")
        .and_then(Value::as_array)
        .ok_or("invalidResponse")?;
    let mut plans = Vec::new();
    for p in raw {
        let id = text(p, "plan_id", "planId").ok_or("invalidResponse")?;
        let grants = p
            .get("entitlements")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter(|e| {
                        text(e, "meter", "meter").as_deref() == Some("model_usage")
                            && text(e, "unit_type", "unitType").as_deref() == Some("token")
                    })
                    .filter_map(|e| {
                        Some(Grant {
                            name: text(e, "show_name", "showName")?,
                            units: number(e, "grant_units", "grantUnits"),
                            period: text(e, "period", "period")
                                .unwrap_or_else(|| "one_time".into()),
                        })
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        let units = grants.first().and_then(|g| g.units);
        plans.push(Plan {
            id,
            name: text(p, "name", "name"),
            description: text(p, "description", "description"),
            priority: p.get("priority").and_then(Value::as_i64).unwrap_or(0),
            units,
            grants,
        });
    }
    plans.sort_by(|a, b| b.priority.cmp(&a.priority).then(a.id.cmp(&b.id)));
    Ok(plans)
}

pub(crate) fn prior_plan_ids(balance: &Value) -> Option<Vec<String>> {
    Some(
        balance
            .get("plans")?
            .as_array()?
            .iter()
            .filter_map(|plan| {
                plan.get("user_plan_id")
                    .and_then(Value::as_str)
                    .map(String::from)
            })
            .collect(),
    )
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Status {
    Unknown,
    Claimable,
    Claimed,
    NoClaim,
    VerificationRequired,
    LoginExpired,
    ResultPending,
    Cancelled,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Record {
    pub status: Status,
    pub plans: Vec<Plan>,
    pub plan_id: Option<String>,
    pub plan_name: Option<String>,
    pub starts_at: Option<i64>,
    pub ends_at: Option<i64>,
    pub checked_at: Option<u64>,
    pub reason: Option<String>,
    pub prior_plan_ids: Vec<String>,
}
impl Default for Record {
    fn default() -> Self {
        Self {
            status: Status::Unknown,
            plans: vec![],
            plan_id: None,
            plan_name: None,
            starts_at: None,
            ends_at: None,
            checked_at: None,
            reason: None,
            prior_plan_ids: vec![],
        }
    }
}
impl Record {
    pub fn preflight_failed(&mut self, reason: &str) {
        if self.status != Status::ResultPending {
            self.status = if reason == "loginExpired" {
                Status::LoginExpired
            } else {
                Status::Unknown
            };
        }
        self.reason = Some(reason.into());
    }
    pub fn may_submit(&self) -> bool {
        matches!(
            self.status,
            Status::Claimable | Status::VerificationRequired
        ) && self.plan_id.is_some()
    }
    pub fn mark_submitted(&mut self) {
        self.status = Status::ResultPending;
        self.reason = Some("confirmResult".into());
    }
    pub fn apply_reply(&mut self, body: &Value) {
        let code = response_code(body);
        self.status = match code {
            Some(0) if body.pointer("/data/plan").is_some_and(Value::is_object) => Status::Claimed,
            Some(1001 | 1002 | 1004 | 1005 | 3001) => Status::NoClaim,
            Some(3007) => Status::VerificationRequired,
            Some(401) => Status::LoginExpired,
            _ => Status::ResultPending,
        };
        self.reason = match code {
            Some(1004) => Some("openOfficialClient".into()),
            Some(1005) => Some("notDue".into()),
            Some(3007) => Some("verifyAgain".into()),
            Some(1003) => Some("confirmResult".into()),
            _ => None,
        };
        // A response may carry another plan even on a known failure. Dates
        // belong to the selected plan only when its explicit IDs agree.
        if let Some(plan) = body.pointer("/data/plan").filter(|plan| {
            self.status != Status::ResultPending && self.plan_id.is_some()
                && plan.get("plan_id").or_else(|| plan.get("planId")).and_then(Value::as_str)
                    == self.plan_id.as_deref()
                && plan.get("plan_id").zip(plan.get("planId")).is_none_or(|(a, b)| a == b)
        }) {
            if self.status == Status::Claimed {
                self.starts_at = plan.get("starts_at").and_then(Value::as_i64);
            }
            self.ends_at = plan.get("ends_at").and_then(Value::as_i64);
        }
    }
    pub fn reconcile(&mut self, balance: &Value) {
        if self.status != Status::ResultPending {
            return;
        }
        let Some(plans) = balance.get("plans").and_then(Value::as_array) else {
            return;
        };
        if let Some(plan) = plans.iter().find(|p| {
            text(p, "plan_id", "planId") == self.plan_id
                && p.get("status").and_then(Value::as_str) == Some("active")
                && text(p, "user_plan_id", "userPlanId")
                    .is_some_and(|id| !self.prior_plan_ids.contains(&id))
        }) {
            self.status = Status::Claimed;
            self.reason = None;
            self.starts_at = plan.get("starts_at").and_then(Value::as_i64);
            self.ends_at = plan.get("ends_at").and_then(Value::as_i64);
        }
    }
}
#[cfg(test)]
#[path = "claim_tests.rs"]
mod tests;

pub(crate) fn allowed_command(window: &str, command: &str) -> bool {
    window != "zcode-claim-captcha"
        || matches!(
            command,
            "get_zcode_claim_captcha" | "submit_zcode_claim_captcha" | "show_zcode_claim_captcha"
        )
}
