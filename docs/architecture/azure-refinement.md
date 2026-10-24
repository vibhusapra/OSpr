# Azure v1 text refinement

Settings offers **BYOK · Azure v1 API** and a preset that clears the URL and
model fields for deliberate configuration. Supply your own Azure resource URL
or v1 base URL, deployment name and resource API key. The deployment name can
differ from the underlying model name. No resource hostname, deployment or key
is automatically chosen. Local/off defaults remain unchanged.

A resource root is normalized to `/openai/v1/chat/completions`. An explicit base
ending in `/openai/v1` is also accepted, including a configured gateway prefix.
The adapter uses the current v1 Chat Completions interface, not dated
`/openai/deployments/...?...api-version=...` routes. It does not implement Entra
OAuth, Azure Speech Services or audio transcription. It sends only transcript
text and deliberate selected-text editing context through the configured
endpoint. It adds no screen/clipboard context or audio upload.

## Credentials and request

`api-key` carries the resource key; it is never placed in the URL, JSON or
command-line arguments. Keys must be nonempty printable ASCII without spaces or
control characters. The existing Keychain scope binds origin and purpose. A
resource root and its v1 base share a scope; a different resource or transcription
purpose cannot reuse that retained key. CLI callers explicitly supply their own
environment key for the endpoint they select.

The shared ephemeral/no-cookie/no-credential-store/no-redirect transport remains
in use. Outside loopback, endpoints require HTTPS and reject URL credentials,
query strings and fragments. Deployment names are JSON data, never URL path
components. Empty/control-bearing/over-200-character names fail locally; the
provider still determines whether a deployment exists and accepts the request.

Requests have separate system/user messages, one choice, no streaming, and a
4,096 `max_completion_tokens` limit. Temperature and thinking defaults are left
to the chosen deployment. No tools, callbacks, retries or automatic continuation
are added. `store: false` is requested; this is not a promise about provider-side
retention, abuse monitoring or organizational configuration. A token-limited
reply is rejected rather than partially delivered. Older/model-specific
parameter compatibility remains an account acceptance item.

## Completion and fidelity

Only one index-zero assistant message with `finish_reason: stop` and nonempty
string content can reach the existing rewrite fidelity guard. Prompt or candidate
filter flags, refusal fields, tool/function calls, audio payloads, incomplete or
ambiguous choices, unknown/missing finish reasons and non-text content fail.
Only the final content string is returned; auxiliary reasoning/metadata is not
copied into transcripts. HTTP error bodies and refusal text are not exposed.

The normal app saves raw text and preserves it if refinement fails. A failed
selected-text edit is not inserted as though its instruction had run. The
existing mode-specific `RewriteGuard` still checks completed replies. Its lexical
tripwires are not semantic proof. No Azure model quality, latency, language,
quota, price or consumer ranking claim follows from this adapter.

## CLI and checks

`ospr-cli rewrite-azure <text-file> <resource-url-or-v1-base> <deployment>` reads
`OSPR_REWRITE_KEY` from the environment and explicitly uploads the UTF-8 text for
Clean refinement. The source file is unchanged. JSON reports accepted output or
original text plus the native guard warning. Provider/incomplete/filtered/refused
responses exit nonzero without partial stdout. Gemini's existing command uses
the same CLI admission path and is rerun as a regression control.

Eleven new Swift cases cover URL normalization, header/body/deployment semantics,
control-character validation, Unicode/whitespace preservation, completion shape,
refusal/tool/audio rejection, nested prompt/candidate filter flags, persistence,
credential scope, native HTTP routing/errors/redirects and cancellation. Local
validation passes **377 Swift / 248 Python tests** and Ruff. Twelve actual Azure
CLI loopback cases cover resource root and explicit v1, a negation fidelity
tripwire, incomplete/filter/refusal errors, HTTP errors/redirects, missing key/
deployment, dated query and legacy-path refusal. Eight Gemini CLI cases also pass.
These use an owned loopback server, synthetic keys and public text only.

Actual SwiftUI Settings light/dark renders were inspected with an isolated
services-disabled profile. [Dark layout](../assets/azure-settings-layout.png)
is simulated, not interactive/native Keychain or provider-account evidence.
Native Settings/save/restart/Keychain checks still require an unlocked Mac. No
Azure account request or real resource key is used. Deployment availability,
provider-side cancellation/quotas, semantic quality and live latency remain
unverified. No normal app/data, recording/playback or sound change is part of
source/loopback validation.

## Primary references

Checked 2026-10-24. Microsoft's [Azure v1 Chat reference](https://learn.microsoft.com/en-us/rest/api/microsoft-foundry/azureopenai/chat)
defines the endpoint, `api-key` authentication and response fields. Its
[v1 lifecycle guide](https://learn.microsoft.com/en-us/azure/foundry/openai/api-version-lifecycle)
explains resource-base configuration and removal of mandatory dated versions.
The [chat guide](https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/chatgpt)
distinguishes deployment names and completion reasons. [OpenAI Docs](https://developers.openai.com/api/reference/resources/chat)
provides the shared chat response schema; Azure deployment/account capabilities
remain governed by Microsoft and your resource.
