# Build 15: existing main.dart identity-only handoff

No new login protocol or extra feature. Existing main.dart -> AccountToolApp ->
_AccountPage -> AppWorkspace -> existing WorkBuddyAccountsPanel, with identity
mode fixed on for this candidate. Initial page WorkBuddy; other navigation items
are visible but disabled, and their account panels are replaced by empty widgets.
The shared constructors keep the original normal-mode defaults for reuse.
All identity action-time, WorkBuddy production and persistent-access gates remain
false. No real authorization, token receipt, saved credential or check-in occurred.

Actual build results with the existing SDK/Xcode:
- normal main release reproduces _window_macos.dart _Rect illegal cid, exit -6;
- command-level --extra-front-end-options=--no-tfa attempt also fails identically;
- no further optimization experiments or SDK modifications/installs;
- normal main DEBUG 1.0.0 (15), arm64, builds and strict deep signature verifies;
- source analysis and all 14 direct Dart suites (331 checks) pass;
- copied artifact signature verifies before and after actual execution.
Release remains blocked. This is an ad-hoc local development preview, not a
notarized/Developer-ID signed release beta. No profile build was added.

Artifact, relative to task root:
artifacts/LoongPass-Normal-WorkBuddy-Debug.app
Bundle ID: com.sailingloong.loongpass.workbuddy.identityrelease
(The suffix names this task namespace, not the actual build mode, which is debug.)
The existing project-copy startup code disables VM service and publication via
process-local engine switches before creating Flutter. No shell or OS settings
are modified. Targeted lsof on the exact matching artifact PID found no TCP
LISTEN sockets. No other process enumeration or account client operation.

Actual page: normal LoongPass sidebar, WorkBuddy selected, other three items grey;
WorkBuddy memory identity text and grey disabled Authorize WorkBuddy account.
No account cards, status/balance/check-in/automatic controls. AX and screenshot
observed through computer control. Initial getApp response was delayed by the
computer-control tool; it is not a reliable cold-start measurement.
Cmd-Q was sent; subsequent AX refresh returned procNotFound and exact bundle
query returned [], confirming the task app no longer runs. No duplicate launch.

Minimum remaining real-account step: receive action-time confirmation covering
both accounts' official AuthState/AuthToken/Profile requests and receiving/using
access tokens only in this memory session. Then change ONLY the two narrow
identity approval gates and build/verify the approved artifact; original
production/persistence gates remain closed. User clicks the existing Authorize
WorkBuddy account button, completes account A login/authorization on the official
website, returns and clicks Check authorization result, verifies UID/domain,
then repeats B. No password/token in chat or official-client account manipulation.
No billing, check-in or saved login. Exit clears account references and admissions,
not website grants or forensic memory contents. No intermediary package uploaded.
