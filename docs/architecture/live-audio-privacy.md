# Live audio retention and active temporary copies

Keep audio is permission to create review copies for new results. A writing-mode
or batch-settings snapshot must not override a later privacy change. Previously
published History clips continue to follow retention and explicit removal;
unresolved recording recovery remains a separate, visible policy.

## Admission, revocation and publication

Each transcription captures an audio-retention epoch. Switching Keep audio or
History off advances it. A later re-enable cannot restore permission for the
already-revoked take; a genuinely new take can use the new preference. Work
admitted with retention off cannot gain it retroactively.

Audio preparation requires the admitted configuration, current Keep audio and
History flags, active History saving and the same epoch. The app rechecks after
awaited review preparation and again when attaching audio to the new History
record. A revoked preparation is discarded and recognition continues on the
original. A copy already used by inference remains a temporary leased input;
without a History reference its lease completion deletes it. All normal and
raw-text fallback paths apply the same publication check.

The prepare/adopt budget is capped by both captured and current validated
settings. Later budget changes during an already leased inference retain the
existing maintenance/error-and-retry behavior; this change does not establish a
new quota policy. No model, generation limit, provider route, language or text
processing policy changes.

Failed selection-edit rewrites also forward the successful History-storage
acknowledgement. The raw fallback remains saved and the batch no longer reports
that successful commit as unacknowledged.

## Temporary-file lifetime

The audio archive tracks staging outputs, reprocessing copies and compressed
upload snapshots in an in-memory set. Preference reconciliation preserves those
active copies. Adoption or explicit discard releases the reservation; failures
and cancellation clean their owned paths. A fresh actor after restart has no
old reservations and prunes abandoned copies. Explicit Erase retained audio
still removes owned temporary copies. Unrelated files and original sources are
preserved.

A real control also exposed a pre-existing directory-URL hint problem: owned
staging could be rejected because its parent URL had a trailing slash and the
stored directory URL did not. Temporary directories using a different URL form
had hidden the failure. Parent checks now compare the standardized filesystem
path and file-URL authority rather than directory-hint equality. Local-file,
UUID-name, root/child-symlink and path-escape checks remain. A package-build-path
regression test exercises the failing form; a symbolic-root control still fails
safely. This is not an atomic filesystem-descriptor security guarantee.

## Verification

Fourteen new permanent tests cover nine AppModel workflow cases and five archive
cases. Controlled IPC gates pause actual request admission, without depending on
short sleeps to change settings at the intended stage. They check:

- Disabling retention during inference removes audio from that result and a later
  unstarted batch file, while old saved payload/audio bytes stay identical.
- Off/on does not resurrect an already revoked take; a new take can retain audio.
  Turning retention on cannot retroactively archive work admitted with it off.
- Preference saves preserve an active preparation; revocation resumes from the
  original without turning the privacy choice into a recognition warning.
- History off preserves session text without new audio or a database record.
  Recognition failure and cancellation release unpublished copies. Failed Clean
  and selection-edit refinements preserve raw text, drop revoked review audio
  and correctly acknowledge successful storage.
- Live staging/reprocessing/upload reservations survive maintenance, expire on
  restart and can still be explicitly erased. Directory hints do not reject an
  owned path, and symbolic roots remain rejected.

The initial red privacy cohort records twelve failures across nine tests,
including cleanup waits observing unexpected retained copies. The initial archive cohort
records three missing-file failures. A separate path regression fails before the
path correction, and a raw-fallback acknowledgement assertion fails before its
fix. These development failures remain retained. One optimized run also exposed
an existing guardian test that reused a 200 ms startup limit for valid cold
Python recovery. Its hung-handshake request remains bounded at 200 ms; the next
healthy recovery now gets a separate five-second request/startup budget. Production
worker deadlines are unchanged.

The real control uses cached Parakeet and three copies of one public LibriSpeech
clip. It first stores a normal clip. The next batch is gated after real review
preparation/adoption, immediately before its second model generation call. The
headless app saves Keep audio off while that request is pending, releases the
gate, and checks that both new transcripts omit audio and match prior text/raw
text/segments/model/duration. The old full encoded transcript and audio bytes
remain identical. A second process verifies three records and only the one old
audio file after restart. Every copied backend source/data file is hashed against
the checkout; the original public WAV remains unchanged. The final control also
checks the worker's MLX GPU device.

This gate is deliberately **before generation**, not proof of a precise
mid-kernel GPU state or a physical microphone interaction. One repeated public
clip cannot establish representative acoustic quality, energy, latency or a
consumer ranking. No native UI, playback, cloud account or permission change is
involved. The first real attempt exposed the URL problem and is retained; later
controls must not be substituted for that failed observation.

Use a nonempty mono clip of at most 30 seconds: the control deliberately
requires one generation call per import and rejects unsupported input before
building/loading a model. This is a harness constraint; product long-file support
is unchanged. From a checkout with cached Parakeet and the locked runtime:

```sh
.venv/bin/python benchmarks/live_audio_privacy.py \
  --python "$PWD/.venv/bin/python" \
  --audio /absolute/public-mono-pcm.wav \
  --output .local/new-live-audio-privacy
```

The runner refuses existing output and temporary-probe paths, builds fresh test
bytes, binds source/runner/probe/runtime-lock hashes, uses offline model loading,
checks the original input and copied backend again afterward, and removes its
owned temporary test source. Separate exercise/restart logs remain in that output
directory. No existing profile is used.

The source change is newer than the preserved standalone archives. Native
settings interaction, clean-Mac/older-OS acceptance and the next signed standalone
preview remain release work. The synthetic and headless real controls establish
these scoped storage/privacy behaviors, not full v0 parity.

[Manifest/all attempts](../../benchmarks/results/live-audio-privacy.json) ·
[Final clean-source GPU control](../../benchmarks/results/live-audio-privacy-real-03.json).
