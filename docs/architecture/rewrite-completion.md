# Complete remote rewrite responses

The combined-v0 audit found that the older compatible/Anthropic parser returned
text without checking its finish status. A loopback HTTP regression reproduced
six draft deliveries: both providers returned text after reporting truncation,
refusal or tool use. Short passages can pass the separate lexical fidelity guard,
so that guard cannot compensate for ignoring protocol completion metadata.

`RewriteResponse` now validates completion before returning edited text. The
existing compatible/Ollama/Anthropic request routes remain; Azure shares the chat
parser and Gemini retains its native completed-candidate parser.

| Route | Required acknowledgement and text |
| --- | --- |
| Compatible, Ollama and Azure chat | One index-zero assistant message, `finish_reason: stop`, nonempty string content; no filter flags, refusal, function/tool or audio output |
| Anthropic Messages | A message/assistant response, `stop_reason: end_turn`, text blocks with optional thinking/redacted-thinking blocks excluded; no stop-sequence/details or unexpected block types |
| Gemini | Existing single `STOP` candidate with complete text/safety checks |
| Local MLX | Existing worker protocol and fidelity guard; unchanged by remote response parsing |

Missing, unknown or incomplete finish metadata fails explicitly. Compatible
servers must provide the standard non-streaming chat response fields; a loosely
compatible endpoint omitting them now returns an error instead of unverifiable
text. Anthropic custom stop sequences are rejected because OSpr does not request
one. There is no automatic continuation, tool execution, paid retry or increase
in token budget. Model/request-parameter compatibility remains provider-specific.

Only final text is returned, preserving supplied whitespace/Unicode. Auxiliary
reasoning, refusal and tool content is not copied. HTTP errors and response
failures do not expose provider bodies or keys. Header keys reject spaces/control
characters; compatible local services can still be anonymous, while Anthropic
requires a key. Compatible/Anthropic model IDs must be configured before transport.
Existing origin/purpose credential binding and no-redirect ephemeral transport
remain unchanged. No real key, provider account or private transcript is used in
the loopback verification.

The app's existing processing path retains original text when refinement fails.
A failed selected-text editing instruction is saved without being inserted as a
completed edit. Completed output still passes its mode-specific `RewriteGuard`.
These lexical tripwires do not prove semantics; a provider can finish naturally
and still change meaning. Refinement remains optional and off by default.

## CLI and tests

The file CLI now also exposes:

- `rewrite-compatible <text-file> <base-url> <model>`
- `rewrite-anthropic <text-file> <base-url> <model>`

Both read `OSPR_REWRITE_KEY` from the environment and use the existing Clean
fidelity guard/output contract. Input is unchanged; a lexical rejection returns
the original, and protocol/provider failure exits without partial stdout.
Gemini/Azure commands use the same CLI admission path as before.

The focused HTTP regression changed from six unexpected draft deliveries to zero.
Seven added permanent Swift cases cover that transport regression, anonymous
local compatibility, setup/header validation and Anthropic completion/text/block
shape. Existing Azure tests cover the shared chat parser. The full local suites
pass **384 Swift / 248 Python tests** and Ruff. Twenty-one actual compatible/
Anthropic CLI loopback cases cover completed/anonymous controls, original-text
retention, truncation/refusal/tool/missing/empty rejection, model setup, HTTP
errors, redirects and unchanged input. Twelve Azure and eight Gemini cases pass
as regression controls. No model-quality, native UI/insertion or real-account
acceptance follows from these tests.

## Primary protocol references

Checked 2026-10-24. [OpenAI Docs](https://developers.openai.com/api/reference/resources/chat)
defines chat completion reasons. [Claude's stop-reason guide](https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons)
distinguishes completed turns, truncation, tools, pauses and refusals. This
implementation requires complete single-turn text and retains raw text when the
request cannot be completed; it does not implement the guides' continuation/tool
workflows.
