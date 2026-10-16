#!/bin/bash
set -euo pipefail

ROOT="${KUMA_HOME:-$HOME/Library/Application Support/Kuma}"
VOICE_DIR="${KUMA_VOICE_DIR:-$ROOT/voice}"
VENV="$VOICE_DIR/.venv"
MODELS="$VOICE_DIR/models"
LOCAL_MODELS="${KUMA_LOCAL_MODELS:-$HOME/.claude/jarvis/models}"
BASE_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf 'kuma-setup: %s\n' "$*"; }

mkdir -p "$VOICE_DIR" "$MODELS"
say "installing into $VOICE_DIR"

find_uv() {
    if command -v uv >/dev/null 2>&1; then command -v uv; return 0; fi
    for c in "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv" /opt/homebrew/bin/uv /usr/local/bin/uv; do
        if [ -x "$c" ]; then echo "$c"; return 0; fi
    done
    return 1
}

if [ -x "$VENV/bin/python" ] && "$VENV/bin/python" -c "import kokoro_onnx, soundfile" >/dev/null 2>&1; then
    say "python environment already ready"
else
    if UV="$(find_uv)"; then
        say "creating python 3.12 environment with uv"
        "$UV" venv --python 3.12 --allow-existing "$VENV"
        say "installing kokoro-onnx and soundfile"
        VIRTUAL_ENV="$VENV" "$UV" pip install --python "$VENV/bin/python" kokoro-onnx soundfile
    else
        PY=""
        for c in python3.12 python3.13 python3.11 python3; do
            if command -v "$c" >/dev/null 2>&1; then PY="$(command -v "$c")"; break; fi
        done
        if [ -z "$PY" ]; then
            say "error: no python3 found, install uv or python 3.12"
            exit 3
        fi
        say "creating python environment with $PY"
        "$PY" -m venv "$VENV"
        say "installing kokoro-onnx and soundfile"
        "$VENV/bin/python" -m pip install --upgrade pip >/dev/null
        "$VENV/bin/python" -m pip install kokoro-onnx soundfile
    fi
    "$VENV/bin/python" -c "import kokoro_onnx, soundfile" || { say "error: python packages failed to import"; exit 4; }
    say "python environment ready"
fi

fetch_model() {
    local name="$1" min_bytes="$2"
    local dest="$MODELS/$name"
    if [ -f "$dest" ] && [ "$(stat -f%z "$dest")" -ge "$min_bytes" ]; then
        say "$name already present"
        return 0
    fi
    rm -f "$dest"
    local src="$LOCAL_MODELS/$name"
    if [ -f "$src" ] && [ "$(stat -f%z "$src")" -ge "$min_bytes" ]; then
        if ln "$src" "$dest" 2>/dev/null; then
            say "$name hard linked from $LOCAL_MODELS"
            return 0
        fi
        if cp -c "$src" "$dest" 2>/dev/null || cp "$src" "$dest"; then
            say "$name copied from $LOCAL_MODELS"
            return 0
        fi
    fi
    say "downloading $name"
    curl -fL --retry 3 --progress-bar -C - -o "$dest.part" "$BASE_URL/$name"
    if [ "$(stat -f%z "$dest.part")" -lt "$min_bytes" ]; then
        say "error: $name download looks truncated"
        exit 5
    fi
    mv "$dest.part" "$dest"
    say "$name downloaded"
}

fetch_model "kokoro-v1.0.onnx" 300000000
fetch_model "voices-v1.0.bin" 20000000

if [ -f "$HERE/kuma_voice.py" ] && [ "$HERE" != "$VOICE_DIR" ]; then
    cp "$HERE/kuma_voice.py" "$VOICE_DIR/kuma_voice.py"
    say "helper script installed"
fi

HELPER="$VOICE_DIR/kuma_voice.py"
[ -f "$HELPER" ] || HELPER="$HERE/kuma_voice.py"
if [ -f "$HELPER" ]; then
    say "verifying voice"
    CHECK_WAV="$VOICE_DIR/.verify.wav"
    REPLY="$(printf '{"id":"verify","text":"Kuma is ready.","voice":"am_onyx","speed":1.0,"out":"%s"}\n' "$CHECK_WAV" \
        | "$VENV/bin/python" "$HELPER" "$MODELS/kokoro-v1.0.onnx" "$MODELS/voices-v1.0.bin" 2>&1 || true)"
    rm -f "$CHECK_WAV"
    if ! printf '%s' "$REPLY" | grep -q '"ok": true'; then
        say "error: voice check failed: $(printf '%s' "$REPLY" | tail -n 1)"
        exit 6
    fi
    say "voice check passed"
fi

say "done"
