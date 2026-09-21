#!/usr/bin/env bash
# Dormancy lifecycle: idle gate, marker semantics, sleep/wake exclusion, and the
# refusal paths that keep a routed request from being swallowed.
set -eu

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-secondmate-dormancy-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PARENT="$TMP/parent"
MATE="$TMP/mate"
mkdir -p "$PARENT/state" "$PARENT/data" "$MATE/state" "$MATE/data"
: >"$MATE/data/backlog.md"
cat >"$MATE/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
cat >"$PARENT/data/secondmates.md" <<EOF
- mate - local mate (home: $MATE; scope: test; projects: none; added 2026-01-01)
EOF

# shellcheck source=bin/fm-ff-lib.sh disable=SC1091
. "$ROOT/bin/fm-ff-lib.sh"

dorm() {
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-secondmate-dormancy.sh" "$@"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. A registered but never-launched mate sleeps: there is no endpoint to stop,
#    and recording the intent is the whole point (it suppresses a respawn).
dorm mate enter >/dev/null
[ -f "$PARENT/state/mate.dormant" ] || fail 'enter did not record the marker'
dorm mate enter | grep -q '^already-dormant: mate$' || fail 'enter is not idempotent'

# 2. A dormant mate is invisible to the routine sweep that fans out sync, update
#    and config push, and reappears once it is awake.
cat >"$PARENT/state/mate.meta" <<EOF
kind=secondmate
home=$MATE
window=missing-window
EOF
[ -z "$(live_secondmate_meta_records "$PARENT/state" "$PARENT/data/secondmates.md")" ] \
  || fail 'a dormant mate was swept as live'

# 3. Work in the mate's own home refuses the entry and leaves no marker. This is
#    the guard that stops a busy mate being frozen mid-task.
rm -f "$PARENT/state/mate.dormant"
cat >"$MATE/data/backlog.md" <<'EOF'
## In flight

## Queued
- busy item - waiting its turn

## Done
EOF
if dorm mate enter >/dev/null 2>"$TMP/err"; then
  fail 'enter succeeded while the mate home had queued work'
fi
grep -q 'has work or an open decision' "$TMP/err" || fail "unexpected refusal: $(cat "$TMP/err")"
[ ! -e "$PARENT/state/mate.dormant" ] || fail 'a refused enter left a marker behind'

# 4. An unresolved routed reply refuses the entry: sleeping the mate would strand
#    the answer this home is still waiting for.
sleepable_backlog=$TMP/idle.md
cat >"$sleepable_backlog" <<'EOF'
## In flight

## Queued

## Done
EOF
cp "$sleepable_backlog" "$MATE/data/backlog.md"
mkdir -p "$PARENT/state/pending-replies"
printf 'schema=fm-pending-reply.v1\ntask_id=mate\nphase=awaiting_report\n' \
  >"$PARENT/state/pending-replies/aaaa000011112222"
if dorm mate enter >/dev/null 2>"$TMP/err"; then
  fail 'enter succeeded with an unresolved routed reply'
fi
grep -q 'unresolved routed reply' "$TMP/err" || fail "unexpected refusal: $(cat "$TMP/err")"
[ ! -e "$PARENT/state/mate.dormant" ] || fail 'a refused enter left a marker behind'
rm -f "$PARENT/state/pending-replies/aaaa000011112222"

# 5. A stop that cannot be proven must NOT claim dormancy: the marker is
#    withdrawn, so a mate that is still running is never hidden from routine
#    sync and a later routed request is never sent to a sleeping-looking mate.
cat >"$PARENT/state/mate.meta" <<EOF
kind=secondmate
home=$MATE
backend=cmux
target=no-such-target
window=no-such-target
EOF
if dorm mate enter >/dev/null 2>"$TMP/err"; then
  fail 'enter claimed dormancy without a proven stop'
fi
[ ! -e "$PARENT/state/mate.dormant" ] || fail 'a failed stop left the marker behind'

# 6. A wake that fails must leave the mate dormant rather than silently clearing
#    the intent: the marker is only dropped once the endpoint is really back.
rm -f "$PARENT/state/mate.meta"
dorm mate enter >/dev/null
if dorm mate leave >/dev/null 2>"$TMP/err"; then
  fail 'leave succeeded against an unusable home'
fi
grep -q 'remains dormant' "$TMP/err" || fail "unexpected wake failure: $(cat "$TMP/err")"
[ -f "$PARENT/state/mate.dormant" ] || fail 'a failed wake cleared the marker'

# 7. A routed request must not silently vanish into a dormant mate: routine
#    machinery refuses instead of waking it.
cat >"$PARENT/state/mate.meta" <<EOF
kind=secondmate
backend=tmux
target=missing-window
window=missing-window
home=$MATE
EOF
FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_SEND_WAKE_DORMANT=0 \
  "$ROOT/bin/fm-send.sh" fm-mate 'routine request' 2>"$TMP/err" \
  && fail 'a routine send reached a dormant mate'
grep -q 'routine request refused for dormant secondmate mate' "$TMP/err" \
  || fail "unexpected refusal: $(cat "$TMP/err")"

# 8. Awake again once the marker is gone, and the sweep sees it.
dorm_clear_ok=0
FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" bash -c \
  '. "$0/bin/fm-wake-lib.sh"; . "$0/bin/fm-secondmate-dormancy-lib.sh"; fm_secondmate_dormancy_clear "$1" mate' \
  "$ROOT" "$PARENT/state" && dorm_clear_ok=1
[ "$dorm_clear_ok" = 1 ] || fail 'clear failed'
[ "$(live_secondmate_meta_records "$PARENT/state" "$PARENT/data/secondmates.md" | cut -d'|' -f1)" = mate ] \
  || fail 'an awake mate is still hidden from the sweep'
dorm mate leave | grep -q '^already-active: mate$' || fail 'leave on an awake mate should be a no-op'

# 9. A non-secondmate record is not sleepable: dormancy must not be smuggled onto
#    an ordinary task record.
cat >"$PARENT/state/mate.meta" <<EOF
kind=ship
home=$MATE
window=missing-window
EOF
if dorm mate enter >/dev/null 2>"$TMP/err"; then
  fail 'enter accepted a non-secondmate record'
fi
grep -q 'is not a secondmate' "$TMP/err" || fail "unexpected refusal: $(cat "$TMP/err")"

# 10. The remote host-side stop verb applies the same idle gate from the mate's
#     own home. Driven directly against a mate home because the ssh transport is
#     not part of what the gate decides. (The companion acceptance branch - an
#     idle mate whose endpoint is positively gone - depends on a live Herdr
#     verdict and is covered by bin/fm-remote-secondmate-control.sh's own
#     endpoint-state tolerance rather than here.)
RMT="$TMP/remote-home"
mkdir -p "$RMT/state/parent-route" "$RMT/data"
printf 'mate\n' > "$RMT/.fm-secondmate-home"
printf '# remote home\n' > "$RMT/AGENTS.md"
ln -s "$ROOT/bin" "$RMT/bin"
cat >"$RMT/data/backlog.md" <<'EOF'
## In flight

## Queued
- busy item - waiting its turn

## Done
EOF
if FM_HOME="$RMT" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-remote-secondmate-control.sh" exit mate >/dev/null 2>"$TMP/err"; then
  fail 'the remote stop verb accepted a mate home with queued work'
fi
grep -q 'has work or an open decision' "$TMP/err" || fail "unexpected refusal: $(cat "$TMP/err")"

printf 'ok: secondmate dormancy\n'
