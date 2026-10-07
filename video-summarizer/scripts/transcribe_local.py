#!/usr/bin/env python3
"""One-off local transcription using a local faster-whisper model directory.

Mirrors the output format of the video-summarizer skill's
parallel_transcribe.py (subtitle.vtt + transcript.txt), but accepts a
filesystem path as the model.
"""
import sys

from faster_whisper import WhisperModel

# 用法: transcribe_local.py <audio> <output_dir> [model_dir]
MODEL_PATH = sys.argv[3] if len(sys.argv) > 3 else "./cache/whisper-models/faster-whisper-small"


def format_timestamp(seconds: float) -> str:
    hours = int(seconds // 3600)
    minutes = int((seconds % 3600) // 60)
    secs = seconds % 60
    return f"{hours:02d}:{minutes:02d}:{secs:06.3f}"


def main():
    audio_path, output_dir = sys.argv[1], sys.argv[2]

    print(f"Loading model: {MODEL_PATH}")
    model = WhisperModel(MODEL_PATH, device="auto", compute_type="auto")

    print("Transcribing...")
    segments, info = model.transcribe(
        audio_path,
        language="zh",
        vad_filter=True,
        condition_on_previous_text=False,
    )

    segment_list = [
        {"start": seg.start, "end": seg.end, "text": seg.text.strip()}
        for seg in segments
    ]

    vtt_path = f"{output_dir}/subtitle.vtt"
    txt_path = f"{output_dir}/transcript.txt"

    with open(vtt_path, "w", encoding="utf-8") as f:
        f.write("WEBVTT\n\n")
        for seg in segment_list:
            f.write(f"{format_timestamp(seg['start'])} --> {format_timestamp(seg['end'])}\n")
            f.write(f"{seg['text']}\n\n")

    with open(txt_path, "w", encoding="utf-8") as f:
        for seg in segment_list:
            f.write(f"{seg['text']}\n")

    print(f"Subtitle saved: {vtt_path}")
    print(f"Transcript saved: {txt_path}")
    print(f"Total segments: {len(segment_list)}")


if __name__ == "__main__":
    main()
