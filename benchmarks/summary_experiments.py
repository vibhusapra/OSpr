"""Research-only source encoding and structured decoding; no runtime/default change.

XGrammar 0.2.8 and apache-tvm-ffi 0.1.15.post0 are installed in an isolated
research directory. The Metal kernel API follows the upstream MLX integration;
this adapter keeps strict per-generation state instead of resetting on rejection.
"""
import hashlib
import json


ENCODING_INSTRUCTION = (
    " Transcript encoding: same_as repeats the exact text of the earlier numbered source in this chunk. "
    "Every row retains its own source ID and chronological position. Repetition is not a new decision "
    "or a correction. Resolve these exact-text references when reading and citing the transcript."
)


def compact_source(prompt, instruction):
    value = json.loads(prompt)
    rows = value.get("transcript")
    if not isinstance(rows, list):
        return prompt, instruction, None
    seen, encoded, aliases = {}, [], 0
    for row in rows:
        original = dict(row)
        if row["text"] in seen:
            reference = dict(id=row["id"], same_as=seen[row["text"]])
            if len(json.dumps(reference)) < len(json.dumps(original, ensure_ascii=False)):
                encoded.append(reference)
                aliases += 1
                continue
        seen.setdefault(row["text"], row["id"])
        encoded.append(original)
    if not aliases:
        return prompt, instruction, None
    recovered = expand_source(encoded)
    if recovered != rows:
        raise ValueError("Lossless transcript encoding did not round-trip.")
    original_bytes = json.dumps(rows, ensure_ascii=False).encode()
    value["transcript"] = encoded
    value["transcript_encoding"] = "exact-text-references-v1"
    output = json.dumps(value, ensure_ascii=False)
    if len(output.encode()) + len(ENCODING_INSTRUCTION.encode()) >= len(prompt.encode()):
        return prompt, instruction, None
    return output, instruction + ENCODING_INSTRUCTION, dict(
        source_units=len(rows), aliases=aliases, exact_roundtrip=True,
        original_prompt_bytes=len(prompt.encode()), encoded_prompt_bytes=len(output.encode()),
        decoded_units_sha256=hashlib.sha256(original_bytes).hexdigest(),
    )


def expand_source(rows):
    known, result = {}, []
    for row in rows:
        index = row["id"]
        if type(index) is not int or index in known:
            raise ValueError("Invalid or repeated source ID.")
        if set(row) == {"id", "text"} and isinstance(row["text"], str):
            text = row["text"]
        elif set(row) == {"id", "same_as"} and type(row["same_as"]) is int and row["same_as"] in known:
            text = known[row["same_as"]]
        else:
            raise ValueError("Invalid, forward or cyclic source reference.")
        known[index] = text
        result.append(dict(id=index, text=text))
    return result


class GrammarResearch:
    def __init__(self, tokenizer, vocab_size):
        import xgrammar as xgr
        from xgrammar.kernels.apply_token_bitmask_mlx import apply_token_bitmask_mlx
        self.xgr = xgr
        self.apply = apply_token_bitmask_mlx
        self.stop_ids = sorted(tokenizer.eos_token_ids)
        info = xgr.TokenizerInfo.from_huggingface(
            tokenizer._tokenizer, vocab_size=vocab_size, stop_token_ids=self.stop_ids,
        )
        self.compiler = xgr.GrammarCompiler(info)
        self.compiled = None

    def processor(self, prompt):
        # Cache one structural schema per model, avoiding a vocabulary-wide
        # recompilation for every changing source-ID set. Source membership,
        # duplicate IDs and factual preservation still use production validation.
        schema = dict(type="object", properties=dict(items=dict(
            type="array", maxItems=32, items=dict(
                type="object", properties=dict(
                    section=dict(enum=["overview", "decisions", "actions", "questions"]),
                    text=dict(type="string", minLength=1, maxLength=1000),
                    source_ids=dict(type="array", minItems=1, maxItems=512,
                                    items=dict(type="integer", minimum=0, maximum=100000)),
                ), required=["section", "text", "source_ids"], additionalProperties=False,
            ),
        )), required=["items"], additionalProperties=False)
        if self.compiled is None:
            self.compiled = self.compiler.compile_json_schema(schema, any_order=True)
        compiled = self.compiled
        matcher = self.xgr.GrammarMatcher(compiled, max_rollback_tokens=0)
        mask = self.xgr.allocate_token_bitmask(1, compiled.tokenizer_info.vocab_size)
        previous_count = None

        def process(tokens, logits):
            nonlocal previous_count
            import mlx.core as mx
            count = int(tokens.size)
            if previous_count is not None:
                if count != previous_count + 1 or not matcher.accept_token(int(tokens[-1].item())):
                    raise RuntimeError("Structured decoding lost serial token admission.")
            previous_count = count
            if matcher.is_terminated():
                allowed = mx.array(self.stop_ids)
                final = mx.full(logits.shape, -float("inf"), dtype=logits.dtype)
                final[..., allowed] = logits[..., allowed]
                return final
            matcher.fill_next_token_bitmask(mask)
            return self.apply(mx.array(mask.numpy()), logits, compiled.tokenizer_info.vocab_size)

        return process
