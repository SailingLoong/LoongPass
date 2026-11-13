# Native Magpie runtime

`upstream.lock.json` is the source/version owner. It pins the Magpie host, all six
complete community packages and Bun archives together. `PluginInstallation`
verifies the packaged files and installs an immutable tree; `launcher.mjs` owns
the exclusive OS lease for native plugin-auth. Credentials are never written by
the Dart UI, the model bridge, or a second supplier adapter.

At startup, `system-proxy.mjs` supplies the OS manual HTTP/HTTPS proxy when
the process has no explicit proxy environment. macOS reads `scutil --proxy`;
Windows reads the current user's Internet Settings. Loopback and existing/system
bypass entries remain direct. This follows Magpie's `internal/netproxy` startup
contract (MIT, reference commit `5f01b9d052a1e2d28e36be9b1d000c3cb7018d3e`);
the pinned host still owns request transport. A proxy change takes effect after
restarting LoongPass. PAC evaluation and SOCKS-only system settings require an
HTTP proxy endpoint; this bridge does not implement either mechanism.

The external `bridge/` is a native Magpie plugin. Each local account grant exposes
its original native model metadata and API model ID. Magpie's internal request
context is captured before its host removes private headers, then carried through
the local `/plugin/fetch` envelope. Neither boundary converts supplier requests
or adds client-specific prompts. External Magpie owns routing/groups/recovery;
LoongPass owns grant admission, persistence, scheduling and App activation. Video-output models stay out of model-grant discovery/admission while native
Magpie polling lacks model/SDK context. Native POST bodies remain opaque.

## Updating

Review upstream changes first, choose explicit commits, update the lock, then run:

```sh
python3 tool/plugin_sources.py --sync --magpie /path/to/magpie --plugins /path/to/plugins
python3 tool/check.py
```

The script reads fixed Git objects and replays the reviewed patches. It never
advances an upstream branch. Verification reverses the patches and checks the
exact original hashes, in addition to checking every effective file/package. Each file declared by a package must also
have a source hash; mere presence on disk is insufficient.
An upstream update must pass native factory, auth, usage, check-in, stream, tool,
bridge and migration contracts before real-client acceptance and packaging.
Do not automatically update packages at application startup.

## Local source changes

The patch list in the lock is ordered. These changes live in their owning native
component; they are not duplicated as client or Dart protocol workarounds.

| Patch | Purpose and removal condition |
| --- | --- |
| `qoder.patch` | Reuse native device-to-job-token exchange for migration, keep Markdown examples out of executable tool calls and preserve unknown credit-pool data during exhaustion classification. Remove once upstream exposes the exchange and passes the tool and quota corpora. |
| `plugin-identity.patch` | Persist verified Loomy UID and region/profile-qualified ZCode identity and region-scoped Start Plan slots shared by the same regional UID across profiles/devices. Remove when upstream preserves those identities under same-name accounts. |
| `usage-precision.patch` | Preserve exact MiniMax/TRAE quantities, Loomy explicit balances and Qoder package expiry and unavailable shared-pool admission. TRAE enterprise currency/credit quantities and ambiguous seat ownership remain native usage facts; Loomy spent/percentage calculation is now entirely upstream. Remove when native outputs pass the absolute-value corpus. |
| `host-usage.patch` | Keep unknown quantity fields distinct from zero. Remove when upstream normalizes those fields without fabricating numbers. |
| `host-auth-snapshot.patch` | Read credential snapshots through native recovery/known-state semantics. Remove when upstream exposes an equivalent read-only snapshot RPC. |
| `host-account-catalog.patch` | Exclude quarantined native slots before catalog/renewal hooks while keeping healthy siblings. Remove when upstream supports per-account admission for listings. |
| `host-api-identity.patch` | Supply scoped API account identity separately from untouched native prompt inputs. Remove when native API registration supports the equivalent contract. |
| `checkin-status.patch` | Optional read-only status hook, native campaign scope and expected-scope binding. Remove when upstream supplies equivalent receipt evidence and mutation boundaries. |
| `zcode-binding.patch` | Optional target reauthorization and reward-context hooks; preserve device and reject stale/wrong identities before save. Remove when native contracts support these operations. |
| `loomy-models.patch` | Preserve complete live native model shapes, reasoning tiers/defaults and request levels. Remove when upstream retains these catalog/wire facts. |
| `zcode-response.patch` | Await native JSON model naming before restoring tool names. Remove when upstream composes both transforms for gift JSON and SSE replies. |
| `workbuddy-usage.patch` | Give admitted routing refusals the exact requested account identity. Remove when upstream composes case-insensitive trace matching with free-window accounting. |
| `workbuddy-desktop-identity.patch` | Bind desktop reads and recovery to the saved UID/domain, while allowing same-account rotation. Remove when upstream enforces the same account boundary. |

Optional host hooks affect account management only. The native inference recovery
policy is preserved. Unknown reward writes remain durable: status reads cannot
infer receipt from balance alone. Only a matching official, bound campaign scope
can reconcile an uncertain generic claim. ZCode has one activity journal per
official region/UID across personal/team profiles and devices. Its richer
activity/captcha transaction remains a LoongPass feature.

## Official desktop credential formats

ZCode enc:v2 desktop credentials are outside the adopted plugin's import
capabilities. Fresh import reports the format and directs browser authorization;
existing usable grants are preserved. LoongPass does not import internal official
cipher services, add OS key-store ownership, or raise the dormant native switch
version gate. See the 2026-11-12 upstream verification record.

## Migration and verification boundaries

Migration freezes and reads back the old private documents, prepares any required
native grants, retires old credential writers, then imports through the native
host. Retry preserves an already rotated native grant. Unknown legacy refresh
state is quarantined, and original backups stay available for rollback review.

Synthetic credentials and responses are used in repository tests. Tests do not
prove real quota receipt, a successful official-client account switch, or a
particular live model/client combination; those are recorded separately in the
verification documents. Keep real prompts/responses and all credentials outside
the repository.
