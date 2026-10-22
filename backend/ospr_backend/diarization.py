"""Word-time speaker attribution. Generic labels, overlap retained, no identity claims."""

import math


def tokens_to_words(tokens):
    """Group the recognizer's timed subword pieces without inventing new timing."""
    words = []
    current = None
    for token in tokens:
        text = token["text"]
        if not text:
            continue
        if current is None or text[0].isspace():
            if current is not None:
                words.append(current)
            current = dict(start=token["start"], end=token["end"], text=text.strip())
        else:
            current["text"] += text
            current["end"] = max(current["end"], token["end"])
    if current is not None:
        words.append(current)
    return words


def attribute(words, turns):
    """Assign maximum acoustic overlap; preserve ambiguity for simultaneous speech.

    This cannot disentangle overlapped ASR text. Unknown spans stay unlabeled.
    Speaker IDs refer only to anonymous channels within this recording.
    """
    attributed = []
    segments = []
    for word in words:
        if not all(math.isfinite(float(word[k])) for k in ("start", "end")) or word["end"] < word["start"]:
            raise ValueError("Invalid recognizer word timing")
        item = dict(word)
        overlaps = {}
        for turn in turns:
            overlap = max(0.0, min(word["end"], turn["end"]) - max(word["start"], turn["start"]))
            if overlap:
                overlaps[turn["speaker"]] = overlaps.get(turn["speaker"], 0.0) + overlap
        active = sorted(
            speaker
            for speaker, duration in overlaps.items()
            if duration / max(0.01, word["end"] - word["start"]) >= 0.25
        )
        item["overlapSpeakers"] = active if len(active) > 1 else []
        item["speaker"] = active[0] if len(active) == 1 else None
        attributed.append(item)
        if (
            segments
            and segments[-1]["speaker"] == item["speaker"]
            and segments[-1]["overlapSpeakers"] == item["overlapSpeakers"]
            and item["start"] - segments[-1]["end"] < 1.2
            and len(segments[-1]["text"]) < 250
        ):
            segments[-1]["text"] += " " + item["text"].strip()
            segments[-1]["end"] = max(segments[-1]["end"], item["end"])
        else:
            segments.append(dict(item))
    return attributed, segments


def formatted(segments):
    lines = []
    for segment in segments:
        if segment["overlapSpeakers"]:
            label = "Overlapping speakers"
        elif segment["speaker"] is None:
            label = "Unassigned"
        else:
            label = f"Speaker {segment['speaker'] + 1}"
        lines.append(f"{label}: {segment['text'].strip()}")
    return "\n".join(lines)
