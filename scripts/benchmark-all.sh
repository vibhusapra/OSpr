#!/bin/bash
# Run sequentially to avoid competing GPU workloads. Prepare fixtures and cache
# weights first; see benchmarks/README.md. Set OSPR_CPP_WEIGHTS for cpp controls.
set -euo pipefail
cd "$(dirname "$0")/.."
export PYTHONPATH=backend
export HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-1}"
for model in parakeet-v3 cohere-native8 whisper-turbo qwen3-asr whisper-small nemotron-streaming; do
  for suite in test-clean test-other; do
    .venv/bin/python benchmarks/run.py --model "$model" --manifest "fixtures/$suite.json"
  done
  .venv/bin/python benchmarks/run.py --model "$model"
done
for model in whisper-turbo qwen3-asr nemotron-streaming; do
  .venv/bin/python benchmarks/run.py --model "$model" --manifest fixtures/fleurs.json
done
for locale in de_de es_419; do
  .venv/bin/python benchmarks/run.py --model parakeet-v3 --manifest fixtures/fleurs.json --suite "fleurs-$locale"
done
for locale in de_de es_419 ja_jp cmn_hans_cn; do
  .venv/bin/python benchmarks/run.py --model cohere-native8 --manifest fixtures/fleurs.json --suite "fleurs-$locale"
done
if [[ -n "${OSPR_CPP_WEIGHTS:-}" ]]; then
  for suite in test-clean test-other; do
    .venv/bin/python benchmarks/cpp_baseline.py --manifest "fixtures/$suite.json" --weights "$OSPR_CPP_WEIGHTS"
  done
fi
.venv/bin/python benchmarks/statistics.py
