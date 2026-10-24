# Runtime footprint and Qwen frontend sensitivity

The checked `streaming-v0` archive remains unchanged. This study does not remove
Torch from production or drop a model to get a smaller runtime.

Torch-owned files account for **523,975,219 bytes of regular-file content** and
**124,925,792 compressed bytes** inside the existing 392,148,942-byte ZIP. The
archive contribution excludes ZIP headers. The study uses a temporary symlink
package tree that omits Torch's four top-level RECORD entries: `torch`,
`functorch`, `torchgen` and its distribution metadata. Other modules, the checked
Python interpreter and backend remain identical. It does not build a smaller ZIP.

The omission is real at the Python boundary: no Torch import specification,
metadata or loaded module is present in the candidate. The checked app's signature
still verifies afterward. Development dependencies and public model choices are
untouched. `mlx-whisper` declares Torch as a dependency; removing a declared
dependency requires feature evidence. The supported
[uv package omission options](https://docs.astral.sh/uv/concepts/projects/sync/#partial-installations)
also explicitly warn that partial installation can break an environment.

## Frozen checks

The smoke protocol at `b09d7ad` performs fifteen API requests per runtime:
warm/transcribe for six engines, notes, diarization and streaming. All thirty
requests pass, with eight identical text pairs and identical source excerpts.

The broader protocol/producer at `e349fa4` runs 211 requests per runtime:
202 file-transcription cases, six warm calls and three feature routes. Inputs
include twenty known English clips per model, all 52 prior original/quiet
multilingual controls and five prior nonspeech controls per model. Candidate runs
first, then baseline. Both use cached MLX weights and Metal. There are **zero API
errors across 422 requests**, including 404 file-transcription requests. Exact-zero
controls can bypass recognition; request counts are not all model-inference calls.

All 52 multilingual and all thirty nonspeech text pairs match. Source-excerpt
notes, diarization and streaming controls also match. Overall **203/204 text pairs
match**. Qwen on `1089-134686-0004` changes `Nelly` to `Nellie`; the reference uses
`NELLY`. On its twenty English clips, this raises errors from 11 to 12 out of
419 words: **2.63% → 2.86% WER**. The five other models' English metrics are
unchanged. This is a small known-input regression, not a significance test or
general accuracy ranking. Every reference/hypothesis remains published.

An independent checker reconstructs 202 normalized PCM recipes/hashes, checks
source/protocol/dependency pins, Torch absence, request IDs and text controls,
then recomputes English edit distances. Temporary WAV file hashes identify files
checked by the producer; the checker reconstructs PCM, not ephemeral WAV headers.

## Why the spelling changes

The pinned Transformers `WhisperFeatureExtractor` chooses its Torch FFT/mel path
when Torch is available and its NumPy path otherwise. MLX Qwen requests NumPy
tensors from the extractor but still uses the selected feature backend. Both paths use the same
weights, tokenizer and decoder; library presence changes preprocessing.

The follow-up diagnostic at `a201e89` holds one Qwen model resident and alternates
six calls: Torch, NumPy, SciPy F32, SciPy F32, NumPy, Torch. This is deliberately
the observed regression case, not a new accuracy corpus. Both Torch calls return
`Nelly`; both NumPy and both SciPy calls return `Nellie`. Upstream NumPy differs
from Torch by at most **1.2636185e-5** in the actual F32 input features. The SciPy
trial uses a Torch-generated Hann window constant and still differs by
1.2516975e-5; reducing this maximum does not fix the spelling.

The feature checker independently recomputes the upstream Torch/NumPy arrays,
hashes and maximum difference without loading recognizer weights. SciPy numeric
values remain producer evidence rather than an independently reimplemented FFT.
The diagnostic also observes **two identical feature extractions per request**.
The pinned Qwen single-chunk generator extracts again after the first token to
count prompt tokens. Reusing those exact features is a separate optimization
candidate; this study does not change production preprocessing or token accounting.

## Limits and next gate

Torch 2.14.1, Transformers 5.20.2 and MLX Audio 0.6.1 are pinned by the existing
lock. Installed upstream source hashes are in `runtime-footprint-source-validation.json`.
This is one paired pass with known inputs and different package paths. Raw process
RSS and final MLX peak-counter readings are exploratory; Engine resets MLX peaks
during requests, so the final counter is not a whole-study maximum. No latency,
energy, calibrated RAM, smaller-distribution or native interaction win is claimed.

The full runtime remains the default. Any replacement frontend must preserve
quality on broader controls; any duplicate-work optimization must preserve the
existing frontend exactly and validate bounded retention/error cleanup. A passing
smoke test alone is insufficient to promote either change.
