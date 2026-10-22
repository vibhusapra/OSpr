"""Build the self-contained research page from auditable repository data."""

import html
import json
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
offerings = json.loads((ROOT / "docs/data/offerings.json").read_text())
parity = json.loads((ROOT / "docs/data/parity.json").read_text())
benchmarks = []
for path in sorted((ROOT / "benchmarks/results").glob("*.json")):
    data = json.loads(path.read_text())
    if "records" not in data or "model" not in data or "summary" not in data or data.get("packet_ms"):
        continue
    benchmarks.append(
        dict(
            file=path.name,
            model=data["model"],
            summary=data["summary"],
            cold_ms=data.get("cold", {}).get("wall_ms", data.get("startup_ms")),
            rss=data.get("process_peak_rss_bytes"),
            peak_gpu=max([r.get("peak_gpu_bytes", 0) for r in data["records"]] or [0]),
            cases=len(data["records"]),
            limitations=data.get("limitations", []),
        )
    )


def esc(value):
    return html.escape(str(value))


def tag(status):
    color = (
        "good"
        if status in ["verified", "contract-tested"]
        else "warn"
        if status in ["partial", "experimental", "implemented", "in progress"]
        else "muted"
    )
    return f'<span class="tag {color}">{esc(status)}</span>'


cards = []
for product in offerings["products"]:
    plans = "".join(
        "<tr><th>" + esc(name) + "</th><td>" + esc(price) + "</td><td>" + esc(detail) + "</td></tr>"
        for name, price, detail in product["plans"]
    )
    links = " · ".join(
        f'<a href="{esc(url)}" target="_blank" rel="noreferrer">Official source {i + 1}</a>'
        for i, url in enumerate(product["sources"])
    )
    cards.append(f'''<article class="product" data-kind="{esc(product["kind"])}" data-search="{esc((" ".join([product["name"], product["difference"], product["routing"], product["notes"], *product["features"], *[" ".join(plan) for plan in product["plans"]]])).lower())}">
    <div class="row"><h3>{esc(product["name"])}</h3><span class="tag muted">{esc(product["kind"])}</span></div>
    <p class="small muted">{esc(product["platforms"])} · {esc(product["license"])}</p>
    <p>{esc(product["difference"])}</p><p class="small"><strong>Processing:</strong> {esc(product["routing"])}</p>
    <div class="scroll"><table class="plans"><thead><tr><th>Plan</th><th>Listed price</th><th>Included / limits</th></tr></thead><tbody>{plans}</tbody></table></div>
    <p class="small muted">{esc(product["notes"])}</p><p class="sources">{links}</p></article>''')
parity_rows = "".join(
    f'<tr data-status="{esc(r["status"])}"><th>{esc(r["feature"])}</th><td>{tag(r["status"])}</td><td>{esc(r["evidence"])}</td><td>{esc(r["gap"])}</td><td>{esc(r["priority"])}</td></tr>'
    for r in parity["items"]
)
optimizations = [
    (
        "Resident ASR + refiner",
        "Implemented",
        "Keep one ASR and one optional text model loaded; avoid process and model startup on each turn.",
        "Cold vs warm p50/p95 and RSS; separate first download/JIT.",
        "Native CLI, engine benchmark and paired fresh-process priming",
    ),
    (
        "One audio normalization path",
        "Implemented",
        "Decode/downmix once to contiguous float32 16 kHz; resample only when needed.",
        "16k mono vs 48k stereo, including preprocessing time and WER.",
        "Format tests; ablation harness",
    ),
    (
        "In-memory Parakeet front end",
        "Implemented",
        "Short utterances bypass temporary WAV encoding and FFmpeg spawning.",
        "Paired latency/text comparison against model.transcribe(file).",
        "Ablation harness",
    ),
    (
        "Precision by stage",
        "Implemented",
        "Float32 acoustic front end; bfloat16 Parakeet weights, fp16 Whisper, quantized Qwen/Nemotron.",
        "WER/CER, p95 and actual peak memory; reject silent drift.",
        "Quantized model runs; dtype ablation remains",
    ),
    (
        "No unnecessary second model",
        "Implemented",
        "Deterministic fillers/snippets by default; AI refinement is explicit.",
        "End-to-end latency and factual preservation with/without rewriting.",
        "Guard tests and rewrite evaluation",
    ),
    (
        "Conservative endpointing",
        "Implemented / partial",
        "RMS edge trimming and silence bypass; configurable auto-stop. No claim of neural VAD.",
        "Quiet speech deletion, silence hallucination, tail-cut rate and 150/300/500ms endpoint sweeps.",
        "Stress fixtures; device endpoint sweep pending",
    ),
    (
        "Bound capture and preview work",
        "Implemented",
        "Preallocated asynchronous disk buffers, reusable mono scratch, 10 Hz UI telemetry, fixed 12s ring, one preview in flight.",
        "Dropped frames, render callback p99, preview contention and memory ceiling.",
        "Native frame/overflow tests; device profiling pending",
    ),
    (
        "Chunked stdio and cancellation",
        "Implemented",
        "Buffered JSON replies, serial queue, request generations, watchdog and child recovery.",
        "IPC round trip, 30-way admission, timeout/restart and stale-output rate.",
        "Native IPC tests; no local server",
    ),
    (
        "True cached streaming",
        "Experimental",
        "Nemotron incremental session avoids repeatedly decoding a growing prefix.",
        "320ms packet replay, first partial, stable-prefix revisions, final tail, WER vs offline.",
        "Replay harness; microphone acceptance pending",
    ),
    (
        "Prime kernels before recording",
        "Implemented",
        "Explicit model loading decodes a one-second synthetic tone and discards the result, moving first-use kernel work before the next real turn.",
        "Three paired fresh processes per model; compare first-real latency, preparation cost and identical outputs. Work is shifted, not removed.",
        "Fresh-process warmup harness; one-clip scope",
    ),
]
optimization_rows = "".join(
    "<tr><th>"
    + str(i + 1)
    + ". "
    + esc(a)
    + "</th><td>"
    + esc(b)
    + "</td><td>"
    + esc(c)
    + "</td><td>"
    + esc(d)
    + "</td><td>"
    + esc(e)
    + "</td></tr>"
    for i, (a, b, c, d, e) in enumerate(optimizations)
)
source_links = {u for p in offerings["products"] for u in p["sources"]}
source_links.update(
    [
        "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
        "https://huggingface.co/Qwen/Qwen3-ASR-1.7B",
        "https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b",
        "https://huggingface.co/CohereLabs/cohere-transcribe-03-2026",
        "https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602",
        "https://www.openslr.org/12/",
        "https://groups.inf.ed.ac.uk/ami/corpus/",
        "https://github.com/pyannote/AMI-diarization-setup",
        "https://huggingface.co/nvidia/Nemotron-3-Diarization",
        "https://huggingface.co/datasets/google/fleurs",
        "https://developers.openai.com/api/docs/guides/speech-to-text",
    ]
)
sources = "".join(
    f'<li><a href="{esc(u)}" target="_blank" rel="noreferrer">{esc(u)}</a></li>' for u in sorted(source_links)
)
payload = json.dumps(
    dict(offerings=offerings, benchmarks=benchmarks, parity=parity), ensure_ascii=False
).replace("<", "\\u003c")


def result(name):
    return json.loads((ROOT / "benchmarks/results" / (name + ".json")).read_text())


native = result("native-ipc")
ablations = result("ablations")
rewrite = result("rewrite-fidelity")
bootstrap = result("speaker-bootstrap")
stream_rows = []
for label in ["default", "1", "0"]:
    run = result("stream-nemotron-" + label)
    score = run["summary"]["librispeech-test-clean"]
    stream_rows.append(
        f"<tr><th>{esc(run['tested_context'])}</th><td>{score['cases']}</td><td>{score['wer'] * 100:.2f}%</td><td>{score['p50_ms']:.0f} ms</td><td>{run['p50_first_partial_audio_ms']:.0f} ms of audio</td><td>{run['p50_final_flush_ms']:.1f} / {run['p95_final_flush_ms']:.1f} ms</td></tr>"
    )
ci_rows = []
for suite, run in bootstrap["suites"].items():
    for model, score in run["models"].items():
        lo, hi = score["ci95"]
        ci_rows.append(
            f"<tr><th>{esc(suite)}</th><td>{esc(model)}</td><td>{score['wer'] * 100:.2f}%</td><td>{lo * 100:.2f}–{hi * 100:.2f}%</td></tr>"
        )
direct, files = ablations["frontend"]["direct_mel"], ablations["frontend"]["file_ffmpeg"]
meeting_rows = []
for model in ["parakeet-v3", "whisper-turbo"]:
    measurements = result("ami-" + model)
    for row in measurements["records"]:
        meeting_rows.append(
            f"<tr><th>{esc(row['id'])}</th><td>{esc(model)}</td><td>{row['asr_wer'] * 100:.1f}%</td><td>{row['der_0ms']['der'] * 100:.1f}%</td><td>{row['der_250ms']['der'] * 100:.1f}%</td></tr>"
        )
meeting_panel = (
    '<h3 style="margin-top:28px">Natural meeting prefixes expose the next quality gap.</h3><p>Four preselected three-minute AMI headset-mix prefixes, not distant-mic SDM or the full AMI test set. The same local Nemotron diarizer supplies speaker turns for both ASR models. Raw recognition WER is separate from speaker DER.</p><div class="scroll"><table><thead><tr><th>Meeting prefix</th><th>ASR</th><th>WER</th><th>Speaker DER, no collar</th><th>DER, 250 ms collar</th></tr></thead><tbody>'
    + "".join(meeting_rows)
    + '</tbody></table></div><p class="score-note">Pinned BUT/pyannote only_words RTTM, 10 ms activity, best per-recording speaker permutation, overlap included. Custom transparent scorer with known-answer tests; no official full-corpus or competing-app ranking. Early broad NXT segment-bound diagnostics are preserved but are not the main reference. Overlap word order can penalize single-stream WER. Substantial misses/confusions make speaker labels experimental. <a href="../benchmarks/results/ami-parakeet-v3.json">Parakeet raw</a> · <a href="../benchmarks/results/ami-whisper-turbo.json">Whisper raw</a>.</p>'
)
warmup = result("warmup")
warmup_rows = []
for model in sorted({r["model"] for r in warmup["records"]}):
    groups = [[r for r in warmup["records"] if r["model"] == model and r["primed"] == flag] for flag in [False, True]]
    times = [statistics.median(r["first_real_ms"] for r in rows) for rows in groups]
    preparation = [statistics.median(r["prepare_ms"] for r in rows) for rows in groups]
    warmup_rows.append(f"<tr><th>{esc(model)}</th><td>{times[0]:.1f} → {times[1]:.1f} ms</td><td>{preparation[0]:.0f} → {preparation[1]:.0f} ms</td></tr>")
control = result("diarization-upstream-control")
control_rows = "".join(f"<tr><th>{esc(r['id'])}</th><td>{r['der_0ms']['der'] * 100:.1f}%</td><td>{r['der_250ms']['der'] * 100:.1f}%</td></tr>" for r in control["records"])
meeting_panel += '<details><summary>Upstream float32 control: the diarization problem is not unique to MLX 8-bit.</summary><p>Official NVIDIA checkpoint on PyTorch MPS, float32, default upstream postprocessing, same four prefixes. Similar misses remain. Timing boundaries and postprocessing differ, so this is a diagnostic control rather than a backend speed ranking.</p><div class="scroll"><table><thead><tr><th>Prefix</th><th>DER, no collar</th><th>DER, 250 ms</th></tr></thead><tbody>' + control_rows + '</tbody></table></div><p><a href="../benchmarks/results/diarization-upstream-control.json">Raw upstream control</a></p></details>'
notes = result("extractive-notes")
notes_passed = sum(r.get("critical_coverage") == 1 for r in notes["records"])
experiments = f"""<h3 style="margin-top:28px">Measured optimizations, including the ones we rejected.</h3>
<div class="grid" style="margin-top:16px"><div class="panel"><h3>The native worker boundary</h3><p><strong>{native["p50_ms"]:.1f} ms p50 / {native["p95_ms"]:.1f} ms p95</strong> across thirty warm native CLI requests on one 5.855-second public clip. Cold request {native["cold_ms"]:.0f} ms. Includes Swift → owned Python worker → model → deterministic text rules.</p><p class="small muted">Excludes microphone, endpointing, UI, rewriting and insertion. This is not complete product latency. <a href="../benchmarks/results/native-ipc.json">Raw requests</a></p></div>
<div class="panel"><h3>Avoid the file round trip</h3><p>On one short clip, twenty paired trials measured <strong>{direct["p50_ms"]:.1f} ms</strong> median for the direct Parakeet front end versus <strong>{files["p50_ms"]:.1f} ms</strong> through the file/FFmpeg path. This supports the in-memory short-turn path.</p><p class="small muted">One-clip exploratory result, not a universal speedup. RMS threshold sweeps are diagnostics; quieter speech can be deleted, and trimming remains optional. <a href="../benchmarks/results/ablations.json">Raw ablations</a></p></div></div>
<div class="scroll" style="margin-top:18px"><table><thead><tr><th>Nemotron attention context</th><th>Clips</th><th>WER</th><th>Total compute p50</th><th>First partial, median position</th><th>Final flush p50 / p95</th></tr></thead><tbody>{"".join(stream_rows)}</tbody></table></div>
<p class="score-note">320 ms packet replay, twenty clips, no wall-clock pacing. First partial is an audio position, not wall latency. Reducing context did not improve the median first partial and increased total compute; OSpr keeps the default [56, 13]. Native scheduling still needs microphone acceptance. <a href="../benchmarks/results/stream-nemotron-default.json">Default replay</a></p>
<details><summary>Speaker-cluster uncertainty: do not crown a winner from a tiny gap</summary><p class="small muted">10,000 seeded paired bootstrap trials over observed speakers, aggregate edit count / reference words. Percentile intervals cover this fixed slice, not all dictation. Overlapping intervals alone are not a paired significance test; raw paired deltas are published too.</p><div class="scroll"><table><thead><tr><th>Slice</th><th>Model</th><th>WER</th><th>95% interval</th></tr></thead><tbody>{"".join(ci_rows)}</tbody></table></div><p><a href="../benchmarks/results/speaker-bootstrap.json">Method, intervals and paired deltas</a></p></details>
<details><summary>Move first-use kernel work into explicit model loading.</summary><p>Three paired fresh processes per model on one public 5.855-second utterance. Priming decodes a one-second synthetic tone and discards its output; it shifts work earlier rather than eliminating it. All paired outputs matched. Model download is excluded. No device or full-product latency claim.</p><div class="scroll"><table><thead><tr><th>Model</th><th>First real request, unprimed → primed</th><th>Preparation cost, unprimed → primed</th></tr></thead><tbody>{"".join(warmup_rows)}</tbody></table></div><p><a href="../benchmarks/results/warmup.json">Raw fresh-process trials</a></p></details>
<div class="panel"><h3>Meeting notes that quote their source.</h3><p>A local 4B model selects numbered source excerpts; OSpr checks their exact source spans and stores a source fingerprint. It generates no paraphrased facts. All required deadline/price/negation/injection sentinels survived in {notes_passed}/4 synthetic cases. Selection can still omit context and important commitments; natural-meeting relevance is not established. This is an extractive aid, not a complete abstractive summary. <a href="../benchmarks/results/extractive-notes.json">Inputs and selected excerpts</a>.</p></div>
<div class="notice warn"><strong>Text refinement is still a fidelity risk.</strong> In twelve synthetic text cases, exact factual sentinels passed {rewrite["summary"]["rewrite"]["passed"]}/12 for Qwen3 1.7B and {rewrite["summary"]["rewrite-quality"]["passed"]}/12 for Qwen3 4B Instruct. Both failed cases. Added commentary can pass substring checks, and dictated prompt injection is a real failure in the raw outputs. Refinement defaults off; raw text and native preservation guards remain essential. <a href="../benchmarks/results/rewrite-fidelity.json">Read the complete outputs</a>.</div>
"""

page = """<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>OSpr — field guide, v0 and measured performance</title>
<style>
:root{--ink:#20202a;--muted:#666777;--accent:#5a3fbd;--line:#dedee8;--bg:#f6f5f9;--card:#fff;--green:#16634d;--orange:#925113}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}a{color:var(--accent);text-underline-offset:3px}button,input,select{font:inherit}button,select,input{border:1px solid #cac8db;border-radius:8px;padding:8px 12px;background:white;color:var(--ink)}button{cursor:pointer}button:hover{border-color:var(--accent)}:focus-visible{outline:3px solid #9179e3;outline-offset:3px}.layout{display:grid;grid-template-columns:214px minmax(0,1fr)}aside{position:sticky;top:0;height:100vh;padding:30px 22px;border-right:1px solid var(--line);background:#eeedf5;display:flex;flex-direction:column;gap:20px}.brand{font-size:28px;font-weight:750;letter-spacing:-1px}.brand span{color:var(--accent)}.eyebrow{font:11px ui-monospace,monospace;letter-spacing:1.7px;text-transform:uppercase;color:var(--accent)}nav{display:flex;flex-direction:column;gap:5px}nav a{padding:7px 0;text-decoration:none;color:#545065;font-size:13px}aside .small{margin-top:auto}main{min-width:0;padding:54px clamp(20px,4vw,66px) 80px;max-width:1600px}section{margin-bottom:64px;scroll-margin-top:25px}h1{font-size:clamp(33px,4vw,55px);line-height:1.08;letter-spacing:-2px;max-width:1000px;margin:14px 0 20px}h2{font-size:28px;letter-spacing:-.7px;margin:0 0 14px}h3{font-size:18px;letter-spacing:-.2px;margin:0}p{margin:10px 0 16px}.lede{font-size:18px;color:#555163;max-width:950px}.muted{color:var(--muted)}.small{font-size:12px}.sources{font-size:11px}.row{display:flex;gap:12px;align-items:center;justify-content:space-between}.tag{display:inline-block;border-radius:5px;padding:3px 7px;font:10px ui-monospace,monospace;white-space:nowrap;background:#edebf4}.tag.good{color:var(--green);background:#e6f2ed}.tag.warn{color:var(--orange);background:#fff0d9}.tag.muted{background:#eeedf4;color:#666}.notice{padding:18px 22px;border-left:3px solid #957bda;background:#eeebf6;border-radius:0 10px 10px 0}.notice.warn{background:#fff3e2;border-color:#d4a468}.stats{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px;margin:25px 0}.stat,.panel,.product{background:var(--card);border:1px solid var(--line);border-radius:13px;padding:22px;min-width:0}.stat strong{display:block;font-size:29px;line-height:1.3;letter-spacing:-1px}.stat small{display:block;font:10px ui-monospace,monospace;letter-spacing:1px;color:var(--muted)}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:18px}.product{margin-bottom:18px}.product h3{font-size:21px}.scroll{overflow:auto;max-width:100%;border-radius:8px;border:1px solid var(--line);background:white}table{width:100%;border-collapse:collapse;font-size:12px;text-align:left}th,td{padding:11px 13px;border-bottom:1px solid #e8e7ee;vertical-align:top}thead{background:#efedf6;color:#555062}tbody th{font-weight:600}tr:last-child>*{border-bottom:0}table.plans{min-width:570px}.controls{display:flex;flex-wrap:wrap;gap:10px;align-items:center;margin:18px 0}.controls input{min-width:220px;flex:1}.bench{min-width:780px}.parity{min-width:950px}.parity th:first-child{min-width:200px}.parity td:nth-child(3),.parity td:nth-child(4){min-width:230px}.matrix{min-width:1000px;font-size:11px}.matrix thead th{min-width:110px}.matrix tbody th{position:sticky;left:0;background:white;min-width:155px}.yes{color:var(--green);font-weight:600}.unknown{color:#a5a3af}.source-list{columns:2;column-gap:35px;padding-left:20px;font-size:11px;overflow-wrap:anywhere}.source-list li{break-inside:avoid;margin-bottom:8px}details{margin:14px 0}summary{cursor:pointer;font-weight:600}code,pre{font:12px/1.6 ui-monospace,SFMono-Regular,monospace}pre{overflow:auto;background:#22212b;color:#eeedf5;padding:18px;border-radius:9px;white-space:pre;max-width:100%}.pipeline{display:flex;align-items:stretch;gap:8px;flex-wrap:wrap;margin:20px 0}.pipeline>div{background:#edeaf5;padding:12px 15px;border-radius:9px;flex:1;min-width:130px}.pipeline b{display:block;font-size:12px}.pipeline small{font-size:11px;color:#625c75}.score-note{font-size:11px;color:#777;max-width:850px}#plot{width:100%;height:auto;display:block}.hidden{display:none!important}.actions{display:flex;gap:10px;flex-wrap:wrap}footer{border-top:1px solid var(--line);padding-top:15px;font-size:11px;color:#777}ol li,ul li{margin-bottom:7px}@media(max-width:800px){.layout{display:block}aside{position:static;height:auto;padding:18px 20px;border-right:0;border-bottom:1px solid var(--line);gap:10px}nav{flex-direction:row;flex-wrap:wrap;gap:12px}nav a{padding:0}aside .small{display:none}main{padding:30px 18px}.stats{grid-template-columns:repeat(2,minmax(0,1fr))}.grid{grid-template-columns:1fr}.source-list{columns:1}.row{align-items:flex-start;flex-wrap:wrap}.product{padding:17px}h1{letter-spacing:-1px}}@media print{aside,.controls,.actions{display:none}.layout{display:block}main{padding:0}section{break-before:auto}.scroll{overflow:visible}details>*{display:block}.product{break-inside:avoid}body{font-size:11px}}
</style><div class="layout"><aside><div><div class="brand"><span>◖</span> OSpr</div><div class="eyebrow">Open voice, measured.</div></div><nav><a href="#thesis">01 · Product direction</a><a href="#field">02 · Offerings & plans</a><a href="#matrix">03 · Feature comparison</a><a href="#bench">04 · Benchmarks</a><a href="#models">05 · Model strategy</a><a href="#parity">06 · v0 parity ledger</a><a href="#performance">07 · Ten optimizations</a><a href="#architecture">08 · Architecture</a><a href="#next">09 · Release & training</a><a href="#sources">10 · Sources</a></nav><p class="small muted">Research checked October 22, 2026.<br>Prices can change. Vendor features are claims until tested.</p></aside><main>
<section id="thesis"><div class="eyebrow">Research + implementation / October 22, 2026</div><h1>A voice tool that belongs on your Mac.</h1><p class="lede">OSpr v0 combines native dictation workflows with accelerated local speech models. The goal is ambitious: match the useful capabilities of the best tools, then win on accuracy, latency, privacy, reliability, and design.</p><div class="notice warn"><strong>Developer preview. Full union parity and a top-three product ranking are not established.</strong> The core implementation and reproducible model tests are real. Live microphone/insertion acceptance is pending because this Mac locked during the build. Consumer-app comparisons, physical desktop/microphone capture acceptance, diarization quality, notarized distribution and battery measurements remain open.</div><div class="stats"><div class="stat"><small>OFFERINGS MAPPED</small><strong>27</strong>products + runtimes</div><div class="stat"><small>PUBLIC-SOURCE APPS</small><strong>13</strong>including paid distributions</div><div class="stat"><small>STRATIFIED ENGLISH</small><strong>365 clips</strong>73 speakers · two test slices</div><div class="stat"><small>MULTILINGUAL SMOKE</small><strong>5 × 10</strong>small FLEURS language slices</div></div><div class="grid"><div class="panel"><h3>What to build around</h3><p>Local Parakeet for fast English/European dictation; Whisper and Qwen for broader coverage and quality tradeoffs. Keep a strict raw transcript, deterministic vocabulary, reliable insertion and an optional refiner.</p><p class="small muted">This is an inference from OSpr’s measurements and the models’ documented language coverage, not a universal winner declaration.</p></div><div class="panel"><h3>Where the product competition moved</h3><p>Many competitors now bundle meetings, agents, mobile, sync and organization controls. Free local dictation and BYOK are already common. A generic “Whisper plus a hotkey” is not enough differentiation.</p><p class="small muted">OSpr needs a better complete writing loop: fast start, dependable end, faithful edits, recoverable failures and no surprises about data routing.</p></div></div></section>
<section id="field"><div class="eyebrow">Official-source field guide</div><h2>Offerings, plans and the reason each matters.</h2><p>Prices below are listed public prices checked on the research date, not a checkout quote. Annual monthly equivalents are labeled. “Not established” means the reviewed sources did not answer the question. Features are vendor/project claims unless the benchmark section says otherwise.</p><div class="controls"><input id="search" type="search" aria-label="Search offerings" placeholder="Search products, processing, features…"><select id="kind" aria-label="Filter offering category"><option value="all">All categories</option><option value="commercial">Commercial</option><option value="open">Public-source applications</option><option value="framework">Frameworks / runtimes</option><option value="built-in">Built-in baseline</option></select><span id="count" class="small muted"></span></div>__CARDS__</section>
<section id="matrix"><div class="eyebrow">Capabilities, not marketing scores</div><h2>A feature map with unknowns left visible.</h2><p class="small muted">✓ = explicitly supported in the cited product/project material. — = not established in this research, not proof of absence. Plan gates are in the offering cards. This matrix is not independent verification. OSpr ◐ means partial, experimental or implemented with interaction acceptance pending; see its detailed ledger.</p><div class="controls"><select id="matrixSet" aria-label="Choose comparison group"><option value="v0">OSpr v0 against key references</option><option value="core">Core commercial references</option><option value="open">Open-source workflow references</option><option value="media">Media and meeting references</option><option value="all">All researched offerings</option></select></div><div class="scroll" id="matrixTable"></div></section>
<section id="bench"><div class="eyebrow">Observed on Apple M5 Max · 40 GPU cores · 128 GB RAM</div><h2>Measure the engine. Then measure the whole tool.</h2><p>The English test slices select the first five utterances per speaker by archive path, before inference: 200 clean clips from 40 speakers, and 165 difficult clips from 33 speakers. Separate regression fixtures cover 73 read-speech clips plus noise, quiet audio, silence and a concatenated long recording. FLEURS adds ten clips in each of Spanish, German, Hindi, Japanese and Mandarin.</p><div class="notice"><strong>Comparison boundary:</strong> these are local inference backends, not Wispr Flow, Superwhisper, Handy or other product timings. OSpr wall times include audio preparation and inference, but omit microphone capture, hotkey delivery, IPC, rewriting and insertion. whisper.cpp includes persistent-server HTTP and WAV transport. Cold starts exclude model download. No energy, thermal-isolation or end-to-end product ranking is claimed.</div><div class="controls"><select id="suite" aria-label="Benchmark suite"><option value="librispeech-test-clean">LibriSpeech test-clean slice · 200</option><option value="librispeech-test-other">LibriSpeech test-other slice · 165</option><option value="human-clean">Small regression · 73</option><option value="human-noise10db">Regression + 10 dB noise · 12</option><option value="human-quiet">Regression, volume ×0.1 · 12</option><option value="fleurs-es_419">FLEURS Spanish · 10</option><option value="fleurs-de_de">FLEURS German · 10</option><option value="fleurs-hi_in">FLEURS Hindi · 10</option><option value="fleurs-ja_jp">FLEURS Japanese · 10 · CER</option><option value="fleurs-cmn_hans_cn">FLEURS Mandarin · 10 · CER</option></select><button id="copyBench">Copy displayed results JSON</button></div><div class="panel"><svg id="plot" viewBox="0 0 860 330" role="img" aria-label="Accuracy versus warm latency scatter plot"></svg><div class="scroll"><table class="bench"><thead><tr><th>Backend / model</th><th>Cases</th><th>Error rate</th><th>Warm p50</th><th>Warm p95</th><th>RTF</th><th>Cold</th><th>Peak GPU*</th><th>Raw</th></tr></thead><tbody id="benchRows"></tbody></table></div><p class="score-note">Lower is better. WER lowercases and removes punctuation; CER also removes whitespace consistently, including character-spaced FLEURS references. Chinese/Japanese whitespace WER is not interpreted. Errors include numerals, abbreviations and spelling differences; no model-specific normalizer. *GPU allocator peak and OS process RSS are different measurements. Small score gaps do not establish significance. Timings are exploratory, with background desktop activity and no calibrated energy sampler.</p></div><details><summary>Reproduce, audit and compare consumer apps</summary><pre>scripts/setup.sh
PYTHONPATH=backend .venv/bin/python benchmarks/prepare.py
# Download official test-clean / test-other archives, then:
PYTHONPATH=backend .venv/bin/python benchmarks/prepare_librispeech.py /path/test-clean.tar.gz
PYTHONPATH=backend HF_HUB_OFFLINE=1 .venv/bin/python benchmarks/run.py \\
  --model parakeet-v3 --manifest fixtures/test-clean.json
PYTHONPATH=backend .venv/bin/python benchmarks/prepare_fleurs.py</pre><p>Pin the machine, power mode, app/model versions, corpus digest, language, hotkey and cleanup settings. Replay the same public speech through a loopback input for dictation-only apps; use equivalent file import separately. Timestamp audio start, first visible partial, speech end and final inserted text. Run cold trials and at least 30 warm repetitions. Score raw recognition separately from formatting, number/name preservation, corrections, failures, memory and energy. Record capture/endpointing delay; do not compare a decoder-only number to a product’s advertised end-to-end number.</p><p class="small muted">The protocol is ready; equivalent commercial-product runs are not complete. Do not place OSpr on a public ASR leaderboard using these partial-corpus numbers.</p></details>__EXPERIMENTS__</section>
<section id="models"><div class="eyebrow">Off the shelf now; customized later</div><h2>Use a portfolio, with explicit tradeoffs.</h2><div class="scroll"><table><thead><tr><th>Model / route</th><th>Role</th><th>Tradeoff / evidence</th><th>License / source</th></tr></thead><tbody>
<tr><th>Parakeet TDT 0.6B v3 / MLX</th><td>Default fast dictation in its 25 European languages.</td><td>Best speed in our main English runs, with competitive WER. No vocabulary prompting in this adapter. Current runtime casts weights to bfloat16; front end stays float32.</td><td>CC BY 4.0 weights; attribute NVIDIA. <a href="https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3">Model card</a></td></tr>
<tr><th>Whisper Large v3 Turbo / MLX</th><td>Broad language fallback; established vocabulary prompting.</td><td>99-language coverage and segment timestamps. Competitive Spanish/Mandarin in tiny smoke slices; those samples do not establish a global language ranking. Turbo is not the standard Whisper translation model.</td><td>MIT. <a href="https://github.com/openai/whisper">Upstream</a></td></tr>
<tr><th>Qwen3 ASR 1.7B / MLX 8-bit</th><td>Quality alternative, especially wider multilingual use.</td><td>Lowest clean-slice English WER by a small, unproven margin; slower than Parakeet. Hindi/Japanese smoke results differ from Whisper. No word-level alignment in OSpr.</td><td>Apache 2.0. <a href="https://huggingface.co/Qwen/Qwen3-ASR-1.7B">Model card</a></td></tr>
<tr><th>Nemotron 3.5 ASR 0.6B / MLX 8-bit</th><td>Cached streaming backbone and multilingual candidate.</td><td>Streaming architecture matters for first partials. Its offline difficult-English result trails Parakeet in our slice; Hindi CER is promising but only ten clips. Language prompts require locale mapping.</td><td>OpenMDW 1.1 weights. <a href="https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b">Model card</a></td></tr>
<tr><th>Cohere Transcribe 2B / MLX</th><td>Research quality candidate; not an accepted default.</td><td>Upstream publishes strong 14-language results. Tested conversions have different layouts; OSpr’s compatibility adapter passes strict weight coverage but showed unacceptable deletions in a smoke test. Must clear a quality gate before shipping.</td><td>Apache 2.0. <a href="https://huggingface.co/CohereLabs/cohere-transcribe-03-2026">Model card</a></td></tr>
<tr><th>Voxtral Mini 4B Realtime</th><td>Next streaming comparison.</td><td>13-language realtime model; latency/quality claims are upstream claims. Not run by OSpr yet. Compare against Nemotron under the same packet and finalization protocol.</td><td>Apache 2.0. <a href="https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602">Model card</a></td></tr>
<tr><th>Qwen3 4B Instruct 2507 / 4-bit</th><td>Optional local text refinement.</td><td>Selected after the 1.7B model dropped a substantive sentence. Preserve every original; guard empty output, major shortening, negations and digits. Translation/voice-edit fidelity still needs broader tests.</td><td>Apache 2.0. <a href="https://huggingface.co/mlx-community/Qwen3-4B-Instruct-2507-4bit">Pinned conversion</a></td></tr>
<tr><th>Core ML / ANE route</th><td>Next deployment/energy experiment.</td><td>WhisperKit, FluidAudio and MLX Audio Swift offer native routes. Avoid claiming ANE is faster or cheaper until profiling on each Mac. Current OSpr speech path is MLX/Metal GPU, not ANE.</td><td>Verify SDK/model licenses separately.</td></tr></tbody></table></div><p class="small muted">Exact checkpoint revisions and artifact sizes are in <a href="../backend/ospr_backend/models.lock.json">models.lock.json</a>; Python dependencies are pinned in uv.lock. Local inference works offline after complete downloads. There is no automatic cloud fallback.</p></section>
<section id="parity"><div class="eyebrow">An honest acceptance ledger</div><h2>What works, what is partial, what remains.</h2><p>“Implemented” means code exists; it does not mean the interaction passed on this locked Mac. “Contract-tested” means a local provider fixture or protocol test passed, not a successful paid vendor call. Deferred organization/mobile features are visible because competitors now include them.</p><div class="controls"><select id="parityFilter" aria-label="Filter parity status"><option value="all">All acceptance items</option><option value="open">Open / partial work</option><option value="verified">Verified or contract-tested</option></select><button id="copyTodos">Copy outstanding TODOs</button></div><div class="scroll"><table class="parity"><thead><tr><th>Capability</th><th>Status</th><th>Evidence</th><th>Remaining limitation</th><th>Priority</th></tr></thead><tbody id="parityRows">__PARITY__</tbody></table></div></section>
<section id="performance"><div class="eyebrow">Ten concrete changes and experiments</div><h2>Optimize the useful outcome.</h2><p>Accuracy, edit fidelity and insertion reliability are gates. A faster result that loses “not,” changes a price or lands in the wrong field is a regression. The table distinguishes shipped mechanisms from experiments whose benefit is still unmeasured.</p><div class="scroll"><table class="parity"><thead><tr><th>Change</th><th>State</th><th>Implementation</th><th>How to measure / reject</th><th>Evidence</th></tr></thead><tbody>__OPTIMIZATIONS__</tbody></table></div></section>
<section id="architecture"><div class="eyebrow">Native shell, replaceable engines</div><h2>Keep the hot path small and the data path obvious.</h2><div class="pipeline"><div><b>Capture</b><small>AVAudioEngine · bounded buffers · private temp WAV</small></div><div><b>Local ASR</b><small>Serial stdio worker · resident Metal models · timestamp normalization</small></div><div><b>Writing</b><small>Literal snippets → deterministic clean → optional guarded refiner</small></div><div><b>Deliver</b><small>Original app/field/cursor checks · AX or clipboard fallback</small></div></div><div class="grid"><div class="panel"><h3>Privacy boundary</h3><p>Default ASR and text rules are local. Local MLX rewriting remains local. BYOK audio and text routes are separate, visible settings; provider keys go to Keychain. HTTPS is required except loopback, redirects are rejected, and provider error bodies are not surfaced.</p><p>History uses owner-only atomic JSON files in Application Support. Capture uses private temporary audio. Completed takes are copied to an owner-only recovery slot before inference and deleted after successful transcription or explicit discard. Failed takes survive restart until retried/exported/discarded. No analytics or background content collection is included.</p><p class="small muted">No claim of application-level history encryption, enterprise compliance, or complete network sandboxing. FileVault and the chosen provider’s policies remain separate.</p></div><div class="panel"><h3>Recovery and maintainability</h3><p>The native app, CLI, MCP adapter and benchmark harness share the engine contract. Request IDs prevent response mixups; generations fence stale output; timeouts and cancellation terminate the owned worker. Raw and edited transcripts remain distinct.</p><p>Weights and package versions are pinned. The local process is replaceable with a Swift MLX/Core ML implementation after equivalent tests. No local inference HTTP service or persistent network credential is required.</p><p class="small muted">The small development build uses its checkout. An optional self-contained bundle passed moved-path/offline smoke tests for all five engines. Signing/notarization and update recovery remain release work. Completed takes now survive inference failure/restart in a private recovery slot; retry/export/discard interactions still need device acceptance.</p></div></div><details><summary>Developer setup and MCP boundary</summary><pre>scripts/setup.sh
scripts/build-app.sh
open dist/OSpr.app
.build/debug/ospr-cli doctor
.build/debug/ospr-cli transcribe /absolute/audio.wav parakeet-v3

# Optional MCP, stdio only; files/text explicitly supplied by the client:
uv sync --frozen --all-extras
PYTHONPATH=backend .venv/bin/python -m ospr_backend.mcp_server</pre><p>MCP tools expose local-file transcription, model listing and supplied-text rewriting. They do not expose microphone capture, UI control, transcript history or the user’s clipboard. Enabling that adapter in a client is a separate, deliberate installation.</p></details></section>
<section id="next"><div class="eyebrow">Close the release gates, then customize</div><h2>A path from credible v0 to a leading tool.</h2><div class="grid"><div class="panel"><h3>Release acceptance</h3><ol><li>Unlock and validate microphone permission, start/stop/PTT, device switching, interruption, HUD and failure recovery.</li><li>Exercise insertion in TextEdit, a browser, a code editor, secure fields and a moving cursor; verify clipboard restoration.</li><li>Validate the implemented native incremental stream, speaker-labeled imports, dual-track desktop capture and local excerpt notes before claiming interaction parity.</li><li>Validate the bundled app on a clean Mac; sign/notarize and exercise install/uninstall, upgrade and login item behavior.</li><li>Replay identical tasks in actual competing apps and publish raw, versioned measurements with correction effort and energy.</li></ol></div><div class="panel"><h3>Training and model surgery</h3><ol><li>Build an opt-in, consented dictation corpus: Indian/other accents, code-switching, names, paths, numbers, disfluencies, noise, silence and short turns.</li><li>Split by speaker/session/device; isolate a sealed test set. Keep public benchmark audio out of fine-tuning and model selection.</li><li>Try vocabulary/context biasing and calibration before training. Compare LoRA and targeted decoder/encoder changes against the same fidelity gates.</li><li>Distill a fast streaming student from stronger ASR teachers with explicit error review. Preserve timing, corrections, punctuation and abstention examples.</li><li>Only then prune heads/channels, quantize sensitive layers separately, distill the refiner and profile Metal/ANE kernels. Keep licenses and model/data provenance in the release.</li></ol></div></div><div class="notice"><strong>Proposed winning axis:</strong> a native, fast, trustworthy writing loop with open measurements and no account requirement. Usefulness and reliability should be obvious in a five-minute trial; model novelty alone is not the product.</div></section>
<section id="sources"><div class="eyebrow">Traceable evidence</div><h2>Source register.</h2><p class="small muted">Official pages and current upstream source were checked on October 22, 2026. The report deliberately excludes lookalike Wispr/VoiceInk domains and unsupported third-party pricing guesses. Vendor claims are not independent audits. Links may change after this snapshot; machine-readable original summaries are in docs/data/offerings.json.</p><ul class="source-list">__SOURCES__</ul></section><footer>OSpr v0 research & benchmark working artifact. Generated from repository data. No external scripts, fonts or network requests are required to read this page.</footer>
</main></div><script id="data" type="application/json">__DATA__</script><script>
const data=JSON.parse(document.getElementById('data').textContent);const $=id=>document.getElementById(id);const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function filterProducts(){let n=0;for(const p of document.querySelectorAll('.product')){const kind=$('kind').value,ok=(kind==='all'||(kind==='open'?p.dataset.kind.includes('open'):p.dataset.kind===kind))&&p.dataset.search.includes($('search').value.toLowerCase());p.classList.toggle('hidden',!ok);if(ok)n++} $('count').textContent=n+' offerings';} $('search').addEventListener('input',filterProducts);$('kind').addEventListener('change',filterProducts);filterProducts();
const groups={core:['Wispr Flow','Superwhisper','VoiceInk (Beingpax)','Aqua Voice','Spokenly','Typeless'],open:['Handy','OpenWhispr','TypeWhisper','OpenWhisp','Muesli','FluidVoice'],media:['MacWhisper','SpeechPulse','Voibe','Monologue','Vibe','Buzz']};
groups.v0=['OSpr v0','Wispr Flow','Superwhisper','VoiceInk (Beingpax)','Handy','OpenWhispr'];groups.all=['OSpr v0',...data.offerings.products.map(p=>p.name)];const osprProduct={name:'OSpr v0',features:['dictation','local_asr','local_llm','byok_asr','byok_llm','custom_endpoints','live_partials','dictionary','snippets','modes','app_profiles','selection_edit','file_import','batch','subtitles','history','cli','mcp','auto_stop','speakers','watch_folders','meetings'],pendingFeatures:['dictation','local_llm','live_partials','modes','selection_edit','file_import','batch','history','auto_stop','speakers','watch_folders','meetings']};
const featureNames={dictation:'System-wide dictation',local_asr:'Local ASR',local_llm:'Local text model',byok_asr:'BYOK recognition',byok_llm:'BYOK rewriting',custom_endpoints:'Custom endpoints',live_partials:'Live partials',dictionary:'Vocabulary',snippets:'Snippets/replacements',modes:'Writing modes',app_profiles:'Per-app behavior',screen_context:'Screen/context features',selection_edit:'Selection editing',file_import:'File import',batch:'Batch files',subtitles:'Subtitle export',history:'Transcript history',meetings:'Meeting workflow',speakers:'Speaker labels',mcp:'MCP/agent bridge',cli:'CLI/API',sync:'Device sync',teams:'Team features',sso:'SSO/SAML',scim:'SCIM',privacy_controls:'Organization privacy',watch_folders:'Watched folders',lan_offload:'LAN offload',auto_stop:'Automatic endpointing'};
function matrix(){let products=groups[$('matrixSet').value].map(n=>n==='OSpr v0'?osprProduct:data.offerings.products.find(p=>p.name===n));$('matrixTable').innerHTML='<table class="matrix"><thead><tr><th>Capability</th>'+products.map(p=>'<th>'+esc(p.name)+'</th>').join('')+'</tr></thead><tbody>'+Object.entries(featureNames).map(([key,name])=>'<tr><th>'+esc(name)+'</th>'+products.map(p=>p.features.includes(key)?(p.pendingFeatures?.includes(key)?'<td title="OSpr partial/experimental; acceptance pending">◐</td>':'<td class="yes" title="Documented project/vendor capability; OSpr code/contract evidence in ledger">✓</td>'):'<td class="unknown" title="Not established in checked sources">—</td>').join('')+'</tr>').join('')+'</tbody></table>'} $('matrixSet').addEventListener('change',matrix);matrix();
let displayed=[];function bench(){const suite=$('suite').value,cer=suite.includes('ja_jp')||suite.includes('cmn_hans');let candidates=data.benchmarks.filter(b=>b.summary[suite]);let best=new Map();for(const b of candidates){let prior=best.get(b.model);if(!prior||b.cases>prior.cases)best.set(b.model,b)}displayed=[...best.values()].map(b=>({...b,score:b.summary[suite]})).filter(b=>b.score.cases===(suite==='librispeech-test-clean'?200:suite==='librispeech-test-other'?165:suite==='human-clean'?73:suite.startsWith('human-')?12:10)&&!b.model.includes('cohere')).sort((a,b)=>a.score.p50_ms-b.score.p50_ms);$('benchRows').innerHTML=displayed.map(b=>{let s=b.score,e=cer?s.cer:s.wer;return '<tr><th>'+esc(b.model)+(b.model.includes('cohere')?' <span class="tag warn">research</span>':'')+'</th><td>'+s.cases+'</td><td>'+(e==null?'—':(e*100).toFixed(2)+'% '+(cer?'CER':'WER'))+'</td><td>'+s.p50_ms.toFixed(0)+' ms</td><td>'+s.p95_ms.toFixed(0)+' ms</td><td>'+s.aggregate_rtf.toFixed(3)+'</td><td>'+(b.cold_ms==null?'—':(b.cold_ms/1000).toFixed(2)+' s')+'</td><td>'+(b.peak_gpu?(b.peak_gpu/1e9).toFixed(2)+' GB':'—')+'</td><td><a href="../benchmarks/results/'+encodeURIComponent(b.file)+'">JSON</a></td></tr>'}).join('');plot(cer);}
function plot(cer){let rows=displayed.filter(b=>(cer?b.score.cer:b.score.wer)!=null),xmax=Math.max(300,...rows.map(b=>b.score.p50_ms))*1.15,ymax=Math.max(0.04,...rows.map(b=>cer?b.score.cer:b.score.wer))*1.2,colors=['#6143bd','#188569','#d0802e','#3280a8','#c04c81','#69717b'];let s='<rect width="860" height="330" fill="white"/><text x="68" y="22" font-size="12" fill="#666">'+(cer?'Character':'Word')+' error rate ↓</text>';for(let i=0;i<=4;i++){let y=270-i*55;s+='<line x1="68" x2="820" y1="'+y+'" y2="'+y+'" stroke="#eeecf4"/><text x="55" y="'+(y+4)+'" text-anchor="end" font-size="10" fill="#777">'+(ymax*i/4*100).toFixed(1)+'%</text>'}for(let i=0;i<=4;i++){let x=68+i*188;s+='<text x="'+x+'" y="290" text-anchor="middle" font-size="10" fill="#777">'+(xmax*i/4).toFixed(0)+'</text>'}s+='<text x="820" y="315" text-anchor="end" font-size="11" fill="#666">Warm audio → text p50 (milliseconds) →</text>';rows.forEach((b,i)=>{let x=68+b.score.p50_ms/xmax*752,y=270-(cer?b.score.cer:b.score.wer)/ymax*220;s+='<circle cx="'+x+'" cy="'+y+'" r="6" fill="'+colors[i%colors.length]+'"><title>'+esc(b.model)+'</title></circle><text x="'+Math.min(x+10,740)+'" y="'+(y-8-(i%2)*2)+'" font-size="10" fill="'+colors[i%colors.length]+'">'+esc(b.model.replace('whisper.cpp Large v3 Turbo FP16','whisper.cpp Turbo'))+'</text>'});$('plot').innerHTML=s;}
$('suite').addEventListener('change',bench);bench();function filterParity(){let f=$('parityFilter').value;for(let r of $('parityRows').rows){let verified=['verified','contract-tested'].includes(r.dataset.status);r.classList.toggle('hidden',f==='verified'?!verified:f==='open'?verified:false)}}$('parityFilter').addEventListener('change',filterParity);
async function copy(text,button){try{await navigator.clipboard.writeText(text);let prior=button.textContent;button.textContent='Copied';setTimeout(()=>button.textContent=prior,1500)}catch{const area=document.createElement('textarea');area.value=text;document.body.append(area);area.select();document.execCommand('copy');area.remove();button.textContent='Copied'}}$('copyBench').addEventListener('click',()=>copy(JSON.stringify({suite:$('suite').value,results:displayed},null,2),$('copyBench')));$('copyTodos').addEventListener('click',()=>copy(data.parity.items.filter(r=>!['verified','contract-tested'].includes(r.status)).map(r=>'- [ ] '+r.priority+' '+r.feature+' — '+r.gap).join('\\n'),$('copyTodos')));
</script></html>"""
for token, value in {
    "__CARDS__": "".join(cards),
    "__PARITY__": parity_rows,
    "__OPTIMIZATIONS__": optimization_rows,
    "__SOURCES__": sources,
    "__EXPERIMENTS__": experiments + meeting_panel,
    "__DATA__": payload,
}.items():
    page = page.replace(token, value)
(ROOT / "docs/research.html").write_text(page)
print(f"Built docs/research.html · {len(page.encode()) / 1024:.0f} KiB")
