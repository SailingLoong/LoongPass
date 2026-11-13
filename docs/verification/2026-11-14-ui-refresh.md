# Desktop UI refresh verification

## Scope and retained capabilities

The refresh changes Flutter presentation and website visuals. It keeps the pinned Magpie host, complete community plugin sources, provider membership, model service, account/reward owners, storage and native update contracts unchanged.

| Capability | Current entry and preservation |
| --- | --- |
| All nine platform/region entries | Account workspace platform selector; settings retains drag and keyboard order and reset |
| Official authorization methods | Add account keeps every native method and input; optional invitation registration remains separate |
| Exact quota and expiry facts | Account rows retain units, query times and unknown values; expiry dialog lists available batches/windows |
| Recovery and account maintenance | Primary action follows the existing state; More retains reauthorization, device rebinding and removal |
| Reward confirmation and automation | Pending claims query the existing owner; switches and most recent confirmed receipts remain accessible |
| Client switching | Visible account action and detail action call existing owners and preserve confirmation/result semantics |
| Magpie and community models | Model connection retains local service, account grants, full catalog, native groups, routing and recovery |
| ZCode entitlement boundary | Trial remains gift-only; ordinary models retain gift-first/existing-plan wording |
| Invitations and app updates | Grouped settings retain scoped invitation drafts, saving, update channels and native updater controls |
| Search, favorites, paging and navigation | Existing preferences and mounted platform pages remain; single-page paging controls are omitted |

## Stack and design conformity

Flutter 3.50.0 and locked Forui 0.27.7 are unchanged. The application uses the official neutral desktop theme, typography and controls, with the existing Inter and Source Han Sans SC fonts. Presentation state such as accordion expansion stays in the UI; refresh, authentication, claims and model connection remain explicit commands or data-owner responsibilities.

Visual checks use actual Flutter widgets and real bundled fonts with synthetic accounts. Four widths (1280, 1024, 800, 480) cover both light and dark themes. The 480×800 case also runs at 200% text scale. The full model catalog is separately rendered at 1024 pixels and at 480 pixels/200% text in both themes. Long identity, exact `3899.96 credits`, activation and detail access are checked together at 480×800/200%.

## Checks

- `flutter test --no-pub --reporter expanded`: 276 passing tests after the final accessibility case.
- `dart analyze lib test tool/render_compact_accounts_test.dart tool/render_model_page_test.dart`: clean.
- `python3 tool/check.py`: passed on the production-source commit, including 305 native plugin tests, Flutter tests, Dart/Python behavior checks and macOS native storage, migration, update and client-switch checks. Subsequent changes only add verification code and this document.
- `python3 tool/build_macos_release.py`: passed; universal arm64/x86_64 application and bundled frameworks, strict code signature and release entitlements verified. This is a local UI candidate, not a new published release.
- `tool/render_compact_accounts_test.dart`: 10 visual cases passed. `tool/render_model_page_test.dart`: 4 visual cases passed, with no model connection mutation.
- Synthetic amount cross-check: the first preview account has 120 + 200 + 300 known-expiry credits and 320 unknown-expiry credits, totaling the displayed 940. The narrow-layout decimal remains exactly 3899.96; no currency conversion or billing arithmetic is added.
- Fresh independent review found no deterministic code defects requiring repair; its narrow-window/large-text verification gap was covered before delivery.

## Coverage boundaries

These checks exercise real Flutter rendering and synthetic native protocols. The macOS desktop automation was blocked by the locked Mac, so installed-app mouse/keyboard interaction and native font rendering were not certified in this run. Windows and Intel hardware, new official authorization, real claims, real client switching, model consumption, updater installation and public release delivery are not inferred from these UI checks. Existing coverage records continue to own those claims.

The website uses synthetic Flutter screenshots and self-hosted licensed font subsets. Release version selection, download proxy and signed feed forwarding remain unchanged; website distribution tests and browser layout checks are recorded in its delivery evidence.
