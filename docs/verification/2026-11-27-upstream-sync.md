# Upstream sync, 2026-11-27

The first run of the daily upstream sync. The app pins Magpie at `5fd855e` and the community plugin checkout at `6057896`. The lock still covers 45 source files, 20 ordered patches and six complete packages; the package check reverses every local patch before comparing the original source hashes. [Host changes](https://github.com/yetone/magpie/compare/f534245f1c0893c5eaaa5b2a1c918ff27085a9c3...5fd855eb753543f3c2bfd690877ee2407b783195) · [Community changes](https://github.com/magpie-community/plugins/compare/836f2e4e4cd899318c422d67cc1b2b30baaf1e06...605789637ab26497f17e89d6a9ca34c0ac4307ce)

Of the 20 patches, 18 differ from the previous revision only in line numbers and context; three of those also drop a pair of cancelling brace lines. Two changed in substance and are described below.

| Provider | Upstream change | In the app |
| --- | --- | --- |
| TRAE 0.2.57 | An enterprise custom model with its own OpenAI-compatible endpoint is asked there first (0.2.53); a reply Trae cut is asked on; a seat kept with no host is read as its console's. | `trae-enterprise-billing` is rebased onto the rewritten request loop. The model host stays the account's enterprise gateway, a seat refusal no longer falls back to the consumer gateway, and the direct endpoint ask is kept as upstream wrote it. |
| WorkBuddy 0.2.41 | A long-lived browser grant is renewed ahead of a request with 10 days left; empty `tool_calls` are dropped from streamed deltas; reasoning deltas are sent as one event; video tasks. | The 7-day renewal through the host (`refreshAt`) stays and is still the earlier one. Video models remain outside model grants. |
| ZCode 0.1.70 | Every claim answer carries a half-hour `until`; a plan claimed, answered 1003 or held for a captcha is not posted again that day, from memory. | The durable activity journal stays the owner of dedupe across restarts. Status reads stay read-only. |
| Qoder 0.2.73 | Claude Code's identity line is sent as the Claude Agent SDK's; a harness opener's comma is fixed. | Upstream request handling is taken as is. The `qoder` patch is completed, see below. |
| MiniMax 0.2.10 | A renewal that starts from the spent token gets the kept one back. | Taken as is. |
| Loomy 0.1.12 | Unchanged. | Unchanged. |

The host now fails only the call whose answer is longer than the line magpie reads, keeps a renewal whose save failed for the next try, forgets an account whose sign-in another process rewrote, and passes the calling agent to plugins.

## Qoder patch completed

`qoder.patch` replaced upstream's `quoted()` with an incremental Markdown tracker but left one call in the stream splitter's detection of a `{"tool_calls":` line, and read a `sent` field it no longer kept. With tools active, a reply carrying that line answered 502 with `quoted is not defined`. This predates the sync and was reproduced on the previous main.

The detection now asks a copy of the tracker about the text up to the object, so a fenced, spanned or indented example stays text as the tagged forms do, and a line-start flag replaces the field. The patch's stated purpose in `runtime/README.md` is unchanged.

## Tests added

- `test/native_qoder_tools.test.mjs`: 24 cases for the `{"tool_calls":` object. A line of its own becomes a call; inside a line, a fence, an indented block or a code span it stays exact text; split across its key it still becomes a call. Each in streamed and non-streamed form, whole and character by character.
- `test/native_trae_enterprise_billing.test.mjs`: three cases for the path the rebase opened. An enterprise custom model is asked at its own endpoint with its key and without the sign-in; after an error there the request goes through the enterprise console; after a refusal the refused key is not asked again. None reaches the personal gateway.

## Verification scope

Automated verification passed on macOS: source lock and patch reversal, Flutter tests (495), native tests (367) and the Swift checks. Synthetic credentials and responses only.

One Flutter test failed once in a full local run while another task held the machine at a load average above 50, and passed in six consecutive runs of its file once the load fell: `plugin_runtime_test.dart`, "cancelled native authorization never publishes a late credential". The fixture's callback saves after an 80 ms timer. A host process starved past that timer runs it before it reads the `abort` and the close waiting on its stdin, so the credential lands. The host's close and pending-call logic is the same line for line in the previous and the new upstream. The test depends on scheduling and is worth hardening; nothing in this sync touches that path.

Real-account acceptance is pending and was not done by this sync: a TRAE CN enterprise seat answering from its own endpoint and from the console after a refusal, including what each bills; a WorkBuddy browser grant renewed by the 7-day schedule; ZCode activity claims across a host restart; Qoder tool calls with a real model, including a reply written as a `{"tool_calls":` object. Upstream has not tried the TRAE direct endpoint or its cut-reply continuation on a real enterprise seat either.
