# Shared helpers for the milestone 0 spike scripts. Source, do not run.
#
# Every script writes human-readable results to $RESULTS/<script>.md and
# echoes the same lines, so a run over SSH shows the result as it happens and
# the harness can pull the file afterwards.

set -euo pipefail

SPIKE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS="$SPIKE_ROOT/results"
mkdir -p "$RESULTS"

INTERACTIVE=1
for arg in "$@"; do
  case "$arg" in
    --no-interactive) INTERACTIVE=0 ;;
  esac
done

RESULT_FILE="$RESULTS/$(basename "$0" .sh).md"

log()    { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn()   { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
fail()   { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# result <check> <PASS|FAIL|SKIP|INFO> [detail]
result() {
  local line
  line="| $1 | $2 | ${3:-} |"
  echo "$line"
  echo "$line" >> "$RESULT_FILE"
}

results_begin() {
  {
    echo "# $1"
    echo
    echo "Host: $(hostname), $(date -Is)"
    echo "Kernel: $(uname -r), $(uname -m)"
    echo "Model: $(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"
    echo
    echo "| Check | Result | Detail |"
    echo "|---|---|---|"
  } > "$RESULT_FILE"
}

results_end() {
  echo
  log "results written to $RESULT_FILE"
}

require() {
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is missing. Run 00-prepare.sh first."
  done
}

# Ask the person at the rabbit to do something, then wait. In non-interactive
# mode return 1 so the caller can record SKIP.
prompt() {
  local seconds="${2:-20}"
  if [ "$INTERACTIVE" = 0 ]; then
    return 1
  fi
  printf '\n\033[1;35m>>> %s\033[0m\n' "$1" >&2
  printf '    continuing in %ss (or press Enter)\n' "$seconds" >&2
  read -r -t "$seconds" _ </dev/tty 2>/dev/null || true
  return 0
}

gpiochip() {
  # The main GPIO block is gpiochip0 on every Pi Zero, but ask rather than assume.
  gpiodetect 2>/dev/null | awk '/pinctrl-bcm/ {gsub(/\[|\]/,"",$2); print $1; exit}'
}

CARD="tagtagtagsound"
# shellcheck disable=SC2034  # used by the scripts that source this file
CARD_DEV="plughw:CARD=$CARD"
