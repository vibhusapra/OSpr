"""Adapt the pinned Swift-layout MLX checkpoint to mlx-audio's NeMo layout.

The checkpoint publishes an explicit original-to-converted key map. Reverse it,
split concatenated Q/K/V rows (including quantization scales/offsets), and let the
runtime validate EVERY weight. Never load partial/random weights with strict=False.
"""

import json
import re
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn


def restore_keys(weights, key_map):
    reverse = {value: key for key, value in key_map.items()}
    restored = {}
    for key, value in weights.items():
        key = re.sub(r"\.subsampling\.conv(\d+)\.", r".subsampling.conv.\1.", key)
        prefix, suffix = key.rsplit(".", 1)
        mapped = reverse.get(key)
        if mapped is None and suffix in {"scales", "biases"}:
            base = reverse.get(prefix + ".weight")
            mapped = base.rsplit(".", 1)[0] + "." + suffix if base else None
        if mapped is None:
            raise ValueError(f"Unmapped Cohere checkpoint parameter: {key}")
        if "<qkv>" in mapped:
            if value.shape[0] % 3:
                raise ValueError(f"Invalid concatenated QKV shape for {key}")
            names = (
                ["linear_q", "linear_k", "linear_v"]
                if mapped.startswith("encoder.")
                else ["query_net", "key_net", "value_net"]
            )
            for name, part in zip(names, mx.split(value, 3, axis=0), strict=True):
                restored[mapped.replace("<qkv>", name)] = part
        else:
            restored[mapped] = value
    return restored


def load_cohere(path):
    from mlx_audio.stt.models.cohere_asr.cohere_asr import Model
    from mlx_audio.stt.models.cohere_asr.config import ModelConfig

    directory = Path(path)
    config = json.loads((directory / "config.json").read_text())
    model = Model(ModelConfig.from_dict(config))
    mapping = json.loads((directory / "key_map.json").read_text())
    weights = restore_keys(mx.load(str(directory / "model.safetensors")), mapping)
    weights = model.sanitize(weights)
    # This checkpoint omits the deterministic sinusoidal table, which the Swift
    # runtime reconstructs. Keep mlx-audio's identical constructor-generated table;
    # every learned parameter still has to pass strict loading.
    position_key = "transf_decoder.embedding.position_embedding.pos_enc"
    if position_key not in weights:
        from mlx.utils import tree_flatten

        weights[position_key] = dict(tree_flatten(model.parameters()))[position_key]
    quantization = config.get("quantization", {})
    nn.quantize(
        model,
        group_size=quantization.get("group_size", 64),
        bits=quantization.get("bits", 8),
        class_predicate=lambda name, module: name + ".scales" in weights,
    )
    model.load_weights(list(weights.items()), strict=True)
    mx.eval(model.parameters())
    model.eval()
    return Model.post_load_hook(model, directory)
