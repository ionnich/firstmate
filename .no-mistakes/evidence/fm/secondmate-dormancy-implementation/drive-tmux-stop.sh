#!/usr/bin/env bash
# Live-drive the full stop-then-mark cycle against a REAL tmux server: a secondmate
# endpoint that is confirmed stopped (dead/missing) must be marked dormant only
# after the stop, and the marker must be the sole result.
set -u
ROOT=${ROOT:?}
export FM_GATE_REFUSE_BYPASS=1

T=$(mktemp -d /tmp/fm-tmux-dormancy.XXXXXX)
MATE=$T/mate
PARENT=$T/parent
mkdir -p "$MATE/state" "$MATE/data" "$MATE/config" "$MATE/projects" "$MATE/bin" "$PARENT/state" "$PARENT/data"
printf '# mate\n' > "$MATE/AGENTS.md"
printf 'mate\n' > "$MATE/.fm-secondmate-home"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$MATE/data/backlog.md"
printf -- '- mate - local mate (home: %s; scope: test; projects: none; added 2026-01-01)\n' "$MATE" > "$PARENT/data/secondmates.md"
printf 'kind=secondmate\nhome=%s\nbackend=tmux\ntarget=firstmate:fm-mate\nwindow=firstmate:fm-mate\nworktree=%s\nproject=test\nharness=codex\nmode=secondmate\n' "$MATE" "$MATE" > "$PARENT/state/mate.meta"
printf 'working: idle\n' > "$PARENT/state/mate.status"

# Real tmux server + window, foreground sleep (classifies "other" -> ambiguous,
# not alive; a bare-shell window would read dead). Either way the endpoint is not
# "missing" before the stop.
tmux kill-server 2>/dev/null || true
tmux new-session -d -s firstmate -n fm-mate
echo "pre-enter-window=$(tmux list-windows -t firstmate -F '#{window_name}' 2>&1 | tr '\n' ' ')"

FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-secondmate-dormancy.sh" mate enter
echo "enter-rc=$?"
echo "post-enter-marker=$(test -f "$PARENT/state/mate.dormant" && echo present || echo absent)"
echo "post-enter-session-count=$(tmux list-sessions -F '#{session_name}' 2>&1 | grep -c '^firstmate$')"
echo "post-enter-window=$(tmux list-windows -t firstmate -F '#{window_name}' 2>&1 | tr '\n' ' ')"
tmux kill-server 2>/dev/null || true
echo "TMP=$T"
