# LoongPass for Magpie

[LoongPass](https://loongpass.com) is a desktop application for AI-platform accounts
and credits. This plugin connects a running local LoongPass application to Magpie.
Every prompt and reply for this provider passes through that local application.

LoongPass 1.0.1 bundles `@sailing-loong/magpie-bridge@0.2.1`. The desktop app and
plugin have independent version numbers. That published plugin was checked with
the 1.0.1 application code and external Magpie 0.1.3346 and 0.1.4277 on macOS;
see the [compatibility record](https://github.com/SailingLoong/LoongPass/blob/main/docs/verification/2026-11-16-stable-1.0.1.md)
for scope.

## What LoongPass provides

- Multiple accounts across supported platforms, official authorization and saved
  identities, with credentials retained by the local application.
- Assisted automatic check-in and reward claims where the platform actually offers
  them. Scheduling runs while LoongPass is running; uncertain claims are retained
  for verification rather than blindly repeated.
- Balances, reward history and remaining-credit expiry from official interfaces.
  Unknown expiry stays unknown. For an eligible model, available accounts with
  credits expiring sooner are preferred; unknown expiry follows known expiry.
  Conversation affinity and recovery are handled by Magpie's native routing.
- Account switching in supported official desktop applications, with credential
  application and verification of the running client's identity reported separately.
- A model service for Magpie, including model priority and `loongpass/auto`, plus
  explicit `loongpass/<standard model ID>` selections.

Account switching, authorization, check-in and model support vary by platform and
OS. The application's [README](../README.md) and
[verification records](https://github.com/SailingLoong/LoongPass/tree/main/docs/verification)
state what is implemented and what has actually been verified. Installing this
plugin alone does not install the application or enable every listed feature.

## Install and connect

1. Install a current [LoongPass release](https://github.com/SailingLoong/LoongPass/releases)
   and [Magpie](https://usemagpie.ai). LoongPass supports macOS and Windows; consult
   the release's verification notes for each platform's actual coverage.
2. In Magpie, install the LoongPass plugin from **Plugins → Discover** when listed,
   or enter `github:SailingLoong/LoongPass` in the manual installation field.
   The command-line equivalent is:

   ```sh
   magpie plugin add github:SailingLoong/LoongPass
   ```

   The published npm package installs the same plugin identity:

   ```sh
   magpie plugin add @sailing-loong/magpie-bridge@0.2.1
   ```

   This selects the initial version. Magpie's current update commands can replace
   an explicit npm version; it is not a catalog-enforced review pin.
3. Save accounts in LoongPass. In **模型连接**, enable the accounts to expose, open
   the connection settings, enable the local service, then click **连接 Magpie**.
   LoongPass uses Magpie's native commands to install its bundled compatible bridge,
   register per-account local grants and synchronize model groups. The current
   connection implementation selects and verifies the bundled bridge before
   retiring recognized npm/GitHub copies and checking the saved grants again.
4. Select `loongpass/auto` or a particular LoongPass model in Magpie and keep
   LoongPass running. Authorization and model availability must be confirmed in the
   application; a successful plugin installation does not certify an account call.

The bridge uses the loopback service, normally `http://127.0.0.1:3426`. It has no
runtime npm dependencies and requires no compilation or installation scripts.

### Existing desktop releases

The automatic source reconciliation above is a source change accompanying this
plugin distribution, not a claim that an older installed desktop release has it.
With an older release, click **连接 Magpie** first, then select its local bridge
and remove the independently installed copy through Magpie's native commands:

```sh
magpie plugin list
magpie plugin use "<LoongPass local bridge path shown by list>" loongpass
magpie plugin rm "<npm or github spec of the independently installed copy>"
magpie plugin list
```

Keep the local bridge entry installed by LoongPass. `plugin rm` unregisters the
extra package without logging out its accounts. Confirm that only the intended
LoongPass bridge serves the provider and that the expected accounts remain.
Magpie's local-path registrations do not deduplicate by the npm package name.

## Authorization and differences from direct provider plugins

This plugin authenticates to **LoongPass's local service**, with a separate grant
for each enabled account. It does not log in to WorkBuddy, MiniMax, Qoder, TRAE,
ZCode or Loomy itself. LoongPass owns the official vendor authorization, native
credential refresh, reward transactions and client activation. Original vendor
credentials remain in LoongPass's application-private directory; Magpie saves only
local invocation grants. Revoking, deleting or reauthorizing an account invalidates
its former grant. Requests cannot follow a redirect to leak that local grant.

Direct community provider plugins authorize the vendor account in Magpie. Choose
this companion when you want LoongPass's multi-account/reward/expiry workflow and
its official-application switching alongside model access. Both routes use the
**same vendor account and credit pools**: installing LoongPass provides no extra
credits or independent allowance. Avoid configuring the same account twice if you
do not want two routes to draw from that pool. The provider ID here is `loongpass`.

## Distribution and maintenance

The package name is `@sailing-loong/magpie-bridge`; its source and package metadata are
owned by `runtime/bridge/` in the LoongPass repository. The root `package.json` is
a generated path-adjusted mirror for GitHub/npm distribution. After editing the
source metadata, run `python3 tool/magpie_package.py --write`; CI checks consistency
and loads the actual packed files. Community marketplace inclusion and its badge
are subject to the maintainers' review, independently of GitHub availability.
