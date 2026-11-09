# Qoder CN invitation settings

Qoder CN receives the same editable invitation settings and official registration entry as WorkBuddy. Its default referral code is `n1SqSmAhYt8nJKTkFM2QyB5IJ0DWROl3`, shown as the input hint. Empty input uses that default. Saved overrides survive restart and remain isolated by platform.

The existing settings owner and Forui panel become platform-configured components. One registration entry declares each supported platform's official host, path, query parameter and default code. WorkBuddy's existing preferences key and saved values continue through this configuration. Qoder overseas retains its own account entry.

The native sign-in dialog already accepts an official registration URL. The composition supplies the selected platform's saved URL. Official invitation binding and reward eligibility remain owned by each platform.

## Execution

- [x] Add a failing Qoder page regression and platform-isolation coverage.
- [x] Generalize the existing owner and panel, then register Qoder CN's supplied URL.
- [x] Run repository checks, inspect light/dark desktop and narrow renders, and review the complete diff.

Delivery follows the workspace's main-branch integration and cleanup process.

`tool/check.py` passed with Flutter 3.47.8, including 247 Flutter tests and 277 native JavaScript tests. The Forui controls were rendered at 1024 and 480 pixels in both light and dark themes, with default and saved invitation values. Independent source review found no production-code issue and confirmed the original WorkBuddy preferences key. Visual fixtures use synthetic account data.

## Acceptance boundary

Local verification covers default and overridden links, persistence, platform isolation, existing WorkBuddy settings and native authorization routing. Real-account invitation binding and reward receipt require a qualifying account on the official website.
