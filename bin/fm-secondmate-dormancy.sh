#!/usr/bin/env bash
# Put one persistent secondmate to sleep, or wake it, without removing its home.
#
# Usage: fm-secondmate-dormancy.sh <id> enter|leave
#
# Dormancy preserves the seeded home, its backlog, its knowledge, and its
# registry route; it only stops the agent so an idle mate costs nothing to keep
# registered. The marker is a durable intent record, so a stopped endpoint is
# never mistaken for an unexpected death by startup liveness recovery, routine
# sync, update, or the reconcile nudge.
#
# Enter is refused unless the mate is provably idle: its own home must report a
# settled summary with no active child work, no queued item, and no open
# decision, and the parent must hold no unresolved routed reply for it. The idle
# signal is the secondmate home
# summary (bin/fm-fleet-snapshot.sh --secondmate-home-summary), NOT the busy
# classifier: a secondmate arms no busy-state wiring, because an idle secondmate
# pane is healthy by design (bin/fm-busy-lib.sh).
#
# The endpoint is stopped FIRST, and the marker published only once that stop is
# proven AND the endpoint reads confirmed stopped: `dead` or `missing`, the two
# states that license recovery (bin/fm-backend.sh). Alive, ambiguous, unreadable
# and unverified reads all refuse, as does a remote endpoint that cannot be
# probed, so a mate is never marked asleep while it is still running - the state
# that would both hide a live agent from routine sync and make a later routed
# request fail. A stop that cannot be proven leaves no marker at all, so dormancy
# is simply lost rather than misreported.
#
# The confirmed-stopped read and the marker write hold the same per-task spawn
# lock a liveness respawn try-acquires (state/.spawn-<id>.lock), so the guard
# and the mark are atomic against a concurrent respawn.
#
# A routed request still wakes a dormant mate: bin/fm-send.sh wakes it before
# delivering. Routine machinery (config push, reconcile, reply recovery) passes
# FM_SEND_WAKE_DORMANT=0 and never wakes it, so only real work does.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:?FM_HOME is required}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-dormancy-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-secondmate-dormancy-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  echo "usage: fm-secondmate-dormancy.sh <id> enter|leave" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
ID=$1
case "$2" in
  enter) ACTION=enter ;;
  leave) ACTION=leave ;;
  *) usage ;;
esac
fm_secondmate_dormancy_id_valid "$ID" || { echo "error: invalid secondmate id: $ID" >&2; exit 1; }
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 1; }

META="$STATE/$ID.meta"
REGISTRY="$DATA/secondmates.md"
remote_host=
home=
if [ -f "$META" ] && [ ! -L "$META" ]; then
  remote_host=$(fm_meta_get "$META" remote_host)
  home=$(fm_meta_get "$META" home)
fi
if [ -f "$REGISTRY" ] && [ ! -L "$REGISTRY" ]; then
  [ -n "$remote_host" ] || remote_host=$(secondmate_registry_field "$REGISTRY" "$ID" host 2>/dev/null || true)
  [ -n "$home" ] || home=$(secondmate_registry_field "$REGISTRY" "$ID" home 2>/dev/null || true)
fi

# The mate must be a real recorded secondmate: either a live secondmate record
# here, or a registry route. Anything else is a mistyped id, not a mate to sleep.
if [ -n "$(fm_meta_get "$META" kind)" ]; then
  [ "$(fm_meta_get "$META" kind)" = secondmate ] || {
    echo "error: $ID is not a secondmate" >&2
    exit 1
  }
elif [ -f "$REGISTRY" ] && secondmate_registry_line_for_id "$REGISTRY" "$ID"; then
  :
else
  echo "error: secondmate $ID is not registered in this home" >&2
  exit 1
fi

# An unresolved routed reply means the mate owes this home an answer; sleeping it
# would silently strand that expectation.
pending_reply_exists() {
  local dir rec task phase
  dir=$(fm_pending_reply_dir "$STATE")
  [ -d "$dir" ] || return 1
  for rec in "$dir"/*; do
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue
    task=$(fm_pending_reply_get "$rec" task_id)
    [ "$task" = "$ID" ] || continue
    phase=$(fm_pending_reply_get "$rec" phase)
    case "$phase" in
      resolved) ;;
      *) return 0 ;;
    esac
  done
  return 1
}

# Idle gate for a local mate, read from its own home. A home whose structured
# state cannot be read reports an invalid summary, which refuses here.
local_dormancy_ready() {
  local summary
  [ -n "$home" ] || { echo "error: secondmate $ID has no recorded home to verify" >&2; return 1; }
  [ -d "$home" ] || { echo "error: secondmate $ID home is unavailable: $home" >&2; return 1; }
  summary=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --secondmate-home-summary 2>/dev/null) \
    || { echo "error: secondmate $ID home summary is unreadable" >&2; return 1; }
  printf '%s\n' "$summary" | jq -e '
    .valid == true
    and .state == "no_active_work"
    and (.active_children | length) == 0
    and (.queued | length) == 0
    and (.decisions_open | length) == 0
  ' >/dev/null 2>&1 || { echo "error: secondmate $ID has work or an open decision" >&2; return 1; }
}

# A recorded endpoint that is positively GONE has no agent to stop. Dormancy
# still applies: preventing an unwanted respawn is exactly what it is for, and
# bin/fm-control.sh's own exit verb refuses this state rather than reporting a
# stop it cannot prove.
endpoint_already_gone() {
  local backend target
  [ -f "$META" ] && [ ! -L "$META" ] || return 1
  backend=$(fm_backend_of_meta "$META")
  target=$(fm_backend_target_of_meta "$META")
  [ -n "$target" ] || return 1
  [ "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable')" = missing ]
}

# Dormancy may be recorded only for an endpoint that is confirmed stopped. `dead`
# and `missing` are the only states that license recovery (bin/fm-backend.sh), so
# they are the only states that license dormancy; alive, ambiguous, unreadable and
# unverified all describe an endpoint that may still be running. A recorded
# endpoint with no usable target cannot be confirmed either. No endpoint record
# at all means there is no agent to run, the single confirmed-stopped case by
# construction. A remote mate is probed on its own host through the remote
# control script's state verb, and an unprobeable remote endpoint refuses.
endpoint_confirmed_stopped() {
  local backend target state
  [ -f "$META" ] && [ ! -L "$META" ] || return 0
  if [ -n "$remote_host" ]; then
    state=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh state "$ID" < /dev/null 2>/dev/null | tail -1) || state=
    case "$state" in
      dead|missing) return 0 ;;
      *) return 1 ;;
    esac
  fi
  backend=$(fm_backend_of_meta "$META")
  target=$(fm_backend_target_of_meta "$META")
  [ -n "$target" ] || return 1
  state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable')
  case "$state" in
    dead|missing) return 0 ;;
    *) return 1 ;;
  esac
}

LOCK="$STATE/.dormancy-$ID.lock"
fm_lock_acquire_wait "$LOCK" || { echo "error: could not lock secondmate $ID dormancy" >&2; exit 1; }
trap 'fm_lock_release "$LOCK" || true' EXIT

if [ "$ACTION" = enter ]; then
  if fm_secondmate_is_dormant "$STATE" "$ID"; then
    printf 'already-dormant: %s\n' "$ID"
    exit 0
  fi
  pending_reply_exists && { echo "error: secondmate $ID has an unresolved routed reply" >&2; exit 1; }
  # A remote mate's idle gate is enforced on its own host, inside the exit verb.
  [ -n "$remote_host" ] || local_dormancy_ready
  stop_rc=0
  if [ -n "$remote_host" ]; then
    "$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh exit "$ID" || stop_rc=$?
  elif [ -f "$META" ] && ! endpoint_already_gone; then
    "$SCRIPT_DIR/fm-control.sh" "$ID" exit || stop_rc=$?
  fi
  if [ "$stop_rc" -ne 0 ]; then
    if [ "$stop_rc" -eq 255 ]; then
      echo "error: secondmate $ID stop could not be confirmed on $remote_host; it is NOT dormant and its route is preserved" >&2
    else
      echo "error: secondmate $ID could not be stopped; it is NOT dormant" >&2
    fi
    exit 1
  fi
  SPAWN_TASK_LOCK="$STATE/.spawn-$ID.lock"
  if ! fm_lock_try_acquire "$SPAWN_TASK_LOCK"; then
    echo "error: another spawn is already creating secondmate $ID; dormancy refused" >&2
    exit 1
  fi
  if ! endpoint_confirmed_stopped; then
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: secondmate $ID endpoint is not confirmed stopped; it is NOT dormant" >&2
    exit 1
  fi
  if ! fm_secondmate_dormancy_mark "$STATE" "$ID"; then
    fm_lock_release "$SPAWN_TASK_LOCK" || true
    echo "error: secondmate $ID stopped but its dormancy could not be recorded" >&2
    exit 1
  fi
  fm_lock_release "$SPAWN_TASK_LOCK" || true
  # A request that landed during the stop itself would be stranded: its reply
  # recovery is refused while a mate is dormant, and the agent that received it
  # was just stopped mid-turn. Waking it back up restores the recovery path, and
  # the durable steering record is re-rung from the mate's own inbox.
  if pending_reply_exists; then
    if ! fm_secondmate_dormancy_clear "$STATE" "$ID"; then
      echo "error: secondmate $ID dormancy marker could not be cleared for the request that arrived during its stop" >&2
      exit 1
    fi
    fm_secondmate_dormancy_wake "$STATE" "$ID" || true
    echo "error: a routed request arrived while secondmate $ID was being stopped; the request will be re-delivered from its inbox" >&2
    exit 1
  fi
  printf 'dormant: %s\n' "$ID"
  exit 0
fi

if ! fm_secondmate_is_dormant "$STATE" "$ID"; then
  printf 'already-active: %s\n' "$ID"
  exit 0
fi
fm_secondmate_dormancy_wake "$STATE" "$ID" || {
  echo "error: could not wake dormant secondmate $ID; it remains dormant" >&2
  exit 1
}
fm_secondmate_dormancy_clear "$STATE" "$ID" \
  || { echo "error: secondmate $ID woke but its dormancy marker could not be cleared" >&2; exit 1; }
printf 'active: %s\n' "$ID"
