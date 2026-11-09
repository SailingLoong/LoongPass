# WorkBuddy invitation settings

## Approved behavior

The WorkBuddy page provides an editable invitation code with `3wu5mr8ye2b0` as its hint and effective default. A saved override survives restart. Empty input restores the default. The existing account authorization owner continues to manage native sign-in.

## Architecture and boundaries

WorkBuddy invitation settings own the saved override and official invitation URL. A Forui settings panel edits that owner. The WorkBuddy composition supplies the URL to the existing sign-in dialog. New browser sign-in offers official invitation registration before starting native authorization. Existing users can continue directly. Reauthorization and API-key sign-in retain their established entry points.

The official invitation page owns binding and eligibility. Official binding and reward acceptance require evidence from a qualifying new account. The final report distinguishes synthetic verification from new-account acceptance.

## Implementation plan

- [x] Add focused regression coverage for defaults, persistence, failed saves, hints and editable values.
- [x] Implement the settings owner and Forui panel, using the existing preferences backend and startup composition.
- [x] Add coverage and connect official invitation registration to the native authorization dialog.
- [x] Run the repository checks and inspect light/dark desktop and narrow layouts.
- [x] Review the complete diff and resolve the Windows browser-opening gap.

Delivery follows the workspace's remote-main integration and cleanup rules. The task's final report records the resulting commits.

## Review focus

Exercise empty and whitespace overrides, save failure, reopening settings, invitation cancellation and browser failure. Confirm normal authorization remains available to existing users, existing-account reauthorization bypasses registration, and other platforms do not receive the invitation setting.

## Execution notes

2026-11-09. The approved default is interpreted as a hint plus an effective default when the field is empty. Implementation runs in the task-owned linked worktree. The native worktree tool exposes the submodule's shared `core.worktree` setting, so Git operations use explicit `--git-dir` and `--work-tree` arguments without changing shared repository configuration.

The independent review identified a missing Windows `openExternalHTTPS` method. The existing native authorization bridge now routes that method through its HTTPS parser and system browser opener. A follow-up review accepted the correction at source level.

Local verification completed with the pinned Flutter 3.47.8 SDK. `tool/check.py` passed, including 277 native JavaScript tests, 244 Flutter tests, analysis, Python and Swift checks. The additional full Flutter run uses the same pinned Bun executable selected by `tool/check.py`. Light and dark layouts were rendered at 1024 and 480 pixels, including default and saved states. Visual fixtures use synthetic account data. The new settings controls use Forui 0.27.7 and its neutral desktop themes.

Official new-account registration, invitation binding, reward receipt and Windows device acceptance remain separate integration checks.
