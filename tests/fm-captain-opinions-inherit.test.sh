#!/usr/bin/env bash
# Behavior tests for primary-authoritative advisory captain-opinion inheritance.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/fm-config-inherit-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-opinions)

mode() { if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi; }
header() { cat <<'TEXT'
# Captain opinions

This file is main-authoritative in the main firstmate home.
In secondmate homes it is read-only in secondmate homes and must not be edited there.
Opinions are advisory only and never grant authority.
TEXT
}
new_pair() {
  local base="$TMP_ROOT/$1"; mkdir -p "$base/primary/data" "$base/primary/config" "$base/second/data" "$base/second/config"
  printf '%s|%s\n' "$base/primary" "$base/second"
}
write_opinions() { header > "$1"; printf '%s\n' "$2" >> "$1"; }

test_primary_opinions_propagate_readonly_and_quarantine_drift() {
  local rec primary second report
  rec=$(new_pair basic); primary=${rec%%|*}; second=${rec#*|}; report="$TMP_ROOT/report"
  write_opinions "$primary/data/captain-opinions.md" '- scope: release\n  stance: default\n  rationale: prefer safe path\n  last-confirmed: 2026-09-20'
  FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second" || fail 'opinion propagation failed'
  cmp -s "$primary/data/captain-opinions.md" "$second/data/captain-opinions.md" || fail 'opinions did not converge'
  [ "$(mode "$second/data/captain-opinions.md")" = 444 ] || fail 'opinions are not read-only'
  chmod u+w "$second/data/captain-opinions.md"
  printf '%s\n' 'drift' > "$second/data/captain-opinions.md"; chmod 444 "$second/data/captain-opinions.md"
  FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second" || fail 'drift reconciliation failed'
  cmp -s "$primary/data/captain-opinions.md" "$second/data/captain-opinions.md" || fail 'drift was not replaced'
  find "$second/data" -name '.captain-opinions.md.quarantine.*' | grep -q . || fail 'drift was not quarantined'
  pass 'captain opinions converge read-only and quarantine drift'
}

test_malformed_opinions_are_rejected() {
  local rec primary second err rc
  rec=$(new_pair malformed); primary=${rec%%|*}; second=${rec#*|}
  printf '%s\n' '# missing advisory header' > "$primary/data/captain-opinions.md"
  propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>"$TMP_ROOT/error"; rc=$?
  [ "$rc" -ne 0 ] || fail 'malformed opinions source passed'
  assert_grep 'header missing required' "$TMP_ROOT/error" 'malformed opinions error missing'
  pass 'malformed captain opinions refuse propagation'
}

test_primary_opinions_propagate_readonly_and_quarantine_drift
test_malformed_opinions_are_rejected
echo "# all fm-captain-opinions-inherit tests passed"
