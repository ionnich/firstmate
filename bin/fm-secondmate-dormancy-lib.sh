#!/usr/bin/env bash
# Shared durable dormancy marker for persistent secondmates.
#
# The marker lives in the supervising home's state directory.  It preserves the
# seeded secondmate home while telling routine sweeps not to treat its stopped
# endpoint as a recovery target.

fm_secondmate_dormancy_id_valid() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_secondmate_dormancy_path() {
  local state=$1 id=$2
  fm_secondmate_dormancy_id_valid "$id" || return 1
  printf '%s/%s.dormant\n' "$state" "$id"
}

fm_secondmate_is_dormant() {
  local path
  path=$(fm_secondmate_dormancy_path "$1" "$2") || return 1
  [ -f "$path" ] && [ ! -L "$path" ]
}

fm_secondmate_dormancy_mark() {
  local state=$1 id=$2 path tmp
  path=$(fm_secondmate_dormancy_path "$state" "$id") || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
  fi
  tmp="$path.tmp.${BASHPID:-$$}"
  (umask 077; printf 'schema=fm-secondmate-dormancy.v1\n' > "$tmp") || return 1
  if ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_secondmate_dormancy_clear() {
  local state=$1 id=$2 path
  path=$(fm_secondmate_dormancy_path "$state" "$id") || return 1
  [ ! -L "$path" ] || return 1
  [ ! -e "$path" ] || [ -f "$path" ] || return 1
  rm -f -- "$path"
}
