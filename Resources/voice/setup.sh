#!/bin/bash
set -euo pipefail
ROOT="${KUMA_HOME:-$HOME/Library/Application Support/Kuma}"
VOICE_DIR="${KUMA_VOICE_DIR:-$ROOT/voice}"
VENV="$VOICE_DIR/.venv"
MODELS="$VOICE_DIR/models"
LOCAL_MODELS="${KUMA_LOCAL_MODELS:-}"
BASE_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf 'kuma-setup: %s\n' "$*"; }
step() { printf 'kuma-step: %s\n' "$*"; }
fail() { printf 'kuma-error: %s\n' "$*"; exit "${2:-1}"; }

mkdir -p "$VOICE_DIR" "$MODELS"
say "installing into $VOICE_DIR"

find_uv() {
    if command -v uv >/dev/null 2>&1; then command -v uv; return 0; fi
    for c in "$VOICE_DIR/bin/uv" "$HOME/.local/bin/uv" "$HOME/.cargo/bin/uv" /opt/homebrew/bin/uv /usr/local/bin/uv; do
        if [ -x "$c" ]; then echo "$c"; return 0; fi
    done
    return 1
}

install_uv() {
    step "Getting the installer"
    mkdir -p "$VOICE_DIR/bin"
    curl -fsSL --retry 3 https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR="$VOICE_DIR/bin" UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 sh >/dev/null 2>&1 || return 1
    [ -x "$VOICE_DIR/bin/uv" ]
}

if [ -x "$VENV/bin/python" ] && "$VENV/bin/python" -c "import kokoro_onnx, soundfile" >/dev/null 2>&1; then
    say "python environment already ready"
else
    UV="$(find_uv || true)"
    if [ -z "$UV" ] && install_uv; then
        UV="$VOICE_DIR/bin/uv"
    fi
    if [ -n "$UV" ]; then
        step "Setting up Python"
        say "creating python 3.12 environment with $UV"
        "$UV" venv --python 3.12 --allow-existing "$VENV" || fail "Could not set up Python. Check your internet connection and try again." 3
        step "Installing voice libraries"
        VIRTUAL_ENV="$VENV" "$UV" pip install --python "$VENV/bin/python" kokoro-onnx soundfile || fail "Could not install the voice libraries. Check your internet connection and try again." 4
    else
        PY=""
        for c in python3.13 python3.12 python3.11 python3.10; do
            if command -v "$c" >/dev/null 2>&1; then PY="$(command -v "$c")"; break; fi
        done
        [ -n "$PY" ] || fail "Could not get Python. Check your internet connection, or install uv from astral.sh, then try again." 3
        step "Setting up Python"
        "$PY" -m venv "$VENV" || fail "Could not set up Python with $PY." 3
        step "Installing voice libraries"
        "$VENV/bin/python" -m pip install --upgrade pip >/dev/null
        "$VENV/bin/python" -m pip install kokoro-onnx soundfile || fail "Could not install the voice libraries. Check your internet connection and try again." 4
    fi
    "$VENV/bin/python" -c "import kokoro_onnx, soundfile" || fail "The voice libraries did not load." 4
    say "python environment ready"
fi

fetch_model() {
    local name="$1" size="$2" label="$3"
    local dest="$MODELS/$name"
    local min_bytes=$((size * 9 / 10))
    if [ -f "$dest" ] && [ "$(stat -f%z "$dest")" -ge "$min_bytes" ]; then
        say "$name already present"
        return 0
    fi
    rm -f "$dest"
    if [ -n "$LOCAL_MODELS" ] && [ -f "$LOCAL_MODELS/$name" ] && [ "$(stat -f%z "$LOCAL_MODELS/$name")" -ge "$min_bytes" ]; then
        if ln "$LOCAL_MODELS/$name" "$dest" 2>/dev/null || cp "$LOCAL_MODELS/$name" "$dest"; then
            say "$name copied from $LOCAL_MODELS"
            return 0
        fi
    fi
    step "$label"
    curl -fsL --retry 3 -C - -o "$dest.part" "$BASE_URL/$name" &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        local have=0
        [ -f "$dest.part" ] && have="$(stat -f%z "$dest.part")"
        printf 'kuma-progress: %d\n' $((have * 100 / size))
        sleep 1
    done
    wait "$pid" || fail "The voice download failed. Check your internet connection and try again." 5
    [ "$(stat -f%z "$dest.part")" -ge "$min_bytes" ] || fail "The voice download was incomplete. Try again." 5
    mv "$dest.part" "$dest"
    say "$name downloaded"
}

fetch_model "kokoro-v1.0.onnx" 325532387 "Downloading the voice model"
fetch_model "voices-v1.0.bin" 28214398 "Downloading the voices"

if [ -f "$HERE/kuma_voice.py" ] && [ "$HERE" != "$VOICE_DIR" ]; then
    cp "$HERE/kuma_voice.py" "$VOICE_DIR/kuma_voice.py"
    say "helper script installed"
fi

HELPER="$VOICE_DIR/kuma_voice.py"
[ -f "$HELPER" ] || HELPER="$HERE/kuma_voice.py"
if [ -f "$HELPER" ]; then
    step "Checking the voice"
    CHECK_WAV="$VOICE_DIR/.verify.wav"
    REPLY="$(printf '{"id":"verify","text":"Kuma is ready.","voice":"am_onyx","speed":1.0,"out":"%s"}\n' "$CHECK_WAV" \
        | "$VENV/bin/python" "$HELPER" "$MODELS/kokoro-v1.0.onnx" "$MODELS/voices-v1.0.bin" 2>&1 || true)"
    rm -f "$CHECK_WAV"
    printf '%s' "$REPLY" | grep -q '"ok": true' || fail "The voice check failed: $(printf '%s' "$REPLY" | tail -n 1)" 6
    say "voice check passed"
fi

say "ready"
