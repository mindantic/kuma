#!/usr/bin/env python3
import json
import os
import re
import sys
import time
import traceback

MAX_CHUNK = 350
MIN_COMMA_CUT = 120
SENTENCE_PAUSE = 0.18


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def resolve_paths(argv):
    root = os.environ.get("KUMA_HOME") or os.path.expanduser("~/Library/Application Support/Kuma")
    models = os.environ.get("KUMA_VOICE_MODELS") or os.path.join(root, "voice", "models")
    model = argv[1] if len(argv) > 1 else os.environ.get("KUMA_KOKORO_MODEL") or os.path.join(models, "kokoro-v1.0.onnx")
    voices = argv[2] if len(argv) > 2 else os.environ.get("KUMA_KOKORO_VOICES") or os.path.join(models, "voices-v1.0.bin")
    return model, voices


def split_sentences(text):
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        return []
    parts = [p.strip() for p in re.split(r"(?<=[.!?;:])\s+", text) if p.strip()]
    chunks = []
    for part in parts:
        while len(part) > MAX_CHUNK:
            cut = part.rfind(",", 0, MAX_CHUNK)
            if cut < MIN_COMMA_CUT:
                cut = part.rfind(" ", 0, MAX_CHUNK)
            if cut <= 0:
                cut = MAX_CHUNK
            chunks.append(part[: cut + 1].strip())
            part = part[cut + 1 :].strip()
        if part:
            chunks.append(part)
    return chunks


def main():
    model_path, voices_path = resolve_paths(sys.argv)
    try:
        import numpy as np
        import soundfile as sf
        from kokoro_onnx import Kokoro

        kokoro = Kokoro(model_path, voices_path)
        known_voices = set(kokoro.get_voices())
        if os.environ.get("KUMA_VOICE_NO_WARMUP") != "1":
            warm_voice = "am_onyx" if "am_onyx" in known_voices else sorted(known_voices)[0]
            kokoro.create("Ready.", voice=warm_voice, speed=1.0, lang="en-us")
    except Exception as exc:
        emit({"ready": False, "error": f"load failed: {exc}"})
        return 2

    emit({"ready": True, "voices": len(known_voices)})

    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue
        req_id = None
        try:
            req = json.loads(line)
            if not isinstance(req, dict):
                raise ValueError("request must be a JSON object")
            req_id = req.get("id")
            if req.get("cmd") == "ping":
                emit({"id": req_id, "ok": True, "pong": True})
                continue
            text = str(req.get("text") or "")
            voice = str(req.get("voice") or "am_onyx")
            out = req.get("out")
            if not out:
                raise ValueError("missing out path")
            if voice not in known_voices:
                raise ValueError(f"unknown voice {voice}")
            try:
                speed = float(req.get("speed", 1.0))
            except (TypeError, ValueError):
                speed = 1.0
            speed = min(max(speed, 0.5), 2.0)
            lang = "en-gb" if voice.startswith("b") else "en-us"
            chunks = split_sentences(text)
            if not chunks:
                raise ValueError("empty text")
            started = time.perf_counter()
            pieces = []
            rate = 24000
            for chunk in chunks:
                samples, rate = kokoro.create(chunk, voice=voice, speed=speed, lang=lang)
                if pieces:
                    pieces.append(np.zeros(int(rate * SENTENCE_PAUSE), dtype=np.float32))
                pieces.append(np.asarray(samples, dtype=np.float32))
            audio = np.concatenate(pieces) if len(pieces) > 1 else pieces[0]
            out = str(out)
            os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
            tmp = out + ".part"
            sf.write(tmp, audio, rate, format="WAV", subtype="PCM_16")
            os.replace(tmp, out)
            ms = int((time.perf_counter() - started) * 1000)
            emit({"id": req_id, "ok": True, "path": out, "ms": ms, "chunks": len(chunks), "seconds": round(len(audio) / rate, 3)})
        except Exception as exc:
            emit({"id": req_id, "ok": False, "error": str(exc) or exc.__class__.__name__})
            if os.environ.get("KUMA_VOICE_DEBUG"):
                traceback.print_exc(file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
