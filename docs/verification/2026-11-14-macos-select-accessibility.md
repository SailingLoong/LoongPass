# macOS selector accessibility crash

## Reproduction and cause

The reported build 43 crashed when selecting WorkBuddy CN in the account workspace. The installed engine UUID matched Flutter 3.50.0's release dSYM. Symbolication located the exception in `AccessibilityBridgeMac::MacOSEventsFromAXEvent`, called from semantic updates. The bridge's text-field value event sends `startEditing` to its native node; read-only fields can instead have an `AXPlatformNodeCocoa` node without that selector.

Forui 0.27.7 renders a non-editable select as a read-only Material TextField. Updating the selected value reproduces the native exception in a separate macOS fixture with accessibility enabled, without account services or real credentials. This is related to the engine's prior platform-node failure in [Flutter #151428](https://github.com/flutter/flutter/issues/151428); that earlier enabled/disabled transition fix is already present in the pinned engine, while the read-only value-event path remains relevant here.

## Change

All eight existing select controls use Forui's public field builder to expose the actual selectable-button semantics. The existing field, its controller, focus, keyboard handling, popover and every option remain in place. The semantic label follows the selected value; the accessibility press invokes the existing select tap callback, and disabled controls expose no press action. The expanded state and popup options remain owned by Forui.

The correction applies to platform selection, sorting, page size, appearance, density, native providers, authentication methods and provider choice prompts. No global accessibility suppression, exception swallowing, SDK modification or provider-specific workaround is added. Account, reward, model, Magpie and community code is unchanged.

## Verification

- Regression first failed because the platform selector exposed text-field semantics.
- The original selector fixture aborted with the same `startEditing` exception; the corrected native fixture completes five alternating value updates with accessibility enabled.
- Widget checks cover WorkBuddy CN selection through accessibility activation, reachable popup options, keyboard activation/selection/focus on macOS and Windows, and disabled-state semantics.
- Complete `tool/check.py` passed on the unchanged production fix before the release version/notes update, including static analysis, 297 Flutter tests, 305 native plugin tests and the macOS storage, migration, updater and client-switch checks.
- `tool/check_macos_select_semantics.py` creates a temporary minimal host using the pinned application dependencies and exact production field builder. It enables the native bridge in the test host, accesses no account data, honors the shared build locks and removes the temporary build on exit. Release packaging runs this check before upload. `--legacy` verifies the original exception for diagnosis.

## Limits

The native fixture verifies the platform bridge with synthetic choices. It does not claim new real authorization, reward, model consumption, account-switch or update-installation acceptance. The existing platform verification records continue to own those claims.
