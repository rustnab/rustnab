#!/usr/bin/env bash
# Drive each ear motor from userspace and record the encoder edges. Checks that
# the edge count and spacing match the known signal, so no kernel module is
# needed for the ears.
source "$(dirname "$0")/lib.sh"
require gpioset gpiomon awk
CHIP="$(gpiochip)"
OUT="$RESULTS/ears"; mkdir -p "$OUT"

# BCM pins. Encoder, motor forward, motor backward.
declare -A ENC=([left]=24 [right]=23)
declare -A FWD=([left]=12 [right]=10)
declare -A BWD=([left]=11 [right]=9)
RUN_SECONDS=6

results_begin "Ears from userspace"

# Print: edges, typical interval ms, longest interval ms, shortest interval ms.
# Plain awk plus sort: Debian's default awk is mawk, which has no asort.
analyze() {
  local n; n="$(grep -c . "$1" || true)"
  if [ "$n" -lt 2 ]; then echo "$n 0 0 0"; return; fi
  awk 'NR > 1 { printf "%.0f\n", ($1 - prev) * 1000 } { prev = $1 }' "$1" | sort -n > "$1.intervals"
  local m; m="$(wc -l < "$1.intervals")"
  echo "$n $(sed -n "$((m / 2 + 1))p" "$1.intervals") $(tail -1 "$1.intervals") $(head -1 "$1.intervals")"
}

run_case() { # <ear> <direction>
  local ear=$1 dir=$2 on off
  local enc=${ENC[$ear]}
  if [ "$dir" = forward ]; then on=${FWD[$ear]}; off=${BWD[$ear]}; else on=${BWD[$ear]}; off=${FWD[$ear]}; fi
  local f="$OUT/$ear-$dir.txt"
  log "$ear ear $dir for ${RUN_SECONDS}s, watching GPIO $enc"
  timeout $((RUN_SECONDS + 1))s gpiomon -c "$CHIP" -e falling -E realtime --format '%S %E %o' "$enc" > "$f" &
  local mon=$!
  sleep 0.3
  gpioset -c "$CHIP" -p "${RUN_SECONDS}s" "$on=1" "$off=0"
  wait $mon || true
  read -r edges typ hi lo < <(analyze "$f")
  local verdict=PASS
  # 17 slots per turn, about 4 s per turn: expect roughly 20 to 30 edges in 6 s.
  [ "$edges" -ge 12 ] || verdict=FAIL
  [ "$typ" -ge 150 ] && [ "$typ" -le 300 ] || verdict=FAIL
  [ "$hi" -ge 600 ] || verdict=FAIL      # the index gap must show up once
  [ "$lo" -ge 60 ] || verdict=FAIL       # anything shorter is bounce
  result "$ear $dir" "$verdict" "edges=$edges typical=${typ}ms gap=${hi}ms shortest=${lo}ms"
}

for ear in left right; do
  for dir in forward backward; do
    run_case "$ear" "$dir"
    sleep 0.5
  done
done

# Timestamps come from the kernel at interrupt time. If %S printed integers
# only, every interval above would be a multiple of 1000 and the checks
# meaningless, so say so.
if awk '{ if ($1 != int($1)) { found=1; exit } } END { exit !found }' "$OUT"/left-forward.txt; then
  result "timestamps have sub-second precision" PASS
else
  result "timestamps have sub-second precision" FAIL "gpiomon printed whole seconds; re-run with a different --format"
fi

for ear in left right; do
  if prompt "Turn the $ear ear by hand now (motors are off)." 2; then
    if timeout 20s gpiomon -c "$CHIP" -e falling -n 1 "${ENC[$ear]}" >/dev/null 2>&1; then
      result "$ear hand turn detected" PASS
    else result "$ear hand turn detected" FAIL "no edge within 20 s"; fi
  else
    result "$ear hand turn detected" SKIP "non-interactive"
  fi
done

results_end
