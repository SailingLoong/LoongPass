# Credit usage and expiry timeline

The two overview cards and the seven-day expiry calendar lead to the same local-time timeline. The upper track uses the existing Magpie request ledger, scoped to this machine and the LoongPass provider. A selected source can show its dated model debits where all registered identities have coverage. The independent lower track shows settled unused quantities, future balances at their last observation and deadlines with unknown quantities. Date-only records stay outside hourly bins. The ranking's denominator is the issued amount of those same settled batches. Without that denominator the rate is unavailable.

## Native evidence

Compared the pinned [Magpie host](https://github.com/yetone/magpie/tree/5fd855eb753543f3c2bfd690877ee2407b783195) and [native packages](https://github.com/magpie-community/plugins/tree/605789637ab26497f17e89d6a9ca34c0ac4307ce) with the current [host](https://github.com/yetone/magpie/tree/b9e408caee2bcacc46687a8c2afadb3eb60cbc48) and [package tree](https://github.com/magpie-community/plugins/tree/0df06dd02837f96eadc80420d0c53012214c47c1). The local patch preserves credit facts at the plugin/host boundary. The read-only Loomy all-records endpoint is also used by the [DSH provider](https://github.com/iJetLi/dsh-providers-hub/blob/fdb5c53b8e2e163712f12f412899ed18860a30c0/src/loomy-credits.ts).

| Source | Evidence used |
| --- | --- |
| MiniMax CN and global | Retain dated purchase/reward rows already read by the native plugin. An expired row must reconcile issued, consumed and remaining amounts before the remainder counts as unused. The routing window still requires the whole ledger. |
| Loomy | Reconcile complete, closed Beijing daily cycles from the all-records ledger, wallet snapshot, funding source and both sides of each movement. Separate permanent credits from the daily pool. Date model spending from model debit entries. Stop on coverage gaps, contradictory records or unknown funding movements. Reuse historical pages at a verified official transaction boundary. The auxiliary read is time- and page-bounded. |
| WorkBuddy | Use the same resource packages, end dates and pool inclusions as native billing. The daily slice is separate. A closed, explicitly used-up package can establish zero when the original amount and usage also agree. |
| Qoder | Use the original unit, remaining quantity and date precision of dedicated packages. Subscription reset dates do not provide package settlements. |
| TRAE CN | Use finite entitlement packs and observed usage for their remaining credit amounts. Enterprise seat currency remains distinct. |
| ZCode | Reuse the official expired entitlement reconciliation. Retain its issued quantity and server observation time. |

## Verification

Native tests cover fractional MiniMax balances, incomplete ledgers, confirmed zero, actual model debits, daily cycles with permanent spending, and discontinuities. Flutter tests cover historic snapshot migration, date-only deadlines, deduplication, source-rate denominators, per-account debit coverage, both overview entry points, drill-down and navigation. The release gate reverses every patch and verifies the pinned upstream bytes. Live checks used authenticated read-only billing responses, with account data kept outside the repository.
