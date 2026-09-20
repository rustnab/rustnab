#!/usr/bin/env bash
# Benchmark speech recognition and synthesis models with the prebuilt
# sherpa-onnx tools. aarch64 only. Downloads about 500 MB on first run.
#
# Recordings: if results/speech/{fr,en}-short.wav and fr-long.wav exist they
# are used, otherwise the script records them from the rabbit's microphones
# (interactive) or falls back to the test files shipped with the models.
source "$(dirname "$0")/lib.sh"
require curl tar bzip2 awk arecord
[ "$(uname -m)" = aarch64 ] || fail "this spike runs on the Zero 2 W with a 64-bit OS"
command -v /usr/bin/time >/dev/null || fail "GNU time missing. Run 00-prepare.sh."

OUT="$RESULTS/speech"; mkdir -p "$OUT"
BENCH="$HOME/rustnab-bench"; mkdir -p "$BENCH"; cd "$BENCH" || exit 1

V=v1.13.8
B=https://github.com/k2-fsa/sherpa-onnx/releases/download
TOOLS="sherpa-onnx-$V-linux-aarch64-shared-cpu"
MOON=sherpa-onnx-moonshine-tiny-en-int8
WHISPER=sherpa-onnx-whisper-tiny
KROKO=sherpa-onnx-streaming-zipformer-fr-kroko-2025-08-06
NEMO=sherpa-onnx-nemo-fast-conformer-ctc-en-de-es-fr-14288-int8
SIWIS=vits-piper-fr_FR-siwis-low
UPMC=vits-piper-fr_FR-upmc-medium
ALAN=vits-piper-en_GB-alan-low

fetch() { # <release-path> <name>
  [ -d "$2" ] && return
  log "downloading $2"
  curl -sSLo "$2.tar.bz2" "$B/$1/$2.tar.bz2"
  tar xjf "$2.tar.bz2" && rm "$2.tar.bz2"
}
fetch "$V" "$TOOLS"
for m in $MOON $WHISPER $KROKO $NEMO; do fetch asr-models "$m"; done
for m in $SIWIS $UPMC $ALAN; do fetch tts-models "$m"; done
export PATH="$BENCH/$TOOLS/bin:$PATH"
export LD_LIBRARY_PATH="$BENCH/$TOOLS/lib"

results_begin "Speech benchmark"

# --- recordings ---------------------------------------------------------------
rec() { # <file> <seconds> <prompt>
  [ -f "$OUT/$1" ] && return
  if prompt "$3 Recording ${2}s." 3; then
    arecord -q -D "$CARD_DEV" -f S16_LE -r 16000 -c 1 -d "$2" "$OUT/$1"
  fi
}
rec fr-short.wav 3 "Say a short French command, like 'quel temps fait-il aujourd'hui'."
rec en-short.wav 3 "Say a short English command, like 'what is the weather today'."
rec fr-long.wav 8 "Say a longer French sentence."
if [ ! -f "$OUT/fr-short.wav" ]; then
  warn "no microphone recordings; using the models' test files"
  cp "$NEMO/test_wavs/fr-french.wav" "$OUT/fr-short.wav" 2>/dev/null || true
  cp "$OUT/fr-short.wav" "$OUT/fr-long.wav" 2>/dev/null || true
  cp "$MOON/test_wavs/0.wav" "$OUT/en-short.wav" 2>/dev/null || true
fi
for f in fr-short en-short fr-long; do
  [ -f "$OUT/$f.wav" ] && result "audio $f" INFO "$(soxi -D "$OUT/$f.wav" 2>/dev/null || echo '?') s"
done

# --- runners ------------------------------------------------------------------
# bench <label> <file> <threads> <command...>
# Runs twice, keeps the second. Extracts wall seconds, RTF and peak RSS.
bench() {
  local label=$1 file=$2 threads=$3; shift 3
  [ -f "$OUT/$file.wav" ] || { result "$label / $file / $threads" SKIP "no audio"; return; }
  local logf="$OUT/$label-$file-t$threads.log"
  "$@" --num-threads="$threads" "$OUT/$file.wav" >/dev/null 2>&1 || true
  /usr/bin/time -v "$@" --num-threads="$threads" "$OUT/$file.wav" > "$logf" 2>&1 || { result "$label / $file / $threads" FAIL "see speech/$(basename "$logf")"; return; }
  local wall rss rtf text
  wall="$(grep 'Elapsed (wall clock)' "$logf" | awk '{print $NF}' | awk -F: '{ if (NF == 3) print $1*3600 + $2*60 + $3; else print $1*60 + $2 }')"
  rss="$(awk '/Maximum resident set size/ { printf "%.0f", $NF/1024 }' "$logf")"
  rtf="$(grep -i 'RTF' "$logf" | grep -oE '[0-9.]+$' | tail -1)"
  text="$(grep -oE '"text" *: *"[^"]*"' "$logf" | head -1 | cut -c1-80)"
  result "$label / $file / ${threads}t" INFO "wall=${wall}s rtf=${rtf:-?} rss=${rss}MB text=${text:-?}"
}

asr_moon()    { sherpa-onnx-offline --moonshine-preprocessor=$MOON/preprocess.onnx --moonshine-encoder=$MOON/encode.int8.onnx --moonshine-uncached-decoder=$MOON/uncached_decode.int8.onnx --moonshine-cached-decoder=$MOON/cached_decode.int8.onnx --tokens=$MOON/tokens.txt "$@"; }
asr_whisper() { sherpa-onnx-offline --whisper-encoder=$WHISPER/tiny-encoder.int8.onnx --whisper-decoder=$WHISPER/tiny-decoder.int8.onnx --tokens=$WHISPER/tiny-tokens.txt --whisper-language=fr --whisper-task=transcribe --whisper-tail-paddings=300 "$@"; }
asr_kroko()   { sherpa-onnx --tokens=$KROKO/tokens.txt --encoder=$KROKO/encoder.onnx --decoder=$KROKO/decoder.onnx --joiner=$KROKO/joiner.onnx --decoding-method=greedy_search "$@"; }
asr_nemo()    { sherpa-onnx-offline --nemo-ctc-model=$NEMO/model.int8.onnx --tokens=$NEMO/tokens.txt "$@"; }

log "recognition, 4 threads"
bench moonshine en-short 4 asr_moon
bench whisper   fr-short 4 asr_whisper
bench kroko     fr-short 4 asr_kroko
bench kroko     fr-long  4 asr_kroko
bench nemo      fr-short 4 asr_nemo
bench nemo      en-short 4 asr_nemo
bench nemo      fr-long  4 asr_nemo
log "recognition, 2 threads"
bench moonshine en-short 2 asr_moon
bench kroko     fr-short 2 asr_kroko
bench nemo      fr-short 2 asr_nemo
bench nemo      en-short 2 asr_nemo

# --- synthesis ----------------------------------------------------------------
FR_TEXT="Il fera douze degrés cet après-midi, avec des averses en fin de journée."
EN_TEXT="It will be twelve degrees this afternoon, with showers later in the day."
tts() { # <label> <model-dir> <onnx> <text>
  local logf="$OUT/tts-$1.log" wav="$OUT/tts-$1.wav"
  /usr/bin/time -v sherpa-onnx-offline-tts --vits-model="$2/$3" --vits-tokens="$2/tokens.txt" --vits-data-dir="$2/espeak-ng-data" --num-threads=4 --output-filename="$wav" "$4" > "$logf" 2>&1 \
    || { result "tts $1" FAIL "see speech/$(basename "$logf")"; return; }
  local wall rss dur rtf
  wall="$(awk '/^Elapsed seconds:/ {print $3}' "$logf")"
  dur="$(awk '/^Audio duration:/ {print $3}' "$logf")"
  rtf="$(grep -i 'RTF' "$logf" | grep -oE '[0-9.]+$' | tail -1)"
  rss="$(awk '/Maximum resident set size/ { printf "%.0f", $NF/1024 }' "$logf")"
  result "tts $1" INFO "wall=${wall}s audio=${dur}s rtf=${rtf:-?} rss=${rss}MB"
  if [ "$INTERACTIVE" = 1 ] && aplay -l 2>/dev/null | grep -q "$CARD"; then aplay -q -D "$CARD_DEV" "$wav" || true; fi
}
log "synthesis"
tts fr-siwis-low   $SIWIS fr_FR-siwis-low.onnx   "$FR_TEXT"
tts fr-upmc-medium $UPMC  fr_FR-upmc-medium.onnx "$FR_TEXT"
tts en-alan-low    $ALAN  en_GB-alan-low.onnx    "$EN_TEXT"

results_end
