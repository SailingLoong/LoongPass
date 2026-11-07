# 2026-11-07 Credit reads and expiry interpretation

## Behavior repaired

Credit queries belong to account owners. Restoring saved accounts starts a
credit-only refresh; periodic reads continue when automatic rewards are off.
MiniMax, Qoder and TRAE still query credits when a reward check fails or returns
without granting anything. Existing credential leases, regional boundaries and
durable claim journals retain ownership of authorization and reward dispatch.

WorkBuddy queries credits after a saved authorization becomes ready. Its existing
in-process scheduler sequences roster credit reads and enabled reward checks in
one cadence. This prevents competing periodic tasks from repeatedly skipping a
busy account. Identity-only owners retain their restricted scope and do not
register automatic tasks. UI reads, searches and detail views do not start refresh.

Qoder accepts explicit remaining quotas, supported ISO package dates and
packages without an availability flag. Year-9999 sentinels retain unknown expiry.
Dedicated packages remain separate from plan/add-on aggregates to avoid double
counting. MiniMax handles a verified successful empty ledger and formatted decimal
amounts, with one page parser shared by pagination and normalization. Embedded
business errors remain failures. Pagination still requires complete stable counts.

Loomy uses the live-verified v2 records endpoint, including its nested data and
daily-remaining variants. A daily-only response does not establish a complete
wallet total. The first-login reward endpoint and its uncertain-outcome rules
remain under the existing reward adapter. Credit formatting removes binary
floating-point display noise while retaining the provider's fractional precision.

## Verification

- Based on the current main including `0fc3acd`, which retires LobsterAI. That
  product decision and the dormant local records are preserved.
- Regression checks failed before the owner and parser repairs, including disabled
  reward policies, failed reward status, successful empty ledgers, ISO expiry and
  floating-point display noise. A fake-clock test reproduced the competing-timer
  starvation with a delayed balance response before the single-cadence repair.
- Repository validation uses `python3 tool/check.py`: Dart analysis, 267
  Flutter tests, standalone Dart/Python checks, and the macOS native checks; all passed.
- Read-only production-transport queries covered saved accounts for WorkBuddy,
  Qoder CN/global, MiniMax CN/global, TRAE CN, ZCode and Loomy. The probes did not
  invoke reward claims, credential renewal, account activation or inference.
  Actual account identifiers, balances, tokens and raw responses stay out of Git.
  Loomy returned business code 900000 once during the window; both v1 and v2
  read-only retests succeeded. This transient is not treated as invalid credentials.
- Initial investigation also observed LobsterAI before its concurrent retirement.
  After incorporating the new product policy, it was excluded from queries and
  the speculative expiry-display work for that retired provider was discarded.

The live queries establish credit-read compatibility for those saved
authorizations. They do not constitute new-login, reward-receipt or Windows
real-account acceptance. The installed application is a separate artifact from
this source verification.

## Remaining data boundaries

Qoder's observed aggregate response supplies no per-batch add-on expiry. A renewal
sentinel or historical issuance is not a substitute; those dates remain unknown.
The official [Credits documentation](https://docs.qoder.com/Credits) distinguishes
current usage from historical acquisition records. A ZCode account without an
active entitlement has no applicable reward expiry; different entitlement units
are not added together as points.

## Protocol evidence

- [Magpie community plugins](https://github.com/magpie-community/plugins/tree/44df5f0505fd2a7c340a58a2c53aa54ec8242784),
  including Qoder, MiniMax, Loomy, TRAE and ZCode provider contracts.
- [dsh-providers-hub](https://github.com/iJetLi/dsh-providers-hub/tree/a5b3cd10dd49c27064c1270da205ca19a5e77d0a)
  credit adapters and regression fixtures.
- Focused REA static inspection of the installed WorkBuddy 5.9.3 package's
  `main/account.js` and `renderer/assets/common-Cklb-JUT.js`, corroborated by the
  read-only resource responses. Static inspection covered selected sources only;
  integrity contradictions and bounded semantic expansion were retained as
  limitations, not treated as runtime or package-authenticity proof.
