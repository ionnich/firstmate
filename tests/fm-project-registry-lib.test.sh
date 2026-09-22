#!/usr/bin/env bash
# tests/fm-project-registry-lib.test.sh - unit tests for the shared
# data/projects.md registry-line helpers (bin/fm-project-registry-lib.sh) and
# the convergence they feed into bin/fm-config-inherit-lib.sh.
#
# The bug under test (task secondmate-registry-drops-yolo): a secondmate
# home's data/projects.md was copied from the primary's registry once, at
# seed time, and never refreshed. When the captain later changed a project's
# registered posture (e.g. added +yolo) in the primary's registry, the
# secondmate's stale copy silently kept the narrower posture forever - a
# lossy copy indistinguishable from a legitimately narrower posture.
#
# The guarantees under test:
#   - fm_project_registry_line reads one project's verbatim line, or fails
#     when the registry or the entry is absent.
#   - fm_project_registry_converge is primary-authoritative for any project
#     BOTH registries know about: a project whose primary line changed is
#     rewritten to match verbatim, and the change is reported.
#   - A project known only to the destination (never registered by the
#     primary) is left completely untouched - convergence never clobbers
#     independently registered local work.
#   - An unchanged project produces no report line and no file churn.
#   - propagate_project_registry (bin/fm-config-inherit-lib.sh) wires this
#     into the same convergence point every other inherited item uses, and
#     prints a SECONDMATE_SYNC: line naming the corrected posture so a lossy
#     copy is reported rather than silently re-obeyed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-project-registry-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-registry-lib)

# --- fm_project_registry_line ------------------------------------------------

reg="$TMP_ROOT/projects.md"
cat > "$reg" <<'EOF'
- finks-api [no-mistakes +yolo] - Commercialize API (added 2026-09-14)
- joe-cms - Joe CMS (added 2026-09-14)
EOF

line=$(fm_project_registry_line "$reg" finks-api) || fail "must find finks-api entry"
[ "$line" = "- finks-api [no-mistakes +yolo] - Commercialize API (added 2026-09-14)" ] \
  || fail "line must be verbatim, got: $line"
pass "fm_project_registry_line reads a project's line verbatim"

if fm_project_registry_line "$reg" nonexistent >/dev/null 2>&1; then
  fail "fm_project_registry_line must fail for an unregistered project"
fi
pass "fm_project_registry_line fails for a project the registry does not have"

if fm_project_registry_line "$TMP_ROOT/absent.md" finks-api >/dev/null 2>&1; then
  fail "fm_project_registry_line must fail when the registry file is absent"
fi
pass "fm_project_registry_line fails when the registry file is absent"

names=$(fm_project_registry_names "$reg")
[ "$names" = "$(printf 'finks-api\njoe-cms')" ] || fail "fm_project_registry_names must list both entries, got: $names"
pass "fm_project_registry_names lists every registered project name"

# --- fm_project_registry_converge: primary-authoritative drift correction ---

primary="$TMP_ROOT/primary-projects.md"
cat > "$primary" <<'EOF'
- finks-api [no-mistakes +yolo] - Commercialize API (added 2026-09-14)
- joe-cms [no-mistakes] - Joe CMS (added 2026-09-14)
EOF

dest="$TMP_ROOT/dest-projects.md"
cat > "$dest" <<'EOF'
- finks-api [no-mistakes] - Commercialize API (added 2026-09-14)
- joe-cms [no-mistakes] - Joe CMS (added 2026-09-14)
- local-only-project - never known to the primary (added 2026-09-16)
EOF

out=$(fm_project_registry_converge "$primary" "$dest") || fail "convergence must not fail"
printf '%s\n' "$out" | grep -qF "$(printf 'finks-api\t- finks-api [no-mistakes] - Commercialize API (added 2026-09-14)\t- finks-api [no-mistakes +yolo] - Commercialize API (added 2026-09-14)')" \
  || fail "convergence report must name the drifted project with old and new lines, got: $out"
pass "fm_project_registry_converge reports the exact old and new line for a drifted project"

! printf '%s\n' "$out" | grep -q '^joe-cms' || fail "an already-matching project must not be reported"
pass "fm_project_registry_converge does not report a project whose posture already matched"

grep -qF -- '- finks-api [no-mistakes +yolo] - Commercialize API (added 2026-09-14)' "$dest" \
  || fail "the destination file must be rewritten with the primary's verbatim line"
pass "fm_project_registry_converge rewrites the destination's drifted line verbatim from the primary"

grep -qF -- '- local-only-project - never known to the primary (added 2026-09-16)' "$dest" \
  || fail "a project the primary never registered must survive convergence untouched"
pass "fm_project_registry_converge never touches a project entry known only to the destination"

grep -qF -- '- joe-cms [no-mistakes] - Joe CMS (added 2026-09-14)' "$dest" \
  || fail "an already-matching project's line must be preserved byte-for-byte"
pass "fm_project_registry_converge leaves an already-converged project's line untouched"

# --- idempotence and no-op paths ---------------------------------------------

out2=$(fm_project_registry_converge "$primary" "$dest") || fail "a second converge pass must not fail"
[ -z "$out2" ] || fail "a second converge pass over an already-converged registry must report nothing, got: $out2"
pass "fm_project_registry_converge is idempotent: nothing left to report on a second pass"

noop_dest="$TMP_ROOT/noop-dest.md"
cp "$primary" "$noop_dest"
before_noop=$(cat "$noop_dest")
out3=$(fm_project_registry_converge "$primary" "$noop_dest") || fail "converge on an already-matching registry must not fail"
[ -z "$out3" ] || fail "converge on an already-matching registry must report nothing, got: $out3"
[ "$(cat "$noop_dest")" = "$before_noop" ] || fail "converge must not rewrite a file with nothing to change"
pass "fm_project_registry_converge is a true no-op (no file churn) when nothing has drifted"

absent_dest="$TMP_ROOT/absent-dest.md"
fm_project_registry_converge "$primary" "$absent_dest" >/dev/null || fail "an absent destination registry must be a no-op, not a failure"
[ ! -e "$absent_dest" ] || fail "converge must never create a destination registry that did not already exist"
pass "fm_project_registry_converge is a no-op when the destination registry does not exist"

absent_primary_dest="$TMP_ROOT/absent-primary-dest.md"
cp "$dest" "$absent_primary_dest"
before_absent_primary=$(cat "$absent_primary_dest")
fm_project_registry_converge "$TMP_ROOT/absent-primary.md" "$absent_primary_dest" >/dev/null \
  || fail "an absent primary registry must be a no-op, not a failure"
[ "$(cat "$absent_primary_dest")" = "$before_absent_primary" ] || fail "converge must not touch dest when the primary registry is absent"
pass "fm_project_registry_converge is a no-op when the primary registry does not exist"

# --- wiring into fm-config-inherit-lib.sh's propagate_project_registry ------

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

src_data="$TMP_ROOT/wired-src-data"
dest_data="$TMP_ROOT/wired-dest-data"
mkdir -p "$src_data" "$dest_data"
cat > "$src_data/projects.md" <<'EOF'
- finks-overwatch [no-mistakes-prod-only +yolo] - Event Relay (added 2026-09-16)
EOF
cat > "$dest_data/projects.md" <<'EOF'
- finks-overwatch [no-mistakes-prod-only] - Event Relay (added 2026-09-16)
EOF

wired_out=$(propagate_project_registry "$src_data" "$dest_data") || fail "propagate_project_registry must not fail"
printf '%s\n' "$wired_out" | grep -q '^SECONDMATE_SYNC: secondmate home .*: project registry for finks-overwatch converged to primary posture:' \
  || fail "propagate_project_registry must emit a SECONDMATE_SYNC report line, got: $wired_out"
grep -qF -- '- finks-overwatch [no-mistakes-prod-only +yolo] - Event Relay (added 2026-09-16)' "$dest_data/projects.md" \
  || fail "propagate_project_registry must converge the destination file"
pass "propagate_project_registry converges a drifted secondmate registry and reports it as SECONDMATE_SYNC"

wired_out2=$(propagate_project_registry "$src_data" "$dest_data") || fail "a second propagate_project_registry pass must not fail"
[ -z "$wired_out2" ] || fail "a converged registry must produce no further SECONDMATE_SYNC output, got: $wired_out2"
pass "propagate_project_registry is silent once the secondmate registry is converged"

# --- remote receiver project-registry command -------------------------------

remote_home="$TMP_ROOT/remote-home"
mkdir -p "$remote_home/config" "$remote_home/data" "$remote_home/state"
cat > "$remote_home/data/projects.md" <<'EOF'
- finks-overwatch [no-mistakes-prod-only] - Event Relay (added 2026-09-16)
- remote-only [direct-PR] - Remote project (added 2026-09-16)
EOF
remote_bytes=$(LC_ALL=C wc -c < "$src_data/projects.md" | tr -d ' ')
remote_hash=$(fm_inherit_sha256 "$src_data/projects.md")
remote_out=$(FM_HOME="$remote_home" "$ROOT/bin/fm-remote-inherit.sh" \
  project-registry data/projects.md "$remote_bytes" "$remote_hash" 1 \
  < "$src_data/projects.md") || fail "remote project-registry merge must succeed"
printf '%s\n' "$remote_out" | grep -q 'pushed: data/projects.md' \
  || fail "remote project-registry merge must report a changed registry"
grep -qF -- '- finks-overwatch [no-mistakes-prod-only +yolo] - Event Relay (added 2026-09-16)' \
  "$remote_home/data/projects.md" || fail "remote receiver kept stale project posture"
grep -qF -- '- remote-only [direct-PR] - Remote project (added 2026-09-16)' \
  "$remote_home/data/projects.md" || fail "remote receiver clobbered remote-only project"
staged_registry=$(find "$remote_home/data" -name '.inherit.*' -print -quit)
[ -z "$staged_registry" ] || fail "remote registry merge left staged payload: $staged_registry"
pass "remote receiver merges shared project posture and preserves remote-only entries"

remote_out2=$(FM_HOME="$remote_home" "$ROOT/bin/fm-remote-inherit.sh" \
  project-registry data/projects.md "$remote_bytes" "$remote_hash" 1 \
  < "$src_data/projects.md") || fail "repeated remote project-registry merge must succeed"
[ "$remote_out2" = "unchanged: data/projects.md" ] \
  || fail "repeated remote project-registry merge must be idempotent, got: $remote_out2"
empty_registry="$TMP_ROOT/empty-projects.md"
: > "$empty_registry"
empty_hash=$(fm_inherit_sha256 "$empty_registry")
remote_absent_out=$(FM_HOME="$remote_home" "$ROOT/bin/fm-remote-inherit.sh" \
  project-registry data/projects.md 0 "$empty_hash" 2 \
  < "$empty_registry") || fail "empty remote project-registry marker must succeed"
[ "$remote_absent_out" = "unchanged: data/projects.md" ] \
  || fail "empty remote project-registry marker must be a no-op, got: $remote_absent_out"
if FM_HOME="$remote_home" "$ROOT/bin/fm-remote-inherit.sh" \
  project-registry data/projects.md "$remote_bytes" "$remote_hash" 1 \
  < "$src_data/projects.md" >/dev/null 2>&1; then
  fail "remote receiver accepted an older registry payload after an empty marker"
fi
grep -qF -- '- remote-only [direct-PR] - Remote project (added 2026-09-16)' \
  "$remote_home/data/projects.md" || fail "older registry payload removed remote-only project"
pass "empty remote registry markers advance generation without deleting local entries"

if FM_HOME="$remote_home" "$ROOT/bin/fm-remote-inherit.sh" \
  put data/projects.md "$remote_bytes" "$remote_hash" 2 \
  < "$src_data/projects.md" >/dev/null 2>&1; then
  fail "ordinary remote put must not accept data/projects.md"
fi
if FM_HOME="$remote_home" "$ROOT/bin/fm-remote-inherit.sh" \
  project-registry config/crew-harness "$remote_bytes" "$remote_hash" 2 \
  < "$src_data/projects.md" >/dev/null 2>&1; then
  fail "project-registry must reject paths other than data/projects.md"
fi
pass "remote receiver reserves data/projects.md for per-project merges"
