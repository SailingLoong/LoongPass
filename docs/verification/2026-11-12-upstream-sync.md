# 2026-11-12 native upstream sync

## Reviewed scope and ownership

The cohort is frozen in `runtime/upstream.lock.json`: Magpie host 873b4987e97328071d4aeabd21996a3a8fcfab24 and community plugins bb3f68a47a06174aecc5b8179bf2edef06e8415f. Six complete packages are imported: WorkBuddy 0.2.31, Qoder 0.2.67, MiniMax 0.2.9, Loomy 0.1.5, TRAE 0.2.34 and ZCode 0.1.61. MiniMax native.mjs is included in the 45-file source closure. Every declared package file must have a verified source hash; patch reversal recovers exact original bytes.

Native host adoption brings renewal and refused-model-list backoff, provider configuration isolation, access-only OAuth persistence, explicit API metadata handling, localized auth words, shared-window metadata and effort-header isolation. Native packages retain their own new catalog, tool-index, credential-rotation, quota and recovery changes. LoongPass does not acquire another supplier translator or client prompt layer.

Native Magpie video polling currently omits the selected model/SDK context. The model-grant service therefore excludes video-output models from discovery and admission, including for existing bridge installations; it cannot start a paid job whose polling is unsupported. Images/chat and the native POST transport retain their normal model/SDK/URL admission. Complete media package sources remain imported. A native producer contract must be established before video models are exposed.

## Patch review and root fixes

All ten existing patches were reviewed by hunk against the fixed cohort. Identity/device binding, read-only auth snapshots, quarantined-account admission, scoped API identities, precise structured balances and durable reward receipts still have no equivalent native public interface. They remain at their native owners.

Loomy's spent/percentage calculation is now upstream: the local duplicate was removed, including its old zero-limit policy. Only explicit balance/unit and remaining-only extensions remain. No independent Dart arithmetic was added.

The audit found and reproduced these current native gaps before fixing them:

| Trigger | Corrected native behavior | Regression |
| --- | --- | --- |
| ZCode gift/freeFirst JSON plus ToolSearch | Await model-name transformation before tool-name restoration; JSON and SSE both preserve the two names | native_zcode_response.test.mjs |
| Equal ZCode UID strings across regions | Separate regional concurrency gates; share one regional UID across personal/team profiles and devices | native_zcode_response.test.mjs |
| WorkBuddy routed 429 with case-varied account spelling | Normalize admitted refusal rows to the requested account identity before window accounting | native_workbuddy_usage.test.mjs |
| TRAE enterprise fractional spend/limit | Preserve 0.0002 CNY or USD, exact limits and separate credits; formatting does not replace facts | native_usage.test.mjs |
| Anonymous TRAE multi-seat usage | Return unknown instead of assigning a tenant sum to one account; known empty and zero stay distinct | native_usage.test.mjs |
| Qoder unavailable/partial sequential pools | Exclude unavailable pools; known children remain aside under an unknown aggregate when an admitted pool is incomplete | native_qoder_quota.test.mjs |
| Loomy live model shape and reasoning metadata | Return complete native API/capability/limit/options/variants; advertise declared tiers only and preserve requested levels | native_loomy_models.test.mjs |
| Declared package module missing from hash lock | Fail source verification before packaging | plugin_sources_test.py |

The two response/usage fixes and Loomy metadata live in small removable native source patches. Their removal criteria are in runtime/README.md. Existing precision/identity patches were updated at their owners. No new client-specific fallback was introduced.

## Ecosystem and other dependencies

The whole community registry was assessed: 97 to 119 entries, 22 additions, 61 changed local packages, and 19 external packages inspected at exact npm versions with verified SRI. The workspace's 2026-11-12 alignment record contains the full disposition. New provider candidates are evaluated separately from enabled account channels; LobsterAI stays stopped. Agent wiring, middleware, memory, pages, tools, billing import and routing remain external Magpie responsibilities. No recurring workflow or optional observation plugin was enabled.

Lamp 3eeaf716 changes README/assets only. dsh 5581d408 adds native-protocol evidence for Loomy reasoning and Qoder shared-pool handling, which informed the owning fixes above; its forced default-high policy and account selection orchestration were not copied.

Bun is pinned to official stable 1.4.4 for all four supported archives with published SHA-256 digests. Forui 0.27.7 remains current; material_ui is updated to 1.11.0. Release builds use the pubspec-pinned Flutter/Dart stable toolchain.

Sparkle 2.10.1, WinSparkle 0.9.4, nlohmann/json 3.12.0 and WebView2 1.0.4314.35 remain current stable releases. Unreleased updater branch changes do not provide an equivalent of the WinSparkle automatic-install/skip policy extension, so that extension stays. Source signing and published package verification remain independent acceptance steps.

LoongPort main 1595af2552b4d7c9a01bc78cd6da5eacdccf0eed has byte-identical ZCode core/native/desktop-text/claim-queue lineage compared with the recorded base. Its Windows stale-lock probing and marketing-plan parser additions do not own the enabled LoongPass runtime path: Windows does not link the dormant Rust switch worker, and active ZCode rewards use the native plugin plus LoongPass journal. They are not copied into an inactive path. pjpv/zcode-switch remains at the existing source commit.

## Official ZCode 3.18 boundary

Official source c5904686ea8341826b3affe5d993d06a134fa779 was inspected. Its enc:v2 system/managed-secret storage and new OAuth session-revision/linked-account/recovery-generation contracts cannot be supported by raising the old version gate. The installed client metadata is 3.18.0; source inspection of 3.18.1 is not installed-client acceptance.

The enabled desktop-import method detects enc:v2 and gives browser-login guidance. It never reads an OS key store or migrates the official client's files. Previously saved usable grants are retained, but cannot follow unsupported desktop rotations. BigModel/Z.ai browser OAuth and saved-grant reward contexts remain separate native paths; their public wire shape was checked. Synthetic import, preserved-grant, official identity, device and unknown-claim checks exercise these boundaries.

The Rust/native switch facts remain productionDisabled with the existing reviewed 3.17.2 gate. Official internal Services/RPC and CLI credential loading can mutate/migrate storage and are not a supported external read-only credential export. This Beta does not claim native 3.18 desktop switching/import support.

## Verification and acceptance

- Source closure: 45 upstream files, six complete packages, exact effective hashes and reverse-patch provenance verified.
- Native regression suite on pinned Bun 1.4.4: 305 passed, 1773 assertions across 16 files.
- Final full tool/check.py passed on Flutter 3.50.0 / Dart 3.14.0 / Bun 1.4.4 after the review corrections and final cohort: 252 Flutter tests, Dart analysis, Python source/release checks and Swift/native bridge checks. Independent review rechecked all three findings without remaining important/critical issues.
- Release acceptance uses the immutable tag pipeline and independent package/source/signature/CDN readback. Published SOURCE_COMMIT and signed feeds identify the actual release; a local suite is not publication evidence.
- No real vendor authorization, reward mutation, paid inference, current desktop switch or new media/client combination was exercised in this sync. Existing real-account baselines remain in VALIDATION.md. Platform build coverage is separate from Intel/Windows real-device coverage.

The first tag candidate, beta.35, was not published: its macOS test run exposed a timing assumption in the bounded-shutdown test. A fixture renewal lasted 80 ms, so a slower second process could legitimately acquire the lease after renewal had already finished. Delaying the second startup reproduced the same failure locally. The test now holds a real loopback vendor response until after the second-host lease check, releases it explicitly, and verifies that both rotated credentials were saved. No production lease or host behavior changed. Beta.36 is the replacement release candidate; the failed tag remains immutable.

## Final reviewed cutoff

At 2026-11-12 13:56 UTC, the final ref check found seven further Magpie commits (host bytes unchanged) and three community commits. WorkBuddy 0.2.31's native AI chat growth-event behavior remains confined to that upstream AI provider, which LoongPass does not enable. ZCode 0.1.61's expired-reset-card exclusion was adopted directly; agy-cli 0.1.26 remains external Magpie. The final source pins above include this delta. Later moving-head changes require the next reviewed sync, never an unreviewed startup update.
