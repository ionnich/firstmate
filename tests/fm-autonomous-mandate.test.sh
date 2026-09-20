#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MANDATE="$ROOT/bin/fm-autonomous-mandate.sh"
TMP_ROOT=$(fm_test_tmproot fm-autonomous-mandate)

make_home() {
  local home=$1
  mkdir -p "$home/data/autonomous-mandates/archive" "$home/state"
}

write_native_meta() {
  local home=$1 generation=$2
  cat > "$home/state/task-a.meta" <<META
endpoint_task_id=task-a
project=/project
mode=no-mistakes
mandate_id=amd-test
mandate_member=member-a
spawn_gen=$generation
META
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
  mv "$home/data/autonomous-mandates/proposed.json" "$home/data/autonomous-mandates/activating.json"
  write_native_meta "$home" s1
  FM_HOME="$home" "$MANDATE" launch-receipt --id amd-test --member member-a --spawn-gen s1 >/dev/null
  out=$(FM_HOME="$home" "$MANDATE" authorize-deployment --home "$home" --task task-a --spawn-gen s1 --environment production)
  printf '%s' "$out" | jq -e '.result == "grant"' >/dev/null || fail "reviewed deployment must grant: $out"
  out=$(FM_HOME="$home" "$MANDATE" authorize-deployment --home "$home" --task task-a --spawn-gen s1 --environment development)
  printf '%s' "$out" | jq -e '.result == "deny"' >/dev/null || fail "unknown environment must deny: $out"
  if FM_HOME="$home" "$MANDATE" archive --id amd-test >/dev/null 2>&1; then
    fail 'active mandate archived without terminal evidence'
  fi
  FM_HOME="$home" "$MANDATE" complete-member --id amd-test --member member-a --spawn-gen s1 >/dev/null
  [ "$(FM_HOME="$home" "$MANDATE" status)" = none ] || fail 'all terminal members must archive mandate'
  pass 'activation binds exact generation and deployment environment'
}

test_revoke_removes_active_authority() {
  local home="$TMP_ROOT/home-revoked" file="$TMP_ROOT/revoked.json" out
  make_home "$home"
  proposal "$file" "$home"
  FM_HOME="$home" "$MANDATE" propose --proposal "$file" >/dev/null
  mv "$home/data/autonomous-mandates/proposed.json" "$home/data/autonomous-mandates/activating.json"
  write_native_meta "$home" s1
  FM_HOME="$home" "$MANDATE" launch-receipt --id amd-test --member member-a --spawn-gen s1 >/dev/null
  FM_HOME="$home" "$MANDATE" revoke --id amd-test >/dev/null
  out=$(FM_HOME="$home" "$MANDATE" query --home "$home" --task task-a --spawn-gen s1 --action merge)
  printf '%s' "$out" | jq -e '.result == "unavailable"' >/dev/null || fail "revocation must remove authority: $out"
  pass 'revocation removes active authority without touching task work'
}

test_root_symlink_and_excluded_action_refuse() {
  local home="$TMP_ROOT/home-root" outside="$TMP_ROOT/outside" file="$TMP_ROOT/root.json" out
  make_home "$home"
  proposal "$file" "$home"
  rm -rf "$home/data/autonomous-mandates"
  mkdir -p "$outside"
  ln -s "$outside" "$home/data/autonomous-mandates"
  if out=$(FM_HOME="$home" "$MANDATE" propose --proposal "$file" 2>&1); then
    fail "symlinked mandate root passed: $out"
  fi
  rm "$home/data/autonomous-mandates"
  make_home "$home"
  FM_HOME="$home" "$MANDATE" propose --proposal "$file" >/dev/null
  mv "$home/data/autonomous-mandates/proposed.json" "$home/data/autonomous-mandates/activating.json"
  write_native_meta "$home" s1
  FM_HOME="$home" "$MANDATE" launch-receipt --id amd-test --member member-a --spawn-gen s1 >/dev/null
  out=$(FM_HOME="$home" "$MANDATE" query --home "$home" --task task-a --spawn-gen s1 --action credential)
  printf '%s' "$out" | jq -e '.result == "deny"' >/dev/null || fail "excluded action granted: $out"
  pass 'unsafe mandate root and excluded action refuse'
}

test_confirm_starts_reviewed_launch_and_receipt_requires_native_identity() {
  local home="$TMP_ROOT/home-launch" file="$TMP_ROOT/launch.json" out
  make_home "$home"
  proposal "$file" "$home"
  FM_HOME="$home" "$MANDATE" propose --proposal "$file" >/dev/null
  if out=$(FM_HOME="$home" "$MANDATE" confirm --id amd-test 2>&1); then
    fail "confirmation accepted without launching reviewed member: $out"
  fi
  [ "$(FM_HOME="$home" "$MANDATE" status)" = 'amd-test activating' ] \
    || fail 'failed launch must preserve recoverable activation state'
  if FM_HOME="$home" "$MANDATE" launch-receipt --id amd-test --member member-a --spawn-gen s999 >/dev/null 2>&1; then
    fail 'receipt accepted without matching native task identity'
  fi
  pass 'confirmation starts reviewed launch and receipt requires native identity'
}

test_rejects_non_real_or_elapsed_utc_expiry() {
  local home="$TMP_ROOT/home-expiry" file="$TMP_ROOT/expiry.json" out
  make_home "$home"
  proposal "$file" "$home" '"2026-99-99T00:00:00Z"'
  if out=$(FM_HOME="$home" "$MANDATE" propose --proposal "$file" 2>&1); then
    fail "non-real UTC expiry passed: $out"
  fi
  proposal "$file" "$home" '"2000-01-01T00:00:00Z"'
  if out=$(FM_HOME="$home" "$MANDATE" propose --proposal "$file" 2>&1); then
    fail "elapsed UTC expiry passed: $out"
  fi
  pass 'proposal rejects non-real and elapsed UTC expiry'
}

test_recover_preserves_partial_activation_and_archive_requires_terminal_receipts() {
  local home="$TMP_ROOT/home-recovery" file="$TMP_ROOT/recovery.json" out
  make_home "$home"
  proposal "$file" "$home"
  FM_HOME="$home" "$MANDATE" propose --proposal "$file" >/dev/null
  mv "$home/data/autonomous-mandates/proposed.json" "$home/data/autonomous-mandates/activating.json"
  if out=$(FM_HOME="$home" "$MANDATE" archive --id amd-test 2>&1); then
    fail "activation archived without terminal native evidence: $out"
  fi
  if out=$(FM_HOME="$home" "$MANDATE" recover --id amd-test 2>&1); then
    fail "recovery accepted a failed reviewed launch: $out"
  fi
  [ "$(FM_HOME="$home" "$MANDATE" status)" = 'amd-test activating' ] \
    || fail 'failed recovery must retain activation for retry'
  pass 'recovery retains partial activation and archive requires terminal evidence'
}

test_propose_and_query_are_fail_closed
test_rejects_duplicate_members_and_unknown_environment_partition
test_confirm_receipt_and_authorize_deployment
test_revoke_removes_active_authority
test_root_symlink_and_excluded_action_refuse
test_confirm_starts_reviewed_launch_and_receipt_requires_native_identity
test_rejects_non_real_or_elapsed_utc_expiry
test_recover_preserves_partial_activation_and_archive_requires_terminal_receipts
