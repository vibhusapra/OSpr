# OSpr v0 combined review

Snapshot: source `728ef76` and its 49-item ledger. Newer
[local meeting-summary work](meeting-summaries.md) adds an experimental entry to
the current ledger; the preserved integration package below predates that work.

**Developer preview; the original goal is not complete.** This branch brings all
23 component PR heads into one review against `main`, preserving the existing
component branches. Review also found and fixed a remote rewrite completion bug:
compatible/Anthropic clients could deliver draft text after truncation, refusal
or a tool turn. The shared completion gate now rejects those responses, and the
file CLI exposes both routes. [Protocol fix](rewrite-completion.md).

The new signed source `728ef76` integration candidate passes the development
package checks below. The prior `3fb3c1d` Azure candidate predates this fix and
remains preserved with its own manifest. Runtime dependency locks are unchanged.
Full native/account/distribution acceptance remains open.

[Machine-readable review and component PRs](../data/v0-review.json) ·
[Full research/benchmark report](../research.html) ·
[Feature acceptance ledger](../data/parity.json) ·
[Prior candidate manifest](../../benchmarks/results/azure-refinement-package.json).

## Original request and evidence

| Requirement | Current evidence | Completion boundary |
| --- | --- | --- |
| Major offerings, plans, features and differences | 29 offerings, each with plans/features/differences/platforms/vendor sources; research snapshot checked 2026-10-22 | Vendor claims and a dated market snapshot; no exhaustive or independently tested feature guarantee |
| Sensible union parity including BYOK | 49-item ledger: 14 verified components, 12 implemented, 5 contract-tested, 8 partial, 6 experimental, 1 research-only, 2 deferred, 1 unproven | Full union parity is not achieved; statuses must not be added together as accepted features |
| Ten Mac-local performance changes | Ten implementation/evaluation tracks below, pinned sources and retained rejected experiments | Native end-to-end latency, physical endpointing, isolated energy and all-axis leadership are not proven |
| Best off-the-shelf model choices and future custom models | Six-engine MLX/Metal portfolio, language/quality/latency slices and training roadmap | No universally best model or custom trained/distilled model is claimed; custom training was requested for later |
| Build v0 and make PRs | Combined source contains all 23 component heads; signed standalone test candidate and exact-build receipts | A combined review with a completion-status fix; current artifact gates pass, no release/merge-ready assertion |
| Test, track features/TODOs/WIP | 384 Swift / 248 Python tests, 21 compatible/Anthropic plus 12 Azure / 8 Gemini CLI cases, portable/archive gates, progress and acceptance ledger | Current-candidate native/physical/device tests and representative fidelity acceptance remain |
| Compare with others and reach top three | Actual Vibe CLI comparison and Apple/native speech research, normalized scoring and frozen protocols | Consumer GUI/dictation equivalence, correction cost, isolated energy and top-three ranking are unproven |
| Great native design/setup | SwiftUI app/setup, model/cache tooling, insertion self-test, simulated light/dark layouts and earlier isolated UI checks | Current integrated first-run, live field/shortcut/device, Keychain and upgrade UI acceptance remain |

The ledger's `verified` labels describe their stated component scope. They do not
certify the whole app. Tests, mocks, layout renders and a signed ZIP cannot stand
in for a successful observed cross-app dictation flow.

## Runtime included

- Six local speech engines: Parakeet v3, Whisper Turbo, Whisper Small, Qwen3 ASR,
  Nemotron 3.5 streaming and native-layout Cohere 8-bit. Model weights/download
  inventory and one resident speech worker remain local; optional detector runs
  on CPU while ASR uses Metal. No silent cloud fallback.
- Toggle/PTT/Fn source paths, late-capture mouse countdown/HUD, checked insertion,
  clipboard restoration, secure-field refusal and a separate no-audio insertion
  self-test. App/site profiles snapshot per-take settings.
- Vocabulary where supported, phrase replacements/snippets, deterministic modes,
  optional local MLX/Ollama refinement and BYOK compatible/Anthropic/Gemini/Azure
  text adapters. Compatible/Deepgram/Soniox speech upload adapters are explicit.
- Paged SQLite history, legacy migration, edit/search/export, retention/session
  privacy, retained-audio review, sequential imports, watched folders, CLI and MCP.
- Experimental desktop/meeting capture, provisional drafts, final diarization
  and exact-span extractive notes. Notes are not a full abstractive summary;
  duplex mixing has no echo cancellation and speaker errors remain substantial.

[Native/Core/CLI source](https://github.com/vibhusapra/OSpr/tree/728ef7624a58db3fd7b95de90842f3668a5e8249/Sources) ·
[Local engine source](https://github.com/vibhusapra/OSpr/tree/728ef7624a58db3fd7b95de90842f3668a5e8249/backend/ospr_backend).

## Ten optimization tracks

| Track | State and remaining measurement |
| --- | --- |
| Resident ASR plus optional refiner | Implemented; cold/warm/priming results exist, native latency still needed |
| Continuous normalization | Exact PCM/tail controls and quality/cost tradeoff study; alternatives rejected, defaults retained |
| In-memory Parakeet frontend | Implemented; file-route ablation exists |
| Precision per stage | Float32 frontend, selected speech dtypes/quantizations; complete dtype ablation remains |
| Avoid unnecessary second model | Deterministic defaults and explicit refinement; semantic quality still needs broader acceptance |
| Conservative endpointing | Full audio default, optional neural/RMS; quiet/multilingual quality and physical sweeps remain |
| Bound capture/preview work | Async disk buffers, bounded rings/UI updates and one preview in flight; device contention profiling remains |
| Chunked IPC and cancellation | Serial framing, generations, watchdog/recovery tests; broader live stress remains |
| Cached incremental streaming | Nemotron replay/stop/tail controls; physical cadence/device/energy acceptance remains |
| Prime kernels before recording | Measured explicit preparation, discarded synthetic input and output-equivalence controls; work is shifted, not removed |

The later [text-preparation follow-up](text-model-preparation.md) extends the tenth
track to cached 4B/9B refinement, with twelve fresh-worker controls and isolated
native preparation/replacement/release/cancel and 9B Save/restart observations.
Preparation cost is retained; the original combined-review snapshot above remains
scoped to its source.

The frozen 20-case product pilot compared OSpr Parakeet, OSpr Whisper Turbo and
Vibe Whisper Turbo, with three process trials per case. It used read speech,
primed OS caches and a shared active Mac. It excludes microphone, UI, endpointing,
rewrite and insertion, so its latency/word-error gaps do not establish a winner.
[Every pilot trial and limits](../../benchmarks/results/product-cli-after-startup.json).

## Validation and an actual archive-copy upgrade

Source `728ef76` [CI 40100957889](https://github.com/vibhusapra/OSpr/actions/runs/40100957889)
passes matching 384/248 tests, all three CLI suites, app/runtime and 248 help links.
[Source validation](../../benchmarks/results/v0-integration-source-validation.json).

Current local validation passes **384 Swift / 248 Python tests** and Ruff, plus
21 compatible/Anthropic, 12 Azure and 8 Gemini actual CLI cases. The known six
draft-return cases are now rejected. The exact source `728ef76` bundle passes
all 41 CLI cases and six-engine/neural/extras replay offline after relocation,
including poisoned Python-path/working-directory isolation, audio review and
optional MCP. All 248 bundled help links resolve. ZIP CRC, extraction, deep
signature, executable-byte identity, extracted offline CLI and license checks pass.

The candidate is `dist/v0-integration/OSpr.app`; its 396,062,164-byte ZIP is
`OSpr-v0.1.0-integration-macOS26.6.2-arm64.zip`, SHA-256
`9cbf06f32b858355f491234332b348018053a2694246dcbaf93ab12e791b9cd3`.
It is Apple Development signed for macOS 26.6.2 arm64, with weights separate.
The bundled report is the frozen source snapshot before final receipts.
[Package manifest](../../benchmarks/results/v0-integration-package.json) ·
[Portable replay](../../benchmarks/results/v0-integration-portable.json) ·
[Compatible/Anthropic CLI](../../benchmarks/results/v0-integration-bundled-rewrite.json) ·
[Azure CLI](../../benchmarks/results/v0-integration-bundled-azure.json) ·
[Gemini CLI](../../benchmarks/results/v0-integration-bundled-gemini.json).
[Completion regression](../../benchmarks/results/v0-rewrite-completion-regression.json).

[Prior source and package evidence](../../benchmarks/results/azure-refinement-source-validation.json)
records the prior source 377 Swift / 248 Python tests and its two CLI suites. That prior exact bundle passes
six-engine/neural/extras replay offline after relocation, 238 bundled source-
snapshot help links, ZIP CRC/extraction/signatures, extracted CLI and license
checks. The newer report includes final receipts absent from the bundle snapshot.
[Portable replay](../../benchmarks/results/azure-refinement-portable.json).

An isolated copy of the existing eight-record/two-audio legacy archive also
passes source 3e5b489 AppModel startup/migration, canonical record/order/config checks,
a saved-record search, an editor quit/save barrier and AppModel restart. The
copied edit preserves raw text, timing, metadata and audio links. Referenced audio
bytes and original settings/history/audio bytes are unchanged. Only sanitized
booleans/counts are published; contents, identifiers, queries and private hashes
were never published. The private test profile/hash snapshot was removed after verification; no secure-erasure claim. Native services are disabled. This is not an interactive or original-
profile upgrade, a separate-process installer test or abrupt-crash acceptance.
[Sanitized archive-copy receipt](../../benchmarks/results/v0-existing-archive-upgrade.json).

## Required work before full acceptance

1. On an unlocked Mac, exercise the latest isolated candidate's owned TextEdit and
   browser fields: cursor, selection, clipboard fallback/restoration, secure
   refusal, app/cursor switches, cancellation and slow-app acknowledgements.
2. Complete actual public-reference microphone-to-insertion, physical Fn/PTT,
   device loss/change, sustained capture and contention. An earlier older-build
   TextEdit delivery did not recognize the reference because speakers were muted.
   The existing bounded-unmute question is separate from the pending unlock.
3. Exercise current profiles, multi-file/drop, Settings/Keychain save/restart,
   retained audio/reprocessing, native recovery/failure dialogs and original-
   profile upgrade. Preserve the normal app/data while testing private copies.
4. Validate system/meeting capture permissions, stop/drain, route loss and echo;
   improve/grade speaker attribution, note relevance and fuller abstractive notes.
   Current extractive notes are deliberately labeled as such.
5. Close remaining provider streaming/account/quotas and broader translation/
   formatting/selected-edit fidelity gaps. Completed replies can still be wrong;
   lexical guards are not semantic proof.
6. Run equivalent consumer-app GUI/dictation tasks with correction cost and
   physical timing, plus controlled energy/memory/thermal measurements. Establish
   a top-three result from those data rather than from engine-only WER.
7. Finish Developer ID/notarization, installer/update/clean-Mac/older-OS acceptance.
   Mobile/sync/enterprise administration remain explicit roadmap items, not v0
   features silently marked complete.

The native tool repeatedly reports macOS locked and automatic unlock failed.
One unlock request is already pending. No new recording, playback, sound change
or QA app launch occurred for this review/isolated archive test. Full scope stays
open; no goal-completion or full-parity claim is made.
