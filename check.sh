#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLOUD=0
if [[ -n "${FLUTTER_ROOT:-}" ]]; then
  FLUTTER="$FLUTTER_ROOT/bin/flutter"
elif [[ -x "$ROOT/toolchain/flutter/bin/flutter" ]]; then
  FLUTTER="$ROOT/toolchain/flutter/bin/flutter"
  CLOUD=1
else
  FLUTTER="$(command -v flutter)"
fi
if [[ "$CLOUD" == 1 ]]; then
  export HOME="$ROOT/toolchain/flutter-home" PUB_CACHE="$ROOT/toolchain/pub-cache"
  export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_HOME="$HOME/.local/share"
fi
export CI=true FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
cd "$HERE"
PUB_ARGS=()
if [[ "${PUB_OFFLINE:-$CLOUD}" == 1 ]]; then PUB_ARGS+=(--offline); fi
"$FLUTTER" --no-version-check pub get "${PUB_ARGS[@]}"
"$(dirname "$FLUTTER")/dart" format --output=none --set-exit-if-changed lib test tool
"$FLUTTER" --no-version-check analyze --no-pub
"$(dirname "$FLUTTER")/dart" run tool/zcode_accounts_checks.dart
"$FLUTTER" --no-version-check test --no-pub --reporter expanded
