#!/usr/bin/env bash
# Owns primary-home autonomous mandate records and authority queries.
# Usage: fm-autonomous-mandate.sh propose --proposal FILE
#        fm-autonomous-mandate.sh confirm --id ID
#        fm-autonomous-mandate.sh launch-receipt --id ID --member ID --spawn-gen GEN
#        fm-autonomous-mandate.sh recover --id ID
#        fm-autonomous-mandate.sh complete-member --id ID --member ID --spawn-gen GEN
#        fm-autonomous-mandate.sh answer --id ID --task ID --spawn-gen GEN --decision-file FILE
#        fm-autonomous-mandate.sh validate-member --id ID --member ID --home HOME --task ID --mode MODE --project PATH
#        fm-autonomous-mandate.sh revoke --id ID
#        fm-autonomous-mandate.sh archive --id ID
#        fm-autonomous-mandate.sh status
#        fm-autonomous-mandate.sh query --home HOME --task ID --spawn-gen GEN --action ACTION [--environment NAME]
#        fm-autonomous-mandate.sh authorize-deployment --home HOME --task ID --spawn-gen GEN --environment NAME
# All commands require FM_HOME and use only its private data directory.
set -euo pipefail

die() { printf '%s\n' "$*" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

caller_home=${FM_HOME:-}
[ -n "$caller_home" ] || die 'FM_HOME is required'
caller_home=$(cd "$caller_home" 2>/dev/null && pwd -P) || die "invalid FM_HOME: $caller_home"
home=$caller_home
if [ -e "$caller_home/.fm-secondmate-home" ] || [ -L "$caller_home/.fm-secondmate-home" ]; then
  fm_secondmate_parent_record_parse "$caller_home/.fm-secondmate-parent" \
    && [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] \
    || die 'local secondmate parent binding is required'
  home=$(cd "$FM_SECONDMATE_PARENT_HOME" 2>/dev/null && pwd -P) \
    || die 'invalid secondmate parent home'
fi
root="$home/data/autonomous-mandates"
lock="$root/.lock"
lock_held=0
release_lock() {
  [ "$lock_held" = 0 ] || fm_lock_release "$lock" || true
  lock_held=0
}
trap release_lock EXIT
require_primary_writer() { [ "$caller_home" = "$home" ] || die 'only primary home may mutate mandates'; }
acquire_lock() {
  if [ -e "$root" ] || [ -L "$root" ]; then
    [ -d "$root" ] && [ ! -L "$root" ] || die 'invalid mandate directory'
  else
    mkdir -p "$root" || die 'cannot create mandate directory'
  fi
  [ -d "$root" ] && [ ! -L "$root" ] || die 'invalid mandate directory'
  mkdir -p "$root/archive" || die 'cannot create mandate archive directory'
  [ -d "$root/archive" ] && [ ! -L "$root/archive" ] || die 'invalid mandate archive directory'
  fm_lock_acquire_wait "$lock" || die 'cannot lock mandate'
  lock_held=1
}
safe_id() { case "$1" in amd-[A-Za-z0-9._-]*|[A-Za-z0-9._-]*) [ -n "$1" ] ;; *) return 1 ;; esac; }

utc_epoch() {
  local stamp=$1 epoch rendered
  case "$stamp" in ????-??-??T??:??:??Z) ;; *) return 1 ;; esac
  epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$stamp" +%s 2>/dev/null \
    || date -u -d "$stamp" +%s 2>/dev/null) || return 1
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  rendered=$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || return 1
  [ "$rendered" = "$stamp" ] || return 1
  printf '%s\n' "$epoch"
}

result() {
  jq -cn --arg result "$1" --arg reason "$2" '{result:$result,reason:$reason}'
}

active_file() { printf '%s\n' "$root/active.json"; }
proposal_file() { printf '%s\n' "$root/proposed.json"; }
activating_file() { printf '%s\n' "$root/activating.json"; }

valid_record() {
  local expiry
  jq -e --arg home "$home" '
    .schema == "fm-autonomous-mandate.v1" and
    (.id | type == "string" and test("^[A-Za-z0-9._-]+$")) and
    .primary_home == $home and
    (.cap | type == "number" and floor == . and . > 0) and
    (.expires_at == null or (type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))) and
    (. as $record | .members | type == "array" and length > 0 and length <= $record.cap) and
    ([.members[] | .id] | length == (unique | length)) and
    ([.members[] | (.home + "\u0000" + .task_id)] | length == (unique | length)) and
    all(.members[];
      (.id|type == "string" and length > 0) and
      (.home|type == "string" and length > 0) and
      (.task_id|type == "string" and length > 0) and
      (.mode|type == "string" and length > 0) and
      (.project|type == "string" and length > 0) and
      (. as $member | .launch | type == "object" and .project == $member.project and .mode == $member.mode and (.yolo == "on" or .yolo == "off")) and
      (.environments.allowed|type == "array") and
      (.environments.excluded|type == "array") and
      (([.environments.allowed[], .environments.excluded[]] | length) == ([.environments.allowed[], .environments.excluded[]] | unique | length))
    )
  ' "$1" >/dev/null
  expiry=$(jq -r '.expires_at // empty' "$1") || return 1
  [ -z "$expiry" ] || utc_epoch "$expiry" >/dev/null
}

copy_record() {
  local source=$1 destination=$2 tmp expiry epoch now
  [ -f "$source" ] && [ ! -L "$source" ] || die "invalid record: $source"
  jq -e '([.members[]? | (.home + "\u0000" + .task_id)] | length == (unique | length))' "$source" >/dev/null || die 'duplicate member'
  valid_record "$source" || die 'invalid autonomous mandate proposal'
  expiry=$(jq -r '.expires_at // empty' "$source") || die 'invalid autonomous mandate proposal'
  if [ -n "$expiry" ]; then
    epoch=$(utc_epoch "$expiry") || die 'invalid autonomous mandate proposal'
    now=$(date -u +%s) || die 'cannot read current time'
    [ "$epoch" -gt "$now" ] || die 'mandate expiry must be after approval'
  fi
  tmp=$(mktemp "$root/.mandate.XXXXXX") || die 'cannot create mandate record'
  cp "$source" "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$destination"
}

record_for_id() {
  local id=$1 file
  for file in "$(proposal_file)" "$(activating_file)" "$(active_file)"; do
    [ -f "$file" ] && jq -e --arg id "$id" '.id == $id' "$file" >/dev/null 2>&1 && { printf '%s\n' "$file"; return; }
  done
  return 1
}

native_meta_value() {
  local meta=$1 key=$2 count value
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  count=$(awk -F= -v key="$key" '$1 == key { count++ } END { print count + 0 }' "$meta") || return 1
  [ "$count" = 1 ] || return 1
  value=$(awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2) }' "$meta") || return 1
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

native_receipt_matches() {
  local record=$1 member=$2 generation=$3 task project mode meta
  task=$(jq -r --arg member "$member" '.members[] | select(.id == $member) | .task_id' "$record") || return 1
  project=$(jq -r --arg member "$member" '.members[] | select(.id == $member) | .project' "$record") || return 1
  mode=$(jq -r --arg member "$member" '.members[] | select(.id == $member) | .mode' "$record") || return 1
  meta="$caller_home/state/$task.meta"
  [ "$(native_meta_value "$meta" endpoint_task_id)" = "$task" ] \
    && [ "$(native_meta_value "$meta" project)" = "$project" ] \
    && [ "$(native_meta_value "$meta" mode)" = "$mode" ] \
    && [ "$(native_meta_value "$meta" mandate_id)" = "$id" ] \
    && [ "$(native_meta_value "$meta" mandate_member)" = "$member" ] \
    && [ "$(native_meta_value "$meta" spawn_gen)" = "$generation" ]
}

launch_members() {
  local record=$1 only_missing=${2:-0} member task project mode yolo
  while IFS= read -r member; do
    task=$(jq -r --arg member "$member" '.members[] | select(.id == $member) | .task_id' "$record") || return 1
    project=$(jq -r --arg member "$member" '.members[] | select(.id == $member) | .launch.project' "$record") || return 1
    mode=$(jq -r --arg member "$member" '.members[] | select(.id == $member) | .launch.mode' "$record") || return 1
    yolo=$(jq -r --arg member "$member" '.members[] | select(.id == $member) | .launch.yolo' "$record") || return 1
    FM_AUTONOMOUS_MANDATE_LOCK_HELD=1 \
    FM_HOME=$(jq -r --arg member "$member" '.members[] | select(.id == $member) | .home' "$record") \
      "$SCRIPT_DIR/fm-spawn.sh" "$task" "$project" --mode "$mode" --yolo "$yolo" \
      --mandate-id "$id" --mandate-member "$member" || return 1
  done < <(jq -r --argjson only_missing "$only_missing" '.members[] | select($only_missing == 0 or (.spawn_gen | type != "string" or length == 0)) | .id' "$record")
}

record_expired() {
  local record=$1 expiry epoch now
  expiry=$(jq -r '.expires_at // empty' "$record") || return 1
  [ -n "$expiry" ] || return 1
  epoch=$(utc_epoch "$expiry") || return 1
  now=$(date -u +%s) || return 1
  [ "$epoch" -le "$now" ]
}

all_members_terminal() {
  jq -e 'all(.members[]; . as $member | (.spawn_gen | type == "string" and length > 0) and (.terminal | type == "object" and .spawn_gen == $member.spawn_gen))' "$1" >/dev/null
}

archive_record() {
  local record=$1 id=$2 suffix=${3:-} destination
  destination="$root/archive/$id$suffix.json"
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || die "mandate archive already exists: $id"
  mv "$record" "$destination"
}

query() {
  local request_home=$1 task=$2 generation=$3 action=$4 environment=${5:-} file now id member
  [ "$request_home" = "$caller_home" ] || { result unavailable 'caller home mismatch'; return; }
  case "$action" in decision|merge|deploy) ;; *) result deny 'action is permanently excluded'; return ;; esac
  [ "${FM_AUTONOMOUS_MANDATE_LOCK_HELD:-}" = 1 ] || acquire_lock
  file=$(active_file)
  [ -f "$file" ] && [ ! -L "$file" ] || { result unavailable 'no active mandate'; return; }
  valid_record "$file" || { result unavailable 'invalid active mandate'; return; }
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if ! jq -e --arg now "$now" '.expires_at == null or .expires_at > $now' "$file" >/dev/null; then result deny 'mandate expired'; return; fi
  if ! jq -e --arg home "$request_home" --arg task "$task" --arg generation "$generation" '
      .members[] | select(.home == $home and .task_id == $task and .spawn_gen == $generation)' "$file" >/dev/null; then result deny 'exact member not active'; return; fi
  id=$(jq -r '.id' "$file") || { result unavailable 'invalid active mandate'; return; }
  member=$(jq -r --arg home "$request_home" --arg task "$task" --arg generation "$generation" '.members[] | select(.home == $home and .task_id == $task and .spawn_gen == $generation) | .id' "$file") || { result unavailable 'invalid active mandate'; return; }
  native_receipt_matches "$file" "$member" "$generation" || { result deny 'native task no longer matches'; return; }
  if [ "$action" = deploy ] && ! jq -e --arg home "$request_home" --arg task "$task" --arg generation "$generation" --arg environment "$environment" '
      .members[] | select(.home == $home and .task_id == $task and .spawn_gen == $generation) | .environments.allowed | index($environment) != null' "$file" >/dev/null; then result deny 'environment not reviewed'; return; fi
  result grant 'reviewed active member'
}

cmd=${1:-}; shift || true
case "$cmd" in
  propose)
    [ "${1:-}" = --proposal ] && [ -n "${2:-}" ] || die 'usage: propose --proposal FILE'
    require_primary_writer
    acquire_lock
    [ ! -e "$(active_file)" ] && [ ! -e "$(activating_file)" ] && [ ! -e "$(proposal_file)" ] || die 'an active, activating, or proposed mandate already exists'
    copy_record "$2" "$(proposal_file)"
    jq -r '"proposed: " + .id' "$(proposal_file)"
    ;;
  confirm)
    [ "${1:-}" = --id ] && [ -n "${2:-}" ] || die 'usage: confirm --id ID'
    safe_id "$2" || die 'invalid mandate id'
    require_primary_writer
    acquire_lock
    [ ! -e "$(active_file)" ] || die 'an active mandate must be archived or revoked first'
    id=$2
    file=$(record_for_id "$id") || die "unknown mandate: $id"
    [ "$file" = "$(proposal_file)" ] || die "mandate is not proposed: $2"
    mv "$file" "$(activating_file)"
    launch_members "$(activating_file)" || die "activation launch failed: $2"
    printf 'activating: %s\n' "$2"
    ;;
  launch-receipt)
    if [ "${1:-}" != --id ] || [ "${3:-}" != --member ] || [ "${5:-}" != --spawn-gen ] || [ -z "${2:-}" ] || [ -z "${4:-}" ] || [ -z "${6:-}" ]; then die 'usage: launch-receipt --id ID --member ID --spawn-gen GEN'; fi
    id=$2 member=$4 generation=$6
    if ! safe_id "$id" || ! safe_id "$member" || ! safe_id "$generation"; then
      die 'invalid receipt identity'
    fi
    [ "${FM_AUTONOMOUS_MANDATE_LOCK_HELD:-}" = 1 ] || acquire_lock
    file=$(record_for_id "$id") || die "unknown mandate: $id"
    [ "$file" = "$(activating_file)" ] || die "mandate is not activating: $id"
    jq -e --arg member "$member" '.members[] | select(.id == $member)' "$file" >/dev/null || die "unknown member: $member"
    native_receipt_matches "$file" "$member" "$generation" || die 'native receipt does not match reviewed member'
    tmp=$(mktemp "$root/.receipt.XXXXXX") || die 'cannot update receipt'
    jq --arg member "$member" --arg generation "$generation" '(.members[] | select(.id == $member)).spawn_gen = $generation' "$file" > "$tmp"
    mv "$tmp" "$file"
    if jq -e 'all(.members[]; (.spawn_gen|type == "string" and length > 0))' "$file" >/dev/null; then mv "$file" "$(active_file)"; fi
    printf 'receipt: %s %s\n' "$member" "$generation"
    ;;
  validate-member)
    if [ "${1:-}" != --id ] || [ "${3:-}" != --member ] || [ "${5:-}" != --home ] || [ "${7:-}" != --task ] || [ "${9:-}" != --mode ] || [ "${11:-}" != --project ]; then die 'usage: validate-member --id ID --member ID --home HOME --task ID --mode MODE --project PATH'; fi
    if ! safe_id "$2" || ! safe_id "$4"; then
      die 'invalid mandate identity'
    fi
    [ "${FM_AUTONOMOUS_MANDATE_LOCK_HELD:-}" = 1 ] || acquire_lock
    file=$(activating_file)
    if [ ! -f "$file" ] || ! jq -e --arg id "$2" --arg member "$4" --arg home "$6" --arg task "$8" --arg mode "${10}" --arg project "${12}" '.id == $id and (.members[] | select(.id == $member and .home == $home and .task_id == $task and .mode == $mode and .project == $project))' "$file" >/dev/null; then die 'reviewed mandate member mismatch'; fi
    printf 'member: %s\n' "$4"
    ;;
  query)
    if [ "${1:-}" != --home ] || [ "${3:-}" != --task ] || [ "${5:-}" != --spawn-gen ] || [ "${7:-}" != --action ] || [ -z "${2:-}" ] || [ -z "${4:-}" ] || [ -z "${6:-}" ] || [ -z "${8:-}" ]; then die 'usage: query --home HOME --task ID --spawn-gen GEN --action ACTION [--environment NAME]'; fi
    request_home=$2 task=$4 generation=$6 action=$8
    shift 8
    environment=
    [ "${1:-}" != --environment ] || environment=${2:-}
    query "$request_home" "$task" "$generation" "$action" "$environment"
    ;;
  lock-path)
    printf '%s\n' "$lock"
    ;;
  authorize-deployment)
    if [ "${1:-}" != --home ] || [ "${3:-}" != --task ] || [ "${5:-}" != --spawn-gen ] || [ "${7:-}" != --environment ] || [ -z "${2:-}" ] || [ -z "${4:-}" ] || [ -z "${6:-}" ] || [ -z "${8:-}" ]; then die 'usage: authorize-deployment --home HOME --task ID --spawn-gen GEN --environment NAME'; fi
    request_home=$2 task=$4 generation=$6 environment=$8
    query "$request_home" "$task" "$generation" deploy "$environment"
    ;;
  recover)
    [ "${1:-}" = --id ] && [ -n "${2:-}" ] || die 'usage: recover --id ID'
    safe_id "$2" || die 'invalid mandate id'
    require_primary_writer
    id=$2
    acquire_lock
    file=$(record_for_id "$id") || die "unknown mandate: $id"
    [ "$file" = "$(activating_file)" ] || die "mandate is not activating: $id"
    if jq -e 'all(.members[]; (.spawn_gen|type == "string" and length > 0))' "$file" >/dev/null; then
      printf 'recover: no-op\n'
    else
      launch_members "$file" 1 || die "recovery launch failed: $id"
      printf 'recover: launch\n'
    fi
    ;;
  complete-member)
    if [ "${1:-}" != --id ] || [ "${3:-}" != --member ] || [ "${5:-}" != --spawn-gen ] || [ -z "${2:-}" ] || [ -z "${4:-}" ] || [ -z "${6:-}" ]; then die 'usage: complete-member --id ID --member ID --spawn-gen GEN'; fi
    id=$2 member=$4 generation=$6
    safe_id "$id" && safe_id "$member" && safe_id "$generation" || die 'invalid terminal identity'
    acquire_lock
    file=$(record_for_id "$id") || die "unknown mandate: $id"
    [ "$file" = "$(active_file)" ] || die "mandate is not active: $id"
    native_receipt_matches "$file" "$member" "$generation" || die 'native terminal evidence does not match reviewed member'
    tmp=$(mktemp "$root/.terminal.XXXXXX") || die 'cannot update terminal evidence'
    jq --arg member "$member" --arg generation "$generation" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '(.members[] | select(.id == $member)).terminal = {spawn_gen:$generation,at:$at}' "$file" > "$tmp"
    mv "$tmp" "$file"
    if all_members_terminal "$file"; then archive_record "$file" "$id"; fi
    printf 'complete: %s %s\n' "$member" "$generation"
    ;;
  answer)
    if [ "${1:-}" != --id ] || [ "${3:-}" != --task ] || [ "${5:-}" != --spawn-gen ] || [ "${7:-}" != --decision-file ] || [ -z "${2:-}" ] || [ -z "${4:-}" ] || [ -z "${6:-}" ] || [ -z "${8:-}" ]; then die 'usage: answer --id ID --task ID --spawn-gen GEN --decision-file FILE'; fi
    id=$2 task=$4 generation=$6 decision_file=$8
    safe_id "$id" && safe_id "$task" && safe_id "$generation" || die 'invalid decision identity'
    [ -f "$decision_file" ] && [ ! -L "$decision_file" ] || die 'invalid decision file'
    grant=$(query "$caller_home" "$task" "$generation" decision)
    [ "$(printf '%s' "$grant" | jq -r '.result // empty')" = grant ] || die 'mandate does not authorize this decision'
    tmp=$(mktemp "$root/.decision.XXXXXX") || die 'cannot stage mandate decision'
    { cat "$decision_file"; printf '\nAuthority source: autonomous-mandate:%s\n' "$id"; } > "$tmp"
    "$SCRIPT_DIR/fm-captain-hold.sh" answer "$task" --decision-file "$tmp" --release
    rm -f "$tmp"
    ;;
  revoke)
    [ "${1:-}" = --id ] && [ -n "${2:-}" ] || die 'usage: revoke --id ID'
    safe_id "$2" || die 'invalid mandate id'
    require_primary_writer
    acquire_lock
    file=$(record_for_id "$2") || die "unknown mandate: $2"
    archive_record "$file" "$2" '.revoked'
    printf 'revoked: %s\n' "$2"
    ;;
  archive)
    [ "${1:-}" = --id ] && [ -n "${2:-}" ] || die 'usage: archive --id ID'
    safe_id "$2" || die 'invalid mandate id'
    require_primary_writer
    acquire_lock
    file=$(record_for_id "$2") || die "unknown mandate: $2"
    if ! record_expired "$file" && ! all_members_terminal "$file"; then die 'mandate members are not terminal'; fi
    archive_record "$file" "$2"
    printf 'archived: %s\n' "$2"
    ;;
  status)
    for file in "$(proposal_file)" "$(activating_file)" "$(active_file)"; do
      [ -f "$file" ] || continue
      jq -r '(.id + " " + (input_filename | split("/") | last | split(".")[0]))' "$file"
      exit 0
    done
    printf 'none\n'
    ;;
  *) die 'usage: fm-autonomous-mandate.sh <propose|confirm|launch-receipt|query|authorize-deployment>' ;;
esac
