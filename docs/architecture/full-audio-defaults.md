# Full-audio defaults and empty-result recovery

The known multilingual study exposed deletions from neural edges; earlier quiet
English evaluation also found severe deletion from the RMS gate. Neither filter
is a safe default for preserving dictated content.

New or missing native settings now leave RMS and neural edge trimming off.
Explicit stored choices remain intact, including the independent RMS preference
saved while neural edges are enabled. CLI requests, worker requests and direct
Python/MCP calls also default to the full normalized waveform. This does not
change provider uploads, model choice, language hints or audio normalization.

An exact-zero normalized waveform bypasses model loading. This is a statement
about model input, not proof that the original recording contained no speech:
for example, stereo downmix can cancel opposite-phase channels. Nonzero input
below a volume threshold still reaches ASR unless a filter was explicitly chosen.
The existing minimum of 320 samples (20 ms) remains. Empty responses distinguish
normalized zeros, too-short audio, volume-filter abstention and neural abstention.

Every empty result now leaves completed recording recovery available in the app,
including results labeled silence. Imports keep their source files. The user can
review, retry without filtering or explicitly discard the recovery; background
cleanup no longer treats a silence flag as successful transcription. A nonempty
partial transcript can still omit content: this change does not establish ASR
fidelity or make either optional filter safe.

Validation includes real waveform forwarding at three low amplitudes, exact-zero
model bypass, strict worker boolean validation, explicit opt-in RMS abstention,
settings compatibility and the existing complete test suites. The fixed real-ASR
check uses source 000 in each supported language from the prior multilingual
study, original and 40 dB attenuation, on all six models (52 requests). This is a
known-input regression check against frozen full-audio text, not new held-out
quality evidence. Native recovery interaction and cross-app insertion remain
separate acceptance gates. The older neural-edges-v0 and context-profiles-v0 ZIPs
predate this change; later packages identify their source in build-info.json.

## Noise tradeoff

The paired bundled check runs the same five previously used synthetic nonspeech
fixtures through the default route and explicit RMS filtering for all six models
(60 requests, 48 actual recognitions; exact-zero input bypasses both routes).
False-positive counts are identical between these routes: Parakeet 0/5, Cohere
0/5, Nemotron 0/5, Whisper Turbo 4/5, Whisper Small 1/5 and Qwen 2/5. These raw
hypotheses are preserved in `full-audio-negatives.json`. RMS is not an effective
nonspeech guard on this narrow set. Full audio is a quiet-content preservation
choice, not a general hallucination fix; five synthetic inputs cannot establish
a real-world false-positive rate. The earlier neural gate rejects these controls
but loses quiet multilingual speech, so it remains optional.

All 52 fixed multilingual default requests match prior full-audio text. Two real
bundled MCP requests also preserve full audio and match the original and quiet
German controls. Source CI passes 305 Swift / 178 Python tests and 17 profile CLI
cases, including clean-runner bundled imports. See the separate source, MCP,
nonspeech and package receipts for their exact build boundaries.
