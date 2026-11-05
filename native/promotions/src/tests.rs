use crate::promotions::*;
use serde_json::{json, Value};
use std::collections::VecDeque;
const BINDING: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
#[derive(Default)]
struct Memory {
    bytes: Option<Vec<u8>>,
    writes: usize,
    fail_at: Option<usize>,
}
impl Store for Memory {
    fn load(&mut self, _: &str) -> Result<Option<Vec<u8>>, Failure> {
        Ok(self.bytes.clone())
    }
    fn persist(&mut self, _: &str, bytes: &[u8]) -> Result<(), Failure> {
        self.writes += 1;
        if self.fail_at == Some(self.writes) {
            return Err(Failure::Storage);
        }
        self.bytes = Some(bytes.to_vec());
        Ok(())
    }
}
struct Wire {
    queue: VecDeque<Result<Value, Failure>>,
    calls: Vec<Request>,
}
impl Wire {
    fn new(replies: Vec<Result<Value, Failure>>) -> Self {
        Self {
            queue: replies.into(),
            calls: vec![],
        }
    }
    fn posts(&self) -> usize {
        self.calls
            .iter()
            .filter(|r| r.endpoint == Endpoint::Claim)
            .count()
    }
}
impl Transport for Wire {
    fn send(&mut self, req: Request) -> Result<Value, Failure> {
        self.calls.push(req);
        self.queue.pop_front().expect("unexpected request")
    }
}
fn balance(plans: Value, now: i64) -> Value {
    json!({"code":0,"data":{"server_time":now,"plans":plans}})
}
fn preview(ids: &[&str]) -> Value {
    json!({"code":0,"data":{"plans":ids.iter().map(|id|json!({"plan_id":id,"name":id,"priority":1})).collect::<Vec<_>>()}})
}
fn success(id: &str) -> Value {
    json!({"code":0,"data":{"plan":{"plan_id":id,"user_plan_id":"new-instance","starts_at":100,"ends_at":200}}})
}
fn run(store: &mut impl Store, wire: &mut Wire, mode: Mode, now: u64) -> Result<Value, Failure> {
    Worker::approved_plans(["event", "weekend-event", "midnight-event"].map(String::from))
        .unwrap()
        .run(BINDING, mode, now, store, wire, &mut || Ok(()))
}
#[test]
fn server_preview_not_local_midnight_or_weekday_controls_offers() {
    for local_time in [0, 43_200, 345_600, 604_800] {
        let mut s = Memory::default();
        let mut w = Wire::new(vec![
            Ok(balance(json!([]), 100)),
            Ok(preview(&["weekend-event"])),
            Ok(success("weekend-event")),
        ]);
        let r = run(&mut s, &mut w, Mode::Claim, local_time).unwrap();
        assert_eq!(r["status"], "claimed");
        assert_eq!(w.posts(), 1);
        assert_eq!(r["windowPolicy"], "serverPreview");
        assert_eq!(r["exactOfferWindow"], Value::Null);
    }
}
#[test]
fn midnight_without_server_offer_does_not_post() {
    let mut s = Memory::default();
    let mut w = Wire::new(vec![Ok(balance(json!([]), 0)), Ok(preview(&[]))]);
    let r = run(&mut s, &mut w, Mode::Claim, 0).unwrap();
    assert_eq!(r["status"], "noClaim");
    assert_eq!(w.posts(), 0);
}
#[test]
fn preview_only_never_posts_and_preserves_unknown_window() {
    let mut s = Memory::default();
    let mut w = Wire::new(vec![
        Ok(balance(json!([]), 100)),
        Ok(preview(&["midnight-event"])),
    ]);
    let r = run(&mut s, &mut w, Mode::Preview, 100).unwrap();
    assert_eq!(r["status"], "claimable");
    assert_eq!(r["canClaim"], true);
    assert_eq!(w.posts(), 0);
    assert_eq!(r["exactOfferWindow"], Value::Null);
}
#[test]
fn pending_write_failure_prevents_post() {
    let mut s = Memory {
        fail_at: Some(1),
        ..Default::default()
    };
    let mut w = Wire::new(vec![Ok(balance(json!([]), 100)), Ok(preview(&["event"]))]);
    assert_eq!(
        run(&mut s, &mut w, Mode::Claim, 100).unwrap_err(),
        Failure::Storage
    );
    assert_eq!(w.posts(), 0);
}
#[test]
fn timeout_stays_pending_across_restart_and_only_reads_balance() {
    let mut s = Memory::default();
    let mut w = Wire::new(vec![
        Ok(balance(json!([]), 100)),
        Ok(preview(&["event"])),
        Err(Failure::Transport),
    ]);
    let r = run(&mut s, &mut w, Mode::Claim, 100).unwrap();
    assert_eq!(r["status"], "resultPending");
    assert_eq!(w.posts(), 1);
    let mut next = Wire::new(vec![Ok(balance(json!([]), 200))]);
    let r = run(&mut s, &mut next, Mode::Claim, 99999999).unwrap();
    assert_eq!(r["status"], "resultPending");
    assert_eq!(
        next.calls.iter().map(|r| r.endpoint).collect::<Vec<_>>(),
        vec![Endpoint::Balance]
    );
}
#[test]
fn malformed_or_foreign_success_stays_pending() {
    for reply in [
        json!({"code":0}),
        json!({"code":0,"data":{"plan":{}}}),
        success("other-event"),
    ] {
        let mut s = Memory::default();
        let mut w = Wire::new(vec![
            Ok(balance(json!([]), 100)),
            Ok(preview(&["event"])),
            Ok(reply),
        ]);
        let r = run(&mut s, &mut w, Mode::Claim, 100).unwrap();
        assert_eq!(r["status"], "resultPending");
        assert_eq!(w.posts(), 1);
    }
}
#[test]
fn pending_reconciliation_requires_new_active_matching_instance() {
    let old = json!({"plan_id":"event","user_plan_id":"old","status":"expired","ends_at":90});
    let mut s = Memory::default();
    let mut w = Wire::new(vec![
        Ok(balance(json!([old]), 100)),
        Ok(preview(&["event"])),
        Err(Failure::Transport),
    ]);
    run(&mut s, &mut w, Mode::Claim, 100).unwrap();
    for plans in [
        json!([{"plan_id":"event","user_plan_id":"old","status":"active","ends_at":300}]),
        json!([{"plan_id":"other","user_plan_id":"new","status":"active","ends_at":300}]),
    ] {
        let mut next = Wire::new(vec![Ok(balance(plans, 200))]);
        assert_eq!(
            run(&mut s, &mut next, Mode::Claim, 200).unwrap()["status"],
            "resultPending"
        );
        assert_eq!(next.posts(), 0);
    }
    let mut next = Wire::new(vec![Ok(balance(
        json!([{"plan_id":"event","user_plan_id":"new","status":"active","starts_at":150,"ends_at":300}]),
        200,
    ))]);
    assert_eq!(
        run(&mut s, &mut next, Mode::Claim, 200).unwrap()["status"],
        "claimed"
    );
    assert_eq!(next.posts(), 0);
}
#[test]
fn malformed_prior_instances_fail_before_post() {
    for plans in [
        json!([{}]),
        json!([{"plan_id":"event","status":"active"}]),
        json!([{"plan_id":"event","user_plan_id":"old","userPlanId":"conflict","status":"active"}]),
    ] {
        let mut s = Memory::default();
        let mut w = Wire::new(vec![Ok(balance(plans, 100))]);
        assert_eq!(
            run(&mut s, &mut w, Mode::Claim, 100).unwrap_err(),
            Failure::InvalidResponse
        );
        assert_eq!(w.posts(), 0);
    }
}
#[test]
fn captcha_rejection_needs_human_and_never_automatically_reposts() {
    let mut s = Memory::default();
    let mut w = Wire::new(vec![
        Ok(balance(json!([]), 100)),
        Ok(preview(&["event"])),
        Ok(json!({"code":3007,"message":"ignored-secret-canary"})),
    ]);
    assert_eq!(
        run(&mut s, &mut w, Mode::Claim, 100).unwrap()["status"],
        "verificationRequired"
    );
    let mut next = Wire::new(vec![]);
    let r = run(&mut s, &mut next, Mode::Claim, 100000).unwrap();
    assert_eq!(r["status"], "verificationRequired");
    assert!(!r.to_string().contains("secret-canary"));
    assert_eq!(next.posts(), 0);
}
#[test]
fn durable_pending_survives_failure_saving_a_success_receipt() {
    let mut s = Memory {
        fail_at: Some(2),
        ..Default::default()
    };
    let mut w = Wire::new(vec![
        Ok(balance(json!([]), 100)),
        Ok(preview(&["event"])),
        Ok(success("event")),
    ]);
    assert_eq!(
        run(&mut s, &mut w, Mode::Claim, 100).unwrap_err(),
        Failure::Storage
    );
    let mut next = Wire::new(vec![Ok(balance(json!([]), 200))]);
    assert_eq!(
        run(&mut s, &mut next, Mode::Claim, 200).unwrap()["status"],
        "resultPending"
    );
    assert_eq!(next.posts(), 0);
}

#[test]
fn default_scope_and_unselected_campaigns_never_post() {
    for worker in [
        Worker::default(),
        Worker::approved_plans(["chosen".into()]).unwrap(),
    ] {
        let mut s = Memory::default();
        let mut w = Wire::new(vec![Ok(balance(json!([]), 100)), Ok(preview(&["event"]))]);
        let r = worker
            .run(BINDING, Mode::Claim, 100, &mut s, &mut w, &mut || Ok(()))
            .unwrap();
        assert_eq!(r["reason"], "activitySelectionRequired");
        assert_eq!(r["canClaim"], false);
        assert_eq!(w.posts(), 0);
    }
}
#[test]
fn explicit_scope_validates_ids_and_does_not_add_signature_or_device_inputs() {
    for ids in [
        vec!["".into()],
        vec![" event".into()],
        vec!["a".repeat(257)],
        vec!["event".into(), "event".into()],
        (0..101).map(|i| format!("id-{i}")).collect(),
    ] {
        assert!(matches!(
            Worker::approved_plans(ids),
            Err(Failure::InvalidContext)
        ));
    }
}
#[test]
fn at_most_one_approved_offer_is_chosen_by_existing_priority_then_id() {
    let mut s = Memory::default();
    let mut w = Wire::new(vec![
        Ok(balance(json!([]), 100)),
        Ok(json!({"code":0,"data":{"plans":[
            {"plan_id":"event","priority":1}, {"plan_id":"weekend-event","priority":2},
            {"plan_id":"midnight-event","priority":2}, {"plan_id":"unselected","priority":99}
        ]}})),
        Ok(success("midnight-event")),
    ]);
    let r = run(&mut s, &mut w, Mode::Claim, 100).unwrap();
    assert_eq!(r["planId"], "midnight-event");
    assert_eq!(w.posts(), 1);
    assert_eq!(
        w.calls.last().unwrap().plan.as_deref(),
        Some("midnight-event")
    );
}
#[test]
fn owned_active_window_uses_server_time_and_missing_time_blocks_duplicate() {
    for body in [
        balance(
            json!([{"plan_id":"event","user_plan_id":"old","status":"active","starts_at":99999,"ends_at":101}]),
            100,
        ),
        balance(
            json!([{"plan_id":"event","user_plan_id":"old","status":"active"}]),
            100,
        ),
        json!({"code":0,"data":{"plans":[{"plan_id":"event","user_plan_id":"old","status":"active","ends_at":1}]}}),
    ] {
        let mut s = Memory::default();
        let mut w = Wire::new(vec![Ok(body), Ok(preview(&["event"]))]);
        assert_eq!(
            run(&mut s, &mut w, Mode::Claim, u64::MAX).unwrap()["reason"],
            "notDue"
        );
        assert_eq!(w.posts(), 0);
    }
    let mut s = Memory::default();
    let mut w = Wire::new(vec![
        Ok(balance(
            json!([{"plan_id":"event","user_plan_id":"old","status":"active","ends_at":100}]),
            100,
        )),
        Ok(preview(&["event"])),
        Ok(success("event")),
    ]);
    assert_eq!(
        run(&mut s, &mut w, Mode::Claim, 0).unwrap()["status"],
        "claimed"
    );
    assert_eq!(w.posts(), 1);
}
fn pending() -> Memory {
    let mut s = Memory::default();
    let mut w = Wire::new(vec![
        Ok(balance(json!([]), 100)),
        Ok(preview(&["event"])),
        Err(Failure::Transport),
    ]);
    run(&mut s, &mut w, Mode::Claim, 100).unwrap();
    s
}
#[test]
fn pending_is_not_cleared_by_errors_auth_expiry_or_new_scope() {
    for response in [
        Err(Failure::Transport),
        Err(Failure::Unauthorized),
        Ok(json!({"code":401})),
        Ok(json!({"code":0,"data":{}})),
        Ok(balance(json!([{}]), 100)),
    ] {
        let mut s = pending();
        let mut w = Wire::new(vec![response]);
        let r = Worker::default()
            .run(BINDING, Mode::Claim, u64::MAX, &mut s, &mut w, &mut || {
                Ok(())
            })
            .unwrap();
        assert_eq!(r["status"], "resultPending");
        assert_eq!(w.posts(), 0);
        assert_eq!(w.calls.len(), 1);
        assert_eq!(
            serde_json::from_slice::<Value>(s.bytes.as_ref().unwrap()).unwrap()["record"]["status"],
            "resultPending"
        );
    }
}
#[test]
fn expired_active_instance_cannot_certify_an_unknown_claim() {
    let mut s = pending();
    let mut w = Wire::new(vec![Ok(balance(
        json!([{"plan_id":"event","user_plan_id":"new","status":"active","ends_at":100}]),
        100,
    ))]);
    assert_eq!(
        run(&mut s, &mut w, Mode::Claim, 100).unwrap()["status"],
        "resultPending"
    );
    assert_eq!(w.posts(), 0);
}
#[test]
fn normalized_alias_snapshot_does_not_mistake_old_instance_for_new() {
    let mut s = Memory::default();
    let mut w = Wire::new(vec![
        Ok(balance(
            json!([{"planId":"event","userPlanId":"old","status":"expired"}]),
            100,
        )),
        Ok(preview(&["event"])),
        Err(Failure::Transport),
    ]);
    run(&mut s, &mut w, Mode::Claim, 100).unwrap();
    let mut next = Wire::new(vec![Ok(balance(
        json!([{"planId":"event","userPlanId":"old","status":"active"}]),
        101,
    ))]);
    assert_eq!(
        run(&mut s, &mut next, Mode::Claim, 101).unwrap()["status"],
        "resultPending"
    );
}
#[test]
fn known_rejections_are_distinct_and_unknown_codes_remain_pending() {
    for (code, status) in [
        (1001, "noClaim"),
        (1002, "noClaim"),
        (1003, "resultPending"),
        (1004, "noClaim"),
        (1005, "noClaim"),
        (3001, "noClaim"),
        (3007, "verificationRequired"),
        (401, "loginExpired"),
        (403, "resultPending"),
        (99999, "resultPending"),
    ] {
        let mut s = Memory::default();
        let mut w = Wire::new(vec![
            Ok(balance(json!([]), 100)),
            Ok(preview(&["event"])),
            Ok(json!({"code":code.to_string(),"message":"do-not-echo-this"})),
        ]);
        let r = run(&mut s, &mut w, Mode::Claim, 100).unwrap();
        assert_eq!(r["status"], status);
        assert!(!r.to_string().contains("do-not-echo-this"));
        assert_eq!(w.posts(), 1);
    }
}
#[test]
fn malformed_preview_or_oversized_response_never_posts() {
    for response in [
        preview(&["event", "event"]),
        json!({"code":0,"data":{"plans":[{"plan_id":"event","planId":"conflict"}]}}),
        json!({"code":0,"data":{"plans":[]},"message":"x".repeat(65536)}),
    ] {
        let mut s = Memory::default();
        let mut w = Wire::new(vec![Ok(balance(json!([]), 100)), Ok(response)]);
        assert_eq!(
            run(&mut s, &mut w, Mode::Claim, 100).unwrap_err(),
            Failure::InvalidResponse
        );
        assert_eq!(w.posts(), 0);
    }
}
#[test]
fn invalid_binding_or_damaged_saved_state_does_not_read_network() {
    let source = pending().bytes.unwrap();
    let mut wrong: Value = serde_json::from_slice(&source).unwrap();
    wrong["binding"] = json!("b".repeat(64));
    let mut missing: Value = serde_json::from_slice(&source).unwrap();
    missing["record"]["planId"] = Value::Null;
    for bytes in [
        b"not-json".to_vec(),
        vec![0; 65537],
        serde_json::to_vec(&wrong).unwrap(),
        serde_json::to_vec(&missing).unwrap(),
    ] {
        let mut s = Memory {
            bytes: Some(bytes.clone()),
            ..Default::default()
        };
        let mut w = Wire::new(vec![]);
        assert_eq!(
            run(&mut s, &mut w, Mode::Claim, 100).unwrap_err(),
            Failure::Storage
        );
        assert!(w.calls.is_empty());
        assert_eq!(s.bytes.unwrap(), bytes);
    }
    let mut s = Memory::default();
    let mut w = Wire::new(vec![]);
    assert_eq!(
        Worker::default()
            .run("bad", Mode::Claim, 100, &mut s, &mut w, &mut || Ok(()))
            .unwrap_err(),
        Failure::InvalidContext
    );
}
#[test]
fn storage_read_failure_is_never_treated_as_an_empty_record() {
    struct Broken;
    impl Store for Broken {
        fn load(&mut self, _: &str) -> Result<Option<Vec<u8>>, Failure> {
            Err(Failure::Storage)
        }
        fn persist(&mut self, _: &str, _: &[u8]) -> Result<(), Failure> {
            panic!("must not write")
        }
    }
    let mut w = Wire::new(vec![]);
    assert_eq!(
        run(&mut Broken, &mut w, Mode::Claim, 100).unwrap_err(),
        Failure::Storage
    );
    assert!(w.calls.is_empty());
}
#[test]
fn cancellation_before_admission_or_after_pending_never_posts() {
    let worker = Worker::approved_plans(["event".into()]).unwrap();
    let mut w = Wire::new(vec![]);
    assert_eq!(
        worker
            .run(
                BINDING,
                Mode::Claim,
                100,
                &mut Memory::default(),
                &mut w,
                &mut || Err(Failure::Cancelled)
            )
            .unwrap_err(),
        Failure::Cancelled
    );
    struct CancelStore {
        inner: Memory,
        worker: Worker,
    }
    impl Store for CancelStore {
        fn load(&mut self, b: &str) -> Result<Option<Vec<u8>>, Failure> {
            self.inner.load(b)
        }
        fn persist(&mut self, b: &str, v: &[u8]) -> Result<(), Failure> {
            self.inner.persist(b, v)?;
            self.worker.cancel();
            Ok(())
        }
    }
    let mut s = CancelStore {
        inner: Memory::default(),
        worker: worker.clone(),
    };
    let mut w = Wire::new(vec![Ok(balance(json!([]), 100)), Ok(preview(&["event"]))]);
    assert_eq!(
        worker
            .run(BINDING, Mode::Claim, 100, &mut s, &mut w, &mut || Ok(()))
            .unwrap()["status"],
        "resultPending"
    );
    assert_eq!(w.posts(), 0);
}
#[test]
fn cloned_worker_keeps_exclusive_job_until_cancelled_post_physically_returns() {
    let worker = Worker::approved_plans(["event".into()]).unwrap();
    struct Nested {
        worker: Worker,
        calls: usize,
    }
    impl Transport for Nested {
        fn send(&mut self, r: Request) -> Result<Value, Failure> {
            self.calls += 1;
            if r.endpoint == Endpoint::Claim {
                self.worker.cancel();
            }
            assert_eq!(
                self.worker
                    .run(
                        BINDING,
                        Mode::Claim,
                        100,
                        &mut Memory::default(),
                        &mut Wire::new(vec![]),
                        &mut || Ok(())
                    )
                    .unwrap_err(),
                Failure::Busy
            );
            Ok(match r.endpoint {
                Endpoint::Balance => balance(json!([]), 100),
                Endpoint::Preview => preview(&["event"]),
                Endpoint::Claim => success("event"),
            })
        }
    }
    let mut w = Nested {
        worker: worker.clone(),
        calls: 0,
    };
    let mut s = Memory::default();
    let r = worker
        .run(BINDING, Mode::Claim, 100, &mut s, &mut w, &mut || Ok(()))
        .unwrap();
    assert_eq!(r["status"], "resultPending");
    assert_eq!(w.calls, 3);
    let mut next = Wire::new(vec![Ok(balance(json!([]), 200))]);
    assert_eq!(
        worker
            .run(BINDING, Mode::Claim, 200, &mut s, &mut next, &mut || Ok(()))
            .unwrap()["status"],
        "resultPending"
    );
    assert_eq!(next.posts(), 0);
    worker.shutdown();
    assert_eq!(
        worker
            .run(
                BINDING,
                Mode::Claim,
                200,
                &mut s,
                &mut Wire::new(vec![]),
                &mut || Ok(())
            )
            .unwrap_err(),
        Failure::Cancelled
    );
}

// Test-only durable fixture, not a production native Store implementation.
struct SyntheticFileStore(std::path::PathBuf);
impl Store for SyntheticFileStore {
    fn load(&mut self, _: &str) -> Result<Option<Vec<u8>>, Failure> {
        match std::fs::read(&self.0) {
            Ok(v) => Ok(Some(v)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(_) => Err(Failure::Storage),
        }
    }
    fn persist(&mut self, _: &str, bytes: &[u8]) -> Result<(), Failure> {
        use std::io::Write;
        let tmp = self.0.with_extension("tmp");
        let mut f = std::fs::File::create(&tmp).map_err(|_| Failure::Storage)?;
        f.write_all(bytes)
            .and_then(|_| f.sync_all())
            .map_err(|_| Failure::Storage)?;
        std::fs::rename(&tmp, &self.0).map_err(|_| Failure::Storage)?;
        std::fs::File::open(self.0.parent().unwrap())
            .and_then(|f| f.sync_all())
            .map_err(|_| Failure::Storage)?;
        if std::fs::read(&self.0).map_err(|_| Failure::Storage)? != bytes {
            return Err(Failure::Storage);
        }
        Ok(())
    }
}
#[test]
#[ignore = "child entry point invoked by process_restart_retains_pending_before_post_return"]
fn synthetic_claim_process_exit() {
    let path = std::path::PathBuf::from(
        std::env::var_os("LOONGPASS_SYNTHETIC_PROMOTION_STATE").expect("synthetic fixture path"),
    );
    struct ExitWire(std::path::PathBuf);
    impl Transport for ExitWire {
        fn send(&mut self, r: Request) -> Result<Value, Failure> {
            match r.endpoint {
                Endpoint::Balance => Ok(balance(json!([]), 100)),
                Endpoint::Preview => Ok(preview(&["event"])),
                Endpoint::Claim => {
                    let saved: Value =
                        serde_json::from_slice(&std::fs::read(&self.0).unwrap()).unwrap();
                    assert_eq!(saved["record"]["status"], "resultPending");
                    assert_eq!(saved["record"]["planId"], "event");
                    std::process::exit(73)
                }
            }
        }
    }
    Worker::approved_plans(["event".into()])
        .unwrap()
        .run(
            BINDING,
            Mode::Claim,
            100,
            &mut SyntheticFileStore(path.clone()),
            &mut ExitWire(path),
            &mut || Ok(()),
        )
        .unwrap();
    panic!("synthetic process should exit inside one claim attempt")
}
#[test]
fn process_restart_retains_pending_before_post_return() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("synthetic-state.json");
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "tests::synthetic_claim_process_exit",
        ])
        .env("LOONGPASS_SYNTHETIC_PROMOTION_STATE", &path)
        .status()
        .unwrap();
    assert_eq!(status.code(), Some(73));
    let mut s = SyntheticFileStore(path);
    let mut w = Wire::new(vec![Ok(balance(json!([]), 200))]);
    assert_eq!(
        run(&mut s, &mut w, Mode::Claim, 99999999).unwrap()["status"],
        "resultPending"
    );
    assert_eq!(w.posts(), 0);
    assert_eq!(w.calls.len(), 1);
    let mut next = Wire::new(vec![Ok(balance(
        json!([{"plan_id":"event","user_plan_id":"new","status":"active","ends_at":300}]),
        200,
    ))]);
    assert_eq!(
        run(&mut s, &mut next, Mode::Claim, 200).unwrap()["status"],
        "claimed"
    );
    assert_eq!(next.posts(), 0);
}

#[test]
fn confirmed_receipt_blocks_repost_while_balance_is_stale() {
    let mut s = Memory::default();
    let mut first = Wire::new(vec![
        Ok(balance(json!([]), 100)),
        Ok(preview(&["event"])),
        Ok(success("event")),
    ]);
    run(&mut s, &mut first, Mode::Claim, 100).unwrap();
    let mut stale = Wire::new(vec![Ok(balance(json!([]), 101)), Ok(preview(&["event"]))]);
    let r = run(&mut s, &mut stale, Mode::Claim, 99999999).unwrap();
    assert_eq!(r["status"], "noClaim");
    assert_eq!(stale.posts(), 0);
}
#[test]
fn receipts_survive_alternating_promotions_and_expire_only_at_server_time() {
    let mut s = Memory::default();
    for id in ["event", "weekend-event"] {
        let mut w = Wire::new(vec![
            Ok(balance(json!([]), 100)),
            Ok(preview(&[id])),
            Ok(success(id)),
        ]);
        run(&mut s, &mut w, Mode::Claim, 100).unwrap();
    }
    let mut stale = Wire::new(vec![
        Ok(balance(json!([]), 199)),
        Ok(preview(&["event", "weekend-event"])),
    ]);
    assert_eq!(
        run(&mut s, &mut stale, Mode::Claim, u64::MAX).unwrap()["status"],
        "noClaim"
    );
    assert_eq!(stale.posts(), 0);
    let mut eligible = Wire::new(vec![
        Ok(balance(json!([]), 200)),
        Ok(preview(&["event"])),
        Ok(success("event")),
    ]);
    assert_eq!(
        run(&mut s, &mut eligible, Mode::Claim, 0).unwrap()["status"],
        "claimed"
    );
    assert_eq!(eligible.posts(), 1);
}
#[test]
fn receipt_without_expiry_stays_blocked_even_if_balance_has_an_unbound_instance() {
    let mut s = Memory::default();
    let mut first = Wire::new(vec![
        Ok(balance(json!([]), 100)),
        Ok(preview(&["event"])),
        Ok(json!({"code":0,"data":{"plan":{"plan_id":"event"}}})),
    ]);
    run(&mut s, &mut first, Mode::Claim, 100).unwrap();
    for body in [
        balance(json!([]), 99999),
        balance(
            json!([{"plan_id":"event","user_plan_id":"known","status":"active","ends_at":100001}]),
            100000,
        ),
    ] {
        let mut w = Wire::new(vec![Ok(body), Ok(preview(&["event"]))]);
        assert_eq!(
            run(&mut s, &mut w, Mode::Claim, 0).unwrap()["status"],
            "noClaim"
        );
        assert_eq!(w.posts(), 0);
    }
    let mut eligible = Wire::new(vec![
        Ok(balance(json!([]), 100001)),
        Ok(preview(&["event"])),
    ]);
    assert_eq!(
        run(&mut s, &mut eligible, Mode::Claim, 0).unwrap()["status"],
        "noClaim"
    );
    assert_eq!(eligible.posts(), 0);
}
#[test]
fn transport_auth_error_cannot_release_a_possibly_sent_claim() {
    let mut s = Memory::default();
    let mut first = Wire::new(vec![
        Ok(balance(json!([]), 100)),
        Ok(preview(&["event"])),
        Err(Failure::Unauthorized),
    ]);
    assert_eq!(
        run(&mut s, &mut first, Mode::Claim, 100).unwrap()["status"],
        "resultPending"
    );
    let mut next = Wire::new(vec![Ok(balance(json!([]), 200))]);
    assert_eq!(
        run(&mut s, &mut next, Mode::Claim, 200).unwrap()["status"],
        "resultPending"
    );
    assert_eq!(next.posts(), 0);
}
#[test]
fn timed_instance_without_server_clock_cannot_confirm_pending() {
    let mut s = pending();
    let mut w = Wire::new(vec![Ok(
        json!({"code":0,"data":{"plans":[{"plan_id":"event","user_plan_id":"new","status":"active","ends_at":100}]}}),
    )]);
    assert_eq!(
        run(&mut s, &mut w, Mode::Claim, 0).unwrap()["status"],
        "resultPending"
    );
    assert_eq!(w.posts(), 0);
}
#[test]
fn malformed_or_duplicate_persisted_receipts_are_not_silently_discarded() {
    let base: Value = serde_json::from_slice(&pending().bytes.unwrap()).unwrap();
    for receipts in [
        json!([{"plan_id":"event","ends_at":null},{"plan_id":"event","ends_at":200}]),
        json!([{"plan_id":"","ends_at":null}]),
        json!([{"plan_id":"event","ends_at":"invalid"}]),
        json!([{"plan_id":"event","ends_at":null,"unexpected":true}]),
    ] {
        let mut state = base.clone();
        state["confirmed"] = receipts;
        let mut s = Memory {
            bytes: Some(serde_json::to_vec(&state).unwrap()),
            ..Default::default()
        };
        let before = s.bytes.clone();
        let mut w = Wire::new(vec![]);
        assert_eq!(
            run(&mut s, &mut w, Mode::Claim, 100).unwrap_err(),
            Failure::Storage
        );
        assert_eq!(s.bytes, before);
        assert!(w.calls.is_empty());
    }
}
#[test]
fn unknown_receipt_expiry_cannot_be_filled_by_an_old_balance_instance() {
    let old = json!([{"plan_id":"event","user_plan_id":"old","status":"active","ends_at":90}]);
    let mut s = Memory::default();
    let mut first = Wire::new(vec![
        Ok(balance(old.clone(), 100)),
        Ok(preview(&["event"])),
        Ok(json!({"code":0,"data":{"plan":{"plan_id":"event"}}})),
    ]);
    run(&mut s, &mut first, Mode::Claim, 100).unwrap();
    let mut stale = Wire::new(vec![Ok(balance(old, 101)), Ok(preview(&["event"]))]);
    assert_eq!(
        run(&mut s, &mut stale, Mode::Claim, 101).unwrap()["status"],
        "noClaim"
    );
    assert_eq!(stale.posts(), 0);
}
#[test]
fn claimed_record_without_matching_receipt_is_corruption() {
    let mut s = Memory::default();
    let mut first = Wire::new(vec![
        Ok(balance(json!([]), 100)),
        Ok(preview(&["event"])),
        Ok(success("event")),
    ]);
    run(&mut s, &mut first, Mode::Claim, 100).unwrap();
    let mut bytes: Value = serde_json::from_slice(&s.bytes.unwrap()).unwrap();
    bytes["confirmed"] = json!([]);
    s.bytes = Some(serde_json::to_vec(&bytes).unwrap());
    let mut next = Wire::new(vec![]);
    assert_eq!(
        run(&mut s, &mut next, Mode::Claim, 101).unwrap_err(),
        Failure::Storage
    );
    assert!(next.calls.is_empty());
}

#[test]
fn preview_3172_absent_code_with_explicit_empty_plans_means_no_offer() {
    for body in [json!({"data":{"plans":[]}}), json!({"code":0,"data":{"plans":[]}})] {
        let mut s = Memory::default();
        let mut w = Wire::new(vec![Ok(balance(json!([]), 100)), Ok(body)]);
        let result = run(&mut s, &mut w, Mode::Claim, 100).unwrap();
        assert_eq!(result["status"], "noClaim");
        assert_eq!(result["reason"], "noServerOffer");
        assert_eq!(w.posts(), 0);
    }
}
#[test]
fn preview_3172_string_code_is_not_claim_authority() {
    let mut s = Memory::default();
    let mut body = preview(&["event"]); body["code"] = json!("0");
    let mut w = Wire::new(vec![Ok(balance(json!([]),100)), Ok(body)]);
    assert_eq!(run(&mut s,&mut w,Mode::Claim,100), Err(Failure::InvalidResponse));
    assert_eq!(w.posts(),0);
}
#[test]
fn already_claimed_shortcut_without_plan_keeps_pending_across_restart() {
    let mut s = Memory::default();
    let mut first = Wire::new(vec![Ok(balance(json!([]),100)), Ok(preview(&["event"])), Ok(json!({"code":"1003"}))]);
    assert_eq!(run(&mut s,&mut first,Mode::Claim,100).unwrap()["status"], "resultPending");
    let state: Value = serde_json::from_slice(s.bytes.as_ref().unwrap()).unwrap();
    assert!(state["confirmed"].as_array().unwrap().is_empty());
    let mut next = Wire::new(vec![Ok(balance(json!([]),101))]);
    assert_eq!(run(&mut s,&mut next,Mode::Claim,101).unwrap()["status"], "resultPending");
    assert_eq!(next.calls.len(),1); assert_eq!(next.posts(),0);
}

#[test]
fn omitted_preview_plans_remain_unknown_until_official_default_is_verified() {
    for body in [json!({"data":{}}), json!({"code":0,"data":{}})] {
        let mut s = Memory::default();
        let mut w = Wire::new(vec![Ok(balance(json!([]),100)), Ok(body)]);
        assert_eq!(run(&mut s,&mut w,Mode::Claim,100),Err(Failure::InvalidResponse));
        assert_eq!(w.posts(),0);
    }
}
#[test]
fn unverified_reply_does_not_import_foreign_grant_times() {
    for code in [1003,99999] {
        let mut s = Memory::default();
        let mut w = Wire::new(vec![Ok(balance(json!([]),100)),Ok(preview(&["event"])),
            Ok(json!({"code":code,"data":{"plan":{"plan_id":"foreign","starts_at":123,"ends_at":456}}}))]);
        let result=run(&mut s,&mut w,Mode::Claim,100).unwrap();
        assert_eq!(result["status"],"resultPending");
        assert!(result.get("startsAt").is_none_or(Value::is_null));
        assert!(result.get("endsAt").is_none_or(Value::is_null));
        let state:Value=serde_json::from_slice(s.bytes.as_ref().unwrap()).unwrap();
        assert!(state["confirmed"].as_array().unwrap().is_empty());
    }
}

#[test]
fn known_failure_never_attaches_unmatched_grant_times_to_selected_plan() {
    for plan in [json!({"plan_id":"foreign","starts_at":123,"ends_at":456}),
        json!({"plan_id":" event ","starts_at":123,"ends_at":456}),
        json!({"starts_at":123,"ends_at":456}),
        json!({"plan_id":"event","planId":"foreign","starts_at":123,"ends_at":456})] {
        let mut s=Memory::default();
        let mut w=Wire::new(vec![Ok(balance(json!([]),100)),Ok(preview(&["event"])),
            Ok(json!({"code":1005,"data":{"plan":plan}}))]);
        let result=run(&mut s,&mut w,Mode::Claim,100).unwrap();
        assert_eq!(result["status"],"noClaim");
        assert!(result.get("startsAt").is_none_or(Value::is_null));
        assert!(result.get("endsAt").is_none_or(Value::is_null));
    }
}

#[test]
fn recognized_failure_preserves_only_matching_expiry_not_grant_start() {
    let mut s=Memory::default();
    let mut w=Wire::new(vec![Ok(balance(json!([]),100)),Ok(preview(&["event"])),
        Ok(json!({"code":1005,"data":{"plan":{"plan_id":"event","starts_at":123,"ends_at":456}}}))]);
    let result=run(&mut s,&mut w,Mode::Claim,100).unwrap();
    assert_eq!(result["status"],"noClaim");
    assert!(result.get("startsAt").is_none_or(Value::is_null));
    assert_eq!(result["endsAt"],456);
}
