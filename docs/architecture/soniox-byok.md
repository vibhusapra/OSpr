# Native Soniox BYOK — async transcription

Current source implements Soniox's Files/Transcriptions API with Foundation and
no extra SDK. This is optional cloud speech; local MLX remains the default.
The native picker/preset selects `https://api.soniox.com/v1` and `stt-async-v5`.
The CLI exposes `transcribe-soniox <audio> <base-url> <model> [language]`, using
`OSPR_TRANSCRIPTION_KEY`, never a key argument. Existing origin/purpose-scoped
Keychain binding and the send-time endpoint guard apply in the app.

## Contract and lifecycle

OSpr normalizes file imports into private, contiguous audio-only parts locally.
Each Soniox call uploads multipart audio with a generic filename and an OSpr
reference, creates an async transcription, polls its status, then fetches the full
text/tokens. Language hints are optional; vocabulary is structured as terms.
No remote audio URL, webhook, translation or cloud diarization is requested.
Native Soniox requests always use the prepared parts path.

The adapter reuses one ephemeral URLSession for each job, with cookies, credential
storage and caching disabled. Redirects are refused. Uploads include multipart
overhead within OSpr's 25 MB transport budget. JSON response size is checked after
receipt; this is not a streaming network-memory cap. IDs must be UUIDs before
becoming follow-up or delete paths. Provider error bodies are not shown or saved.
The default polling interval is one second; a ten-minute operation watchdog also
cancels an active network request. Individual requests have a 120-second limit.

Deadline expiry initially exposed a Foundation race: creating a URLSession task
after invalidation raises an Objective-C exception. Task admission is now locked
against closure, with explicit cancellation binding. A rapid-poll deadline stress
case covers this alongside the slow-request cancellation test.

After completion, OSpr attempts to delete the owned transcription and uploaded
file, in that order; DELETE 204/404 is accepted. Cleanup runs outside the canceled
caller, with a separate two-second-per-request timeout. A processing job may reject
deletion. Its file is then preserved, and no transcript-completion claim is made
on cancellation/failure. An ambiguous create-job timeout/server error is not
retried or treated as proof that no remote job exists. Unknown/processing resources
can remain in the provider account. Check the Soniox console. No recognition
request is automatically retried, and cancellation cannot reverse provider charges.
An upload accepted before its response is lost may have an unknown ID.

Successful text is retained if later cleanup fails; a warning with the owned IDs
survives part assembly and is shown with the app transcript. Failure errors include
pending resource information when available. Cancellation returns promptly with
CancellationError; the picker warns in advance that console cleanup may be needed.
This is best-effort provider cleanup, not a remote-retention guarantee or a durable
background cleanup service.

## Timing and text fidelity

The full provider text remains authoritative and unmodified. Token bounds can
provide the utterance segment. Word groups are exposed only when whitespace word
boundaries coincide with token boundaries and concatenated tokens exactly match
the full text. A single token spanning multiple words is never divided into
invented word times. Invalid/reordered/nonfinite/bool timing data falls back to
coarse part bounds, with the full text still available. Mixed token languages use
`mul`. Independent jobs do not imply stable cross-part speaker identities.

## Validation and limits

Eighteen dedicated tests cover lifecycle/auth/hints, language auto detection,
subword/Unicode grouping, malformed and mismatched timing, complete part assembly,
cleanup warnings, create/job errors, ambiguous creation, UUID/redirect guards,
missing keys, upload limits, cancellation, deadlines and the close/admission race.
The current local suite passes 215 Swift tests and 94 Python tests. A separate
80-minute real Swift/worker loopback control validates actual normalized samples,
part assembly, token time offsets and owned resource cleanup; its versioned
receipt is [soniox-upload-parts.json](../../benchmarks/results/soniox-upload-parts.json),
pinned to source `4fae54bfee3cdcc67944b71b25de1f53bff14a3a` and the measured CLI.
All 76,800,000 samples, nine part offsets and all 36 create/delete lifecycle events
passed. Compatible/Deepgram controls passed on the same source. The fake provider
text is a sentinel, not recognition or a paid-account quality/latency result.

Native Soniox picker defaults, dummy Keychain save/quit/restart/use, a short
public-file import and persisted full text/timing passed in a distinct fixture
app at source `e9b196c`. Injected cleanup failure retained text and a History
warning. Source `054de0b` also shows warnings in Studio after restart and
discloses provider charges in the cloud footer. The dummy key was removed,
the QA app reset local-only and quit, and the fixture server stopped. Normal
preview settings/history were unchanged. See
[the native receipt](../../benchmarks/results/soniox-native-ui.json) for build
fingerprints and boundaries. Source `e9b196c` passes macOS 15 CI 39891673474.
Soniox long-file native UI and real-account checks remain separate. No real
Soniox account call or Soniox real-time WebSocket path has been tested/implemented.
Part boundaries can affect real recognition context; actual quota, retention and
accuracy behavior remain controlled by Soniox.

## Primary sources checked October 22, 2026

- [Current models](https://soniox.com/docs/stt/models)
- [Upload file](https://soniox.com/docs/api-reference/stt/files/upload_file)
- [Create transcription](https://soniox.com/docs/api-reference/stt/transcriptions/create_transcription)
- [Job status](https://soniox.com/docs/api-reference/stt/transcriptions/get_transcription)
- [Transcript and tokens](https://soniox.com/docs/api-reference/stt/transcriptions/get_transcription_transcript)
- [Delete transcription](https://soniox.com/docs/api-reference/stt/transcriptions/delete_transcription)
- [Delete file](https://soniox.com/docs/api-reference/stt/files/delete_file)
- [OpenAPI schema](https://soniox.com/docs/openapi.yaml)

## Portable preview

Source `fb2ad6f6f99bf83a25edba7cc7f43d4a9dfcfba0` passes macOS 15 CI run
39892523094 with 215 Swift and 94 Python tests. The matching standalone preview
is `dist/soniox-v0/OSpr.app`, with a 383,131,695-byte ZIP beside it.
[The release manifest](../../benchmarks/results/soniox-release-package.json)
pins its SHA-256, build and all receipt digests. Relocated/offline six-engine
smoke, both synthetic hour files and all three 80-minute provider transports
passed on this exact artifact. ZIP CRC, extracted signatures and the extracted
CLI inventory also passed. Three black-box release-gate controls reject a stale
Soniox build, retained owned resources and missing delete events. The extracted
CLI inventory is distinct from the six inference checks in the relocated suite.

Apple Development signing is not Developer ID/notarization. Weights are not
bundled. The packaged report is a frozen pre-verification snapshot; repository
receipts record the later artifact checks. Full native interaction, real provider
accounts and streaming acceptance remain separate from packaging.
