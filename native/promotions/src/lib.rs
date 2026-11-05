//! Synthetic promotion orchestration candidate; no HTTP/native account adapter.
#[allow(dead_code)]
#[path = "upstream/claim.rs"]
mod claim;
#[allow(dead_code)]
#[path = "upstream/claim_queue.rs"]
mod claim_queue;
pub mod promotions;
#[cfg(test)]
mod tests;
