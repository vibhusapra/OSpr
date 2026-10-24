# Native Gemini text refinement

Settings offers **BYOK · Google Gemini API**, with a preset base URL of
`https://generativelanguage.googleapis.com/v1beta`. Enter an available model ID
from your account and an API key. No model ID is pinned or automatically chosen.
The model ID may start with `models/`; URL/query/method names are rejected.
This adapter supports public model identifiers of up to 200 ASCII characters,
not tuned-model resource paths, Vertex AI or the Interactions API.

Refinement remains optional and off by default. Local speech inference and the
local MLX refinement option are unchanged. This adapter sends transcript text
and deliberate selected-text editing context to the configured provider. It
never uploads audio, adds browser tools, supplies a callback or changes provider
safety settings. Screen/clipboard content is not added as rewrite context.

## Protocol and response handling

The implementation uses Google's text-only `generateContent` REST protocol:
`models/{id}:generateContent`, `systemInstruction` plus a separate user `contents`
message, and a single candidate with a 4,096-output-token limit. It leaves model
thinking and temperature defaults to the chosen model. The limit can cause a
long rewrite to be rejected rather than partially delivered; no automatic
continuation, paid retry or tool invocation is performed.

The key is placed only in `x-goog-api-key`, never in the URL or JSON. Keys with
spaces, non-ASCII characters or control characters are refused. Endpoint
validation requires HTTPS outside loopback and rejects URL credentials, query
strings and fragments. The existing ephemeral, no-cookie, no-credential-store,
no-redirect URLSession transport is reused. Keychain credentials remain scoped
to origin and purpose; changing origin cannot reuse a retained key accidentally.

Only one candidate completed with `finishReason: STOP` is delivered. Prompt
blocks, candidate blocks, token limits, missing/unknown finish reasons, multiple
candidates, empty text and non-text parts fail explicitly. Thought parts are
excluded; opaque thought signatures attached to final text are accepted as
metadata and never displayed or persisted. Unexpected part fields fail rather
than silently dropping possibly significant content. HTTP/provider error bodies
are not exposed. Unknown rewrite-provider names now fail before transport instead
of falling through to the compatible API.

Normal app processing applies its existing mode-specific `RewriteGuard` after
parsing. On failure it retains raw text and does not apply an unexecuted
selected-text edit. These checks are conservative tripwires, not proof of meaning
preservation. No Gemini quality, latency, cost or language ranking is claimed.

## CLI and repeatable verification

`ospr-cli rewrite-gemini <text-file> <base-url> <model>` reads the key from
`OSPR_REWRITE_KEY`, never a command-line argument. It explicitly sends the UTF-8
file's text for Clean refinement, applies the existing native fidelity guard and
prints JSON with `text`, `rewrite_accepted` and `warning`. A rejected fidelity
check returns the original text. An incomplete/blocked/provider failure exits
nonzero without delivering partial text. The source file is never modified.
Avoid pasting credentials into shell commands or transcripts; supply the key
through your preferred environment/secret tool.

Ten new Swift tests cover native header/body routing and Unicode, model/endpoint/
credential validation including CRLF, parsing/finish/safety/thought/non-text
cases, settings persistence, credential origin/purpose separation, unknown
providers, redirects, sanitized errors and cancellation. A separate eight-case
replay runs the actual Swift CLI against an owned loopback server, checking
success, original-text retention on a negation tripwire, truncation/blocking,
HTTP errors, no redirect following, absent key/invalid model and unchanged input.
No real credentials or account calls are used.

The Settings layout is rendered from the actual SwiftUI source in light and dark
appearance with an isolated services-disabled profile. These are simulated
renders, not interactive/native Keychain/provider-account acceptance.
[Dark layout](../assets/gemini-settings-layout.png).

Native Settings/save/restart/Keychain acceptance still needs an unlocked Mac.
Account access, model support, provider-side cancellation/quotas, semantic quality
and live latency remain unverified. No normal app/settings/history or sound
setting is changed for these source/loopback checks.

## Primary references

Checked 2026-10-24. Google's [generateContent REST reference](https://ai.google.dev/api/generate-content)
defines request fields, candidate completion reasons and safety feedback.
The [text-generation guide](https://ai.google.dev/gemini-api/docs/generate-content/text-generation)
shows header-key authentication and single-turn text requests. The
[thought-signature guide](https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures)
describes signature metadata. Google currently labels this protocol as its
Generate Content API (Legacy); this adapter deliberately supports its single-turn
REST interface, without claiming Interactions or Vertex support.
