# Explicit model publication

## Behavior and ownership

Concrete models start unpublished, including upgraded configurations and newly
discovered models. `routing.published` records explicit publication separately
from the existing Auto candidate choices in `routing.models`.

Magpie public discovery contains one native Auto group and the individual groups
explicitly selected by the user. Its unlisted provider retains account-scoped
native model metadata for protocol conversion and account allowlists. LoongPass
projects model priority and exact account-credit expiry into ordered native group
members; Magpie owns session affinity, recovery and failover. Both chat and image
models use the same publication boundary. Existing `loongpass/auto` requests are
rewritten to the native Auto group; new discovery offers `group/loongpass-auto`.

The data owner supplies the next quota expiry/reset boundary. The connection
owner schedules it and includes derived group order in its sync fingerprint, so
partial expiry changes order even when the upstream usage response is identical.
Views and inference reads trigger no upstream refresh.

The sidebar contains Auto and published models. Search and show-all expose opt-in
switches; model details separately control participation in Auto. Unpublishing a
model leaves its Auto candidacy intact.

## Automated and synthetic integration verification

`tool/check.py` passed: 309 Bun tests, 382 Flutter tests, clean analysis, and the
repository Dart/Python/Swift checks. Independent review found no remaining
actionable issues after the expiry-boundary correction.

- Regression tests cover default-off publication, persistence, failed atomic
  writes, discovery, independent Auto participation, native account-scoped
  admission, image groups, obsolete group cleanup, sidebar and search controls.
- Responsive widget checks cover narrow windows and 200% text scale.
- Independent review identified a stale ordering case at partial expiry. A new
  owner-level test failed before the boundary timer/fingerprint correction and
  passed afterward without any new account snapshot or view interaction.
- An isolated profile of installed Magpie 0.1.3346 used synthetic loopback grants
  and the actual bridge/native commands. Its HTTP model list contained only
  `group/loongpass-auto` by default, added exactly one selected group, and returned
  to Auto after unpublication.
- The same isolated gateway passed the legacy Auto request alias, Anthropic
  conversion, Chat SSE, a separately published model excluded from Auto, account
  failover, and advancement to the next model after failures. Native resting may
  skip a recently refused account on the next model, as intended.

## Installed macOS and real accounts

The final production-code commit `ffc4eb8` was built as a universal arm64/x86_64
macOS app and installed locally. Strict deep signature verification and the
installed App.framework SHA-256 matched the packaged build. The installed app
reported version 1.0.2, build 51; the bridge reports 0.2.3.

The actual profile changed from 72 managed groups to one Auto group. Enabling
MiniMax-M3.1-Flash added exactly one public group and sidebar row; its selection
survived app replacement/restart. Unpublishing it restored one Auto group. The
complete previous Auto choices remained unchanged under the existing routing
schema migration. Actual search and the default/selected UI states were checked.

Real-account calls through the installed app returned HTTP 200 for a text request
using the legacy Auto alias and for a synthetic echo tool round trip using the
native Auto group. Both final replies matched their exact acceptance markers.
Local profile snapshots and client transcripts remain private, outside this repo.

On November 18, 2026, an existing WorkBuddy 5.11.3 conversation still held
`custom-local:loongpass/auto` and failed in the client before a gateway call was
recorded. After Magpie synchronized its model entries, restarting WorkBuddy
loaded the new catalog. Selecting `group/loongpass-auto` in the same conversation
returned the exact test reply in six seconds. Magpie recorded HTTP 200 from
MiniMax-M3.1-Flash. The LoongPass portion of the live catalog still contained only
the Auto group.

This acceptance covers Apple Silicon real-account execution. Intel real-account
execution and Windows real-client inference were not exercised locally. This
source change does not publish an npm package, release, or updater feed by itself.
