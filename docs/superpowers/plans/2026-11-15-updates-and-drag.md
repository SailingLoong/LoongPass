# Update visibility and application dragging

> Execute inline with regression tests and a final independent code review.

**Goal:** Check updates hourly, show useful download telemetry, and make platform-order settings immediately draggable without navigation.

**Architecture:** Native Sparkle / WinSparkle remain the update and scheduling owners. Their byte counters and actual schedule feed the existing passive Flutter owner. Use Flutter's standard reorder listeners over entire items instead of separate hit areas.

**Tech stack:** Existing Flutter / Forui, Swift / Sparkle 2.10.1 and C++ / pinned WinSparkle integration.

**Requirements:** Allen approved hourly checks and visible last / next checks. Downloads show percentage and live speed. Platform-order settings reorder immediately from the whole row and do not navigate on click. Preserve account data, update verification, opt-outs and keyboard ordering. Allen assigned navigation click / long-press behavior to other agents; this task leaves that component untouched.

## Review focus

- Unknown download totals, idle transfers and replacement downloads must not show false percentages or stale speeds.
- Late native replies must not overwrite newer update state.
- Platform ordering starts from the row body, with keyboard and accessibility ordering still available.
- Platform-order clicks do not open applications, and stored ordering survives restart.
- Narrow windows and enlarged text must keep telemetry readable.

## Tasks

- [x] Add failing regression cases for sorting without navigation and changing download telemetry.
- [x] Use a focused drag-only platform-order item and standard whole-item listeners; preserve keyboard actions.
- [ ] Extend the shared update contract with native bytes and actual check times. Set the native schedule to one hour, derive live transfer speed in the data owner, and render telemetry beside download status.
- [ ] Run targeted tests, native adapter checks, static analysis and the repository check entry point; inspect rendered UI and a running isolated client.
- [ ] Independently review, address defects, merge through repository checks, verify remote main and clean task-owned intermediates / worktree.
