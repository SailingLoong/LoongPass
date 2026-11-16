# Model selection and aggregation

## Behavior

The expanded sidebar and compact model popover have a fixed search field.
Search includes canonical names, native aliases, providers and account labels.
The model page initially shows enabled models. “显示全部模型” exposes the full
catalog for changing participation. “仅保留筛选结果” persists the displayed
selection, hides other sidebar entries and removes their native routes. Newly
discovered models remain disabled after this action until explicitly enabled.

Regional provider IDs now use the same official alias resolver as their base
provider. Complete supplier names aggregate across accounts when the underlying
official API identity remains unknown. MiniMax Image therefore has one row with
both regional account pools and retains its unverified-name indicator. The
pinned MiniMax plugin describes this entry as a Matrix image tool without an
underlying model ID.

Versioned routing preferences preserve old per-alias and per-account choices,
including temporarily missing catalogs. Model toggles and bulk retention govern
the group. Previously disabled sources can be restored through account
participation switches. Concurrent writes are serialized and failed writes
preserve the last persisted selection.

## Native routing

LoongPass provides model-applicable remaining-credit snapshots. Native groups
prefer the eligible account with the earliest known expiry. Existing native
session affinity remains active for subsequent calls in the same model group.

Image APIs use a native group ID shown in the model details. Internal image
members are account-scoped. Native account-model allowlists keep image failover
inside the group's account order. Group member listing stays disabled so clients
see the aggregate image group. Vendor API IDs and request bodies retain their
native protocol identity.

Exported usage is projected by the existing Dart quota matcher before account
namespaces are added. This preserves case-insensitive allowlists, context-sized
IDs, exclusion lists and windows that match none of the selected models.

## Acceptance

- The repository verification command passed Dart analysis, 366 Flutter tests,
  311 native plugin tests, source provenance and macOS native checks.
- Actual Flutter application composition was rendered with synthetic owners at
  1024×768, 1024×480, 800×628 and 480×800, in both themes, including 200% text.
  Sidebar filtering, compact navigation, retention and recovery of hidden models
  were exercised through their normal widgets using Forui and the existing fonts.
- Installed Magpie 0.1.3346 passed isolated synthetic text requests covering
  aggregation, exact expiry order, session reuse, manual order, streaming, tools,
  account failover and native group lifecycle.
- Official Magpie CLI 0.1.4277 passed isolated image generation with regional
  accounts and three same-provider accounts. The requests verified expiry
  changes, 401 failover order, exhausted credits and disabled participation.
  Its executable matched the release digest and SHA256SUMS.
- The numeric fixture asserts 278.68 credits expiring on November 17 and 393.36
  credits expiring on December 6. November 17 is 19 days earlier and wins the
  initial account selection. Amounts retain their original credits unit.

Magpie 0.1.3346 lacks the image metadata behavior needed by this image path.
Image integration requires an updated Magpie and was verified with 0.1.4277.
These checks use synthetic accounts and loopback services. Vendor credit
consumption, new account authorization, Windows/Intel hardware operation and a
new desktop release remain outside this verification.
