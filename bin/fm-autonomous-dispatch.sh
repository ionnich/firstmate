#!/usr/bin/env bash
# One reviewed, primary-local autonomous dispatch.
set -euo pipefail

die() { printf '%s\n' "$*" >&2; exit 1; }
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
home=${FM_HOME:-}
[ -n "$home" ] || die 'FM_HOME is required'
home=$(cd "$home" 2>/dev/null && pwd -P) || die 'invalid FM_HOME'
root="$home/data/autonomous-dispatch"
active="$root/active.json"
activating="$root/activating.json"

utc_epoch() {
  local stamp=$1 epoch rendered
  case "$stamp" in ????-??-??T??:??:??Z) ;; *) return 1;; esac
  epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$stamp" +%s 2>/dev/null || date -u -d "$stamp" +%s 2>/dev/null) || return 1
  rendered=$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 1
  [ "$rendered" = "$stamp" ] && printf '%s\n' "$epoch"
}

valid() {
  jq -e --arg home "$home" '
    .schema == "fm-autonomous-dispatch.v1" and
    (.id | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    (.reviewed_revision | type == "string" and length > 0) and
    .reviewed_by == "captain" and
    (.expires_at == null or (type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))) and
    (.members | type == "array" and length > 0) and
    ([.members[] | (.home + "\u0000" + .task_id)] as $members | ($members | length) == ($members | unique | length)) and
    all(.members[];
      (.home|type == "string" and length > 0) and
      (.task_id|type == "string" and length > 0) and
      (.mode|type == "string" and length > 0) and
      (.project|type == "string" and length > 0) and
      (. as $member | .launch|type == "object" and .project == $member.project and .mode == $member.mode and (.yolo == "on" or .yolo == "off")) and
      (.deploy_environments|type == "array") and (.excluded_deploy_environments|type == "array") and
      (([.deploy_environments[], .excluded_deploy_environments[]] | length) == ([.deploy_environments[], .excluded_deploy_environments[]] | unique | length)) and
      .full_autonomy == true)
  ' "$1" >/dev/null
}

active_member() { # home task generation action [environment]
  local request_home=$1 task=$2 generation=$3 action=$4 environment=${5:-}
  [ -f "$active" ] && [ ! -L "$active" ] && valid "$active" || return 1
  if jq -e '.expires_at != null' "$active" >/dev/null; then
    [ "$(utc_epoch "$(jq -r .expires_at "$active")")" -gt "$(date -u +%s)" ] || return 1
  fi
  jq -e --arg home "$request_home" --arg task "$task" --arg generation "$generation" --arg action "$action" --arg environment "$environment" '
    .members[] | select(.home == $home and .task_id == $task and .spawn_gen == $generation) |
    if $action == "deploy" then .deploy_environments | index($environment) != null
    else $action == "decision" or $action == "merge" end
  ' "$active" >/dev/null
}

record_receipt() { # member task
  local member=$1 task=$2 generation tmp
  generation=$(awk -F= '$1 == "spawn_gen" { print substr($0, index($0, "=") + 1); exit }' "$member/state/$task.meta")
  [ -n "$generation" ] || die "spawn did not publish a generation for $task"
  tmp=$(mktemp "$root/.receipt.XXXXXX")
  jq --arg home "$member" --arg task "$task" --arg generation "$generation" \
    '(.members[] | select(.home == $home and .task_id == $task)).spawn_gen = $generation' "$activating" > "$tmp"
  mv "$tmp" "$activating"
}

case "${1:-}" in
  approve)
    [ "${2:-}" = --record ] && [ -n "${3:-}" ] || die 'usage: approve --record FILE'
    [ ! -e "$root" ] || [ -d "$root" ] && [ ! -L "$root" ] || die 'invalid dispatch directory'
    mkdir -p "$root"
    [ ! -e "$active" ] && [ ! -e "$activating" ] || die 'an autonomous dispatch is already active or activating'
    [ -f "$3" ] && [ ! -L "$3" ] && valid "$3" || die 'invalid reviewed autonomous dispatch record'
    if jq -e '.expires_at != null' "$3" >/dev/null; then
      expiry=$(utc_epoch "$(jq -r .expires_at "$3")") || die 'invalid dispatch expiry'
      [ "$expiry" -gt "$(date -u +%s)" ] || die 'dispatch expiry must be after approval'
    fi
    cp "$3" "$activating"
    chmod 600 "$activating"
    while IFS=$'\t' read -r member task project mode yolo; do
      FM_HOME="$member" "$script_dir/fm-spawn.sh" "$task" "$project" --mode "$mode" --yolo "$yolo"
      record_receipt "$member" "$task"
    done < <(jq -r '.members[] | [.home,.task_id,.launch.project,.launch.mode,.launch.yolo] | @tsv' "$activating")
    mv "$activating" "$active"
    jq -r '.id' "$active"
    ;;
  member)
    [ "${2:-}" = --home ] && [ "${4:-}" = --task ] && [ "${6:-}" = --spawn-gen ] && [ "${8:-}" = --action ] || die 'usage: member --home HOME --task ID --spawn-gen GEN --action decision|merge|deploy [--environment NAME]'
    environment=
    [ "${10:-}" != --environment ] || environment=${11:-}
    active_member "$3" "$5" "$7" "$9" "$environment" || { printf 'deny\n'; exit 1; }
    printf 'grant\n'
    ;;
  revoke|end)
    [ -f "$active" ] && rm "$active"
    [ -f "$activating" ] && rm "$activating"
    printf '%s\n' "$1"
    ;;
  status) [ -f "$active" ] && jq -r '.id' "$active" || { [ -f "$activating" ] && jq -r '.id + " activating"' "$activating" || printf 'none\n'; } ;;
  *) die 'usage: fm-autonomous-dispatch.sh <approve|member|revoke|end|status>' ;;
esac
