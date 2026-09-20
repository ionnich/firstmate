#!/usr/bin/env bash
# Owns one reviewed, primary-local autonomous dispatch.
# Usage: fm-autonomous-dispatch.sh approve --record FILE
#        fm-autonomous-dispatch.sh member --home HOME --task ID
#        fm-autonomous-dispatch.sh revoke|end|status
set -euo pipefail

die() { printf '%s\n' "$*" >&2; exit 1; }
home=${FM_HOME:-}
[ -n "$home" ] || die 'FM_HOME is required'
home=$(cd "$home" 2>/dev/null && pwd -P) || die 'invalid FM_HOME'
root="$home/data/autonomous-dispatch"
active="$root/active.json"

valid() {
  jq -e --arg home "$home" '
    .schema == "fm-autonomous-dispatch.v1" and
    (.id | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    .state == "active" and
    (.expires_at == null or (type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))) and
    (.members | type == "array" and length > 0) and
    ([.members[] | (.home + "\u0000" + .task_id)] as $members | ($members | length) == ($members | unique | length)) and
    all(.members[]; (.home|type == "string" and length > 0) and (.task_id|type == "string" and length > 0) and .full_autonomy == true)
  ' "$1" >/dev/null
}

expired() {
  jq -e --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.expires_at != null and .expires_at <= $now' "$active" >/dev/null
}

case "${1:-}" in
  approve)
    [ "${2:-}" = --record ] && [ -n "${3:-}" ] || die 'usage: approve --record FILE'
    [ ! -e "$root" ] || [ -d "$root" ] && [ ! -L "$root" ] || die 'invalid dispatch directory'
    mkdir -p "$root"
    [ ! -e "$active" ] || die 'an autonomous dispatch is already active'
    [ -f "$3" ] && [ ! -L "$3" ] || die 'invalid dispatch record'
    valid "$3" || die 'invalid autonomous dispatch record'
    if jq -e '.expires_at != null' "$3" >/dev/null; then
      date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$(jq -r .expires_at "$3")" +%s >/dev/null 2>&1 || die 'invalid dispatch expiry'
    fi
    tmp=$(mktemp "$root/.active.XXXXXX")
    cp "$3" "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$active"
    jq -r '.id' "$active"
    ;;
  member)
    [ "${2:-}" = --home ] && [ "${4:-}" = --task ] && [ -n "${3:-}" ] && [ -n "${5:-}" ] || die 'usage: member --home HOME --task ID'
    [ -f "$active" ] && [ ! -L "$active" ] && valid "$active" || { printf 'deny\n'; exit 1; }
    expired && { printf 'deny\n'; exit 1; }
    jq -e --arg home "$3" --arg task "$5" '.members[] | select(.home == $home and .task_id == $task and .full_autonomy)' "$active" >/dev/null || { printf 'deny\n'; exit 1; }
    printf 'grant\n'
    ;;
  revoke|end)
    [ -f "$active" ] && rm "$active"
    printf '%s\n' "$1"
    ;;
  status) [ -f "$active" ] && jq -r '.id' "$active" || printf 'none\n' ;;
  *) die 'usage: fm-autonomous-dispatch.sh <approve|member|revoke|end|status>' ;;
esac
