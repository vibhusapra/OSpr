# Reliability preview qualification

This preview integrates source-name History search, durable import resume,
native worker parent-death cleanup and live audio-retention revocation. It is a
separate Apple Development signed application, with an isolated QA overlay for
native checks. The earlier preview archives and the normal installed profile
are preserved. Model weights remain separate first-use downloads.

## Build boundary

The frozen app is built from clean `c906a352835e49c51c5559a75c43e6d485e7c205`.
Its manifest-v2 application fingerprint is
`1b05e8a984553e97c7d83ca9f8b04643cc63ea11d62909d35bca741103df41ec`.
The packaging-script change does not change application/backend code from the
final live-privacy control. The frozen bundle uses Python 3.12.15; selected actual
library versions match `uv.lock`, and MLX reports `Device(gpu, 0)`. The runtime
receipt records interpreter/dependency hashes separately from inference results. All package gates use the same signed app and bind
their receipts to its build metadata, native executable and CLI hashes.

The first build used an existing Python 3.13 environment. The backend supports
that interpreter, but the portable launcher and library paths require 3.12;
staging failed before a usable bundle was produced. The builder now checks the
interpreter before staging and runs the existing locked 3.12 setup when needed.
The failed output/log is preserved separately. The corrected build succeeds
without removing signatures or changing an earlier archive.

The first portable and long-file gates also found that this managed checkout
lacked their ignored public speech files. Neither produced an inference result.
Existing public fixtures
were copied only after each byte hash matched the versioned manifest, and the
gates were resumed. These are fixture-provisioning failures, separate from model or
application correctness.

## Qualification protocol

`benchmarks/preview_package_gates.py` runs eighteen serial exact-bundle gates:
relocated/offline six-engine recognition and neural edges, text preparation and
cache boundaries, local model choice through CLI/MCP, meeting notes through
CLI/MCP, application profiles, rewrite fidelity, Azure/Gemini contracts, output
limits, default/neural long files and compatible/Deepgram/Soniox multipart upload.
Provider fixtures run against loopback synthetic services with no API accounts.
`benchmarks/package_media_recovery.py` separately checks malformed-media rejection
and recovery on a resident Whisper/Parakeet worker. Tests exercise functional
invariants; elapsed times on this shared Mac do not establish a speed ranking.

`scripts/package-release.py` requires matching portable/long-file/provider
receipts and passing Swift/Python logs, then checks archive CRC, extraction,
deep signatures and the extracted CLI. `benchmarks/preview_package_verify.py`
binds the archive and all eighteen gates to application/backend, lock/license,
binary and harness bytes, plus original-profile preservation and media recovery.
Existing receipts cannot be silently replaced; resume only remaining gates.

## Existing archive upgrade

The actual eight-record/two-audio legacy archive was copied into a fresh private
profile. Current AppModel startup migrated it, searched a private term, edited
one copied record, flushed at quit and restarted. Canonical fields, record order,
raw text, metadata, timing, audio links and both referenced audio files were
preserved. There was no duplicate or loss, and the original files stayed
byte-identical. The receipt publishes booleans/counts/hashes, never private text,
search terms, settings contents or source paths. Native services were disabled;
this proves the copied-profile component path, not an in-place user upgrade or
power-loss behavior.

## Native TextEdit follow-up

TextEdit reopened the owned public target, and the isolated latest candidate
reported existing microphone/insertion access enabled. No new grant was made.
The setup test started, but the native control surface exposed the main Studio
window without a verifiable captured destination from its nonactivating panel.
The test was cancelled without Send. The original target remained unchanged,
the QA app quit and the normal app visibly returned with eight saved sessions.
All six pre-existing baseline app/profile/target hashes still matched. This
attempt establishes cancellation/preservation, not delivery or clipboard
restoration. Foreground/field checks were not bypassed.

## Remaining acceptance

Physical microphone/Fn/PTT/device and acoustic acceptance, current TextEdit
delivery, broader app compatibility, native resume/privacy controls and VoiceOver,
representative semantic quality, correction effort, energy/latency distributions,
broad consumer-app comparisons, clean-Mac/older-macOS checks, Developer ID signing,
notarization and updates remain open. Package qualification does not establish
full union parity or a top-three product ranking.

Receipts: [package/archive bindings](../../benchmarks/results/reliability-preview-package.json),
[runtime/lock provenance](../../benchmarks/results/reliability-preview-runtime.json),
[all failed setup controls](../../benchmarks/results/reliability-preview-attempts.json),
[copied archive](../../benchmarks/results/reliability-preview-existing-archive-upgrade.json),
[native cancellation](../../benchmarks/results/reliability-preview-textedit-focus.json).
