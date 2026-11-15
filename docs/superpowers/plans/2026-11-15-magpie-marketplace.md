# Magpie Marketplace Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans in this session.

**Goal:** Ship one self-maintained Magpie plugin and submit its community listing.

**Architecture:** The existing bridge owns code and package metadata. A checked,
generated root manifest enables GitHub installation; community review lists that
same package, following existing externally maintained entries.

**Tech Stack:** Existing JavaScript Magpie bridge, Python packaging checks, npm,
GitHub Actions. This is necessary integration for the upstream plugin runtime.

**Spec:** `docs/superpowers/specs/2026-11-15-magpie-marketplace.md`

## Global Constraints

- Preserve native credential, scheduling, routing and protocol ownership.
- Keep the public package free of credentials, app binaries and vendor sources.
- Use one implementation and retain the existing package/provider identity.
- Report npm publication, discovery and community acceptance separately.

## Review Focus

- A fresh installation has no application or grant: instructions must explain setup.
- Existing app-installed bridge and repository package must identify the same plugin.
- Tarball entry points, middleware and public documentation must resolve after packing.
- Expiry ordering applies to eligible model/account quotas, with unknown expiry last.
- Claimed account switching/check-in support must retain platform verification limits.

### Task 1: Installable package and distribution checks

Files: `runtime/bridge/package.json`, generated `package.json`,
`tool/magpie_package.py`, `test/magpie_package_test.py`.

- [x] Add and run a failing package smoke test: pack, inspect contents, load factory.
- [x] Generate the root manifest from the existing metadata and check drift.
- [x] Add discoverable name, summaries, icon, repository and keywords.
- [x] Run packaging smoke and existing native bridge/routing tests.
- [x] Reconcile npm/GitHub source registrations in explicit connect only: select
  bundled bridge, save/verify grants, retire recognized own distributions, verify
  again. Cover superseded owner, missing grants and post-removal failure.

### Task 2: Public setup instructions and CI

Files: `docs/magpie-plugin.md`, `README.md`, `.github/workflows/magpie-plugin.yml`.

- [x] Document standalone installation, app connection, full product value and limits.
- [x] Add a lightweight distribution check, without triggering an app release.
- [x] Review diff and verify from an isolated Magpie installation.

### Task 3: Delivery and community submission

- [ ] Review, merge through repository policy and verify remote main.
- [ ] Add the GitHub discovery topic and verify indexing/discovery.
- [ ] Publish npm only with valid credentials; otherwise retain explicit pending state.
- [ ] Submit the community registry PR with differentiation, evidence and readiness.
- [ ] Preserve delivery evidence and clean only this task's merged work and caches.
