# Account table and exact remaining balances

Beta 39 changes the shared account list to five fields: account, next expiring
quantity, expiry time, latest claim time, and balance. Dates and times occupy
separate lines. At a 560 logical-pixel content width all five columns fit without
horizontal scrolling. Narrow windows and enlarged text use labelled fields
under each account. Search, favourites, paging, details and activation remain
available. The sidebar grip uses Flutter's grab/grabbing cursors; accessible
move actions and keyboard reordering remain available without a floating hint.

The account data owner now projects structured remaining quantities. The UI
does not extract numbers from native display strings or treat usage percentages
as spent quantities. A numeric balance requires its unit; otherwise a complete
limit/amount pair supplies remaining credits. Unknown values stay unknown.
This supersedes Beta 38's use of full native summaries in the balance column;
those summaries remain visible in account details.

The contract comes from the sources fixed in `runtime/upstream.lock.json`:
WorkBuddy 0.2.31 and Qoder 0.2.67 publish a primary aggregate and mark overlapping
components as `aside`. An unknown aggregate never falls back to a partial known
component. MiniMax 0.2.9 and TRAE 0.2.34 expose structured credit quantities.
Loomy 0.1.5 exposes distinct daily and permanent wallets; only a complete pair
in the same unit is additive. Multiple independent model entitlements have no
invented account total. No upstream code, dependencies or credentials changed.

Expiry uses future `runsOutAt` and the associated remaining quantity, or the
separate official activity buckets. It never substitutes a plan renewal or a
window reset. Where independent quantities share an expiry, the date can be
known while the comparable total remains unknown; details retain each quantity.
Only `confirmedAt` or the journal's date-only `day` can populate latest claim
time. `observedAt` remains labelled as verification time in details.

Synthetic checks include an independent hand calculation: 500 base credits plus
3400 extra credits, less 0.04 spent, leaves **3899.96 credits**. The total window
is used once. Other exact expectations include 3050, 2487, 5499.7456, 4393.36,
12224 and zero credits; Loomy's two 5000-credit wallets yield 10000 credits.
Unknown/missing fields, non-finite values, percentages, overlapping windows,
mixed units and ambiguous expiry totals are covered separately.

Local validation passed on Flutter 3.50.0 / Dart 3.14.0 with the pinned Bun 1.4.4:
Dart analysis, all 279 Flutter tests (two workers), update-contract consistency
and native source provenance checks. The initial four UI regression assertions
failed against Beta 38. Review also added explicit Qoder `aside` package expiry
coverage in both credits and tokens, and a real row-height assertion for the
compact/comfortable preference. Release package verification and installed-client
visual acceptance are recorded separately. No account identifier, credential or
raw official response is included here.
