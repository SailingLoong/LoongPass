# Account quota and receipt projection

## Findings

The adopted native usage contract returns its overall balance as text. The
Flutter panel previously accepted only a numeric overall balance, and also
discarded display-only quota windows. Native usage error replies were treated as
successful reads: they replaced a good snapshot, advanced its timestamp and
cleared account attention. A failing model loader could prevent an independent
usage read. Generic reward journals store observation time, while the receipt
projection looked only for an official claim timestamp.

## Behavior

- Account owners retain the last successful usage snapshot within the running
  process when a usage request fails. Its original timestamp stays attached.
  Consumers receive a sanitized failure and the native sign-in state; private
  provider exception text is not projected or saved. A later successful read
  replaces the snapshot and clears the error. Failed RPCs export a neutral
  `kept` sign-in signal, preserving UI attention separately rather than replaying
  a historical `renewed` or `expired` event into Magpie's account routing.
- Model loading and usage reading have independent failure handling. Identity
  and registration are still verified around native calls; mismatched accounts
  cannot publish cached quantities or proceed to usage hooks.
- Lists accept native balance text and display-only windows. Details retain
  exact structured values and original units. Overlapping windows are not added,
  and no number is reconstructed from rounded display text.
- Usage failures are visible alongside reward state, including pending claims,
  and enter the shared attention filter. Current Start Plan observations remain
  independent of a failed native Coding Plan usage read.
- Reward observation time is labelled as verification time, never as official
  claim time. Historical receipts without amounts or timestamps stay unknown.
  Querying or opening details never resubmits a reward request.

The retained usage snapshot is an in-process cache, not a new durable source of
quota facts. This change does not claim offline quota restoration after restart.

## Live investigation and limits

Read-only inspection of the installed Beta 37 and its own private data confirmed
that account registrations, migration backups and reward journals were present.
TRAE, Qoder, MiniMax, Loomy and WorkBuddy returned quota data. Their expiry and
reset fields are distinct: missing credit-batch expiry is not replaced with a
plan renewal, a year-9999 sentinel or a window reset.

The inspected legacy ZCode grants contained a Start Plan JWT but no Coding Plan
key. Native usage reported no usable Start Plan; the application's separate
official activity observations contained no current plans or buckets. This does
not establish whether a user owns an unimported paid subscription. Existing
Coding Plan access must be recovered through the adopted official authorization
flow, not invented from a legacy JWT. Old confirmed claims do not prove current
remaining balance or supply an official amount or claim timestamp.

No reward POST, account replacement, client activation or credential import was
performed for this investigation. Real credentials, account identifiers and raw
responses remain outside Git. Synthetic regression tests cover failed replies,
transport failures, authorization expiry, loader independence, text balances,
display-only windows, independent activity quotas and receipt verification time.
Release build and installed-client acceptance are separate from these tests.

`python3 tool/check.py` passed locally on the pinned Flutter 3.50.0 / Dart
3.14.0 and Bun 1.4.4 toolchains: 305 native protocol tests, 268 Flutter tests,
Dart analysis and the repository's Python/Swift checks. New regression cases
were observed failing before the corresponding repairs. Native protocol source
pins, dependencies and update-signing configuration are unchanged.
