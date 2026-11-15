# Model routing and workspace verification

## Delivered behavior

The model workspace groups native supplier aliases by verified official API ID. Each binding carries its native model ID, capability metadata, protocol adapter and ZCode gift-only/freeFirst entitlement. Unverified model identities retain their supplier-qualified identity.

Magpie receives `loongpass/auto` and `loongpass/<canonical ID>`. Auto uses the persisted model order. Each canonical group orders eligible accounts by the expiry of remaining model-applicable quota, with unknown expiry last. Native session affinity retains a successful eligible account for subsequent requests in the same model group. LoongPass publishes quota snapshots and rejects unavailable bindings at native-fetch admission.

The sidebar has independently scrolling account and model lists. Model selection opens the related-account table. The account link resolves provider membership and the exact stored account key, clears obstructing search/filter state, selects the target page and scrolls to its highlighted row. These actions consume existing account-owner snapshots.

## Verification

- `python3 tool/check.py` passed on the integrated feature, including 310 native plugin tests, 339 Flutter tests, static analysis and the repository's Dart, Python and Swift checks.
- Normal application composition verifies model order updates, selection, regional account identity and cross-page deep links. A 100-model sidebar case verifies that scrolling leaves primary navigation accessible.
- `tool/render_model_page_test.dart` passed six real Flutter rendering cases with bundled Inter and Source Han Sans fonts. Widths 1024, 800 and 480 cover light/dark themes, with 200% text at 480. The captures include auto, model accounts and the target account after navigation. Long model/account names also pass the 604-pixel/200% regression.
- The model account fixture asserts exact remaining values of 60 and 48 credits, with an independent 32.5-credit expiring batch. The Loomy regression verifies the disjoint wallet sum of 37.59375 + 10.0625 = 47.65625 credits. Model-window allow/deny lists, exhausted/expired windows and confirmed authorization failure have dedicated checks.
- Installed Magpie 0.1.3346, the actual bridge package and the actual Dart `MagpieConnection.syncRouting` were exercised against an isolated synthetic LoongPass HTTP service. Thirteen synthetic requests verified canonical/auto visibility, earliest-expiry selection, repeated synchronization, same-session reuse, model isolation, manual priority changes, streaming, Chat-to-Anthropic tool round trips and 401 account failover.
- Native synchronization verified first creation, updating existing groups, removal of auto before referenced child groups, and retry after groups were already removed. XDG, DSH and client configuration directories were isolated, and native subprocesses were restricted from reading real account data or modifying the home directory.
- `python3 tool/build_macos_release.py` passed. The local candidate contains arm64 and x86_64 application/framework binaries and passed strict code-signature and release-entitlement verification.

## Independent review

One fresh-context read-only review identified a reset-boundary bug. An exhausted renewable window now becomes unknown at its reset time so native recovery can proceed. Expired credit batches retain their unavailable state. Regression tests demonstrated failure before the fix and passing unit/HTTP admission after it.

The same review found differences in context-size matching and allowlist precedence. The projection now follows the pinned native contract, distinguishes explicit context sizes, and gives `models` precedence over `notModels`. ZCode freeFirst resolves each discovered model into one explicit allowance list and drops empty windows. The regression covers a paid allowlist alongside a live gift allowance.

## Stack and acceptance scope

The implementation uses Flutter 3.50.0 and the locked Forui desktop design system. Model order and participation belong to the model service, while selected rows and disclosure state belong to the UI. Native Magpie owns protocol conversion, capability matching, cooldown and session affinity.

The UI evidence uses real Flutter widgets with synthetic owners. Native integration uses the installed gateway with synthetic accounts. This run covers local compilation and routing behavior. Real supplier consumption, installed-client upgrades and Windows/Intel hardware acceptance retain their separate existing verification records.
