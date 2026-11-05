# WorkBuddy 5.9.3 account-scoped candidate correction

This document describes the authorization protocol port. Current release enablement and real-account acceptance are recorded only in [SINGLE-ACCOUNT-STATUS.md](SINGLE-ACCOUNT-STATUS.md). The contract checks below use injected synthetic maps.

Connection endpoint defaults to https://www.workbuddy.cn independently of account X-Domain. Explicit endpoint choices stay bounded to the existing two China hosts; no copilot/staging/international discovery or failover is added. Browser authorization origin is aligned to the selected endpoint only after validating the returned HTTPS URL, state and existing bounded hosts; query parameters are retained, not fabricated. Both browser validators now include the documented default www.workbuddy.cn.

State POST has platform=workbuddy, endpoint X-Domain and four X-No-* flags. Token GET has state and four flags, no fabricated account headers. Profile GET is /v2/plugin/account with Bearer and account-domain header, no state query or placeholder user ID. Missing token domain falls back to endpoint. LoongPass identifies itself; no official User-Agent/device/channel identity is copied.

The authorization flow has a five-minute wall-clock and monotonic deadline. Business codes 11217 and 12151 remain pending; a usable token takes precedence over 11217. Profile-pending retains that token only in memory with its original expiry instead of requesting a new one. Only known personal/pro profile types without enterprise identity are admitted. Missing, unknown or malformed identity is rejected. Unknown critical payload shapes, domains, credentials and malformed expiry fail closed; unrelated optional profile fields are ignored, not treated as identity evidence.

Optional expiresAt (milliseconds) and expiresIn (seconds) produce the earlier known deadline; nonpositive, nonnumeric, nonfinite, overflowing or already-expired values fail. Known expiry follows the returned in-memory account and is checked at sending boundaries. Absent expiry remains absent; there is no refresh-token persistence or renewal implementation.

The claim core uses these verified account identities. Balance and check-in request ownership is described in WORKBUDDY-UI.md. Current real-account and build acceptance is maintained in VALIDATION.md.
