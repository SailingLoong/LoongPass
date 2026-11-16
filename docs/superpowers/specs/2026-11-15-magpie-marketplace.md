# Magpie marketplace distribution

Allen approved both self-maintained distribution and community marketplace review,
with self-maintained installation available while the review is pending.

## Design

Keep `runtime/bridge/` as the single plugin implementation and metadata owner.
Generate a repository-root package manifest with relocated entry paths so Magpie
can discover and install the existing public repository through its
`magpie-plugin` GitHub topic. The same package can subsequently be published to
npm. The published package uses the authenticated `@sailing-loong` npm scope;
`@loongpass` is unavailable. The provider remains `loongpass`. Direct CLI evidence
shows local path registrations coexist with registry registrations, so connection
setup must explicitly reconcile these sources rather than assume name deduplication.

Submit the existing package to the community registry as an externally maintained
plugin, following the existing OpenViking/deja-vu entries. Community endorsement is
the maintainers' decision. An independently maintained source plus a reviewed
listing avoids two implementations and two account owners. A separate plugin
repository and a copied community implementation add maintenance without another
user capability and are not selected.

## Product description and boundaries

Describe the LoongPass application: multiple platforms/accounts, assisted check-in and reward claims, balances and expiry, expiring eligible credits first,
official application account switching, and models supplied to Magpie. State
per-platform support and verification limits. The installed plugin connects the
running desktop application; it does not independently implement these features.
Account credentials, reward scheduling and official application activation remain
with LoongPass; Magpie owns its routing, protocol handling and inference recovery.

## Acceptance

- GitHub installation works without compiling the Flutter application or running
  installation scripts. Package contents include only the bridge and public docs.
- Source and root manifests cannot silently drift; existing native bridge and
  expiry routing contracts continue to pass.
- Public metadata and instructions explain the application requirement, supported
  authorization path, credential ownership, shared credit pools and differentiation.
- Self-maintained source reaches remote main; discovery is checked separately
  from code/installation. A community PR is submitted with its real readiness.
- npm publication requires valid publishing rights; it is not inferred from a
  successful tarball build. No private account or diagnostic data is published.
