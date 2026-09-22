#!/usr/bin/env bash
# Live-drive the bearings surface of the dormancy change with a real valid
# secondmate home and the real tmux binary (no server -> missing -> dead read).
set -u
ROOT=${ROOT:?}
export FM_GATE_REFUSE_BYPASS=1

T=$(mktemp -d /tmp/fm-bearings-dormancy.XXXXXX)
home=$T/parent
mate=$T/asleep-mate-home
mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
: > "$home/data/backlog.md"
: > "$home/data/secondmates.md"

# valid secondmate home
mkdir -p "$mate/state" "$mate/data" "$mate/config" "$mate/projects" "$mate/bin"
printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
printf 'asleep-mate\n' > "$mate/.fm-secondmate-home"
cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
printf -- '- asleep-mate - fixture domain (home: %s; scope: fixture; projects: sample; added 2026-07-13)\n' "$mate" > "$home/data/secondmates.md"

# parent meta: secondmate whose endpoint no longer exists (dead read)
cat > "$home/state/asleep-mate.meta" <<EOF
window=firstmate:fm-dead-asleep-mate
worktree=$mate
project=$mate
harness=codex
kind=secondmate
mode=secondmate
home=$mate
projects=sample
EOF

# a stopped child task preserved inside the mate's home
mkdir -p "$mate/projects/dead-child"
cat > "$mate/state/dead-child.meta" <<EOF
window=firstmate:fm-dead-child
worktree=$mate/projects/dead-child
project=sample
harness=claude
kind=ship
mode=no-mistakes
EOF

BEAR="$ROOT/bin/fm-bearings-snapshot.sh"

baseline=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$BEAR" --json 2>/dev/null)
echo "$baseline" | jq -c '[.unhealthy_endpoints[]? | select(.id=="asleep-mate" or .id=="asleep-mate/dead-child") | .id]' | sed 's/^/baseline-unhealthy=/'

printf 'schema=fm-secondmate-dormancy.v1\n' > "$home/state/asleep-mate.dormant"
dormant=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$BEAR" --json 2>/dev/null)
echo "$dormant" | jq -c '[.unhealthy_endpoints[]? | select(.id=="asleep-mate" or .id=="asleep-mate/dead-child") | .id]' | sed 's/^/dormant-unhealthy=/'

projected=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$BEAR" --json --fields endpoints 2>/dev/null)
echo "$projected" | jq -c '[.endpoints[]? | select(.id=="asleep-mate") | {id,dormant,agent}]' | sed 's/^/endpoints-projection=/'

echo "TMP=$T"
