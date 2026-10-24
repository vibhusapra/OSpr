# Current v0 standalone review package

This development preview includes edited-text summary snapshots and the final
profile-feedback footer. It is Apple Development signed for macOS 26.6.2 arm64,
with model weights downloaded separately. It is not notarized. This is a local
review artifact, not a production distribution or a full-parity acceptance claim.
The normal app and earlier archives are preserved.

Archive: `OSpr-v0.1.0-macOS26.6.2-arm64.zip` (400931517 bytes).
SHA256: `1de0985a612dca7eec8a2bbecd408e4b5acc4288928216a07f561f5943e8e561`.

## Packaging corrections

An actual absolute-path build failed because the bundle script prepended the
checkout directory to an already absolute bundled-Python path. The script now
resolves that interpreter from its real directory. The corrected signed build
succeeded at an absolute output path with a space in its parent directory.
Existing CI continues to exercise the default relative output path.

The long-file harness initially stopped before inference: importing its shared
scoring helpers unnecessarily imported the checkout backend. Backend imports now
belong to the direct benchmark entry point. The standalone harness imports from a
foreign working directory without the checkout backend; CI verifies that case.
Neither failure was counted as a successful runtime gate.

Review also preserves the research Cohere candidate's custom engine through an
explicit factory argument. Constructor controls cover both the candidate and
default routes without loading weights; CI runs the same helper. The WER
normalization AST is unchanged from the code used for the retained hour receipts.
This [compatibility check](../../benchmarks/results/v0-review-scoring-compatibility.json)
changes neither the packaged app nor the earlier measured outputs.

## Exact artifact evidence

The [aggregate receipt](../../benchmarks/results/v0-review-package.json) identifies
one clean source build, app and CLI executable hashes, archive SHA256, the full
strict release manifest and all eighteen individual receipt/sidecar hashes.
The build's source fingerprint is checked against current Swift and backend
sources; bundled backend, dependency locks, LICENSE and NOTICE bytes match.
Research grammar dependencies and the experimental 35B model remain excluded.

The gate cohort comprises:

- Relocated offline six-engine ASR, exact-PCM neural edges, cached models,
  source-excerpt notes, attribution, track mixing, upload preparation and MCP.
- Eleven preparation contracts; four paired worker/speech-retention controls;
  missing-cache rejection; twelve selected-model CLI controls and two real MCP calls.
- Eleven summary CLI cases, actual MCP summary/input-bound controls, seventeen
  profile resolver cases and output-limit recovery retaining the warm ASR worker.
- Forty-one loopback rewrite/Azure/Gemini cases.
- Two cold hour-long Parakeet/Qwen requests through each default and neural-edge
  route; bounded original-timeline timestamps and fixture-specific WER below 5%.
- Eighty-minute compatible/Deepgram/Soniox multipart uploads, full PCM16 coverage,
  request-size limits, preserved source, temporary-workspace cleanup and Soniox
  owned remote-resource cleanup against an isolated loopback server.

Provider responses are deterministic test sentinels, not recognition results;
these checks use no real API account or key. Long speech is repeated public
speech, not a natural meeting. Timings include cold loading and shared-machine
activity and are not used to rank speed or energy. The scoring rule is retained
with raw responses and is not a general accuracy promise.

The archive passes ZIP CRC, extraction to a path with spaces, deep signature,
offline bundled CLI and archived executable identity checks. Local optimized
Swift tests pass 438/438 and Python passes 355/355. Normal settings/history and
normal-app executable/metadata hashes remain unchanged.

A separate [current-source archive-upgrade check](../../benchmarks/results/v0-review-existing-archive-upgrade.json)
uses private copies of the eight existing legacy records and referenced audio.
Current AppModel migration, canonical fields/order/configuration, search, edited
text across quit/restart and audio hashes pass in optimized Swift with services
disabled. Original-file hashes are unchanged; source content is not published.
The [SwiftPM helper](../../benchmarks/existing_archive_upgrade.swift) must be copied
temporarily into `Tests/OSprPlatformTests/RealArchiveUpgradeTemporary.swift` and
run with `swift test -c release --filter RealArchiveUpgradeTemporary`, setting
`OSPR_UPGRADE_COPY` to a private directory containing a **copy** in `profile/`.
Never point the helper at the normal profile. Remove the temporary test afterward.
This is a component upgrade check, not an actual upgrade of the running app.

The bundled report is the frozen **358-link source snapshot** from before these
final receipts. The newer repository report links the final manifest. Rebuilding
merely to embed the archive's own receipt would produce a different artifact.

## Reproduce without touching the normal app

Use a fresh output directory and receipt prefix. The default bundle output is
`dist/standalone/OSpr.app`; choose a separate location for review candidates.
The full suite assumes the pinned model weights and public speech fixtures are
already cached, and requires local Apple Silicon/Metal. It intentionally runs
offline and does not request microphone access or open native applications.

```sh
OSPR_BUNDLE_OUTPUT="/absolute/path/with spaces/OSpr.app" scripts/bundle-app.sh
uv run --frozen --all-extras python benchmarks/preview_package_gates.py \
  --app "/absolute/path/with spaces/OSpr.app" --prefix your-new-prefix
```

Set `OSPR_SIGN_IDENTITY` to an existing authorized signing identity when needed;
otherwise the default is ad-hoc signing. Do not export a private signing key.
Use `--only` solely to resume named remaining gates after diagnosing a failure;
existing receipts cannot be overwritten. Retain successful receipts and never
substitute evidence from another build.

Run `scripts/package-release.py --help` for the five required runtime receipts,
Swift/Python logs and archive destination. Then
`benchmarks/preview_package_verify.py --help` lists the aggregate verification
arguments. The latter also requires a private pre-test SHA256 mapping of owned
normal-app/data files; it publishes only the unchanged result. Source helper
hashes, build metadata and receipt hashes must agree, or verification fails.

## Remaining work

The current release GUI also passes scoped native light-mode footer checks in
an isolated session-only profile: query-bearing site and empty Custom instruction
validation stay visible above disabled Save; valid input enables Save with
inactive-provider guidance. Saving persists the exact valid site/name/Custom
instruction and leaves private global values unchanged.
[Native receipt](../../benchmarks/results/v0-review-native-feedback.json) ·
[Saved synthetic profile](../../benchmarks/fixtures/v0-review-native-profiles.json) ·
[Invalid site](../assets/v0-review-native-invalid-site.png) ·
[Empty instruction](../assets/v0-review-native-invalid-custom.png) ·
[Provider off](../assets/v0-review-native-provider-off.png).

The QA overlay is re-signed for its private Info.plist profile. Signed executable
hashes differ, while signature-stripped copies compare byte-identical to the
packaged GUI. This is scoped native evidence of that GUI payload, not a launch of
the delivery archive against normal data. One checkbox action reported transient
AX failure; refreshed state showed it completed. Dark/compact native controls,
VoiceOver, enable/delete/duplicate/site-canonicalization and live routing remain
open. A new insertion diagnostic still captured Chrome, so it was cancelled
without sending. The owned TextEdit field is unchanged; the candidate is stopped
and normal OSpr is restored at eight sessions/265 words with unchanged hashes.
Current target-app insertion remains unverified. Earlier native summary/profile
checks remain pinned to their source phases. Physical Fn/PTT, route loss/interruption, reference-acoustic
microphone tests, live browser metadata/routing, VoiceOver, clean-Mac/older-OS
and updater acceptance remain open. Representative independent semantic quality,
isolated latency/energy and consumer-app comparisons are also pending. No
full-union parity, top-three ranking or best-on-every-axis claim is established.
Only an Apple Development identity is currently available; Developer ID signing
and notarization remain release work. [Feature progress](../PROGRESS.md) and
[parity status](../data/parity.json) retain the detailed scope.
