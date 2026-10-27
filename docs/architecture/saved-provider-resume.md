# Saved provider identity and confirmation

An interrupted file batch keeps its original recognition and writing settings.
Changing global preferences to Local does not redirect that saved batch. Before
approving a recovered remote batch, the user needs its exact saved destination
and model. A host-only label hid the port, base path and model, so two services on
the same host looked identical.

The shared batch-card and confirmation description now shows the validated full
endpoint and model for speech and active remote rewriting. Verbatim hides the
unused refiner. Invalid endpoints, including embedded credentials or query
strings, display `invalid saved endpoint`. Routing, confirmation policy, model
selection, inference deadlines and the version-1 journal schema are unchanged.

## Evidence and limits

- One existing workflow case reproduces two missing-description assertions before
  the fix. Afterward, 26 focused cases and all 509 optimized Swift tests pass.
  Two new Core cases cover both routes/models, JSON roundtrip/schema, an unused
  refiner and invalid credential/query endpoints. Ruff passes.
- Four retained headless AppModel/real HTTP controls cover the original label,
  corrected label and two generated-silence CI runs. Services are disabled; each
  uses a new owned profile and a server bound only to `127.0.0.1`.
- Each exercise sees zero requests before confirmation and after a model-only
  decline. Explicit model confirmation produces exactly one accepted POST to
  `/saved/v1/audio/transcriptions`, with the original model, English, vocabulary
  and exact WAV SHA256. Current Local / Whisper Small / French settings survive.
  One planned History ID stores the fixed fixture text, model and source, with no
  retained audio. The receiver rejects Authorization and Cookie headers.
- CI generates one second of silence, returns constant fixture text, requires no
  weights or credentials, and stops its owned server. Ready metadata is published
  atomically. This tests routing and confirmation state, not recognition quality.
- The actual `ImportBatchContent` is rendered **offscreen** in light, dark and
  700-point compact layouts. Long speech/rewrite endpoint labels wrap visibly.
  These are component renders, not native screenshots or dialog acceptance.
- All six normal app/profile/owned-target hashes remain unchanged. No provider
  QA app was launched: macOS native control reported the Mac locked. The renewed
  TextEdit attempt also stopped at that lock, without insertion.

[Controller/HTTP/source receipts](../../benchmarks/results/saved-provider-resume.json) ·
[Offscreen layout receipt](../../benchmarks/results/saved-provider-resume-layouts.json) ·
[Light](../assets/provider-resume-light.png) ·
[Dark](../assets/provider-resume-dark.png) ·
[Compact](../assets/provider-resume-compact.png).

## Reproduce the controller CI

After the locked development dependencies and checkout app are built:

```sh
scripts/build-app.sh
uv run --frozen --all-extras python benchmarks/native_provider_resume.py \
  --stage ci --app dist/OSpr.app --output /tmp/ospr-provider-resume-new-run
```

The output root must be new. The runner checks deep signatures, manifest-v2
application fingerprint, signed app executable, source probe, runner and freshly
compiled XCTest bytes. Temporary XCTest source is removed in `finally`. Results
explicitly say `native_interaction_proven: false`. Preparation does not launch an
app, grant permissions or use the normal profile. Failed roots/logs are retained;
do not reuse them for a later attempt. For separately observed native testing,
`serve`, `prepare`, `verify-declined` and `verify-completed` are explicit stages.
Bind the final signed isolated candidate before preparation; re-signing afterward
changes its executable hash.

## Earlier native batch executable identity

The earlier native batch receipts identify their selected base app executable;
the native overlays changed only `Info.plist` to select owned data directories
and were signed again. Those signed executable hashes differ. An additional
read-only comparison removes signatures **only on disposable executable copies**:
both original and updated overlay program payloads equal their selected base
payloads, and all original signed files remain byte-identical. Existing receipts
are preserved rather than relabeled.

[Companion program-identity receipt](../../benchmarks/results/native-batch-program-identity.json) ·
[Earlier native batch protocol](native-batch-acceptance.md).

## Still open

Actual native saved-provider warning/cancel/approve, focus/VoiceOver, TextEdit
delivery and clipboard restoration remain unverified. No real provider account,
microphone, playback or physical shortcut was used. The corrected checkout app is
Apple Development signed and not notarized; it depends on the checkout/runtime.
The preserved c906 standalone ZIP predates this source change. Broader native,
model-quality, correction-effort, energy, consumer and release qualification remain
in the acceptance ledger; these controls establish neither full parity nor a
top-three ranking.
