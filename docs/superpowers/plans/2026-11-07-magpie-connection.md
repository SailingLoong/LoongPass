# Magpie connection implementation plan

Allen authorized continuing integration, testing with Claude Code and merging
passing changes to main. Implementation uses the existing Flutter application,
Dart HTTP server and native private document store. Tests are executed by Claude.

## Architecture

LoongPass exposes an authenticated loopback Anthropic provider and an official
Magpie import link. Magpie owns client protocol conversion and model selection.
Existing platform owners retain credentials, identity validation and refresh.
Each provider implements the same dispatch contract. Connection settings contain
explicit account/model intent and a local caller key, never copied platform tokens.

The first source must pass a tiny real saved-credential inference probe before
being advertised. The initial connection uses one explicitly selected account
and model. The gateway performs one dispatch and propagates streaming responses.
An uncertain result never triggers automatic replay or another account.

## Decisions

The official Magpie custom-provider/import mechanism fits the existing product
boundary. It keeps platform authorization with the existing account owner and
client conversions with Magpie, with one adapter contract for model sources.

## Execution

- [x] Claude verifies the first saved-account source and exact native protocol.
- [x] Add isolated checks for authentication, bounded input, SSE, single dispatch,
  persisted intent, startup failure and shutdown. Claude records the missing-feature failure.
- [x] Implement the loopback owner, first provider and existing model-service page.
- [x] Claude runs targeted checks, the repository checks and the real
  Claude Code → installed Magpie → LoongPass → official service chain.
- [x] Review the diff and raw evidence and update public capability boundaries.

Delivery uses remote main, a matching workspace gitlink and task-owned cleanup.

## Review focus

Read paths perform no authorization refresh. Concurrent requests share the
existing account lock. Bind or persistence failure never reports a running
service. Browser-origin requests and incorrect caller keys are rejected.
Account tokens and raw upstream errors stay out of diagnostics. Tests and
implementation preserve previously saved account data.
