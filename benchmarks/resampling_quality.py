"""Frozen CoreAudio quality/cost/ASR study; no physical capture or default change."""

import argparse
from collections import defaultdict
import datetime
import gzip
import hashlib
import json
from pathlib import Path
import subprocess

import jiwer
import numpy as np
from scipy.signal import resample_poly
import soundfile as sf

from ospr_backend.engine import Engine
from run import normalize

ROOT = Path(__file__).resolve().parents[1]
PROTOCOL = ROOT / "benchmarks/fixtures/resampling-quality-protocol.json"


def sha(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def pcmsha(values):
    return hashlib.sha256(values.astype("<f4").tobytes()).hexdigest()


def score(reference, hypothesis):
    reference, hypothesis = normalize(reference), normalize(hypothesis)
    words = jiwer.process_words(reference, hypothesis)
    chars = jiwer.process_characters("".join(reference.split()), "".join(hypothesis.split()))
    return dict(
        reference=reference,
        hypothesis=hypothesis,
        words=len(reference.split()),
        word_errors=words.substitutions + words.deletions + words.insertions,
        characters=len("".join(reference.split())),
        character_errors=chars.substitutions + chars.deletions + chars.insertions,
    )


def summarize(protocol, traces):
    gates = protocol["gates"]
    rows = []
    for policy in protocol["policies"]:
        fidelity, costs, first_output, passband, alias, continuity = {}, {}, {}, [], [], []
        for rate in protocol["rates"]:
            speech = [
                r
                for r in traces["audio"]
                if r["policy"] == policy
                and r["rate"] == rate
                and r["case"]["suite"].startswith("librispeech")
            ]
            fidelity[str(rate)] = float(np.median([r["relative_rms_error"] for r in speech]))
            diagnostic = next(r for r in traces["cost"] if r["policy"] == policy and r["rate"] == rate)
            durations = [cost for trial in diagnostic["native"]["trials"] for cost in trial["process_ms"]]
            costs[str(rate)] = dict(
                p50_ms=float(np.quantile(durations, 0.5)), p95_ms=float(np.quantile(durations, 0.95))
            )
            first_output[str(rate)] = max(
                trial["first_output_input_frames"] / rate * 1000 for trial in diagnostic["native"]["trials"]
            )
            continuity.append(
                next(
                    r["identical"]
                    for r in traces["continuity"]
                    if r["policy"] == policy and r["rate"] == rate
                )
            )
        for row in traces["signals"]:
            if row["policy"] == policy:
                (passband if row["band"] == "passband" else alias).append(row["gain_db"])
        aggregates = defaultdict(lambda: dict(word_errors=0, words=0, character_errors=0, characters=0))
        new_empty = new_nonspeech = worst_case = regressed = improved = 0
        for row in traces["audio"]:
            if row["policy"] != policy:
                continue
            baseline = next(
                r
                for r in traces["audio"]
                if r["policy"] == "system-default"
                and r["rate"] == row["rate"]
                and r["case"]["id"] == row["case"]["id"]
            )
            for model in protocol["models"]:
                actual, before = row["asr"][model], baseline["asr"][model]
                if row["case"]["expected_speech"]:
                    key = model + ":" + row["case"]["language"] + ":" + str(row["rate"])
                    for metric in aggregates[key]:
                        aggregates[key][metric] += actual["score"][metric]
                    delta = actual["score"]["word_errors"] - before["score"]["word_errors"]
                    worst_case = max(worst_case, delta)
                    regressed += delta > 0
                    improved += delta < 0
                    new_empty += (
                        bool(before["response"]["text"].strip()) and not actual["response"]["text"].strip()
                    )
                else:
                    new_nonspeech += not baseline["asr"][model]["response"]["text"].strip() and bool(
                        actual["response"]["text"].strip()
                    )
        streams = [r for r in traces["streaming"] if r["policy"] == policy]
        stream_delta = sum(r["score"]["word_errors"] for r in streams) - sum(
            r["score"]["word_errors"] for r in traces["streaming"] if r["policy"] == "system-default"
        )
        row = dict(
            policy=policy,
            fidelity=fidelity,
            costs=costs,
            first_output_ms=first_output,
            max_abs_passband_db=max(map(abs, passband)),
            max_alias_db=max(alias),
            continuity=all(continuity),
            scores=dict(aggregates),
            new_empty=int(new_empty),
            new_nonspeech=int(new_nonspeech),
            worst_case_added_word_errors=worst_case,
            regressed_cases=regressed,
            improved_cases=improved,
            streaming_word_error_delta=stream_delta,
        )
        rows.append(row)
    baseline = rows[0]
    for row in rows:
        checks = dict(
            continuity=row["continuity"],
            passband=row["max_abs_passband_db"] <= gates["passband_max_abs_db"],
            alias=row["max_alias_db"] <= gates["alias_max_db"],
            fidelity=all(
                row["fidelity"][str(rate)]
                <= baseline["fidelity"][str(rate)] * gates["median_speech_relative_rms_ratio_max"]
                for rate in protocol["rates"]
            ),
            packet_cost=all(
                row["costs"][str(rate)]["p95_ms"] <= gates["packet_p95_ms_max"]
                and row["costs"][str(rate)]["p95_ms"]
                <= baseline["costs"][str(rate)]["p95_ms"] + gates["packet_p95_increase_ms_max"]
                for rate in protocol["rates"]
            ),
            first_output=all(
                row["first_output_ms"][str(rate)]
                <= baseline["first_output_ms"][str(rate)] + gates["first_output_increase_ms_max"]
                for rate in protocol["rates"]
            ),
            language_errors=all(
                row["scores"][key][metric] <= value[metric] + gates["language_error_increase_max"]
                for key, value in baseline["scores"].items()
                for metric in ["word_errors", "character_errors"]
            ),
            aggregate_errors=all(
                sum(value[metric] for value in row["scores"].values())
                <= sum(value[metric] for value in baseline["scores"].values())
                + gates["aggregate_error_increase_max"]
                for metric in ["word_errors", "character_errors"]
            ),
            new_empty=row["new_empty"] <= gates["new_empty_speech_max"],
            new_nonspeech=row["new_nonspeech"] <= gates["new_nonspeech_text_max"],
            worst_case=row["worst_case_added_word_errors"] <= gates["worst_case_additional_errors_max"],
            case_balance=row["regressed_cases"] - row["improved_cases"]
            <= gates["regressing_cases_minus_improving_cases_max"],
            streaming=row["streaming_word_error_delta"] <= gates["streaming_error_increase_max"],
        )
        row["checks"] = checks
        row["passes"] = row["policy"] != "system-default" and all(checks.values())
    passing = [row for row in rows if row["passes"]]
    chosen = (
        min(
            passing,
            key=lambda row: (
                max(value["p95_ms"] for value in row["costs"].values()),
                protocol["policies"].index(row["policy"]),
            ),
        )["policy"]
        if passing
        else None
    )
    return rows, chosen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert not args.work.exists() and not args.output.exists()
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    protocol = json.loads(PROTOCOL.read_text())
    for name, digest in protocol["locks"].items():
        assert sha(ROOT / name) == digest
    helper = args.helper.resolve(strict=True)
    helper_sha = sha(helper)
    args.work.mkdir(parents=True, mode=0o700)
    traces = dict(audio=[], signals=[], cost=[], continuity=[], streaming=[], initial=[])
    trace_path = args.output.with_suffix(".traces.json.gz")

    def save():
        trace_path.write_bytes(gzip.compress(json.dumps(traces, ensure_ascii=False).encode(), mtime=0))

    errors = args.work / "native-stderr.log"
    with errors.open("w") as stderr:
        process = subprocess.Popen(
            [str(helper)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, text=True
        )
        calls = 0

        def convert(path, policy, packets, repeats=1):
            nonlocal calls
            output = args.work / f"output-{calls:05d}.wav"
            request = dict(
                id=str(calls),
                path=str(path.resolve()),
                output=str(output.resolve()),
                policy=policy,
                packets=packets,
                repeats=repeats,
            )
            calls += 1
            process.stdin.write(json.dumps(request) + "\n")
            process.stdin.flush()
            raw = process.stdout.readline()
            assert raw, "Native helper ended unexpectedly"
            response = json.loads(raw)
            with (args.work / "native-responses.jsonl").open("a") as log:
                log.write(json.dumps(dict(request=request, response=response)) + "\n")
            assert response.get("ok") and response["id"] == request["id"], response
            values, rate = sf.read(output, dtype="float32")
            assert rate == 16000 and values.ndim == 1 and np.isfinite(values).all()
            assert len(values) == response["result"]["output_frames"]
            return output, values, response["result"]

        try:
            # Synthetic signals are generated directly at the native rate.
            for rate in protocol["rates"]:
                for band in ["passband", "stopband"]:
                    for frequency in protocol["signal"][band + "_hz"]:
                        t = np.arange(rate * protocol["signal"]["seconds"]) / rate
                        path = args.work / f"tone-{rate}-{frequency}.wav"
                        sf.write(
                            path,
                            (protocol["signal"]["amplitude"] * np.sin(2 * np.pi * frequency * t)).astype(
                                "float32"
                            ),
                            rate,
                            subtype="FLOAT",
                        )
                        for policy in protocol["policies"]:
                            output, values, native = convert(path, policy, protocol["packets"])
                            trim = round(protocol["signal"]["trim_seconds"] * 16000)
                            middle = values[trim:-trim].astype("float64")
                            time = np.arange(trim, len(values) - trim) / 16000
                            folded = abs((frequency + 8000) % 16000 - 8000)
                            basis = np.column_stack(
                                [np.sin(2 * np.pi * folded * time), np.cos(2 * np.pi * folded * time)]
                            )
                            coefficients = np.linalg.lstsq(basis, middle, rcond=None)[0]
                            gain_db = float(
                                20
                                * np.log10(
                                    max(np.linalg.norm(coefficients), 1e-15) / protocol["signal"]["amplitude"]
                                )
                            )
                            traces["signals"].append(
                                dict(
                                    rate=rate,
                                    frequency=frequency,
                                    band=band,
                                    policy=policy,
                                    gain_db=gain_db,
                                    samples=len(values),
                                    pcm_sha256=pcmsha(values),
                                    file=output.name,
                                    native=native,
                                )
                            )
                save()
            # Stable, long fixture for callback-cost distributions, separately from ASR.
            for rate in protocol["rates"]:
                t = np.arange(rate * 60) / rate
                values = (0.2 * np.sin(2 * np.pi * 997 * t) + 0.05 * np.sin(2 * np.pi * 6503 * t)).astype(
                    "float32"
                )
                path = args.work / f"cost-{rate}.wav"
                sf.write(path, values, rate, subtype="FLOAT")
                for policy in protocol["policies"]:
                    output, values, native = convert(
                        path, policy, protocol["packets"], protocol["cost_repeats"]
                    )
                    traces["cost"].append(
                        dict(
                            rate=rate,
                            policy=policy,
                            native=native,
                            pcm_sha256=pcmsha(values),
                            file=output.name,
                        )
                    )
                save()
            engines = {model: Engine() for model in protocol["models"]}
            normalized_files = {}
            for index, item in enumerate(protocol["cases"]):
                original_path = ROOT / "benchmarks" / item["path"]
                assert sha(original_path) == item["sha256"]
                original, original_rate = sf.read(original_path, dtype="float32")
                assert original_rate == 16000 and original.ndim == 1
                original *= np.float32(item["amplitude"])
                for rate in protocol["rates"]:
                    divisor = int(np.gcd(rate, 16000))
                    native_source = resample_poly(original, rate // divisor, 16000 // divisor).astype(
                        "float32"
                    )
                    path = args.work / f"source-{index}-{rate}.wav"
                    sf.write(path, native_source, rate, subtype="FLOAT")
                    offset = (index + protocol["rates"].index(rate)) % len(protocol["policies"])
                    order = protocol["policies"][offset:] + protocol["policies"][:offset]
                    for policy in order:
                        output, values, native = convert(path, policy, protocol["packets"])
                        assert native["exact_whole_reference"] and native["whole_reference_frames"] == len(
                            values
                        )
                        assert abs(len(values) - len(native_source) * 16000 / rate) <= 1
                        assert 0 <= len(values) - len(original) <= 1
                        reference = np.pad(original, (0, len(values) - len(original)))
                        norm = float(np.linalg.norm(original.astype("float64")))
                        row = dict(
                            case=item,
                            rate=rate,
                            policy=policy,
                            file=output.name,
                            native=native,
                            pcm_sha256=pcmsha(values),
                            original_frames=len(original),
                            reference_padding_frames=len(values) - len(original),
                            relative_rms_error=float(
                                np.linalg.norm(values.astype("float64") - reference) / norm
                            )
                            if norm
                            else 0,
                            maximum_sample_error=float(np.max(np.abs(values - reference))),
                            asr={},
                        )
                        traces["audio"].append(row)
                        save()
                        normalized_files[item["id"], rate, policy] = output
                        for model, engine in engines.items():
                            response = engine.transcribe(
                                str(output), model_id=model, language=item["language"], trim=False
                            )
                            row["asr"][model] = dict(
                                response=response,
                                score=score(
                                    item["reference"] if item["expected_speech"] else "", response["text"]
                                ),
                            )
                            save()
                        if item["id"] == protocol["continuity_source"]:
                            second, different, comparison = convert(
                                path, policy, protocol["continuity_packets"]
                            )
                            same = np.array_equal(values, different)
                            traces["continuity"].append(
                                dict(
                                    rate=rate,
                                    policy=policy,
                                    identical=bool(same),
                                    original_file=output.name,
                                    comparison_file=second.name,
                                    native=comparison,
                                )
                            )
                            save()
                            assert same
                print(
                    json.dumps(
                        dict(case=index + 1, total=len(protocol["cases"]), id=item["id"], native_calls=calls)
                    ),
                    flush=True,
                )
            # Actual cached streaming recognition, on completed normalized files
            # split into 320 ms chunks; not a native arrival/availability replay.
            engine = engines["nemotron-streaming"]
            for identity in protocol["streaming_ids"]:
                item = next(row for row in protocol["cases"] if row["id"] == identity)
                for rate in protocol["rates"]:
                    for policy in protocol["policies"]:
                        source, _ = sf.read(normalized_files[identity, rate, policy], dtype="float32")
                        state = engine.stream_begin(item["language"])
                        row = dict(id=identity, rate=rate, policy=policy, events=[])
                        traces["streaming"].append(row)
                        save()
                        packet = args.work / "stream-packet.wav"
                        for position in range(0, len(source), 5120):
                            chunk = source[position : position + 5120]
                            sf.write(packet, chunk, 16000, subtype="FLOAT")
                            response = engine.stream_feed(str(packet), session_id=state["session_id"])
                            row["events"].append(dict(end_sample=position + len(chunk), response=response))
                        row["final"] = engine.stream_feed(final=True, session_id=state["session_id"])
                        row["score"] = score(item["reference"], row["final"]["text"])
                        save()
            process.stdin.close()
            assert process.wait(timeout=10) == 0
        finally:
            save()
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
    summary, chosen = summarize(protocol, traces)
    assert sha(helper) == helper_sha
    assert not subprocess.check_output(["git", "diff", "--name-only", "HEAD"], cwd=ROOT)
    receipt = dict(
        status="completed-frozen-resampling-quality-study",
        timestamp=datetime.datetime.now(datetime.UTC).isoformat(),
        git_commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        protocol_sha256=sha(PROTOCOL),
        producer_sha256=sha(Path(__file__)),
        helper_sha256=helper_sha,
        core_sha256=sha(ROOT / "Sources/OSprCore/StreamingSpeechResampler.swift"),
        native_calls=calls,
        file_asr_requests=sum(len(row["asr"]) for row in traces["audio"]),
        streaming_sessions=len(traces["streaming"]),
        summary=summary,
        passing_candidate=chosen,
        traces_file=trace_path.name,
        traces_sha256=sha(trace_path),
        scope=protocol["scope"],
        boundary=protocol["boundary"],
    )
    args.output.write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")
    print(
        json.dumps(dict(passing_candidate=chosen, checks={row["policy"]: row["checks"] for row in summary})),
        flush=True,
    )


if __name__ == "__main__":
    main()
