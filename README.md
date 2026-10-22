# OSpr

Native, local-first dictation for Apple Silicon Macs. No account or usage cap.

**v0 developer preview.** The app, local engines, BYOK adapters and benchmark
harness are implemented. Interactive microphone/insertion acceptance and several
advanced parity features are still open. This is not a claim of full feature parity
or a top-three product ranking. See [progress](docs/PROGRESS.md), the
[acceptance ledger](docs/data/parity.json), and the self-contained
[research and benchmark report](docs/research.html).

## Run on your Mac

Requirements: Apple Silicon, macOS 14+, Xcode 16+ / Swift 6, [uv](https://docs.astral.sh/uv/),
and roughly 3–8 GB of available memory for the selected inference configuration.
The small development build retains a checkout/runtime dependency. An optional
standalone app bundles Python and locked inference libraries. Model
weights download on first load; disk use depends on the selected models.

```sh
git clone https://github.com/vibhusapra/OSpr.git
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

This app bundles a relocatable Python runtime and inference libraries (about
1.3 GB before compression), and downloads weights separately. All five engines
passed an offline smoke test after moving the bundle to a path containing spaces,
using a temporary working directory and an unrelated `PYTHONPATH`. The bundle
minimum OS follows its build host (this artifact: macOS 26.6.2); source setup on
older macOS chooses compatible wheels. Older-OS bundle acceptance is untested. This verifies
the runtime boundary, not interactive microphone/insertion behavior.

Builds are ad-hoc signed. Distribution signing, notarization and an updater are not complete. Do not overwrite an existing installation
until its transcripts/settings are backed up.

## Included

- Native SwiftUI studio, menu bar control, floating HUD and microphone selection.
- Toggle / hold-to-talk global shortcut with a visual shortcut editor.
- Local MLX/Metal ASR: Parakeet v3, Whisper Turbo/Small, Qwen3 ASR 1.7B 8-bit,
  Nemotron 3.5 ASR 8-bit, and native-layout Cohere Transcribe 8-bit. Cohere
  supports 14 languages with an explicit hint; blank uses English. Exact revisions are in
  [models.lock.json](backend/ospr_backend/models.lock.json).
- Optional live preview: cached incremental Nemotron, or a rolling tail for other
  engines. Nemotron can flush final text from its cache; other engines finalize
  from the full recording. Native microphone streaming still needs acceptance QA.
- Verbatim/basic clean output, vocabulary hints, literal replacements/snippets,
  spoken punctuation, app-specific modes and selected-text voice editing.
- Optional local Qwen3 4B Instruct refinement, Ollama/compatible services, or BYOK
  compatible/Anthropic rewriting. Refinement can change meaning; raw text is kept
  and a conservative preservation check rejects several obvious regressions.
- Separate optional BYOK audio transcription with compatible endpoints (including
  Groq and the current OpenAI `gpt-transcribe` request contract).
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

The default path sends no audio or text to a provider. Complete model downloads
first, then set `HF_HUB_OFFLINE=1` for an offline engine run. Weight downloads come
from Hugging Face. OSpr never silently switches to cloud inference.

Cloud transcription sends audio; cloud refinement sends transcript text (and the
selected passage for voice editing). These are separate visible choices. API keys
use macOS Keychain; settings contain no keys. Provider use may incur charges and
has the provider's retention terms. HTTP is permitted only for loopback endpoints;
redirects do not forward credentials.

History is owner-only JSON in `~/Library/Application Support/OSpr`. It is not
application-encrypted; use FileVault for disk protection. Capture uses temporary audio; a completed take is kept in a private recovery slot
until transcription succeeds or you explicitly discard it. Failed takes survive
restart and can be retried or exported. In-progress capture before stop is not yet
crash-recovered. No analytics or automatic screen/clipboard context
collection is included.

Model language coverage differs. Parakeet has 25 European languages and no
vocabulary prompting in this adapter. Whisper supports broader language coverage.
Qwen and Nemotron are useful alternatives, not universal accuracy winners. Do not
infer Apple Neural Engine use: the current local speech path uses **MLX/Metal GPU**.

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
.build/debug/ospr-cli rewrite 'Um, keep every sentence and number.'
```

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
