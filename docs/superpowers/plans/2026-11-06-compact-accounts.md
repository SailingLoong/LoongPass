# Compact account workspace

Goal: implement Allen's approved compact multi-account workspace. Columns are
账号 → 余额 → 即将到期 → 最近领取. A supported client-switch action appears beside
the account on hover or keyboard focus. Pagination defaults to 10 (5/10/20).

Architecture: one shared Flutter table owns presentation, search, ordering and
pagination. Platform panels supply immutable display snapshots and existing
explicit actions. Account owners remain authoritative for credentials, claims,
balances and scheduling. Details open on demand without expanding table rows.

Tech: existing Flutter Material components; no new packages or native protocols.
Spec: user-approved compact preview and final column/hover correction in this chat.

Global constraints: keep every regional entry and ZCode campaign semantics; no
model proxy, fabricated amounts/dates or view-triggered network/check-in work.
Never call selection a successful client switch. Tests use synthetic identities.

## Task 1: Shared compact table
- Add display-only rows, four columns, fixed-height desktop rows, horizontal
  scrolling on narrow windows, search/filter/sort before pagination, focus/hover
  switching, an account detail dialog and an expiry detail dialog.
- Verify pagination/search across 20 rows, hover/focus behavior, absolute credit
  values/unknown dates, small window overflow and light/dark rendering.
- Expected: targeted widget tests pass; navigation never calls account actions.

## Task 2: Platform presentation and claim facts
- Integrate the shared table in WorkBuddy, MiniMax, Qoder, TRAE and ZCode panels;
  move existing explicit controls into details; compact header/sidebar/theme.
- Project successful receipts from the owning data modules. Preserve the last
  confirmed success when a later attempt is unresolved; old missing timestamps
  remain unknown. Keep credit units and Qoder balance scopes separate.
- Expected: platform tests and receipt-history tests pass with synthetic stores.

## Task 3: Verification and delivery
- Run repository analyze/tests and relevant native checks via tool/check.py.
- Render actual Flutter widgets with synthetic 20-account data at desktop and
  narrow widths. Review the branch once; correct material findings.
- Record evidence and commit the implementation. Reclaim task build/test caches;
  retain source worktree until integrated. No release/real-account claim implied.

## Review Focus
Check old persisted records, unresolved claims after a success, mixed units,
partial/expired balance snapshots, keyboard-only access, filtering off-page
accounts, regional state retention, and detail controls updating while open.
