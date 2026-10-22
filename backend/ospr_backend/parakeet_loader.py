"""Load the pinned TDT model without constructing fixed filters through librosa.

The committed float32 filter bank is the exact librosa reference output for this
preprocessor. Public parakeet-mlx model construction/eval and weight loading are
retained; no global third-party module is patched and no model weights change.
"""
import hashlib
import json
from pathlib import Path

import numpy as np

FILTER_SHA256 = "63d8ddc9c24726f43b867a48037f9ccf9607e0ed59a1cd3e899c678a4f693f80"
FILTER_PATH = Path(__file__).with_name("data") / "parakeet-v3-mel.npy"


def filterbank(sample_rate, n_fft, features):
    if (sample_rate, n_fft, features) != (16000, 512, 128):
        raise ValueError("This Parakeet preprocessor needs a newly verified filter bank.")
    data = FILTER_PATH.read_bytes()
    if hashlib.sha256(data).hexdigest() != FILTER_SHA256:
        raise ValueError("The packaged Parakeet filter bank failed its integrity check.")
    # Parsing the bytes checked above also avoids a second mutable file read.
    import io

    filters = np.load(io.BytesIO(data), allow_pickle=False)
    if filters.shape != (128, 257) or filters.dtype != np.float32 or not np.isfinite(filters).all():
        raise ValueError("Invalid packaged Parakeet filter bank.")
    return filters


def load_parakeet(path):
    import mlx.core as mx
    from dacite import from_dict
    from mlx.utils import tree_flatten, tree_unflatten
    from parakeet_mlx.audio import PreprocessArgs
    from parakeet_mlx.utils import from_config

    class FixedPreprocessArgs(PreprocessArgs):
        def __post_init__(self):
            self._filterbanks = mx.array(filterbank(self.sample_rate, self.n_fft, self.features), dtype=mx.float32)

    root = Path(path)
    config = json.loads((root / "config.json").read_text())
    if (config.get("target") != "nemo.collections.asr.models.rnnt_bpe_models.EncDecRNNTBPEModel"
            or config.get("model_defaults", {}).get("tdt_durations") != [0, 1, 2, 3, 4]):
        raise ValueError("This Parakeet architecture needs a reviewed loader update.")
    # dacite preserves an already constructed instance of the expected base
    # dataclass. Unknown config fields/defaults follow the upstream rules.
    config["preprocessor"] = from_dict(FixedPreprocessArgs, config["preprocessor"])
    model = from_config(config)  # Includes upstream eval mode (LayerNorm).
    model.load_weights(str(root / "model.safetensors"), strict=True)
    parameters = [(name, value.astype(mx.bfloat16)) for name, value in tree_flatten(model.parameters())]
    model.update(tree_unflatten(parameters))
    return model
