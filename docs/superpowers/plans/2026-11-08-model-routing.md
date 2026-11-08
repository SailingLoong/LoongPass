# Model routing implementation plan

> Execute inline with `superpowers:executing-plans`; use TDD and one whole-branch review.

**Goal:** Let Magpie select a model while LoongPass selects its saved platform/account, preserving session affinity.
**Architecture:** Existing account owners and provider catalogs feed one model router. A unified Messages ingress bridges native Chat where necessary; existing account-scoped endpoints retain their permissions.
**Tech stack:** Dart/Flutter, local HTTP/SSE, existing Magpie CLI and Claude Code acceptance tools.
**Spec:** `docs/superpowers/specs/2026-11-08-model-routing.md`.

## Global constraints

- No credentials or private account evidence in Git; no reward claims in inference acceptance.
- No model-version substitution, paid fallback, or automatic replay of an uncertain request.
- Reads consume snapshots; refresh belongs to lifecycle, owner events, or explicit actions.
- Reuse native build locks and caches; clean reproducible task artifacts before handoff.
- Merge through repository review requirements, verify remote main, then clean the task worktree and branches.

## Review focus

- Same-name platform routing aliases must not be mistaken for the same underlying model.
- Concurrent sessions, failed streams and account revocation must not leak or replay requests.
- Old account keys and restored legacy grants must retain their original scope.
- Chat tools, incremental UTF-8/SSE, reasoning and multimodal content must survive conversion or fail clearly.
- Session propagation must work through the installed Magpie, not only direct local HTTP.

### Task 1: Model identity and session routing

Files: new `lib/model_router.dart` and `test/model_router_checks.dart`.
Consumes: `ModelDefinition` and enabled account/catalog snapshots.
Produces: unified model groups, target selection and bounded session/failure state.

- [ ] Add behavior checks for exact identity, namespaced aliases, sticky sessions, new-session distribution, cooldown and revocation.
- [ ] Observe failure, implement the router, and run the checks to green.
- [ ] Commit the independently verified routing unit.

### Task 2: Unified local gateway and UI

Files: `lib/model_service.dart`, new `lib/model_messages.dart`, `lib/loomy_model_provider.dart`, `lib/workspace_tools.dart`, focused gateway/bridge/provider/page tests.
Consumes: Task 1 router and existing production providers.
Produces: separate pooled grant, unified Messages endpoint/import link, source counts and native protocol dispatch.

- [ ] Add failing HTTP/bridge checks for pooled catalogs, permissions, session routing, streaming and tool round trips.
- [ ] Implement persisted pooled authorization, Messages-to-Chat bridge, explicit session template and the unified UI connection.
- [ ] Filter non-chat output modalities using official capability facts; verify with a regression case.
- [ ] Run existing keyed endpoints and new checks; update only assertions for intentionally changed behavior; commit.

### Task 3: Real-model coverage and delivery

Files: existing `tool/model_pooling_*` acceptance tools, `docs/verification/2026-11-08-model-routing.md`, README and AGENTS model-service sections.
Consumes: Task 2 production gateway and saved-account owners.
Produces: model-by-model real-client evidence, exact remaining gaps and merged delivery.

- [ ] Extend acceptance to select explicit catalog models and test the unified source; do not select the first model as a proxy for model-family coverage.
- [ ] Run focused checks, installed Magpie/Claude Code acceptance and the repository check suite; preserve private evidence outside Git.
- [ ] Perform one independent whole-branch review and resolve material findings with regressions.
- [ ] Merge and verify remote main, advance workspace reference separately, and clean task worktrees, dependencies and intermediate builds.
