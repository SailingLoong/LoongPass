# WorkBuddy native routing upgrade acceptance

## Failure and ownership

An existing connection upgraded from before model routing had enabled grants but
no `routingConnected` marker. The native bridge advertised `loongpass/auto`, while
startup never created its routing graph. WorkBuddy consequently received HTTP
400 `invalid_native_request` before supplier inference.

The real installation also exposed a second failure: Magpie's default short
model picker omitted later native aliases from its full catalog. Native group
creation resolves that exposed list, so the first group could not be saved.
Earlier isolated routing probes had too few models to exercise this boundary.

`ModelConnection` now recognizes an existing saved grant only on the verified,
loaded, enabled bundled bridge. It preserves connection intent and uses its
existing serialized synchronization/retry path. New or unrelated installations
remain unconnected. Intent persistence failures remain retryable; disposal and
source changes are checked across the persistence boundary.

`MagpieConnection` explicitly publishes selected native and canonical model IDs
through supported native provider commands before creating groups. Empty
selection uses native `none`; later selections restore explicit picks. Routing,
conversion and recovery remain native Magpie responsibilities.

## Verification

- Regression tests failed before both corrections and passed afterward. They
  cover old connections, partial saved membership, unrelated/disabled/superseded
  sources, source changes, disposal, persistence retry and selection transitions.
- The complete Flutter suite passed 377 tests; Dart analysis reported no issues.
- Installed Magpie 0.1.3346 synchronized 71 model groups from 11 admitted local
  grants through the actual Dart routing implementation. This exercised the
  catalog beyond the native default picker. A separate isolated native CLI test
  verified selected → none → selected, including native `noModels` persistence.
- The release build passed Universal arm64/x86_64, strict signature and release
  entitlement checks. The final candidate was installed and restarted on
  Apple Silicon macOS with the existing private account store.
- WorkBuddy 5.11.3 selected `Auto · LoongPass:loongpass/auto`. Three prompted
  messages returned the exact requested markers in 6, 6 and 5 seconds: initial
  text, a second turn in the same conversation, then another turn after the
  final installed build restarted. The first two followed native routing repair;
  the third used the final installed source. Four gateway requests, including
  title generation, completed HTTP 200. The main conversation retained its
  session and used MiniMax CN `MiniMax-M3.1-Flash`.

This is real WorkBuddy text/stream acceptance for that selected route. It does
not certify every supplier/model, tool execution, Windows/Intel hardware, or
per-request financial attribution. No public release or update feed was changed.
Credentials and private diagnostic material remain outside the repository.
