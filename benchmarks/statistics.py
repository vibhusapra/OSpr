"""Speaker-cluster bootstrap: intervals for fixed public slices, not product rankings."""

import json
from pathlib import Path
import jiwer
import numpy as np
from run import normalize

ROOT = Path(__file__).resolve().parent
SEED = 61022
TRIALS = 10000


def clusters(records):
    result = {}
    for record in records:
        if record.get("error"):
            raise ValueError("Do not bootstrap a run with unhandled errors")
        score = jiwer.process_words(normalize(record["reference"]), normalize(record["text"]))
        speaker = record["speaker_id"]
        errors, words = result.get(speaker, (0, 0))
        result[speaker] = (
            errors + score.substitutions + score.deletions + score.insertions,
            words + score.hits + score.substitutions + score.deletions,
        )
    return result


def main():
    output = {
        "method": "Paired percentile bootstrap, resample speaker clusters with replacement; aggregate edits/reference words.",
        "seed": SEED,
        "trials": TRIALS,
        "limitations": [
            "Fixed, lexicographically selected five-utterance-per-speaker slices; not full LibriSpeech or real dictation.",
            "Intervals describe sampling over observed speakers, not model training or timing uncertainty.",
        ],
        "suites": {},
    }
    for suite in ("test-clean", "test-other"):
        models = {}
        for model in (
            "parakeet-v3",
            "qwen3-asr",
            "whisper-turbo",
            "whisper-small",
            "nemotron-streaming",
            "whisper-cpp",
            "cohere-native8",
        ):
            data = json.loads((ROOT / "results" / f"{model}-{suite}.json").read_text())
            models[model] = clusters(data["records"])
        speakers = sorted(models["parakeet-v3"])
        rng = np.random.default_rng(SEED)
        indices = rng.integers(0, len(speakers), size=(TRIALS, len(speakers)))
        rates = {}
        intervals = {}
        for model, values in models.items():
            if sorted(values) != speakers:
                raise ValueError("Paired speaker sets differ")
            array = np.array([values[speaker] for speaker in speakers])
            sampled = array[indices].sum(axis=1)
            rates[model] = sampled[:, 0] / sampled[:, 1]
            intervals[model] = {
                "wer": float(array[:, 0].sum() / array[:, 1].sum()),
                "ci95": np.percentile(rates[model], [2.5, 97.5]).tolist(),
            }
        differences = {}
        for alternative in models:
            if alternative == "parakeet-v3":
                continue
            delta = rates["parakeet-v3"] - rates[alternative]
            differences[f"parakeet-v3 minus {alternative}"] = {
                "wer_delta": intervals["parakeet-v3"]["wer"] - intervals[alternative]["wer"],
                "ci95": np.percentile(delta, [2.5, 97.5]).tolist(),
            }
        output["suites"][suite] = {
            "speakers": len(speakers),
            "models": intervals,
            "paired_differences": differences,
        }
    path = ROOT / "results" / "speaker-bootstrap.json"
    path.write_text(json.dumps(output, indent=2) + "\n")
    print(path.read_text())


if __name__ == "__main__":
    main()
