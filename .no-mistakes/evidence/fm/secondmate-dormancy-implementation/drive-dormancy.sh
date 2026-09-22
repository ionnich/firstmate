#!/usr/bin/env bash
# Live-drive driver for the secondmate dormancy change. Runs the REAL product
# scripts against isolated FM_HOME state. Evidence printed to stdout.
set -u
ROOT=${ROOT:?}
EV=${EV:?}
export FM_GATE_REFUSE_BYPASS=1

T=$(mktemp -d /tmp/fm-dormancy-live.XXXXXX)
MATE=$T/mate
PARENT=$T/parent
mkdir -p "$MATE/state" "$MATE/data" "$PARENT/state" "$PARENT/data"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$MATE/data/backlog.md"
printf -- '- mate - local mate (home: %s; scope: test; projects: none; added 2026-01-01)\n' "$MATE" > "$PARENT/data/secondmates.md"
printf 'kind=secondmate\nhome=%s\nbackend=tmux\ntarget=firstmate:fm-mate\nwindow=firstmate:fm-mate\nworktree=%s\nproject=test\nharness=codex\nmode=secondmate\n' "$MATE" "$MATE" > "$PARENT/state/mate.meta"
printf 'working: idle\n' > "$PARENT/state/mate.status"

dorm() { FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-secondmate-dormancy.sh" "$@"; }

echo "======== sweep exclusion ========"
source "$ROOT/bin/fm-ff-lib.sh"
source "$ROOT/bin/fm-wake-lib.sh"
source "$ROOT/bin/fm-secondmate-dormancy-lib.sh"
dorm mate enter >/dev/null
echo "sweep-while-dormant=[$(live_secondmate_meta_records "$PARENT/state" "$PARENT/data/secondmates.md")]"
fm_secondmate_dormancy_clear "$PARENT/state" mate
echo "sweep-while-awake=[$(live_secondmate_meta_records "$PARENT/state" "$PARENT/data/secondmates.md" | cut -d'|' -f1)]"

echo "======== fm-send routine refusal ========"
dorm mate enter >/dev/null
FM_SEND_WAKE_DORMANT=0 FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-send.sh" fm-mate 'routine request'; echo "rc=$?"
echo "marker-after-routine-refusal=$(test -f "$PARENT/state/mate.dormant" && echo present || echo absent)"

echo "======== bearings: dormant excluded from unhealthy + endpoints projection ========"
out=$(FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-bearings-snapshot.sh" --json 2>/dev/null)
echo "$out" | jq -c '{unhealthy_dormant:[.unhealthy_endpoints[]? | select(.id=="mate")] , endpoints_dormant:[.endpoints[]? | select(.id=="mate") | {id,dormant}]}' 2>/dev/null || echo "bearings-jq-failed: $out"

echo "======== session-start digest dormant label ========"
# session-start reads state/*.meta; drive the digest label path directly by
# checking what fm-session-start prints for a dormant mate. It needs a full
# session-start environment; if it is too heavy, report the label from the
# source path the test exercises instead.
if [ -x "$ROOT/bin/fm-session-start.sh" ]; then
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_SKIP_SECONDMATE_INHERIT=1 FM_SKIP_SECONDMATE_SYNC=1 \
    "$ROOT/bin/fm-session-start.sh" 2>&1 | grep -E 'endpoint: (dormant|dead)' || echo "no-endpoint-line"
else
  echo "no-session-start-script"
fi

echo "======== leave on never-launched dormant mate ========"
# wake path: no .meta record -> fm-spawn.sh --secondmate. Record what happens.
rm -f "$PARENT/state/mate.meta"
dorm mate enter >/dev/null
echo "before-leave marker=$(test -f "$PARENT/state/mate.dormant" && echo present || echo absent)"
dorm mate leave; echo "rc=$?"
echo "after-leave marker=$(test -f "$PARENT/state/mate.dormant" && echo present || echo absent)"

echo "======== real tmux dead-stop cycle ========"
# Start a real tmux server with a bare-shell window; enter must stop it and only
# then record the marker; the re-read must see missing.
if command -v tmux >/dev/null 2>&1; then
  TMUX_SESSION="fmdorm$(date +%s)"
  tmux new-session -d -s "$TMUX_SESSION" -n fm-realmate 'sleep 1000'
  printf 'kind=secondmate\nhome=%s\nbackend=tmux\ntarget=%s:fm-realmate\nwindow=%s:fm-realmate\nworktree=%s\nproject=test\nharness=codex\nmode=secondmate\n' "$MATE" "$TMUX_SESSION" "$TMUX_SESSION" "$MATE" > "$PARENT/state/mate.meta"
  printf 'working: idle\n' > "$PARENT/state/mate.status"
  rm -f "$PARENT/state/mate.dormant"
  echo "pre-enter windows=$(tmux list-windows -t "$TMUX_SESSION" -F '#{window_name}' 2>&1 | tr '\n' ' ')"
  dorm mate enter; echo "enter-rc=$?"
  echo "post-enter marker=$(test -f "$PARENT/state/mate.dormant" && echo present || echo absent)"
  echo "post-enter session=$(tmux list-sessions -F '#{session_name}' 2>&1 | grep -c "^$TMUX_SESSION\$")"
  tmux kill-server 2>/dev/null || true
else
  echo "no-tmux-binary"
fi

echo "TMP=$T"
