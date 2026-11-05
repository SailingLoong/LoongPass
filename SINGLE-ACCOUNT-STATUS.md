# Single-account source preparation: final build still pending

Main chain only: existing Add -> official authorization/Profile -> save to own
Keychain service -> restore into existing roster/flow -> existing LoongPass claim
core and durable intent journal. Normal main and existing page only; no client
switching, refresh service, new account database or automatic feature. The
single-account page does not construct an automatic controller.

Implemented in this independent copy:
- existing pollAndSave is invoked by the normal page; restoreSingle discovers
  only own-service metadata and refuses ambiguous saved accounts;
- own service com.sailingloong.loongpass.workbuddy, Generic Password,
  non-synchronizing, default Keychain selected lazily only upon native vault call;
  the default resolver was never invoked in tests;
- existing lifetime owner flock/private-directory checks reused for cooperating
  app processes; synthetic physical-root binding preserved separately;
- saved SingleAccount refuses a second stored identity before saving; ordinary
  memory removal leaves saved grant/journal, which is disclosed in the dialog;
- fresh official reauthorization can CAS-replace only the same active identity;
  revoked/rotationPending entries are not revived, claim history is untouched;
- expired/failed authorization retires its slot, avoiding a permanently blocked Add;
- restore failure is explicit; claim has its own action confirmation dialog;
- existing journal/Core enforce prior intent/no repeat; no real claim attempted.

New verification only: 12 single-chain checks, 12 dedicated synthetic-Keychain
checks, final analyzer No issues found, final read-only review found no serious
new issues. Fake server and fake tokens only; fixture Keychains deleted. No
repetition of the old 331-check suite, Flutter/XCTest suites or real-account tests.

IMPORTANT BUILD LIMIT: the first release18 build and strict signature verification
succeeded, then code review fixes changed source. That binary is SUPERSEDED and
is not evidence that the final source has compiled. Latest instruction explicitly
said do not repeat builds; no final rebuild was performed. Do not distribute or
launch candidate/build/.../Release/LoongPass.app as the completed single-account
version. Existing release17 remains preserved separately as identity-only.

This is a capable but NOT LAUNCHED preparation: Dart broad/persistence flags,
native broad vault gate and native persistent capability are true, deliberately
compiled/prepared for a reviewed handoff. They are not evidence of real action-time
user consent. Actual default Keychain access, fresh token receipt/transmission,
persistent saving, restore Profile call and check-in must stay behind their
corresponding action-time confirmations. None occurred here. Final app sandbox,
signing identity/ACL behavior, real expiry/Profile payload and real credit balance
remain unaccepted. No promise of website grant revocation or forensic memory wipe.

Repository read-only check: SailingLoong/LoongPass is private; connected user
SailingLoong has admin/push metadata permission. main remains fcdb1a98a29337ca3a85c02a50571b34046838ac,
pubspec 1.0.0-beta.1+1. Releases [] and git matching refs/tags [] as observed.
Local newer sources are not on main; no push, tag, Release or attachment upload
was performed. Active account permission is not a mutation-test of the connector's
Release asset-upload capability. Current tool list has no Release-write tool.

Remaining shortest steps: one necessary final-source build/signature check,
then per-action confirmed ONE account authorization and persistence, quit/restart
restore verification, separately confirmed existing LoongPass check-in and receipt
corroboration. Only after that publish the reviewed exact source/artifact and
matching version/tag; preserve private visibility unless user explicitly changes it.
