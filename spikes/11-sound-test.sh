#!/usr/bin/env bash
# Test the mainline wm8960 codec through the tagtagtag overlay: kernel log,
# playback at two rates, microphone capture, jack detect, volume switches.
# Run after 10-sound-install.sh and a reboot.
source "$(dirname "$0")/lib.sh"
require aplay arecord amixer speaker-test sox gpioset gpiomon
CHIP="$(gpiochip)"
OUT="$RESULTS/sound"; mkdir -p "$OUT"

results_begin "Sound test"

# --- kernel log and card presence -------------------------------------------
dmesg_out="$(sudo dmesg | grep -iE 'wm8960|simple-audio|i2s|asoc' || true)"
echo "$dmesg_out" > "$OUT/dmesg.txt"

if aplay -l | grep -q "$CARD"; then result "card $CARD present" PASS
else result "card $CARD present" FAIL "$(aplay -l | tr '\n' ';')"; results_end; exit 1; fi

if echo "$dmesg_out" | grep -q "slave mode, but proceeding with no clock configuration"; then
  result "PLL clock configured" FAIL "codec has no clock input; overlay is wrong. Stop here."
  results_end; exit 1
else result "PLL clock configured" PASS "no slave-mode warning"; fi

if echo "$dmesg_out" | grep -qiE 'failed to configure clock|hw_params\(\) failed'; then
  result "no clock or hw_params errors" FAIL "$(echo "$dmesg_out" | grep -iE 'failed' | head -3 | tr '\n' ';')"
else result "no clock or hw_params errors" PASS; fi

# --- amplifier on for the duration of the test -------------------------------
# GPIO 7 shutdown and 8 mute are active low. gpioset holds them until killed.
gpioset -c "$CHIP" 7=1 8=1 &
AMP_PID=$!
trap 'kill $AMP_PID 2>/dev/null || true' EXIT
sleep 0.2
result "amplifier enabled" PASS "gpioset holding 7=1 8=1"

# --- mixer -------------------------------------------------------------------
# Control names are mainline's and shift slightly between kernels, so a miss is
# a warning, not an abort. The list of controls is saved for the port later.
amixer -c "$CARD" contents > "$OUT/mixer-controls.txt"
mset() {
  if amixer -c "$CARD" -q sset "$1" "$2" 2>/dev/null; then :
  else warn "mixer control '$1' not found"; echo "missing: $1" >> "$OUT/mixer-missing.txt"; fi
}
mset 'Left Output Mixer PCM' on
mset 'Right Output Mixer PCM' on
mset 'Playback' 230
mset 'Headphone' 100
mset 'Speaker' 100
mset 'Capture' 40
mset 'Left Input Boost Mixer LINPUT1' 3
mset 'Right Input Boost Mixer RINPUT1' 3
mset 'Left Boost Mixer LINPUT1' on
mset 'Right Boost Mixer RINPUT1' on
missing="$( [ -f "$OUT/mixer-missing.txt" ] && wc -l < "$OUT/mixer-missing.txt" || echo 0)"
result "mixer controls set" "$([ "$missing" = 0 ] && echo PASS || echo INFO)" "$missing control names missing, see sound/mixer-missing.txt"

# --- playback ----------------------------------------------------------------
play_rate() { # <rate>
  local f="$OUT/sine-$1.wav"
  sox -n -r "$1" -c 2 "$f" synth 2 sine 440 vol 0.3
  aplay -q -D "$CARD_DEV" "$f" &
  local pid=$!
  sleep 0.7
  local hw; hw="$(grep -E '^(rate|format)' "/proc/asound/$CARD/pcm0p/sub0/hw_params" 2>/dev/null | tr '\n' ' ' || echo "hw_params unreadable")"
  local rc=0; wait $pid || rc=$?
  [ $rc = 0 ] && result "playback at $1 Hz" PASS "$hw" || result "playback at $1 Hz" FAIL "aplay exit $rc"
}
log "playing 440 Hz sines. Listen: a flat, out of tune tone means the PLL is wrong."
play_rate 44100
play_rate 48000
play_rate 16000

if prompt "Did the tones sound in tune (not flat)? Press Enter for yes, type n then Enter for no." 15; then
  result "tone in tune (listener)" INFO "answered by listener, see notes"
else
  result "tone in tune (listener)" SKIP "non-interactive"
fi

# --- capture -----------------------------------------------------------------
prompt "Recording 5 seconds from the onboard microphones. Speak to the rabbit." 3 || true
arecord -q -D "$CARD_DEV" -f S16_LE -r 16000 -c 2 -d 5 "$OUT/mic.wav" \
  && result "capture 16 kHz stereo" PASS "sound/mic.wav" \
  || result "capture 16 kHz stereo" FAIL "arecord exit $?"

if [ -f "$OUT/mic.wav" ]; then
  stats="$(sox "$OUT/mic.wav" -n stats 2>&1 | grep -E 'RMS lev dB|Pk lev dB' | tr -s ' ' | tr '\n' ';')"
  result "capture level" INFO "$stats"
  # Ticks show up as a clear peak above the noise floor at ~6 Hz. The full
  # analysis happens on a laptop; here we only keep the file and a coarse stat.
  if sudo dmesg | grep -qi 'sync error'; then
    result "I2S sync" FAIL "I2S SYNC error in kernel log"
  else result "I2S sync" PASS "no sync error in kernel log"; fi
  aplay -q -D "$CARD_DEV" "$OUT/mic.wav" || true
fi

# --- jack detect --------------------------------------------------------------
jack_state() { amixer -c "$CARD" contents 2>/dev/null | grep -A2 -i 'jack' | grep -oE 'values=(on|off)' | head -1 || echo "values=unknown"; }
before="$(jack_state)"
if prompt "Plug a 3.5 mm cable into the line out now." 15; then
  after="$(jack_state)"
  [ "$before" != "$after" ] && result "jack detect" PASS "$before -> $after" || result "jack detect" FAIL "no change: $before"
  prompt "Unplug it again." 10 || true
else
  result "jack detect" SKIP "non-interactive; state now $before"
fi

# --- volume switches ------------------------------------------------------------
if prompt "Turn the volume wheel both ways for the next 10 seconds." 2; then
  timeout 10s gpiomon -c "$CHIP" -E realtime --format '%S %E %o' 22 27 > "$OUT/volume-events.txt" || true
  n="$(wc -l < "$OUT/volume-events.txt")"
  [ "$n" -gt 0 ] && result "volume switches" PASS "$n events, see sound/volume-events.txt" || result "volume switches" FAIL "no events on 22 or 27"
else
  result "volume switches" SKIP "non-interactive"
fi

results_end
