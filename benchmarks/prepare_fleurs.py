"""Small multilingual FLEURS smoke slices; never a full benchmark claim.

Downloads public test shards, selects the first ten rows per language before
model evaluation. Report CER for languages without space-delimited words.
"""

import argparse
import hashlib
import io
import json
from pathlib import Path

from huggingface_hub import HfApi, hf_hub_download
import pyarrow.parquet as pq
import soundfile as sf

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--languages", nargs="+", default=["es_419", "de_de", "hi_in", "ja_jp", "cmn_hans_cn"]
    )
    parser.add_argument("--count", type=int, default=10)
    args = parser.parse_args()
    repo = "google/fleurs"
    revision = HfApi().dataset_info(repo).sha
    items, sources = [], []
    for language in args.languages:
        print("Downloading", language, flush=True)
        path = hf_hub_download(
            repo,
            f"parquet-data/{language}/test-00000-of-00001.parquet",
            repo_type="dataset",
            revision=revision,
        )
        rows = next(pq.ParquetFile(path).iter_batches(batch_size=args.count)).to_pylist()
        directory = ROOT / "fixtures/audio/fleurs" / language
        directory.mkdir(parents=True, exist_ok=True)
        for index, row in enumerate(rows):
            audio, rate = sf.read(io.BytesIO(row["audio"]["bytes"]), dtype="float32")
            target = directory / f"{index:03d}.wav"
            sf.write(target, audio, rate, subtype="PCM_16")
            code = {"cmn_hans_cn": "zh"}.get(language, language.split("_")[0])
            reference = row.get("transcription") or row.get("raw_transcription")
            if not reference:
                raise ValueError(f"Missing reference in {row.keys()}")
            items.append(
                dict(
                    id=f"fleurs-{language}-{index:03d}",
                    path=str(target.relative_to(ROOT)),
                    reference=reference,
                    language=code,
                    suite=f"fleurs-{language}",
                    source_id=row.get("id"),
                    sha256=hashlib.sha256(target.read_bytes()).hexdigest(),
                    seconds=len(audio) / rate,
                )
            )
        sources.append(
            dict(language=language, sha256=hashlib.file_digest(Path(path).open("rb"), "sha256").hexdigest())
        )
    manifest = dict(
        dataset=repo,
        revision=revision,
        license="CC BY 4.0 · Google FLEURS / FLoRes multilingual evaluation corpus",
        selection=f"First {args.count} test rows per language. Not selected by model output.",
        sources=sources,
        caveats="Tiny multilingual read-speech slices. Not a representative language ranking. Japanese/Chinese use CER; whitespace WER is not meaningful.",
        items=items,
    )
    (ROOT / "fixtures/fleurs.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(f"Prepared {len(items)} multilingual clips.")


if __name__ == "__main__":
    main()
