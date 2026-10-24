"""Resident MLX models, serial GPU admission, normalized timed results."""

import gc
import platform
import time
from collections import OrderedDict
from contextlib import redirect_stdout
import sys
import json
import os
import uuid
from pathlib import Path

from .audio import SAMPLE_RATE, read_audio, speech_bounds

MODELS = {
    "parakeet-v3": {
        "repo": "mlx-community/parakeet-tdt-0.6b-v3",
        "engine": "parakeet",
        "name": "Parakeet v3 · fast multilingual",
        "languages": "25 European languages",
        "license": "CC-BY-4.0 (weights); Apache-2.0 (runtime)",
    },
    "whisper-turbo": {
        "repo": "mlx-community/whisper-large-v3-turbo",
        "engine": "whisper",
        "name": "Whisper Turbo · broad language coverage",
        "languages": "99 languages",
        "license": "MIT",
    },
    "whisper-small": {
        "repo": "mlx-community/whisper-small-mlx",
        "engine": "whisper",
        "name": "Whisper Small · lower memory",
        "languages": "99 languages",
        "license": "MIT",
    },
    "qwen3-asr": {
        "repo": "mlx-community/Qwen3-ASR-1.7B-8bit",
        "engine": "mlx-audio",
        "name": "Qwen3 ASR · experimental quality",
        "languages": "30 languages + Chinese dialects",
        "license": "Apache-2.0",
    },
    "cohere-transcribe": {
        "repo": "beshkenadze/cohere-transcribe-03-2026-mlx-8bit",
        "engine": "mlx-audio",
        "name": "Legacy Swift-layout Cohere conversion · research only",
        "languages": "14 languages",
        "license": "Apache-2.0",
        "research_only": True,
        "quality_gate": "Unacceptable deletions in the tested conversion/runtime path. Not enabled in the app.",
    },
    "cohere-native8": {
        "repo": "littoralai/cohere-transcribe-mlx-8bit",
        "engine": "mlx-audio",
        "name": "Cohere Transcribe · measured English quality",
        "languages": "14 languages; blank hint uses English (no automatic detection)",
        "license": "Apache-2.0",
    },
    "nemotron-streaming": {
        "repo": "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit",
        "engine": "mlx-audio",
        "name": "Nemotron 3.5 · experimental streaming backbone",
        "languages": "40 language-locales",
        "license": "OpenMDW-1.1 (weights); MIT (runtime)",
    },
}
PUBLIC_MODELS = {key: value for key, value in MODELS.items() if not value.get("research_only")}
REWRITE_MODEL = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
MODEL_LOCK = json.loads(Path(__file__).with_name("models.lock.json").read_text())


def resolve_model(model_id, progress=None):
    """Pinned weights, cache-first: offline hot/cold loads never need a hub call."""
    from huggingface_hub import snapshot_download
    from huggingface_hub.errors import LocalEntryNotFoundError

    entry = MODEL_LOCK[model_id]
    if progress:
        progress({"phase": "checking", "model": model_id})
    options = dict(
        repo_id=entry["repo"],
        revision=entry["revision"],
        allow_patterns=["*.json", "*.safetensors", "*.npz", "*.txt", "*.model", "*.tiktoken", "*.jinja"],
    )
    offline = os.environ.get("HF_HUB_OFFLINE", "").lower() in {"1", "true", "yes"}

    def complete(directory):
        root = Path(directory) / entry["subfolder"] if entry.get("subfolder") else Path(directory)
        return all(
            (root / name).is_file() and (root / name).stat().st_size == size
            for name, size in entry["required_files"].items()
        )

    try:
        directory = snapshot_download(**options, local_files_only=True)
        if not complete(directory):
            raise LocalEntryNotFoundError(
                "Pinned model cache is incomplete. Reconnect once to repair the download."
            )
    except LocalEntryNotFoundError:
        if offline:
            raise
        if progress:
            from .model_cache import progress_bar

            progress({"phase": "download", "model": model_id})
            directory = snapshot_download(**options, tqdm_class=progress_bar(progress))
        else:
            directory = snapshot_download(**options)
        if not complete(directory):
            raise RuntimeError("Pinned model download is incomplete; check disk space and retry.") from None
    return str(Path(directory) / entry["subfolder"]) if entry.get("subfolder") else directory


class Engine:
    """One Engine per serial worker. Keep at most one ASR + one rewrite model resident."""

    def __init__(self):
        self.models = OrderedDict()
        self.rewriter = None
        self.rewriter_id = None
        self.diarizer = None
        self.primed_model = None
        self.stream = None
        self.stream_text = ""
        self.stream_id = None
        self.stream_normalizer = None
        self.progress = None

    def _load(self, model_id):
        if model_id not in MODELS:
            raise ValueError(f"Unknown model: {model_id}")
        if model_id in self.models:
            return self.models[model_id], True
        if platform.machine() != "arm64":
            raise RuntimeError("Local MLX inference requires Apple Silicon.")
        # The app serializes GPU work. Evict BEFORE loading, bounding peak residency.
        self.models.clear()
        self.primed_model = None
        self.stream_cancel()
        if "mlx_whisper.transcribe" in sys.modules:
            from mlx_whisper.transcribe import ModelHolder

            ModelHolder.model = None
            ModelHolder.model_path = None
        gc.collect()
        import mlx.core as mx

        mx.clear_cache()
        spec = MODELS[model_id]
        with redirect_stdout(sys.stderr):
            path = resolve_model(model_id, self.progress)
            if self.progress:
                self.progress({"phase": "loading", "model": model_id})
            if spec["engine"] == "parakeet":
                from .parakeet_loader import load_parakeet

                model = load_parakeet(path)
            elif spec["engine"] == "whisper":
                from mlx_whisper.transcribe import ModelHolder

                model = ModelHolder.get_model(path, mx.float16)
            elif model_id == "cohere-transcribe":
                from .cohere import load_cohere

                model = load_cohere(path)
            else:
                from mlx_audio.stt.utils import load_model

                model = load_model(path, strict=True)
        self.models[model_id] = model
        return model, False

    def warm(self, model_id):
        started = time.perf_counter()
        self._load(model_id)
        load_ms = (time.perf_counter() - started) * 1000
        prime_ms = 0
        if self.primed_model != model_id:
            if self.progress:
                self.progress({"phase": "priming", "model": model_id})
            # Move first-use Metal kernel work into the explicit Load action.
            # A synthetic tone contains no user speech; its output is discarded.
            from .temporary import private_audio_file
            import numpy as np
            import soundfile as sf

            priming = time.perf_counter()
            with private_audio_file() as audio:
                # Also prepare the real 48 kHz microphone resampling path.
                # Moving optional imports must not defer that work until after
                # the user has explicitly waited for "Model ready".
                prime_rate = 48000
                tone = (np.sin(np.arange(prime_rate) * (2 * np.pi * 440 / prime_rate)) * 0.01).astype(np.float32)
                sf.write(audio.name, tone, prime_rate, subtype="FLOAT")
                self.transcribe(audio.name, model_id, language="en", trim=False)
            self.primed_model = model_id
            prime_ms = (time.perf_counter() - priming) * 1000
        return {"model": model_id, "load_ms": load_ms, "prime_ms": prime_ms, "primed_sample_rate": 48000,
                "total_ms": (time.perf_counter() - started) * 1000}

    def transcribe(
        self,
        path,
        model_id="parakeet-v3",
        language=None,
        vocabulary="",
        trim=False,
        threshold=0.003,
        word_timestamps=False,
        speech_edges=None,
    ):
        started = time.perf_counter()
        audio = read_audio(path)
        original_duration = len(audio) / SAMPLE_RATE
        offset = 0
        selected_start = 0
        if speech_edges is not None:
            from .speech_edges import checked_bounds

            start, end = checked_bounds(audio, speech_edges, trim)
            offset = start / SAMPLE_RATE
            selected_start = start
            audio = audio[start:end]
        elif trim:
            start, end = speech_bounds(audio, threshold=float(threshold))
            offset = start / SAMPLE_RATE
            selected_start = start
            audio = audio[start:end]
        preprocess_ms = (time.perf_counter() - started) * 1000
        base = {
            "model": model_id,
            "audio_seconds": original_duration,
            "speech_seconds": len(audio) / SAMPLE_RATE,
        }
        if speech_edges is not None:
            base["speech_edges"] = speech_edges
        # Only exact zeros bypass ASR by default. A volume threshold is an
        # explicit opt-in: even very quiet nonzero samples can contain words.
        if len(audio) < 320 or not audio.any():
            return dict(
                base,
                text="",
                segments=[],
                language=language,
                silence=True,
                detector_abstained=speech_edges is not None,
                empty_reason=("detector_abstained" if speech_edges is not None else
                              "volume_filter_abstained" if trim and len(audio) < 320 else
                              "too_short" if len(audio) < 320 else "normalized_zero"),
                warm=True,
                load_ms=0,
                decode_ms=0,
                preprocess_ms=preprocess_ms,
                total_ms=preprocess_ms,
            )
        loaded = time.perf_counter()
        model, warm = self._load(model_id)
        load_ms = (time.perf_counter() - loaded) * 1000
        import mlx.core as mx

        mx.reset_peak_memory()
        decoded = time.perf_counter()
        spec = MODELS[model_id]
        words = []
        with redirect_stdout(sys.stderr):
            if spec["engine"] == "parakeet":
                from parakeet_mlx.audio import get_logmel

                if len(audio) <= SAMPLE_RATE * 30:
                    # Skip file encoding and ffmpeg spawning for the hot path.
                    mel = get_logmel(mx.array(audio, dtype=mx.float32), model.preprocessor_config)
                    result = model.generate(mel)[0]
                else:
                    from .parakeet import transcribe_long

                    result = transcribe_long(model, audio, offset, word_timestamps)
                if isinstance(result, dict):
                    text, segments, words = result["text"], result["segments"], result["words"]
                    base.update(decoder_chunks=result["decoder_chunks"], decoded_samples=result["decoded_samples"])
                else:
                    text = result.text
                    segments = [
                        dict(start=float(s.start) + offset, end=float(s.end) + offset, text=s.text)
                        for s in result.sentences
                    ]
                    if word_timestamps:
                        from .diarization import tokens_to_words

                        words = tokens_to_words(
                            [
                                dict(start=float(t.start) + offset, end=float(t.end) + offset, text=t.text)
                                for t in result.tokens
                            ]
                        )
                detected_language = language
            elif spec["engine"] == "whisper":
                import mlx_whisper

                result = mlx_whisper.transcribe(
                    audio,
                    path_or_hf_repo=resolve_model(model_id),
                    language=language or None,
                    initial_prompt=vocabulary or None,
                    word_timestamps=word_timestamps,
                    temperature=0.0,
                    condition_on_previous_text=False,
                    verbose=False,
                )
                text, detected_language = result["text"], result.get("language")
                if word_timestamps:
                    words = [
                        dict(
                            start=float(w["start"]) + offset,
                            end=float(w["end"]) + offset,
                            text=w["word"].strip(),
                        )
                        for segment in result["segments"]
                        for w in segment.get("words", [])
                    ]
                segments = [
                    dict(
                        start=float(s["start"]) + offset, end=float(s["end"]) + offset, text=s["text"].strip()
                    )
                    for s in result["segments"]
                ]
            elif model_id == "qwen3-asr" and len(audio) > SAMPLE_RATE * 30:
                from .qwen import transcribe_long

                result = transcribe_long(model, audio, language, offset)
                text, segments, detected_language = result["text"], result["segments"], result["language"]
                base.update(decoder_chunks=result["decoder_chunks"], max_tokens_per_chunk=result["max_tokens_per_chunk"],
                            frontend_evaluations=result["frontend_evaluations"], frontend_cache_hits=result["frontend_cache_hits"])
            else:
                hint = language
                if model_id == "nemotron-streaming" and hint and hint not in model.prompt_dictionary:
                    matches = sorted(
                        key for key in model.prompt_dictionary if key.lower().startswith(hint.lower() + "-")
                    )
                    hint = matches[0] if matches else hint
                if model_id == "cohere-transcribe" and not hint:
                    hint = "en"  # Cohere has no automatic language detection.
                if model_id == "cohere-native8":
                    # Native NeMo-layout checkpoint, not the legacy Swift adapter.
                    # Bound long-file peak residency and allow complete 35s chunks.
                    hint = (hint or "en").lower().replace("_", "-").split("-")[0]
                    result = model.generate(audio, language=hint, max_tokens=512, batch_size=1)
                elif model_id == "qwen3-asr":
                    from .qwen_features import generate

                    result, work = generate(model, audio, **({"language": hint} if hint else {}))
                    base.update(frontend_evaluations=work.evaluations, frontend_cache_hits=work.hits)
                else:
                    result = model.generate(audio, **({"language": hint} if hint else {}))
                text = result.text
                segments = [dict(start=offset, end=offset + len(audio) / SAMPLE_RATE, text=text)]
                detected_language = hint if model_id == "cohere-native8" else getattr(result, "language", language)
                if model_id == "qwen3-asr":
                    from .qwen import language_tag

                    detected_language = language_tag(detected_language, language)
            mx.synchronize()
        decode_ms = (time.perf_counter() - decoded) * 1000
        from .timing import bound_timings

        timing = bound_timings(segments, words, start=offset, end=(selected_start + len(audio)) / SAMPLE_RATE,
            text=text, granularity=("chunk" if "decoder_chunks" in base else "utterance") if spec["engine"] == "mlx-audio" else "segment")
        return dict(
            base,
            **timing,
            text=text.strip(),
            language=detected_language,
            silence=False,
            warm=warm,
            load_ms=load_ms,
            preprocess_ms=preprocess_ms,
            decode_ms=decode_ms,
            total_ms=(time.perf_counter() - started) * 1000,
            peak_gpu_bytes=mx.get_peak_memory(),
            active_gpu_bytes=mx.get_active_memory(),
            vocabulary_applied=spec["engine"] == "whisper" and bool(vocabulary),
        )

    def meeting(self, path, model_id="parakeet-v3", language=None, vocabulary="", trim=False, threshold=0.003, speech_edges=None):
        if model_id not in {"parakeet-v3", "whisper-turbo", "whisper-small"}:
            raise ValueError("Speaker-labeled imports currently require Parakeet or Whisper word timing.")
        started = time.perf_counter()
        audio = read_audio(path)
        if not 0 <= float(threshold) <= 0.1:
            raise ValueError("Threshold must be between 0 and 0.1.")
        if speech_edges is not None:
            from .speech_edges import checked_bounds

            start, end = checked_bounds(audio, speech_edges, trim)
            if end - start < 320:
                return dict(text="", raw_text="", words=[], segments=[], speaker_turns=[], model=model_id,
                            audio_seconds=len(audio) / SAMPLE_RATE, speech_seconds=(end - start) / SAMPLE_RATE,
                            silence=True, detector_abstained=True, empty_reason="detector_abstained",
                            speech_edges=speech_edges, total_ms=0)
        volume_abstained = trim and speech_bounds(audio, threshold=float(threshold)) == (0, 0)
        if len(audio) < 320 or not audio.any() or volume_abstained:
            return dict(
                text="",
                raw_text="",
                words=[],
                segments=[],
                speaker_turns=[],
                model=model_id,
                audio_seconds=len(audio) / SAMPLE_RATE,
                silence=True,
                empty_reason=("volume_filter_abstained" if volume_abstained else
                              "too_short" if len(audio) < 320 else "normalized_zero"),
                total_ms=0,
            )
        from mlx_audio.vad import load
        from .diarization import attribute, formatted
        import mlx.core as mx

        if self.diarizer is None:
            with redirect_stdout(sys.stderr):
                self.diarizer = load(resolve_model("diarization"), strict=True)
        diar_started = time.perf_counter()
        diarized = self.diarizer.generate(audio, threshold=0.5, min_duration=0.2, merge_gap=0.15)
        mx.synchronize()
        turns = [
            dict(
                start=float(s.start), end=min(len(audio) / SAMPLE_RATE, float(s.end)), speaker=int(s.speaker)
            )
            for s in diarized.segments
        ]
        diar_ms = (time.perf_counter() - diar_started) * 1000
        result = self.transcribe(path, model_id, language, vocabulary, trim=False, word_timestamps=True, speech_edges=speech_edges)
        if result["text"] and not result.get("words"):
            raise RuntimeError("Recognizer returned no word timing; speaker attribution would be unreliable.")
        words, segments = attribute(result.get("words", []), turns)
        return dict(
            result,
            raw_text=result["text"],
            text=formatted(segments),
            words=words,
            segments=segments,
            speaker_turns=turns,
            num_speakers=diarized.num_speakers,
            diarization_ms=diar_ms,
            timestamp_granularity="recognizer-word",
            total_ms=(time.perf_counter() - started) * 1000,
            limitations=[
                "Anonymous within-recording labels, not identity recognition.",
                "Overlapping speech is flagged, not separated; ASR can omit simultaneous words.",
                "Word timing is recognizer alignment, not a manually verified reference.",
            ],
        )

    def stream_begin(self, language=None):
        self.stream_cancel()
        model, _ = self._load("nemotron-streaming")
        if language and language not in model.prompt_dictionary:
            matches = sorted(
                key for key in model.prompt_dictionary if key.lower().startswith(language.lower() + "-")
            )
            language = matches[0] if matches else language
        self.stream = model.create_streaming_session(language=language or None)
        self.stream_text = ""
        self.stream_id = str(uuid.uuid4())
        return {"text": "", "sample_rate": SAMPLE_RATE, "session_id": self.stream_id}

    def stream_feed(self, path=None, final=False, session_id=None):
        if self.stream is None:
            raise ValueError("Start a streaming session first.")
        if session_id is not None and session_id != self.stream_id:
            raise ValueError("Expired streaming session.")
        started = time.perf_counter()
        if path:
            from .streaming_audio import StreamNormalizer, read_stream_packet

            audio, rate = read_stream_packet(path)
            if self.stream_normalizer is None:
                self.stream_normalizer = StreamNormalizer(rate)
            elif rate != self.stream_normalizer.sample_rate:
                raise ValueError("Microphone sample rate changed; restart live preview.")
            normalized = self.stream_normalizer.feed(audio)
            if len(normalized):
                self.stream.feed(normalized)
        if final:
            if self.stream_normalizer is not None:
                tail = self.stream_normalizer.feed([], final=True)
                if len(tail):
                    self.stream.feed(tail)
            self.stream.close()
        # Cooperative steps are bounded during live input. At finalization, drain
        # until done with an explicit deadline; queue overflow is never hidden.
        for _ in range(100000 if final else 64):
            self.stream_text += "".join(self.stream.step(max_decode_tokens=256))
            if self.stream.done:
                break
            if final and time.perf_counter() - started > 60:
                raise TimeoutError("Streaming flush exceeded 60 seconds.")
        text = self.stream_text
        done = self.stream.done
        if final:
            if not done:
                raise TimeoutError("Streaming flush exceeded step budget.")
            self.stream = None
            self.stream_id = None
            self.stream_normalizer = None
        return {"text": text.strip(), "done": done, "processing_ms": (time.perf_counter() - started) * 1000}

    def stream_cancel(self, session_id=None):
        if session_id is not None and session_id != self.stream_id:
            return {"cancelled": False}
        if self.stream is not None:
            self.stream.cancel()
        self.stream = None
        self.stream_id = None
        self.stream_text = ""
        self.stream_normalizer = None
        return {"cancelled": True}

    def notes(self, text):
        from .notes import select

        started = time.perf_counter()
        result = select(text, lambda prompt, instruction: self.rewrite(prompt, instruction, task="source-selection")["text"])
        return dict(result, model=MODEL_LOCK["rewrite-quality"]["repo"], total_ms=(time.perf_counter() - started) * 1000)

    def rewrite(self, text, instruction, model_id="rewrite-quality", task="transcript"):
        from .refinement import messages

        conversation = messages(text, instruction, task)
        if not text.strip():
            return {"text": "", "total_ms": 0}
        started = time.perf_counter()
        from mlx_lm import load, generate

        with redirect_stdout(sys.stderr):
            if model_id not in {"rewrite", "rewrite-quality"}:
                raise ValueError("Unsupported local rewrite model.")
            if self.rewriter is None or self.rewriter_id != model_id:
                # Keep one ASR and one small refiner resident. Repeated dictations
                # must not reload both models at every ASR/refinement boundary.
                self.rewriter = None
                gc.collect()
                self.rewriter = load(resolve_model(model_id))
                self.rewriter_id = model_id
            model, tokenizer = self.rewriter
            prompt = tokenizer.apply_chat_template(
                conversation, tokenize=False, add_generation_prompt=True, enable_thinking=False
            )
            result = generate(
                model, tokenizer, prompt=prompt, max_tokens=128 if task == "source-selection" else min(4096, len(text) * 2 + 128), verbose=False
            )
        return {
            "text": result.strip(),
            "total_ms": (time.perf_counter() - started) * 1000,
            "model": MODEL_LOCK[model_id]["repo"],
        }
