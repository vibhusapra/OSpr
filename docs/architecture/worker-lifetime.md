# Native worker and decoder lifetime

A native owner could previously disappear while Python was inside synchronous
inference. The production loop notices stdin EOF only between requests. App
shutdown, task cancellation and timeouts sent TERM to the worker group, but a
crashed owner cannot run that cleanup. Escalation also depended on the leader
remaining alive, potentially missing a decoder that outlived it.

## Ownership and admission

`ospr-worker-guardian` is a separate native executable. Its only arguments are
owner and worker PIDs. It validates its actual parent, matching user, direct
worker parent and an independent worker process group. It receives no audio,
text, API keys or inherited environment. Its working directory is `/`.

Two Dispatch process sources observe owner and worker exit. The helper emits
`READY` on a separate pipe only after both registration handlers have run and
identities have been rechecked. WorkerClient admits its boot ping and subsequent
inference only after that handshake. Startup is bounded by the shortest of the
request deadline, startup deadline and five seconds. A missing, failed or hung
helper fails with a rebuild/reinstall error. Guardian loss interrupts an active
request independently of the serial read queue; a subsequent request starts a
protected replacement. A healthy warm worker keeps its existing guardian.

On either exit, the guardian snapshots the owned group, sends TERM, waits one
second and escalates surviving identities to KILL even if the leader has exited.
Each signal rechecks UID and microsecond process-start identity. A surviving
original group member anchors a second snapshot for late descendants. Escalation
never sends a delayed signal to a bare process-group number. Enumeration failure
still stops the verified leader. Ordinary WorkerClient cancellation uses the
same cleanup implementation. The helper exits after cleanup.

These are kernel exit notifications, with no idle polling loop or Python thread.
Apple documents [process sources](https://developer.apple.com/documentation/dispatch/dispatchsource/makeprocesssource(identifier:eventmask:queue:))
and [registration handlers](https://developer.apple.com/documentation/dispatch/dispatchsourceprotocol/setregistrationhandler(handler:)).
The negative control calls C `sleep` through `ctypes.PyDLL`, which retains the
GIL; [Python's documentation](https://docs.python.org/3.12/library/ctypes.html#ctypes.PyDLL)
explains this distinction. A Python observer thread cannot be relied on to run
through that call. The guardian has an independent interpreter-free process.

## Packaging and embedding

Both app executables and development CLI discover the adjacent
`ospr-worker-guardian`, resolving executable symlinks. XCTest discovers its
sibling in the current build directory. `scripts/build-app.sh` copies the helper
alongside `dist/ospr-cli` and into `Contents/MacOS`, signs the app and verifies the
helper signature. Standalone bundling carries it forward with the whole app.
Applications embedding Core elsewhere can pass an explicit `guardianExecutable`
URL to WorkerClient. Copying the CLI alone is insufficient.

Python's standalone stdio protocol is unchanged. Finite stdin remains valid:
`echo '{"action":"ping"}' | python -m ospr_backend.worker` still replies before
exiting. No generic stdin-HUP detector was introduced.

## Reproduction and evidence

Eight new permanent tests cover group membership and escalation after leader
exit; worker-first exit; rejection of invalid/unowned targets; missing helper;
hung-helper recovery; short total handshake deadline; guardian crash while warm;
and guardian crash during an admitted blocked request. Existing worker protocol,
progress, cancellation, typed-rejection residency and timeout tests still pass.
Local complete debug and optimized suites pass **493 Swift** tests; **380 Python**
tests and Ruff pass. The final optimized suite includes the leader fallback.

From a checkout with locked dependencies installed:

```sh
python3 benchmarks/worker_lifetime.py \
  --python "$PWD/.venv/bin/python" \
  --output .local/new-worker-lifetime
```

For the retained before/after control, add
`--baseline-ref fe6f0b33c4c2b797f94f5b2f85e2ffdb8259ea87`.
To include cached Parakeet, add `--real-audio /absolute/public-mono-pcm.wav`.
The runner refuses existing directories, builds fresh optimized binaries, binds
source/binary/runner/lock hashes, freezes the protocol before launching cases,
retains failures and checks the application fingerprint again afterward. It
only kills its owned owner/worker/decoder fixtures. The original audio is read;
the repeated hour-long WAV is written into the new output directory.

The final control runs **baseline / candidate / candidate / baseline**. Every
GIL-held case uses an exact copy of the production Python main with an injected
blocking dispatch and a same-group decoder that ignores TERM. Both baseline
workers and decoders remain alive after the declared 2.5-second observation;
both candidate workers and decoders stop without harness intervention. Verified
baseline processes are then stopped separately as test cleanup.

A candidate enters real cached Parakeet generation on an hour of repeated public
speech. Its owner is killed 200 ms after generation entry, while the request is
still live. The worker stops within the same observation window. Fresh baseline
and candidate processes then transcribe the original public clip and match text,
segments, language, model and audio duration exactly. This is recognition recovery
on one fixture, not broad acoustic/semantic acceptance or proof of the GPU's
precise execution state at the instant of the kill.

Four processes also perform one cold plus five warm pings each. Final baseline
cold observations are 298 and 242 ms; candidate observations are 228 and 330 ms.
Warm pings are approximately 0.06–0.13 ms. These two samples per kind cannot
establish speed, equivalence, isolated p95 or a product ranking. Three diagnostic
helper snapshots are **7,776 KiB RSS** each; these are not peak memory or energy
measurements. The guardian adds one native process per resident worker.

The durable-import crash runner now observes production cleanup before any
harness fallback. Failure to stop the interrupted batch worker fails that gate.
Its separate resumed/verified/privacy stages continue to check stable result IDs
and payloads. Earlier manual-cleanup receipts remain historical evidence.

See [manifest and all attempts](../../benchmarks/results/worker-lifetime.json),
[final source-bound control](../../benchmarks/results/worker-lifetime-control-03.json)
and [benchmark runner](../../benchmarks/worker_lifetime.py).

## Boundaries and remaining work

The guard covers the managed worker and same-group decoder descendants. A child
that deliberately detaches into another session is outside this contract.
Simultaneously killing both the owner and guardian is also outside it. macOS PID
identity checks are separate syscalls, not an atomic pidfd-style signal API.
No transcript quality algorithm, inference timeout, model or language policy
changes here. No native GUI, microphone, physical shortcut or destination
insertion acceptance follows from these process controls.

The preserved standalone archives predate this change. The local app is a signed
checkout-dependent development build; clean-runner standalone/older macOS,
notarization, clean-Mac install and full release qualification remain separate.
TextEdit testing remains pending because the fresh native check reported a locked
Mac. This does not establish feature completeness, top-three performance, power
savings or all-device reliability.
