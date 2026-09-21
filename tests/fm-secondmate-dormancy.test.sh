#!/usr/bin/env bash
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-secondmate-dormancy-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PARENT="$TMP/parent"
MATE="$TMP/mate"
mkdir -p "$PARENT/state" "$PARENT/data" "$MATE/state" "$MATE/data"
printf '## In flight\n\n## Queued\n\n## Done\n' >"$MATE/data/backlog.md"
cat >"$PARENT/data/secondmates.md" <<EOF
- mate - local mate (home: $MATE; scope: test; projects: none; added 2026-01-01)
EOF

FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-secondmate-dormancy.sh" mate enter >/dev/null
[ -f "$PARENT/state/mate.dormant" ]
FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-secondmate-dormancy.sh" mate enter | grep -q '^already-dormant: mate$'

cat >"$PARENT/state/mate.meta" <<EOF
kind=secondmate
backend=tmux
target=missing-window
window=missing-window
home=$MATE
EOF
FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_SEND_WAKE_DORMANT=0 \
  "$ROOT/bin/fm-send.sh" fm-mate 'routine request' 2>&1 | grep -q 'routine request refused for dormant secondmate mate'

# shellcheck source=bin/fm-ff-lib.sh disable=SC1091
. "$ROOT/bin/fm-ff-lib.sh"
rm "$PARENT/state/mate.dormant"
[ "$(live_secondmate_meta_records "$PARENT/state" "$PARENT/data/secondmates.md" | cut -d'|' -f1)" = mate ]
FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-secondmate-dormancy.sh" mate leave | grep -q '^already-active: mate$'

printf 'ok: secondmate dormancy\n'
