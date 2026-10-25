# Workflow standalone preview

This separate preview freezes clean source `f74bb75` (application fingerprint
`c1ddeec3cddfd05bee44d6b91342a0e9dff462a01ebf62737ca740ff4a64ee3d`).
It includes per-file import outcomes/retry, readable malformed-media failures and
complete history/search exports. The earlier v0-review package and the normal
app are preserved. Apple Development signed, macOS 26.6.2 arm64, weights separate;
not notarized or a full-parity/top-three acceptance claim.

## Verified artifact

Local app: `dist/workflow preview/OSpr.app`.
Archive: `dist/workflow preview/OSpr-v0.1.0-macOS26.6.2-arm64.zip` (402,410,428 bytes).
SHA256: `3de66ad6e6f86326032d39fb3f3224ab9b05e772f802817b502a678ccce5a1fd`. This is a local review artifact, not a public GitHub release.

[Aggregate manifest](../../benchmarks/results/workflow-preview-package.json)
binds all eighteen runtime receipts/sidecars and both real media controls to the
same clean build, app/CLI bytes and archive. Source/backend/lock/license bytes
match. ZIP CRC, extraction to a spaced path, deep signatures and extracted
offline CLI inventory pass. The frozen bundled report has 387 relative links;
the repository report adds these final receipts without rebuilding the artifact.

453 optimized Swift / 372 Python tests and Ruff pass. The initial full Swift
run failed in the termination test, and its isolated retry failed during control
startup before termination. Startup/recovery now have separate allowances;
the original 0.5/0.4-second operation deadlines and forced-kill bounds remain,
and both timeout tests require a replacement PID. Fourteen worker tests and the
final full suite pass. No production WorkerClient/deadline change.
[Validation and refusal controls](../../benchmarks/results/workflow-preview-validation.json).
The package reader accepts both standard and quiet pytest summary formatting.

A [private-copy upgrade](../../benchmarks/results/workflow-preview-existing-archive-upgrade.json)
preserves all eight existing legacy records, canonical fields/order/settings,
search, edited text across quit/restart and both referenced audio files using
current AppModel with native services disabled. Original bytes are unchanged;
no record contents/identifiers/audio/private hashes are published. This is a
component check, not a GUI upgrade of the normal app.

The old v0-review ZIP retains its original SHA256. All five normal data/app
baseline files and the owned TextEdit target remain unchanged, and normal OSpr
is visibly restored with eight sessions/265 words. The later
[focus retry](../../benchmarks/results/workflow-preview-textedit-focus.json)
remains inconclusive; no phrase, microphone capture or playback was used.

## Reproduce

Use a fresh output directory and receipt prefix. The bundle script defaults to
the normal `dist/standalone/OSpr.app`; always choose a separate output for QA.
Weights must already be cached. No native application, microphone, OS permission,
provider account or key is used by the package gates.

```sh
OSPR_BUNDLE_OUTPUT="/absolute/path/workflow preview/OSpr.app" scripts/bundle-app.sh
.venv/bin/python benchmarks/preview_package_gates.py \
  --app "/absolute/path/workflow preview/OSpr.app" --prefix your-prefix
.venv/bin/python benchmarks/package_media_recovery.py \
  --app "/absolute/path/workflow preview/OSpr.app" --prefix your-prefix
```

Use an existing authorized signing identity through `OSPR_SIGN_IDENTITY` when
needed. Existing receipts cannot be overwritten. Resume only named remaining
gates/models after diagnosing a failure; retain every attempt. The media runner
checks the complete current application fingerprint and bundled backend bytes
before compiling the real Swift WorkerClient helper, then verifies the signature
before/after each actual cached-ASR request and emits build-bound sidecars.

Run optimized Swift/backend suites into fresh logs, then package using
`scripts/package-release.py --help` with the same five required runtime receipts.
The aggregate verifier requires explicit `--swift-tests 453 --python-tests 372`
and `--media-recovery-prefix your-prefix` for this frozen source, plus the app,
release manifest, receipt prefix, private normal-file SHA baseline and output.
The historical v0-review source used 438/355; these are expectations for distinct
source snapshots, not silently inferred from the archive. Incorrect counts,
foreign source, changed receipts/harnesses/binaries or a changed normal baseline
must reject verification. Only the unchanged result is published.

## Uncontrolled timing difference

These runs have substantially higher wall/decode times than the historical
preview session, despite identical text/WER, five byte-identical recognizer
modules, unchanged dependency inventories and the same long-file harness.
Metal availability and the default GPU device were checked. Timing includes cold
load and shared-machine activity. Different sessions were not isolated for
power, thermal state or GPU contention; cause remains unresolved. A controlled
interleaved replay is required before attributing a code regression or accepting
speed. [Raw context](../../benchmarks/results/workflow-preview-timing-context.json).

| Repeated-hour route | Model | Historical session | Current session |
| --- | --- | --- | --- |
| native-long | parakeet-v3 | 25.1 s | 54.7 s |
| native-long | qwen3-asr | 82.7 s | 412.2 s |
| neural-long | parakeet-v3 | 35.9 s | 95.6 s |
| neural-long | qwen3-asr | 101.7 s | 285.5 s |

## Boundaries

Provider loopback replies are synthetic. Long-file public speech is repeated;
these gates do not rank natural-meeting quality, latency or energy. Native
file-import/export scope is documented separately. TextEdit’s actual foreground
handoff remains unconfirmed; no phrase was sent in the latest focus retry, and
the owned target and normal app/data remain unchanged. Physical shortcuts,
acoustics/devices, VoiceOver, broad application compatibility, representative
semantic quality, clean-Mac/older-OS/updater and Developer-ID distribution remain
open. The development preview does not establish universal feature parity.
