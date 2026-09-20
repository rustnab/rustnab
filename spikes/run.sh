#!/usr/bin/env bash
# Harness: push the spike scripts and the overlay to a rabbit over SSH, run one
# script there, and pull the results back into spikes/results/<host>/.
#
#   spikes/run.sh user@rabbit.local 11            # run 11-sound-test.sh
#   spikes/run.sh user@rabbit.local 20 --no-interactive
#   spikes/run.sh user@rabbit.local shell         # just open a shell there
#   spikes/run.sh user@rabbit.local pull          # only fetch results
#
# Needs only ssh and tar on both ends. No rsync, no agent on the rabbit.
set -euo pipefail

HOST="${1:?usage: run.sh user@host <script-number|shell|pull> [args]}"
WHAT="${2:?usage: run.sh user@host <script-number|shell|pull> [args]}"
shift 2
REPO="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE=rustnab-spikes
LOCAL_RESULTS="$REPO/spikes/results/${HOST#*@}"
SSH=(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$HOST")

push() {
  tar -C "$REPO" -czf - spikes/lib.sh spikes/[0-9]*.sh hardware/overlays \
    | "${SSH[@]}" "mkdir -p $REMOTE && tar -C $REMOTE -xzf - && chmod +x $REMOTE/spikes/*.sh"
}

pull() {
  mkdir -p "$LOCAL_RESULTS"
  "${SSH[@]}" "cd $REMOTE 2>/dev/null && [ -d results ] && tar -czf - results || true" \
    | tar -C "$LOCAL_RESULTS" -xzf - 2>/dev/null || true
  echo "results in $LOCAL_RESULTS/results"
}

case "$WHAT" in
  shell) exec "${SSH[@]}" -t ;;
  pull)  pull ;;
  *)
    push
    script="$("${SSH[@]}" "ls $REMOTE/spikes/ | grep -E '^$WHAT-' | head -1")"
    [ -n "$script" ] || { echo "no script starting with $WHAT-" >&2; exit 1; }
    "${SSH[@]}" -t "cd $REMOTE && bash spikes/$script $*" || echo "script exited with $?" >&2
    pull
    ;;
esac
