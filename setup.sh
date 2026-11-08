#!/usr/bin/env bash
# kde-piper-tts setup — wire Piper into speech-dispatcher as the default voice.
# KWrite/Kate "Speak Text", Orca, spd-say and every other speech-dispatcher
# client follow this default. Targeted at CachyOS/Arch (Plasma 6, PipeWire).
#
# Idempotent: re-runs are safe. It never edits an existing user speechd.conf.
#
# Usage:     ./setup.sh                       (en_US-lessac-medium)
#            VOICE=en_US-ryan-high ./setup.sh (any rhasspy/piper-voices model)
#            LENGTH_SCALE=none ./setup.sh     (model default pace, no slowdown)
set -euo pipefail

VOICE="${VOICE:-en_US-lessac-medium}"
LENGTH_SCALE="${LENGTH_SCALE:-1.1}"
VOICE_DIR="${HOME}/.local/share/piper/voices"
VOICES_URL="https://huggingface.co/rhasspy/piper-voices/resolve/main"
SPEECH_MODULES="/usr/lib/speech-dispatcher/speech-dispatcher-modules"
HOME_CONF_DIR="${HOME}/.config/speech-dispatcher"
CFG="${HOME_CONF_DIR}/speechd.conf"
MARK_START="# >>> kde-piper-tts >>>"
MARK_END="# <<< kde-piper-tts <<<"

info() { printf '%s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# --- 0. prerequisites -------------------------------------------------------
PIPER_BIN="$(command -v piper || true)"
[ -n "$PIPER_BIN" ] || cat >&2 <<EOF
ERROR: 'piper' not found on PATH.
  pip wheel:        pipx install piper-tts
  manual binary:    https://github.com/rhasspy/piper/releases  (put it in ~/.local/bin)
EOF
[ -n "$PIPER_BIN" ] || exit 1

command -v pacat >/dev/null 2>&1 || die "pacat not found (pipewire-pulse). Check your audio stack."
command -v curl  >/dev/null 2>&1 || die "curl not found."
command -v python3 >/dev/null 2>&1 || die "python3 not found (used to read the model sample rate)."

# Detect whether piper needs LD_LIBRARY_PATH (common with pip/manual trees).
LD_PREFIX=""
if ! "$PIPER_BIN" --help >/dev/null 2>&1; then
  LIBS_DIR="$(dirname "$(dirname "$PIPER_BIN")")/lib"
  if find "$LIBS_DIR" -name 'libpiper_phonemize*' >/dev/null 2>&1; then
    LD_PREFIX="LD_LIBRARY_PATH=$LIBS_DIR "
    info "Note: piper needs LD_LIBRARY_PATH set; baking '$LIBS_DIR' into the module config."
  fi
  LD_PREFIX="${LD_PREFIX:-LD_LIBRARY_PATH=$(dirname "$(find "$HOME" /usr -name 'libpiper_phonemize.so*' 2>/dev/null | head -n1)") }"
  "$PIPER_BIN" --help >/dev/null 2>&1 || true
fi
# Only keep the prefix if an LD path was actually needed.
if [ -n "$LD_PREFIX" ] && ! env ${LD_PREFIX} "$PIPER_BIN" --help >/dev/null 2>&1; then
  die "Could not make '$PIPER_BIN' run even with LD_LIBRARY_PATH — check its libs."
fi

# --- 1. voice model ---------------------------------------------------------
mkdir -p "$VOICE_DIR"
if [ ! -f "$VOICE_DIR/${VOICE}.onnx" ]; then
  lang="${VOICE%%-*}"          # en_US-lessac-medium -> en
  tail="${VOICE#*-}"           #                       en_US-lessac-medium
  name="${tail%-*}"            #                       en_US / lessac
  size="${tail##*-}"           #                       medium
  info "Downloading voice $VOICE (~60-130 MB) from $VOICES_URL ..."
  curl -L --fail -o "$VOICE_DIR/${VOICE}.onnx" \
    "$VOICES_URL/$lang/$lang/$name/$size/${VOICE}.onnx"
  curl -L --fail -o "$VOICE_DIR/${VOICE}.onnx.json" \
    "$VOICES_URL/$lang/$lang/$name/$size/${VOICE}.onnx.json"
else
  info "Voice model present: $VOICE_DIR/${VOICE}.onnx"
fi

MODEL_JSON="$VOICE_DIR/${VOICE}.onnx.json"
[ -f "$MODEL_JSON" ] || die "Missing model config $MODEL_JSON"
# Piper voices vary in sample rate (22050 is common; newer ones differ) —
# read it from the model instead of hard-coding it.
SAMPLE_RATE="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['audio']['sample_rate'])" "$MODEL_JSON")"
info "Sample rate for $VOICE: ${SAMPLE_RATE} Hz"

# --- 2. generic module conf --------------------------------------------------
MODCONF="$HOME_CONF_DIR/piper-generic.conf"
mkdir -p "$HOME_CONF_DIR"
[ "$LENGTH_SCALE" = "none" ] && LS_FLAGS="" || LS_FLAGS="--length_scale ${LENGTH_SCALE}"

cat > "$MODCONF" <<CONF
# Generic output module for Speech Dispatcher: Piper TTS via sd_generic.
# See https://github.com/eonicman/kde-piper-tts for the full guide.
# Paths are machine-specific; --output_raw is HEADERLESS PCM (hence pacat --raw).
# Do NOT pipe into paplay (it cannot parse a raw PCM stream).

Debug 0

GenericExecuteSynth \\
"printf %s \\'\$DATA\\' | ${LD_PREFIX}${PIPER_BIN} --model ${VOICE_DIR}/${VOICE}.onnx --output_raw --quiet ${LS_FLAGS} | /usr/bin/pacat --raw --format=s16le --rate=${SAMPLE_RATE} --channels=1 --latency-msec=20"

GenericSoundIconFolder "/usr/share/sounds/sound-icons/"

AddVoice	"en"	"FEMALE1"	"${VOICE}"

DefaultVoice    "${VOICE}"
CONF
info "Wrote $MODCONF"

# --- 3. user speechd.conf ----------------------------------------------------
CREATED_CFG=""
if [ ! -f "$CFG" ]; then
  cp /etc/speech-dispatcher/speechd.conf "$CFG"
  CREATED_CFG=1
  info "Copied /etc/speech-dispatcher/speechd.conf -> $CFG"
fi

if grep -qF "$MARK_START" "$CFG"; then
  info "kde-piper-tts block already present in $CFG (leaving it as is)."
elif [ -n "$CREATED_CFG" ]; then
  cat >> "$CFG" <<EOF

${MARK_START}
AddModule "piper"     "${SPEECH_MODULES}/sd_generic"   "${MODCONF}"  "piper.log"
AddModule "espeak-ng" "${SPEECH_MODULES}/sd_espeak-ng" "/etc/speech-dispatcher/modules/espeak-ng.conf"  "espeak-ng.log"
DefaultModule piper
LanguageDefaultModule "en"  "piper"
${MARK_END}
EOF
  info "Appended kde-piper-tts block to $CFG"
else
  # A user config exists that we did not create — do not edit it silently.
  info "NOTE: $CFG already exists and has no kde-piper-tts block."
  info "      Add the following block to the END of it (or delete the file first),"
  info "      substituting your home directory:"
  sed "s|/home/YOU|${HOME}|g" <<EOF

${MARK_START}
AddModule "piper"     "${SPEECH_MODULES}/sd_generic"   "${MODCONF}"  "piper.log"
AddModule "espeak-ng" "${SPEECH_MODULES}/sd_espeak-ng" "/etc/speech-dispatcher/modules/espeak-ng.conf"  "espeak-ng.log"
DefaultModule piper
LanguageDefaultModule "en"  "piper"
${MARK_END}
EOF
fi

# --- 4. restart + test instructions ------------------------------------------
cat >&2 <<EOF

Done. Restart speech-dispatcher (it re-spawns automatically):
  pkill -x speech-dispatch

Then verify:
  spd-say -O             # should list: piper  (+ espeak-ng fallback)
  spd-say -L             # should list only your piper voice
  spd-say -w "It works"  # -o vs -O vs -L are case-sensitive

KWrite/Kate: Tools -> Speak Text. Orca and everything else that uses
speech-dispatcher follows the same default voice now.
EOF
