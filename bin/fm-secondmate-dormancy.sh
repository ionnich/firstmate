#!/usr/bin/env bash
# Put one persistent secondmate to sleep or wake it without removing its home.
#
# Usage: fm-secondmate-dormancy.sh <id> enter|leave
#        fm-secondmate-dormancy.sh <id> on|off
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
# shellcheck source=bin/fm-busy-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-busy-lib.sh"

usage() {
  echo "usage: fm-secondmate-dormancy.sh <id> enter|leave" >&2
  echo "       aliases: on|off" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
ID=$1
case "$2" in
  enter|on) ACTION=enter ;;
  leave|off) ACTION=leave ;;
  *) usage ;;
esac
fm_secondmate_dormancy_id_valid "$ID" || { echo "error: invalid secondmate id: $ID" >&2; exit 1; }
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 1; }

META="$STATE/$ID.meta"
remote_host=
home=
if [ -f "$META" ] && [ ! -L "$META" ]; then
  remote_host=$(fm_meta_get "$META" remote_host)
  home=$(fm_meta_get "$META" home)
fi
if [ -f "$DATA/secondmates.md" ]; then
  [ -n "$remote_host" ] || remote_host=$(secondmate_registry_field "$DATA/secondmates.md" "$ID" host 2>/dev/null || true)
  [ -n "$home" ] || home=$(secondmate_registry_field "$DATA/secondmates.md" "$ID" home 2>/dev/null || true)
fi

if [ -f "$META" ] && [ ! -L "$META" ]; then
  grep -q '^kind=secondmate$' "$META" 2>/dev/null || {
    echo "error: $ID is not a secondmate" >&2
    exit 1
  }
elif [ -f "$DATA/secondmates.md" ]; then
  secondmate_registry_line_for_id "$DATA/secondmates.md" "$ID" || {
    echo "error: secondmate $ID is not registered" >&2
    exit 1
  }
else
  echo "error: secondmate $ID is not registered" >&2
  exit 1
fi
pending_reply_exists() {
  local rec task phase
  for rec in "$(fm_pending_reply_dir "$STATE")"/*; do
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue

    task=$(fm_pending_reply_get "$rec" task_id)
    [ "$task" = "$ID" ] || continue
    phase=$(fm_pending_reply_get "$rec" phase)
    case "$phase" in
      awaiting_report|recovery_sending|recovery_sent|delivery_unknown|escalated) return 0 ;;
    esac
  done
  return 1
}

local_dormancy_ready() {
  local verdict summary
  if [ -f "$META" ] && [ ! -L "$META" ]; then
    verdict=$(fm_busy_classify_meta "$META" "$ID" "$STATE" 2>/dev/null || printf 'unknown')
    case "${verdict%% *}" in
      idle) ;;
      *) echo "error: secondmate $ID is not idle (${verdict:-unknown})" >&2; return 1 ;;
    esac
  fi
  if pending_reply_exists; then
    echo "error: secondmate $ID has an unresolved reply" >&2
    return 1
  fi
  if [ -n "$home" ] && [ -x "$FM_ROOT/bin/fm-fleet-snapshot.sh" ]; then
    summary=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$FM_ROOT" \
      "$FM_ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary 2>/dev/null) \
      || { echo "error: secondmate $ID home summary is unreadable" >&2; return 1; }
    if ! printf '%s\n' "$summary" | jq -e '.state == "no_active_work" and (.active_children | length) == 0 and (.queued | length) == 0 and (.decisions_open | length) == 0' >/dev/null 2>&1; then
      echo "error: secondmate $ID has work or an open decision" >&2
      return 1
    fi
  fi
}

LOCK="$STATE/.dormancy-$ID.lock"
fm_lock_acquire_wait "$LOCK" || { echo "error: could not lock secondmate $ID dormancy" >&2; exit 1; }
trap 'fm_lock_release "$LOCK" || true' EXIT

if [ "$ACTION" = enter ]; then
  if fm_secondmate_is_dormant "$STATE" "$ID"; then
    printf 'already-dormant: %s\n' "$ID"
    exit 0
  fi
  if pending_reply_exists; then
    echo "error: secondmate $ID has an unresolved reply" >&2
    exit 1
  fi
  if [ -z "$remote_host" ]; then
    local_dormancy_ready
  fi
  # Publish intent before stopping the endpoint, so a crash cannot make startup
  # mistake an intentional stop for an unexpected dead agent.
  fm_secondmate_dormancy_mark "$STATE" "$ID" \
    || { echo "error: could not record dormancy for $ID" >&2; exit 1; }
  if [ -n "$remote_host" ]; then
    "$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh exit "$ID"
  elif [ -f "$META" ]; then
    "$SCRIPT_DIR/fm-control.sh" "$ID" exit
  fi
  printf 'dormant: %s\n' "$ID"
  exit 0
fi

if ! fm_secondmate_is_dormant "$STATE" "$ID"; then
  printf 'already-active: %s\n' "$ID"
  exit 0
fi
if [ -n "$remote_host" ]; then
  "$SCRIPT_DIR/fm-spawn.sh" "$ID" --secondmate || {
    echo "error: could not wake dormant secondmate $ID; it remains dormant" >&2
    exit 1
  }
else
  "$SCRIPT_DIR/fm-spawn.sh" "$ID" --relaunch || {
    echo "error: could not wake dormant secondmate $ID; it remains dormant" >&2
    exit 1
  }
fi
fm_secondmate_dormancy_clear "$STATE" "$ID" \
  || { echo "error: secondmate $ID woke but its dormancy marker could not be cleared" >&2; exit 1; }
printf 'active: %s\n' "$ID"
