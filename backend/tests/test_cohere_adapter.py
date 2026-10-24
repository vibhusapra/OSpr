import pytest

mx = pytest.importorskip("mlx.core")
from ospr_backend.cohere import restore_keys  # noqa: E402 (optional MLX test dependency)


def test_fused_qkv_and_quantization_rows_restore_without_reordering():
    mapping = {"encoder.layers.0.self_attn.<qkv>.weight": "encoder.layers.0.self_attn.qkv_proj.weight"}
    weights = {
        "encoder.layers.0.self_attn.qkv_proj.weight": mx.arange(12).reshape(6, 2),
        "encoder.layers.0.self_attn.qkv_proj.scales": mx.arange(6).reshape(6, 1),
    }
    result = restore_keys(weights, mapping)
    assert result["encoder.layers.0.self_attn.linear_q.weight"].tolist() == [[0, 1], [2, 3]]
    assert result["encoder.layers.0.self_attn.linear_k.weight"].tolist() == [[4, 5], [6, 7]]
    assert result["encoder.layers.0.self_attn.linear_v.scales"].tolist() == [[4], [5]]


def test_unmapped_learned_weights_fail_closed():
    with pytest.raises(ValueError, match="Unmapped"):
        restore_keys({"unknown.weight": mx.ones((2, 2))}, {})
