#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MANDATE="$ROOT/bin/fm-autonomous-mandate.sh"
TMP_ROOT=$(fm_test_tmproot fm-autonomous-mandate)

make_home() {
  local home=$1
  mkdir -p "$home/data/autonomous-mandates/archive" "$home/state"
}

proposal() {
  local path=$1 home=$2 expiry=${3:-null}
  cat > "$path" <<JSON
{"schema":"fm-autonomous-mandate.v1","id":"amd-test","primary_home":"$home","cap":4,"expires_at":$expiry,"members":[{"id":"member-a","home":"$home","task_id":"task-a","mode":"no-mistakes","project":"/project","environments":{"allowed":["staging","production"],"excluded":[]},"launch":{"project":"/project","mode":"no-mistakes","yolo":"off"}}]}
JSON
}

test_propose_and_query_are_fail_closed() {
  local home="$TMP_ROOT/home" file="$TMP_ROOT/proposal.json" out
  make_home "$home"
  proposal "$file" "$home"
  out=$(FM_HOME="$home" "$MANDATE" propose --proposal "$file") || fail "proposal should pass: $out"
  [ "$out" = 'proposed: amd-test' ] || fail "unexpected proposal output: $out"
  out=$(FM_HOME="$home" "$MANDATE" query --home "$home" --task task-a --spawn-gen s1 --action merge) || fail "query should be a denial result"
  printf '%s' "$out" | jq -e '.result == "unavailable"' >/dev/null || fail "inactive mandate must be unavailable: $out"
  pass 'propose persists reviewed mandate and inactive query fails closed'
}

test_rejects_duplicate_members_and_unknown_environment_partition() {
  local home="$TMP_ROOT/home-invalid" file="$TMP_ROOT/invalid.json" out
  make_home "$home"
  proposal "$file" "$home"
  jq '.members += [.members[0]]' "$file" > "$file.next" && mv "$file.next" "$file"
  if out=$(FM_HOME="$home" "$MANDATE" propose --proposal "$file" 2>&1); then
    fail "duplicate member proposal passed: $out"
  fi
  printf '%s' "$out" | grep -Fq 'duplicate member' || fail "missing duplicate rejection: $out"
  pass 'proposal rejects duplicate reviewed members'
}

test_confirm_receipt_and_authorize_deployment() {
  local home="$TMP_ROOT/home-active" file="$TMP_ROOT/active.json" out
  make_home "$home"
  proposal "$file" "$home"
  FM_HOME="$home" "$MANDATE" propose --proposal "$file" >/dev/null
  FM_HOME="$home" "$MANDATE" confirm --id amd-test >/dev/null
  FM_HOME="$home" "$MANDATE" launch-receipt --id amd-test --member member-a --spawn-gen s1 >/dev/null
  out=$(FM_HOME="$home" "$MANDATE" authorize-deployment --home "$home" --task task-a --spawn-gen s1 --environment production)
  printf '%s' "$out" | jq -e '.result == "grant"' >/dev/null || fail "reviewed deployment must grant: $out"
  out=$(FM_HOME="$home" "$MANDATE" authorize-deployment --home "$home" --task task-a --spawn-gen s1 --environment development)
  printf '%s' "$out" | jq -e '.result == "deny"' >/dev/null || fail "unknown environment must deny: $out"
  pass 'activation binds exact generation and deployment environment'
}

test_propose_and_query_are_fail_closed
test_rejects_duplicate_members_and_unknown_environment_partition
test_confirm_receipt_and_authorize_deployment
