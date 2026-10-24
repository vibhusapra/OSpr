# OSpr

Native, local-first dictation for Apple Silicon Macs. No account or usage cap.

**v0 developer preview.** The app, local engines, BYOK adapters and benchmark
harness are implemented. Interactive microphone/insertion acceptance and several
advanced parity features are still open. This is not a claim of full feature parity
or a top-three product ranking. See [progress](docs/PROGRESS.md), the
[acceptance ledger](docs/data/parity.json), and the self-contained
[research and benchmark report](docs/research.html).

[Combined v0 review](docs/architecture/v0-review.md) maps the original request to
current evidence, the 23 component PRs and remaining acceptance work. It includes
a sanitized existing-archive-copy migration/restart check and a fix for remote
rewrite completion status. The signed source `728ef76` integration candidate passes offline relocated
six-engine, all 41 bundled provider CLI and archive checks. Full parity and a
top-three result remain unproven. [Package evidence](benchmarks/results/v0-integration-package.json).

The local candidate is `dist/v0-integration/OSpr.app`; its 396,062,164-byte ZIP is
`dist/v0-integration/OSpr-v0.1.0-integration-macOS26.6.2-arm64.zip`
(SHA-256 `9cbf06f32b858355f491234332b348018053a2694246dcbaf93ab12e791b9cd3`).
Apple Development signed, macOS 26.6.2 arm64, model weights separate; native and
release acceptance remain pending. Older candidates and the normal app are preserved.

Newer experimental [local meeting summaries](docs/architecture/meeting-summaries.md)
are on `codex/meeting-summaries`: a separate pinned 9B model, structured notes,
source quotes, CLI and MCP. Structural/source validation passes 13/14 development
cases; accepted paraphrases still have known semantic errors. The preserved
integration ZIP above predates this feature. The newer source `566c637` candidate
is `dist/meeting-summaries-v0/OSpr.app`; its
`OSpr-v0.1.0-meeting-summaries-macOS26.6.2-arm64.zip` is 396,453,429 bytes
(SHA-256 `391dc41bc29c3e28b2f2178393f3529217ff3262fcce9bc1ff58ade5722a1e5b`).
[Package/source evidence](benchmarks/results/meeting-summary-source-validation.json)
passes offline engines, actual bundled CLI/MCP, provider regressions, archive and
source CI checks. Apple Development signed macOS 26.6.2 arm64; weights separate.
Native, semantic-quality and distribution acceptance remain open.

The newer `codex/local-completion` source adds a [local EOS completion gate](docs/architecture/local-completion.md)
for all text tasks. Eight actual old/new controls preserve completed output; two
valid-JSON output-limit sentinels fail safely. A verified text output limit retains
warm speech. Full source checks pass 400 Swift / 318 Python tests; both 14-case
summary replays preserve the previous outputs and known semantic failures.
The new source `0cacb1d` candidate is `dist/local-completion-v0/OSpr.app`.
Its 396,521,056-byte `OSpr-v0.1.0-local-completion-macOS26.6.2-arm64.zip`
has SHA-256 `3c640d05a3cf7a5f08eb2957f7c425ac6dbeb520c14a59250800793dde0e0d43`.
[Exact package gates](benchmarks/results/local-completion-package.json) include
offline engines, bundled warm-ASR recovery, summary CLI/MCP, provider contracts,
archive extraction and signatures. Apple Development signed macOS 26.6.2 arm64;
weights separate; native and release acceptance remain open. Earlier candidates
are preserved and predate this guard.

## Run on your Mac

The next [local model choice](docs/architecture/local-model-choice.md) source on
`codex/local-model-choice` adds experimental 9B refinement, explicit preparation,
selected-model acknowledgement and accented-spelling preservation. The 36-case
development comparison favors 9B on raw lexical checks but still finds mistakes;
4B and Off remain unchanged. Existing packages below/above predate this choice.

The current experimental preview is on `codex/local-completion` ([draft PR #26](https://github.com/vibhusapra/OSpr/pull/26)), stacked on the summary and combined-v0 reviews. `main` still contains the initial bootstrap.

Requirements: Apple Silicon, macOS 14+, Xcode 16+ / Swift 6, [uv](https://docs.astral.sh/uv/),
and roughly 3–8 GB of available memory for the selected inference configuration.
The small development build retains a checkout/runtime dependency. An optional
standalone app bundles Python and locked inference libraries. Model
weights download on first load; disk use depends on the selected models.

```sh
git clone --branch codex/local-completion https://github.com/vibhusapra/OSpr.git
cd OSpr
scripts/setup.sh
scripts/build-app.sh
open dist/OSpr.app
```

For compressed audio and video import, install FFmpeg (`brew install ffmpeg`).
`setup.sh --minimal` installs the Parakeet/Whisper/refiner path without research,
MCP or test extras. The default setup includes the MLX Audio research engines.
Install `uv` first if setup reports that it is missing.

1. In OSpr, load a model. Start with **Parakeet v3** for English/European languages.
2. Click the microphone once to grant macOS Microphone access. Accessibility
   permission is needed only for inserting into other apps.
3. Place the cursor in your destination, press **Control–Option–Space**, speak,
   then press again. Enable hold-to-talk in Settings if preferred.
4. Select another OSpr checkout in Settings if you move the repository. If a local
   engine times out, check macOS folder permissions and choose the folder again.

To build the self-contained app after setup:

```sh
scripts/bundle-app.sh
open dist/standalone/OSpr.app
```

For local development, optionally set `OSPR_SIGN_IDENTITY` to an installed Apple
Development signing identity (name or hash, listed by `security find-identity -v -p codesigning`). Both build scripts use it without recording the identity in
source. The default remains ad-hoc signing for reproducible builds without an
Apple account. Ad-hoc rebuilds change code identity and can invalidate macOS
permissions; a stable development identity avoids that rebuild churn. This does
not notarize the app or replace a Developer ID distribution workflow. If several
OSpr copies appear in macOS, use Show in Finder on its Accessibility entry to
verify that the permission belongs to the exact bundle you are running.

This app bundles a relocatable Python runtime and inference libraries (about
1.3 GB before compression), and downloads weights separately. All six engines
passed an offline smoke test after moving the bundle to a path containing spaces,
using a temporary working directory and an unrelated `PYTHONPATH`. The bundle
minimum OS follows its build host (this artifact: macOS 26.6.2); source setup on
older macOS chooses compatible wheels. Older-OS bundle acceptance is untested. This verifies
the runtime boundary, not interactive microphone/insertion behavior.

After running `benchmarks/portable_app.py`, the bundled hour-long regression
check (`PYTHONPATH=backend .venv/bin/python benchmarks/native_long.py --app dist/standalone/OSpr.app`),
all three public 80-minute loopback transport checks, and successful native/Python
test logs, create a verified delivery archive with:

```sh
.venv/bin/python benchmarks/upload_parts.py --cli dist/standalone/OSpr.app/Contents/MacOS/ospr-cli
.venv/bin/python benchmarks/upload_parts.py --cli dist/standalone/OSpr.app/Contents/MacOS/ospr-cli --provider deepgram
.venv/bin/python benchmarks/upload_parts.py --cli dist/standalone/OSpr.app/Contents/MacOS/ospr-cli --provider soniox
.venv/bin/python scripts/package-release.py --swift-log .local/swift-tests.log --python-log .local/python-tests.log
```

The packager checks the portable receipt against this exact executable, verifies
ZIP CRCs, extracts with macOS `ditto`, checks signatures before and after running
the extracted offline CLI, and writes a SHA-256 manifest. It replaces the previous
local archive only after verification succeeds. This requires the fully cached
models used by the preceding portable smoke suite; weights are never embedded.

Builds use ad-hoc signing by default; the current local preview uses an Apple Development signature. Developer ID distribution signing, notarization and an updater are not complete. Do not overwrite an existing installation
until its transcripts/settings are backed up.

Newer focused test candidates are tracked in [progress](docs/PROGRESS.md). The
Azure candidate at `dist/azure-refinement-v0/OSpr.app` is source `3fb3c1d`:
377 Swift/248 Python tests, source CI, six-engine portable checks, twelve Azure /
eight Gemini bundled CLI loopback cases and archive checks pass. It adds native
Azure v1 resource-key/deployment text refinement to the prior source features.
Live account/native/distribution gates remain open.
[Manifest and scope](docs/architecture/azure-refinement.md).

The
native Gemini candidate at `dist/gemini-refinement-v0/OSpr.app` is source
`46223b0`: 366 Swift/248 Python tests, source CI, six-engine portable checks,
eight exact bundled Gemini loopback CLI cases and archive checks pass. It adds
Gemini Settings/preset/Keychain routing and a guarded text-file CLI, alongside
the insertion setup test and delivery guard. Native/account/distribution gates
remain open; this is a separate Apple Development signed test candidate.
[Manifest and scope](docs/architecture/gemini-refinement.md).

The latest delivery with the broader long-file/transport gate set is `dist/streaming-v0/OSpr.app` and
`dist/streaming-v0/OSpr-v0.1.0-macOS26.6.2-arm64.zip`, frozen at source `3feaf65`.
It includes continuous native-rate preview normalization, steady cadence and
visible preview failure handling, plus full-audio defaults and timing bounds.
The [manifest](benchmarks/results/streaming-release-package.json) pins
310 Swift / 230 Python tests. [Exact-build gates](benchmarks/results/streaming-package-gates.json)
pass relocated/offline six-engine/neural routes, ten real native IPC stop cases,
four synthetic hour requests, three every-sample 80-minute local provider
transports, real MCP defaults, 17 CLI profile cases and ZIP CRC/extraction/signatures.
All 168 bundled help links pass; CI checks these links on future bundles.
This remains an Apple Development signed local preview, with separate weights.
Physical capture/shortcuts/insertion/devices, clean-Mac install, updater and
Developer ID/notarization acceptance remain open. The normal older app and its
history/settings are restored unchanged. Bundled help is the pre-packaging source
snapshot; the current report has final artifact receipts.

The previous checked delivery is `dist/full-audio-v0/OSpr.app` and
`dist/full-audio-v0/OSpr-v0.1.0-macOS26.6.2-arm64.zip`, frozen at source `9a51603`.
It adds full-audio defaults, empty-result recovery retention and bounded ASR
timestamps. The [manifest](benchmarks/results/full-audio-release-package.json)
pins 305 Swift / 178 Python tests; [artifact gates](benchmarks/results/full-audio-package-gates.json)
verify all six offline engines after relocation, four synthetic hour requests,
three every-sample 80-minute transports, real MCP defaults, 17 bundled CLI cases
and ZIP CRC/extraction/signatures/inventory. Source CI is green at the identical
application fingerprint; native insertion/recovery interaction, clean-Mac
installation and notarization remain open. Weights download separately. The
[noise controls](benchmarks/results/full-audio-negatives.json) preserve remaining
false positives rather than promoting a universal quality claim.

The earlier checked delivery remains `dist/neural-edges-v0/OSpr.app` and
`dist/neural-edges-v0/OSpr-v0.1.0-macOS26.6.2-arm64.zip`, frozen at source `2f7f2a8`.
It includes app/site profiles, indexed history, Soniox BYOK, mouse-start countdown,
local refinement, and separate opt-in neural auto-finish/final-edge controls.
Its [SHA-256 manifest](benchmarks/results/neural-edges-release-package.json) pins
304 Swift/141 Python tests. [Portable gates](benchmarks/results/neural-edges-package-gates.json)
include all six engines and native neural edges offline after relocation, nine
model inventories, audio review/MCP, both synthetic hour-file regressions with
and without neural edges, and all three 80-minute transports. The exact bundled
CLI passes [17 profile cases](benchmarks/results/neural-edges-bundled-cli.json).
[CI at the packaged head](benchmarks/results/neural-edges-packaged-ci.json) passes.
Quit other OSpr copies before opening a new bundle. Back up
existing settings/history before an archive upgrade; the normal older preview
remains unchanged. This is an Apple Development signed macOS 26.6.2 arm64 preview,
with separate weight downloads and native interaction gates still open. Its bundled
report is a snapshot preceding the final artifact receipts. Earlier
`context-profiles-v0` and `refinement-v0` deliveries remain available. The latest
insertion handoff stopped at the macOS lock before a recording could start;
actual microphone-to-insertion acceptance remains open.

## Included

- Native SwiftUI studio, menu bar control, floating HUD and microphone selection.
- Toggle / hold-to-talk global shortcut with a visual shortcut editor.
- A three-second mouse-start countdown gives you time to focus the destination
  field before recording. Allow microphone access first; cancel from the HUD,
  Studio or the global shortcut. Native countdown/insertion acceptance is pending;
  the latest preview includes this feature.
- Local MLX/Metal ASR: Parakeet v3, Whisper Turbo/Small, Qwen3 ASR 1.7B 8-bit,
  Nemotron 3.5 ASR 8-bit, and native-layout Cohere Transcribe 8-bit. Cohere
  supports 14 languages with an explicit hint; blank uses English. Exact revisions are in
  [models.lock.json](backend/ospr_backend/models.lock.json).
- Optional live preview: cached incremental Nemotron, or a rolling tail for other
  engines. Nemotron can flush final text from its cache; other engines finalize
  from the full recording. Native microphone streaming still needs acceptance QA.
- Verbatim/basic clean output, vocabulary hints, literal replacements/snippets,
  spoken punctuation, app/site profiles and selected-text voice editing.
  Current source adds per-profile local models, recognition language, translation
  targets and Custom instructions, with deterministic site/path matching and
  per-take snapshots. The verified `context-profiles-v0` ZIP includes these profiles;
  [native acceptance and compatibility limits](docs/architecture/context-profiles.md)
  are tracked separately.
- Optional local Qwen3 4B Instruct refinement, Ollama/compatible services, or BYOK
  compatible/Anthropic/native Gemini/Azure v1 rewriting. Refinement can change meaning; raw text is kept
  and a conservative preservation check rejects several obvious regressions.
  Local cleanup now passes the transcript as JSON-quoted data, with separate
  tasks for deliberate selection editing and extractive notes. A 36-case probe
  still required six original-text fallbacks. Refinement stays off by default;
  [raw outputs and limits](docs/architecture/refinement-fidelity.md) are published.
- Separate optional BYOK audio transcription with compatible endpoints (including
  Groq and the current OpenAI `gpt-transcribe` request contract). Oversized audio
  is normalized locally into contiguous PCM16 parts of at most ten minutes. Each
  request stays below 25 MB; timestamps are offset to the full recording. Retries
  resend all parts and may incur provider charges. No partial result is saved.
- Native Deepgram prerecorded BYOK uses Token auth, Nova-3 vocabulary keyterms,
  language detection or an explicit hint, and utterance/word timestamps. Audio is
  normalized locally before upload; automatic number formatting and paid add-on
  features are not requested. Cloud streaming and paid-account validation remain open.
- Native Soniox async BYOK uses Files/Transcriptions with `stt-async-v5`, optional
  language/vocabulary hints and conservative token-derived word times. Owned jobs
  and uploads are deleted after completion when possible; processing or ambiguous
  jobs may need console cleanup. No automatic recognition retry. [Lifecycle and
  validation limits](docs/architecture/soniox-byok.md). This is current source;
  the newer `dist/soniox-v0` preview includes Soniox; `dist/history-v0` predates it.
- File/batch import, searchable editable local history, copy/delete/retention,
  and TXT/JSON/SRT/VTT export. Subtitles use **original** transcript timing.
- Experimental local speaker-labeled imports: Nemotron 3 Diarization (up to eight
  anonymous speaker channels) with Parakeet/Whisper word timing. Keep raw ASR,
  flag overlap and export original speaker-timed subtitles. Real-meeting
  attribution errors remain substantial; labels require review.
- Optional watched-folder processing while OSpr is open: stable new files,
  persistent deduplication, retry backoff and non-overwriting TXT/JSON/SRT/VTT
  exports. Processing is local, without rewriting or auto-paste.
- Experimental desktop audio recording on macOS 15+, with an optional separate
  microphone track, local FFmpeg mixing and raw-track recovery. Video is not stored.
  Physical capture/permissions/echo acceptance is pending; use headphones.
- Local key-excerpt notes: a 4B model selects exact original quotations. Source
  references are checked; no generated paraphrases. Review context and omissions.
- A native CLI, optional stdio MCP adapter, tests and reproducible benchmarks.
- Optional Globe/Fn-only gestures (experimental). Accessibility is required; set
  the macOS Globe/Fn action to Do Nothing. Modified shortcuts remain the default.
  Fn combinations cancel the gesture, and typed content is not collected.
- Private atomic manual exports and one GUI instance per shared data folder.

- Completed-take recovery across inference failure/restart, with retry/export/discard.

**Open scope:** fully verified cross-app insertion and recovery interactions,
physical meeting/system capture acceptance, diarization quality, complete
abstractive summaries,
richer alignment and URL context,
notarized distribution, mobile/sync and enterprise administration. Cohere
Transcribe’s legacy Swift-layout conversion remains research-only after lost
utterances. A separately pinned native-layout 8-bit conversion passed the larger
quality gate and is included as a quality option.

## Models and privacy

The Models screen shows pinned download sizes and cache completeness for all six
ASR engines plus the optional refiner, diarizer and native speech detector. Download weights separately
from loading them onto Metal, watch prepared-byte progress, reveal the shared
cache in Finder, or release engine memory. Inventory is offline and weights remain
on disk when memory is released. OSpr never deletes the shared Hugging Face cache.


The default path sends no audio or text to a provider. Complete model downloads
first, then set `HF_HUB_OFFLINE=1` for an offline engine run. Weight downloads come
from Hugging Face. OSpr never silently switches to cloud inference.

Current source also exposes **Neural auto finish · experimental** in Settings.
Prepare the small Silero detector in Models, enable the setting, choose a pause
duration and save preferences. Starting dictation only checks cached data; it
does not download weights. The worker and native loader both verify the pinned
files. This detector runs locally on CPU while ASR remains on Metal; it also works
before an explicitly selected BYOK transcription route.

The detector can reuse a verified shared Hub snapshot. Downloads/repairs publish
new verified versions inside an OSpr-owned cache subdirectory, without editing
shared snapshots or immutable blobs. Superseded versions stay available to any
native model still reading them; model data is not automatically deleted.

The detector is off by default. A pause can finish a take; a detector/queue error
keeps recording and displays **stop manually**, without switching to RMS.
Final edge trimming is separate. **Neural edge trimming · experimental** optionally
uses the same pinned CPU detector on the exact normalized final-ASR samples. It
keeps interior pauses and original timestamps, checks the complete PCM hash again
in the worker, and never combines its bounds with RMS filtering. This applies to
local dictation, imports and the ASR portion of speaker-labeled imports. Cloud
uploads are unchanged. With neural edges, previews remain provisional and the
complete take gets a separate final decode. An empty detector range keeps
completed recording recovery available; **Retry without edge trimming** uses the
full recording for that attempt, without changing saved preferences.

New installations now leave both volume and neural edge trimming off so local
recognition receives the full normalized audio. Explicit saved preferences are
preserved; CLI, worker and MCP defaults also use full audio. Every empty result
retains completed recording recovery for review/retry, including a silence flag.
See [full-audio defaults and noise tradeoffs](docs/architecture/full-audio-defaults.md).
The older neural-edges-v0 and context-profiles-v0 ZIPs predate this change.
Full-audio recognition can still emit false words from noise on some models;
volume trimming did not reduce those outputs in the five synthetic controls.

Both neural options are off by default. New settings encode legacy edge trimming
and auto-stop as off while their neural counterparts are enabled, so an older
build cannot silently substitute RMS. Native controls and physical microphone
acceptance remain separate gates. The context-profiles-v0 ZIP predates both
options; see [capture evidence and remaining gates](docs/architecture/neural-endpointing.md).

**Known neural-edge quality failures:** the multilingual follow-up finds 32 new
empty outputs across 520 model/input pairs, plus partial quiet-speech deletions.
For example, quiet German Parakeet WER rises 4.10% → 22.13% with the current
detector policy. For quiet/multilingual use, keep both neural options off and
disable volume-based edge trimming to recognize the full audio while model
selection is improved. Empty results retain recovery, but a nonempty partial
transcript can still lose content. The same study exposes out-of-range Whisper
timestamps. The source now bounds those estimates and preserves the transcript,
with explicit approximate timing when alignment is unusable. All 12 observed
overruns are corrected in real old/new reproduction, with text unchanged. The
older neural-edges-v0 preview predates this fix. The current preview passes a
[native warning and JSON/SRT check](benchmarks/results/full-audio-native-timing.json)
on one public Japanese fixture; seeking and broader native acceptance remain open.
See [multilingual results](benchmarks/results/neural-edges-multilingual-v1.json)
and [independent checks](benchmarks/results/neural-edges-multilingual-v1-checks.json).

Cloud transcription sends audio; cloud refinement sends transcript text (and the
selected passage for voice editing). These are separate visible choices. API keys
use macOS Keychain; settings contain no keys. Provider use may incur charges and
has the provider's retention terms. HTTP is permitted only for loopback endpoints;
redirects do not forward credentials.

History uses an owner-only SQLite archive in `~/Library/Application Support/OSpr`. It is not
application-encrypted; use FileVault for disk protection. Legacy JSON is streamed into SQLite, checked against every complete payload and removed only after verification. Keep a private backup before upgrading this developer preview; older JSON-only builds cannot read the new archive. Capture uses temporary audio; a completed take is kept in a private recovery slot
until transcription succeeds or you explicitly discard it. Failed takes survive
restart and can be retried or exported. In-progress capture before stop is not yet
crash-recovered. No analytics or automatic screen/clipboard context
collection is included.

History edits coalesce for 300 ms on a serial background writer and flush on
orderly quit. New recording recovery is kept until saved history is confirmed.
Unreadable history is preserved until an explicit reset. Audio retention is opt-in
and keeps normalized audio without imported video or tags. The History player
supports speed control, scrubbing and original segment/word seeking; retained WAV
export is separate from transcript export. Oldest clips are evicted to fit the
budget, and history deletion/expiry removes their audio. Existing clips follow
history retention when future audio retention is turned off. An abrupt crash can lose
an unflushed edit. History loads bounded summary pages and on-demand details; literal Unicode search is debounced and runs off the UI executor. Saving-off snapshots the complete current archive in memory and clears disk content/search; enabling saving restores that session transactionally. A failed privacy or durability transition remains visible and retryable. Normal quit awaits pending edits and reports failures before allowing unsaved work to be discarded. See [storage and native acceptance](docs/architecture/indexed-history.md).

Model language coverage differs. Parakeet has 25 European languages and no
vocabulary prompting in this adapter. Whisper supports broader language coverage.
Long Parakeet imports use the direct float32 front end with bounded low-energy
chunks and independent recognizer word timing. This avoids the previous overlap
merger’s deletions in the tested long-file pipeline; it can still change accuracy
at boundaries. Natural-meeting and full source results remain available.

Long Qwen imports use bounded low-energy chunks and a fresh token budget per
chunk; reaching the budget fails instead of saving partial text. Chunk timestamps
are coarse, and cutting context can change accuracy. Exact before/after results
are retained in the long-file completeness experiment.

Qwen and Nemotron are useful alternatives, not universal accuracy winners. Do not
infer Apple Neural Engine use: the current local speech path uses **MLX/Metal GPU**.

Provider keys are scoped separately by endpoint origin and purpose in Keychain.
Switching a provider loads its own key; a send-time check blocks stale cross-origin
credentials. Older unscoped keys are left untouched; re-enter them once when upgrading.

Engine diagnostic logging is disabled by default. For a diagnostic launch, set
`OSPR_DEBUG_LOG=1`; the private `engine.log` can include file paths or model output.
Transient worker audio is private and removed on normal exit; orphaned decode
directories are cleaned on next use. Abrupt native capture recovery remains a
separate limitation. No secure-erasure guarantee is made.

## CLI and agent integration

```sh
.build/debug/ospr-cli doctor
.build/debug/ospr-cli transcribe /absolute/audio.wav parakeet-v3
.build/debug/ospr-cli benchmark /absolute/audio.wav parakeet-v3 30
.build/debug/ospr-cli meeting /absolute/meeting.wav parakeet-v3
.build/debug/ospr-cli models
.build/debug/ospr-cli download whisper-small
.build/debug/ospr-cli download speech-detector
.build/debug/ospr-cli verify-speech-detector
.build/debug/ospr-cli transcribe-neural-edges /absolute/path/audio.wav parakeet-v3
.build/debug/ospr-cli rewrite 'Um, keep every sentence and number.'
.build/debug/ospr-cli resolve-profile settings.json com.example.browser https://example.org/team
.build/debug/ospr-cli analyze-speech public-16k-mono.wav /path/to/model.mlmodelc cpu 1.2
```

For explicit Gemini cloud text refinement, configure `OSPR_REWRITE_KEY` through
your environment/secret tool, then run
`ospr-cli rewrite-gemini /path/to/transcript.txt https://generativelanguage.googleapis.com/v1beta YOUR_MODEL_ID`.
The input file is unchanged; JSON reports whether the Clean fidelity guard
accepted the rewrite or returned the original. Incomplete/blocked/provider
failures exit without partial output. This command uploads text, uses no audio
or local model, and does not imply semantic fidelity or provider-account acceptance.

`rewrite-compatible` and `rewrite-anthropic` use the same file/base/model/key
contract. Standard completion metadata is required: incomplete, refused or tool
turns retain the original instead of delivering draft text. Compatible local
services can omit the key. See [completion handling](docs/architecture/rewrite-completion.md).

`ospr-cli rewrite-azure /path/to/transcript.txt https://YOUR-RESOURCE.openai.azure.com YOUR_DEPLOYMENT`
uses an Azure resource key from `OSPR_REWRITE_KEY` with the same input-preservation
and Clean guard behavior. Configure your own resource and deployment. It supports
v1 resource-key authentication, not dated deployment URLs or Entra sign-in.

`analyze-speech` is in current source; the context-profiles-v0 ZIP predates it.
It is a research command for a supplied local Silero-compatible
Core ML model. It reports probabilities and audio-time endpoint events without
microphone capture, ASR or network access. Current source adds the opt-in native
microphone option above. The older neural-edges-v0 preview predates the safer
full-audio defaults included in full-audio-v0. See [evaluation and integration gates](docs/architecture/neural-endpointing.md).

The standalone app also includes `Contents/MacOS/ospr-cli`, which discovers its
bundled engine automatically, including through a symlink. For example:

```sh
/Applications/OSpr.app/Contents/MacOS/ospr-cli doctor
```

Development commands run from the checkout or use `OSPR_ROOT`. The native app/CLI own a serial Python
child over stdio; no local inference HTTP server is required.

Optional MCP uses the official Python SDK and stdio:

```sh
uv sync --frozen --all-extras
PYTHONPATH=backend .venv/bin/python -m ospr_backend.mcp_server
```

Point your client's stdio command at the checkout's Python, with arguments
`-m ospr_backend.mcp_server` and `PYTHONPATH=/absolute/OSpr/backend`.
Tools: `list_models`, `transcribe_file`, `rewrite_text`. No microphone, UI, clipboard
or history access is exposed. The client supplies the file/text explicitly.

## Test and benchmark

```sh
swift test
uv sync --frozen --all-extras
.venv/bin/pytest -q
.venv/bin/ruff check backend benchmarks scripts
PYTHONPATH=backend .venv/bin/python benchmarks/prepare.py
PYTHONPATH=backend HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/run.py --model parakeet-v3
python3 scripts/build-report.py
```

See [benchmark methodology](benchmarks/README.md) for corpus downloads, streaming
replay, ablations, raw results and comparison boundaries. The current runs are on
one M5 Max. They are **not** consumer-app rankings or full official leaderboard
scores. No paid cloud API call, battery-life result or independent vendor privacy
audit is claimed.

## Contributing and license

Apache 2.0 for OSpr code. Models, runtimes and datasets have their own licenses;
see [NOTICE](NOTICE). Keep core recognition, text transformation and delivery
separate. Preserve raw data, declare network routes, and include reproducible
accuracy/reliability evidence for performance changes.
