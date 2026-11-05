//! Pure native fact resolution. No environment, filesystem, process or HTTP reads.
use crate::owner_context::{Fact, OwnerError};
use serde::{Deserialize, Serialize};

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RuntimeFacts {
    pub zcode_env: Fact,
    pub base_url: Fact,
    pub endpoint_origin: Fact,
    pub production_base_url: Fact,
    pub test_base_url: Fact,
    pub override_origin: Fact,
    pub process_arch: Fact,
}

/// Non-secret, separately bound runtime identity. It never changes receipt IDs.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RuntimeContext {
    pub origin: String,
    pub credential_platform: String,
    pub request_platform: String,
}

// ECMAScript String.trim, used by the inspected 3.17.2 resolver. Rust's trim
// includes U+0085 and omits U+FEFF, so it is not an interchangeable operation.
fn trim(value: &str) -> &str {
    value.trim_matches(|c| {
        matches!(c, '\u{0009}'..='\u{000d}' | '\u{0020}' | '\u{00a0}'
        | '\u{1680}' | '\u{2000}'..='\u{200a}' | '\u{2028}' | '\u{2029}'
        | '\u{202f}' | '\u{205f}' | '\u{3000}' | '\u{feff}')
    })
}
fn optional(fact: &Fact) -> Result<Option<&str>, OwnerError> {
    match fact {
        Fact::Unknown => Err(OwnerError::NativeContextUnavailable),
        Fact::Unset => Ok(None),
        Fact::Value(value) => Ok(Some(trim(value)).filter(|s| !s.is_empty())),
    }
}
fn normalize_origin(value: &str) -> Result<String, OwnerError> {
    let url = reqwest::Url::parse(trim(value)).map_err(|_| OwnerError::NativeContextUnavailable)?;
    if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
        return Err(OwnerError::NativeContextUnavailable);
    }
    Ok(url.origin().ascii_serialization())
}
impl RuntimeContext {
    pub fn validate(&self) -> Result<(), OwnerError> {
        if self.credential_platform != "darwin"
            || !matches!(
                self.request_platform.as_str(),
                "darwin-arm64" | "darwin-x64"
            )
            || normalize_origin(&self.origin)? != self.origin
        {
            return Err(OwnerError::NativeContextUnavailable);
        }
        Ok(())
    }
}

/// ZCode Jk/UM/Qe semantics, with explicit three-state observations instead of
/// consulting LoongPass's process. Only the selected priority path is required.
pub fn resolve_runtime(
    facts: &RuntimeFacts,
    process_platform: &Fact,
) -> Result<RuntimeContext, OwnerError> {
    let platform = match process_platform {
        Fact::Value(value) if value == "darwin" => value,
        _ => return Err(OwnerError::NativeContextUnavailable),
    };
    let arch = match &facts.process_arch {
        Fact::Value(value) if matches!(value.as_str(), "arm64" | "x64") => value,
        _ => return Err(OwnerError::NativeContextUnavailable),
    };
    let test = optional(&facts.zcode_env)?.is_some_and(|value| value.eq_ignore_ascii_case("test"));
    // Production ignores overrideOrigin entirely, including an unknown value.
    let override_origin = if test {
        optional(&facts.override_origin)?
    } else {
        None
    };
    let raw = if let Some(value) = override_origin {
        value
    } else if let Some(value) = optional(&facts.base_url)? {
        value
    } else if let Some(value) = optional(&facts.endpoint_origin)? {
        value
    } else if let Some(value) = optional(if test {
        &facts.test_base_url
    } else {
        &facts.production_base_url
    })? {
        value
    } else if test {
        "https://zcode.chatglm.site"
    } else {
        "https://zcode.z.ai"
    };
    Ok(RuntimeContext {
        origin: normalize_origin(raw)?,
        credential_platform: platform.clone(),
        request_platform: format!("{platform}-{arch}"),
    })
}

pub fn verify_runtime_binding(
    expected: Option<&RuntimeContext>,
    observed: Option<&RuntimeContext>,
) -> Result<(), OwnerError> {
    match (expected, observed) {
        (None, None) => Ok(()), // Historical switch-only owner, never promotions.
        (Some(expected), Some(observed)) => {
            expected.validate()?;
            observed.validate()?;
            if expected == observed {
                Ok(())
            } else {
                Err(OwnerError::SourceChanged)
            }
        }
        _ => Err(OwnerError::NativeContextUnavailable),
    }
}
