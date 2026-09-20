#!/usr/bin/env bash
# Owns primary-home autonomous mandate records and authority queries.
# Usage: fm-autonomous-mandate.sh propose --proposal FILE
#        fm-autonomous-mandate.sh confirm --id ID
#        fm-autonomous-mandate.sh launch-receipt --id ID --member ID --spawn-gen GEN
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

result() {
  jq -cn --arg result "$1" --arg reason "$2" '{result:$result,reason:$reason}'
}

active_file() { printf '%s\n' "$root/active.json"; }
proposal_file() { printf '%s\n' "$root/proposed.json"; }
activating_file() { printf '%s\n' "$root/activating.json"; }

valid_record() {
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
      (.launch|type == "object") and
      (.environments.allowed|type == "array") and
      (.environments.excluded|type == "array") and
      (([.environments.allowed[], .environments.excluded[]] | length) == ([.environments.allowed[], .environments.excluded[]] | unique | length))
    )
  ' "$1" >/dev/null
}

copy_record() {
  local source=$1 destination=$2 tmp
  [ -f "$source" ] && [ ! -L "$source" ] || die "invalid record: $source"
  jq -e '([.members[]? | (.home + "\u0000" + .task_id)] | length == (unique | length))' "$source" >/dev/null || die 'duplicate member'
  valid_record "$source" || die 'invalid autonomous mandate proposal'
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

query() {
  local request_home=$1 task=$2 generation=$3 action=$4 environment=${5:-} file now
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
    file=$(record_for_id "$2") || die "unknown mandate: $2"
    [ "$file" = "$(proposal_file)" ] || die "mandate is not proposed: $2"
    mv "$file" "$(activating_file)"
    printf 'activating: %s\n' "$2"
    ;;
  launch-receipt)
    if [ "${1:-}" != --id ] || [ "${3:-}" != --member ] || [ "${5:-}" != --spawn-gen ] || [ -z "${2:-}" ] || [ -z "${4:-}" ] || [ -z "${6:-}" ]; then die 'usage: launch-receipt --id ID --member ID --spawn-gen GEN'; fi
    id=$2 member=$4 generation=$6
    if ! safe_id "$id" || ! safe_id "$member" || ! safe_id "$generation"; then
      die 'invalid receipt identity'
    fi
    require_primary_writer
    acquire_lock
    file=$(record_for_id "$id") || die "unknown mandate: $id"
    [ "$file" = "$(activating_file)" ] || die "mandate is not activating: $id"
    jq -e --arg member "$member" '.members[] | select(.id == $member)' "$file" >/dev/null || die "unknown member: $member"
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
    acquire_lock
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
  revoke)
    [ "${1:-}" = --id ] && [ -n "${2:-}" ] || die 'usage: revoke --id ID'
    safe_id "$2" || die 'invalid mandate id'
    require_primary_writer
    acquire_lock
    file=$(record_for_id "$2") || die "unknown mandate: $2"
    mv "$file" "$root/archive/$2.revoked.json"
    printf 'revoked: %s\n' "$2"
    ;;
  archive)
    [ "${1:-}" = --id ] && [ -n "${2:-}" ] || die 'usage: archive --id ID'
    safe_id "$2" || die 'invalid mandate id'
    require_primary_writer
    acquire_lock
    file=$(record_for_id "$2") || die "unknown mandate: $2"
    mv "$file" "$root/archive/$2.json"
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
