#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Shared durable dormancy marker for persistent secondmates, plus the one wake
# path that brings a dormant mate back.
#
# The marker lives in the supervising home's state directory. It preserves the
# seeded secondmate home and its registry route while telling routine sweeps not
# to treat the stopped endpoint as a recovery target.
#
# Sourcing requires bin/fm-backend.sh to be loaded first, which is the same
# precondition bin/fm-busy-lib.sh states for its meta-aware helpers. No side
# effects on source. set -u / set -e safe.

_FM_SECONDMATE_DORMANCY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_SECONDMATE_DORMANCY_LIB_DIR="."

fm_secondmate_dormancy_id_valid() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_secondmate_dormancy_path() {  # <state-dir> <id>
  local state=$1 id=$2
  fm_secondmate_dormancy_id_valid "$id" || return 1
  printf '%s/%s.dormant\n' "$state" "$id"
}

fm_secondmate_is_dormant() {  # <state-dir> <id>
  local path
  path=$(fm_secondmate_dormancy_path "$1" "$2") || return 1
  [ -f "$path" ] && [ ! -L "$path" ]
}

fm_secondmate_dormancy_mark() {  # <state-dir> <id>
  local state=$1 id=$2 path tmp
  path=$(fm_secondmate_dormancy_path "$state" "$id") || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  # A symlink where the marker belongs is not ours to replace.
  if [ -L "$path" ]; then
    return 1
  fi
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    return 1
  fi
  tmp="$path.tmp.${BASHPID:-$$}"
  (umask 077; printf 'schema=fm-secondmate-dormancy.v1\n' > "$tmp") || return 1
  if ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_secondmate_dormancy_clear() {  # <state-dir> <id>
  local state=$1 id=$2 path
  path=$(fm_secondmate_dormancy_path "$state" "$id") || return 1
  [ ! -L "$path" ] || return 1
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    return 1
  fi
  rm -f -- "$path"
}

# fm_secondmate_dormancy_wake: bring a dormant mate's endpoint back through the
# path its OWN recorded endpoint state calls for.
#
# A stopped agent on an endpoint that still exists is adopted in place
# (--relaunch reuses the pane and its worktree); an endpoint that is gone, or is
# not recorded here at all, is recreated (--secondmate). This mirrors the
# recovery path startup liveness already uses for a dead or missing secondmate
# endpoint (bin/fm-bootstrap.sh) instead of inventing a second revival
# mechanism, and it is why dormancy does not need the endpoint killed on the way
# in: killing an endpoint stays with bin/fm-teardown.sh.
#
# An endpoint that is positively alive means the mate never truly slept - the
# marker outlived a manual start - so that is reported as awake rather than
# refused, and the caller clears the stale marker.
#
# Prints nothing; 0 means the mate is awake (or was already), non-zero leaves it
# dormant.
fm_secondmate_dormancy_wake() {  # <state-dir> <id>
  local state=$1 id=$2 meta backend target agent_state
  meta="$state/$id.meta"
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    "$_FM_SECONDMATE_DORMANCY_LIB_DIR/fm-spawn.sh" "$id" --secondmate
    return $?
  fi
  if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
    "$_FM_SECONDMATE_DORMANCY_LIB_DIR/fm-spawn.sh" "$id" --secondmate
    return $?
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  if [ -z "$target" ]; then
    "$_FM_SECONDMATE_DORMANCY_LIB_DIR/fm-spawn.sh" "$id" --secondmate
    return $?
  fi
  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable')
  case "$agent_state" in
    alive) return 0 ;;
    dead) "$_FM_SECONDMATE_DORMANCY_LIB_DIR/fm-spawn.sh" "$id" --relaunch ;;
    missing) "$_FM_SECONDMATE_DORMANCY_LIB_DIR/fm-spawn.sh" "$id" --secondmate ;;
    *) return 1 ;;
  esac
}
