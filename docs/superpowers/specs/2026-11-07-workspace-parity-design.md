# Workspace UI parity

Allen approved the sidebar correction and restoration of the model-services
entry, requested a detailed comparison with the original compact prototype,
and added vertical app drag ordering. The accepted four-column account table
remains account → balance → upcoming expiry → latest confirmed receipt.

## Approach

Use a small sidebar-layout button in the brand row. Collapse to a 64-point icon
rail, keeping app switching and tooltips available. Distinguish domestic and
international versions with region badges. Reuse Flutter's reorderable list;
persist stable app identifiers, not indexes. Keep selection and mounted pages
independent of presentation order. Provide keyboard movement too.

This follows desktop navigation conventions, requires no second navigation
level, and separates platform navigation from auxiliary workspaces. A floating
edge arrow was rejected because it resembles back navigation; completely hiding
the rail would add an extra step to the core app-switching workflow.

Restore the prototype's secondary workspaces: overview, accounts and credits,
model services, activity, settings. Cross-platform views consume a read-only
projection of the existing platform presentation snapshots. They never restore
credentials, refresh, schedule or claim on navigation. The projection is not
persisted or used as an authority for balances or client-current identity.
Existing platform owners remain the only business writers.

The model-services page must state that real serving/routing is not implemented.
It must not expose a fabricated Base URL, key, available model or success state.
Its Magpie information remains reachable even before real integration exists.
Activity shows confirmed receipt information actually available, without
inventing authorization timestamps or a complete audit history.

UI preferences use the Flutter-maintained shared_preferences async API, backed
by platform preferences. Only app order, collapsed state, favorites, table page
size, display density and appearance belong there; no credentials or balances.
Load once at composition startup, serialize writes, and surface save failures.

## Prototype comparison and scope

- Restore missing navigation sections and account count/region context.
- Align page title and primary/secondary actions, remove redundant explanatory
  blocks from the normal working area, retain them in help/details.
- Add filter counts, default favorite-first order, persistent favorites/page
  size, visible query-time context and a clear empty/search-reset state.
- Preserve 5/10/20 pagination, latest-success facts, expiry details, owner-backed
  operations, keyboard/focus switching, narrow-screen scrolling and dark mode.
- Avoid summing credits across platforms or incompatible scopes. No numeric
  balance sort where official units/scopes are not comparable.
- Never copy mock model calls, launch-at-login, unimplemented client identity
  verification or fabricated activity records from the design prototype.
- Settings expose only implemented UI preferences and accurate runtime/data
  explanations. Automatic-claim settings remain in account details.

## Verification

Exercise actual drag, keyboard movement, restored order, app selection and form
state after reorder; malformed/legacy preferences; region/identity separation;
global views updating with source snapshots; no new owner/network side effects;
favorites surviving reload; narrow/light/dark layouts and no mock model success.
Run standard repository checks and one independent review, then one locked
Universal beta28 build after the parallel beta27 build. Keep real-account GUI
ownership with the other chat. Save package/evidence before cleaning intermediates.
