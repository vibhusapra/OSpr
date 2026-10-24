"""Recompute resampling study metrics/gates without loading ASR or the producer."""

import argparse
from collections import defaultdict
import gzip
import hashlib
import json
import math
from pathlib import Path
import statistics
import unicodedata

import numpy as np
from scipy.signal import resample_poly
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def normalized(text):
    return " ".join("".join(c for c in text.lower() if not unicodedata.category(c).startswith("P")).split())


def distance(a, b):
    row = list(range(len(b) + 1))
    for i, left in enumerate(a, 1):
        following = [i]
        for j, right in enumerate(b, 1):
            following.append(min(row[j] + 1, following[-1] + 1, row[j - 1] + (left != right)))
        row = following
    return row[-1]


def quantile(values, p):
    values = sorted(values)
    position = (len(values) - 1) * p
    index = math.floor(position)
    return values[index] + (values[math.ceil(position)] - values[index]) * (position - index)


def close(a, b):
    assert math.isclose(a, b, rel_tol=1e-11, abs_tol=1e-12), (a, b)


def pcm(path):
    values, rate = sf.read(path, dtype="float32")
    assert rate == 16000 and values.ndim == 1 and np.isfinite(values).all()
    return values


def pcm_hash(values):
    return hashlib.sha256(values.astype("<f4").tobytes()).hexdigest()


def verify(receipt_path, work, helper):
    receipt = json.loads(receipt_path.read_text())
    protocol_path = ROOT / "benchmarks/fixtures/resampling-quality-protocol.json"
    protocol = json.loads(protocol_path.read_text())
    assert sha(protocol_path) == receipt["protocol_sha256"] and sha(helper) == receipt["helper_sha256"]
    assert sha(ROOT / "Sources/OSprCore/StreamingSpeechResampler.swift") == receipt["core_sha256"]
    assert sha(ROOT / "benchmarks/resampling_quality.py") == receipt["producer_sha256"]
    for name, value in protocol["locks"].items():
        assert sha(ROOT / name) == value
    trace_path = receipt_path.with_suffix(".traces.json.gz")
    assert sha(trace_path) == receipt["traces_sha256"]
    traces = json.loads(gzip.decompress(trace_path.read_bytes()))
    policies, rates = protocol["policies"], protocol["rates"]
    assert protocol["packets"] == [protocol["first_output_gate_packet_frames"]]
    assert len(traces["audio"]) == len(protocol["cases"]) * len(rates) * len(policies) == 750
    assert len(traces["cost"]) == len(rates) * len(policies) == 10
    assert len(traces["continuity"]) == len(rates) * len(policies) == 10
    assert len(traces["streaming"]) == len(protocol["streaming_ids"]) * len(rates) * len(policies) == 50
    assert (
        len(traces["signals"])
        == len(rates)
        * len(policies)
        * sum(len(protocol["signal"][key]) for key in ["passband_hz", "stopband_hz"])
        == 100
    )
    assert receipt["file_asr_requests"] == 1500 and receipt["streaming_sessions"] == 50
    assert receipt["native_calls"] == 870
    lookup, measured_fidelity = {}, defaultdict(list)
    cursor = 0
    for case_index, case in enumerate(protocol["cases"]):
        original_path = ROOT / "benchmarks" / case["path"]
        assert sha(original_path) == case["sha256"]
        original, rate = sf.read(original_path, dtype="float32")
        assert rate == 16000
        original *= np.float32(case["amplitude"])
        for native_rate in rates:
            native_path = work / f"source-{case_index}-{native_rate}.wav"
            native, actual_rate = sf.read(native_path, dtype="float32")
            divisor = math.gcd(native_rate, 16000)
            expected_native = resample_poly(original, native_rate // divisor, 16000 // divisor).astype(
                "float32"
            )
            assert actual_rate == native_rate
            np.testing.assert_array_equal(native, expected_native)
            offset = (case_index + rates.index(native_rate)) % len(policies)
            order = policies[offset:] + policies[:offset]
            for policy in order:
                row = traces["audio"][cursor]
                cursor += 1
                assert row["case"] == case and row["rate"] == native_rate and row["policy"] == policy
                assert set(row["asr"]) == set(protocol["models"])
                values = pcm(work / row["file"])
                assert pcm_hash(values) == row["pcm_sha256"]
                info = row["native"]
                assert info["input_rate"] == native_rate and info["input_frames"] == len(native)
                assert info["output_frames"] == info["whole_reference_frames"] == len(values)
                assert info["exact_whole_reference"]
                assert abs(len(values) - len(native) * 16000 / native_rate) <= 1
                assert (
                    len(original) == row["original_frames"]
                    and len(values) - len(original) == row["reference_padding_frames"]
                )
                assert row["reference_padding_frames"] in [0, 1]
                expected = np.pad(original, (0, row["reference_padding_frames"]))
                denominator = np.linalg.norm(original.astype("float64"))
                relative = (
                    float(np.linalg.norm(values.astype("float64") - expected) / denominator)
                    if denominator
                    else 0
                )
                close(relative, row["relative_rms_error"])
                close(float(np.max(np.abs(values - expected))), row["maximum_sample_error"])
                if case["suite"].startswith("librispeech"):
                    measured_fidelity[policy, native_rate].append(relative)
                for result in row["asr"].values():
                    expected_text = normalized(case["reference"] if case["expected_speech"] else "")
                    hypothesis = normalized(result["response"]["text"])
                    s = result["score"]
                    assert s["reference"] == expected_text and s["hypothesis"] == hypothesis
                    assert s["words"] == len(expected_text.split())
                    assert s["characters"] == len("".join(expected_text.split()))
                    assert s["word_errors"] == distance(expected_text.split(), hypothesis.split())
                    assert s["character_errors"] == distance(
                        "".join(expected_text.split()), "".join(hypothesis.split())
                    )
                    close(result["response"]["audio_seconds"], len(values) / 16000)
                lookup[case["id"], native_rate, policy] = row
    for row in traces["continuity"]:
        first, second = pcm(work / row["original_file"]), pcm(work / row["comparison_file"])
        np.testing.assert_array_equal(first, second)
        assert row["identical"] and row["native"]["exact_whole_reference"]
    signal_values = defaultdict(lambda: dict(passband=[], stopband=[]))
    for row in traces["signals"]:
        assert row["rate"] in rates and row["policy"] in policies
        assert row["frequency"] in protocol["signal"][row["band"] + "_hz"]
        values = pcm(work / row["file"])
        assert len(values) == row["samples"] == protocol["signal"]["seconds"] * 16000
        assert pcm_hash(values) == row["pcm_sha256"]
        trim = round(protocol["signal"]["trim_seconds"] * 16000)
        values = values[trim:-trim].astype("float64")
        time = (np.arange(len(values)) + trim) / 16000
        frequency = abs((row["frequency"] + 8000) % 16000 - 8000)
        # Independent complex projection over an integer number of cycles,
        # rather than the producer's two-column least-squares solution.
        amplitude = abs(np.sum(values * np.exp(-2j * np.pi * frequency * time))) * 2 / len(values)
        db = float(20 * np.log10(max(amplitude, 1e-15) / protocol["signal"]["amplitude"]))
        assert abs(db - row["gain_db"]) < 0.02
        signal_values[row["policy"]][row["band"]].append(row["gain_db"])
    streams = defaultdict(int)
    for row in traces["streaming"]:
        source = lookup[row["id"], row["rate"], row["policy"]]
        values = pcm(work / source["file"])
        positions = [min(start + 5120, len(values)) for start in range(0, len(values), 5120)]
        assert [event["end_sample"] for event in row["events"]] == positions
        assert row["final"]["done"]
        case = source["case"]
        expected = normalized(case["reference"])
        hypothesis = normalized(row["final"]["text"])
        assert row["score"]["reference"] == expected and row["score"]["hypothesis"] == hypothesis
        errors = distance(expected.split(), hypothesis.split())
        assert row["score"]["word_errors"] == errors
        assert row["score"]["character_errors"] == distance(
            "".join(expected.split()), "".join(hypothesis.split())
        )
        streams[row["policy"]] += errors
    summaries = {row["policy"]: row for row in receipt["summary"]}
    assert list(summaries) == policies
    for policy in policies:
        summary = summaries[policy]
        for rate in rates:
            close(statistics.median(measured_fidelity[policy, rate]), summary["fidelity"][str(rate)])
            cost = next(row for row in traces["cost"] if row["rate"] == rate and row["policy"] == policy)
            values = pcm(work / cost["file"])
            assert len(values) == 60 * 16000 and pcm_hash(values) == cost["pcm_sha256"]
            trials = cost["native"]["trials"]
            assert len(trials) == protocol["cost_repeats"]
            costs = [value for trial in trials for value in trial["process_ms"]]
            assert all(math.isfinite(value) and value >= 0 for value in costs)
            for trial in trials:
                assert len(trial["process_ms"]) == math.ceil(rate * 60 / 1024)
                assert trial["output_frames"] == len(values)
                assert trial["live_output_frames"] <= len(values)
            close(quantile(costs, 0.5), summary["costs"][str(rate)]["p50_ms"])
            close(quantile(costs, 0.95), summary["costs"][str(rate)]["p95_ms"])
            close(
                max(t["first_output_input_frames"] / rate * 1000 for t in trials),
                summary["first_output_ms"][str(rate)],
            )
        expected_scores = defaultdict(lambda: dict(words=0, characters=0, word_errors=0, character_errors=0))
        empty = nonspeech = worst = improved = regressed = 0
        for case in protocol["cases"]:
            for rate in rates:
                actual = lookup[case["id"], rate, policy]
                baseline = lookup[case["id"], rate, "system-default"]
                for model in protocol["models"]:
                    a, b = actual["asr"][model], baseline["asr"][model]
                    if case["expected_speech"]:
                        key = model + ":" + case["language"] + ":" + str(rate)
                        for metric in expected_scores[key]:
                            expected_scores[key][metric] += a["score"][metric]
                        delta = a["score"]["word_errors"] - b["score"]["word_errors"]
                        worst = max(worst, delta)
                        improved += delta < 0
                        regressed += delta > 0
                        empty += bool(b["response"]["text"].strip()) and not a["response"]["text"].strip()
                    else:
                        nonspeech += not b["response"]["text"].strip() and bool(a["response"]["text"].strip())
        assert dict(expected_scores) == summary["scores"]
        assert (empty, nonspeech, worst, improved, regressed) == (
            summary["new_empty"],
            summary["new_nonspeech"],
            summary["worst_case_added_word_errors"],
            summary["improved_cases"],
            summary["regressed_cases"],
        )
        assert summary["streaming_word_error_delta"] == streams[policy] - streams["system-default"]
        close(max(abs(value) for value in signal_values[policy]["passband"]), summary["max_abs_passband_db"])
        close(max(signal_values[policy]["stopband"]), summary["max_alias_db"])
        assert summary["continuity"]
    baseline = summaries["system-default"]
    gate = protocol["gates"]
    for row in summaries.values():
        checks = {}
        checks["continuity"] = row["continuity"]
        checks["passband"] = row["max_abs_passband_db"] <= gate["passband_max_abs_db"]
        checks["alias"] = row["max_alias_db"] <= gate["alias_max_db"]
        checks["fidelity"] = all(
            row["fidelity"][str(rate)] / baseline["fidelity"][str(rate)]
            <= gate["median_speech_relative_rms_ratio_max"]
            for rate in rates
        )
        checks["packet_cost"] = all(
            row["costs"][str(rate)]["p95_ms"]
            <= min(
                gate["packet_p95_ms_max"],
                baseline["costs"][str(rate)]["p95_ms"] + gate["packet_p95_increase_ms_max"],
            )
            for rate in rates
        )
        checks["first_output"] = all(
            row["first_output_ms"][str(rate)] - baseline["first_output_ms"][str(rate)]
            <= gate["first_output_increase_ms_max"]
            for rate in rates
        )
        checks["language_errors"] = all(
            row["scores"][key][metric] - baseline["scores"][key][metric]
            <= gate["language_error_increase_max"]
            for key in baseline["scores"]
            for metric in ["word_errors", "character_errors"]
        )
        checks["aggregate_errors"] = all(
            sum(value[metric] for value in row["scores"].values())
            - sum(value[metric] for value in baseline["scores"].values())
            <= gate["aggregate_error_increase_max"]
            for metric in ["word_errors", "character_errors"]
        )
        checks["new_empty"] = row["new_empty"] <= gate["new_empty_speech_max"]
        checks["new_nonspeech"] = row["new_nonspeech"] <= gate["new_nonspeech_text_max"]
        checks["worst_case"] = row["worst_case_added_word_errors"] <= gate["worst_case_additional_errors_max"]
        checks["case_balance"] = (
            row["regressed_cases"] - row["improved_cases"]
            <= gate["regressing_cases_minus_improving_cases_max"]
        )
        checks["streaming"] = row["streaming_word_error_delta"] <= gate["streaming_error_increase_max"]
        assert checks == row["checks"]
        assert row["passes"] == (row["policy"] != "system-default" and all(checks.values()))
    candidates = [row for row in summaries.values() if row["passes"]]
    chosen = (
        min(
            candidates,
            key=lambda row: (
                max(cost["p95_ms"] for cost in row["costs"].values()),
                policies.index(row["policy"]),
            ),
        )["policy"]
        if candidates
        else None
    )
    assert chosen == receipt["passing_candidate"]
    return dict(
        status="verified-samples-signal-scores-costs-order-and-every-gate",
        study_commit=receipt["git_commit"],
        receipt_sha256=sha(receipt_path),
        traces_sha256=sha(trace_path),
        verifier_sha256=sha(Path(__file__)),
        audio_cases=len(protocol["cases"]),
        file_asr_requests=1500,
        streaming_sessions=50,
        native_calls=870,
        passing_candidate=chosen,
        policies=[
            dict(policy=row["policy"], checks=row["checks"], passes=row["passes"])
            for row in summaries.values()
        ],
        boundary="Independent file/hash/projection/edit-distance/quantile/order/gate checks; does not rerun Apple converter or ASR. Native whole-track equivalence comes from the frozen native helper plus separate Core unit reference tests. No physical capture, UI latency, energy or consumer ranking claim.",
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    result = verify(args.receipt, args.work, args.helper)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
