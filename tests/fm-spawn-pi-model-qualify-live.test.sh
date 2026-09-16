#!/usr/bin/env bash
# Live guard test for Pi model qualification (defect 1 fix).
#
# This test exercises the real installed Pi harness's --list-models output
# shape, the assumption bin/fm-spawn.sh's pi_model_qualify is built on. An
# absent harness is reported explicitly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_PI_MODEL_QUALIFY_LIVE pi

test_pi_model_listing() {
  local bin listing

  bin=$(type -P pi 2>/dev/null) || fail "pi binary not found on PATH despite fm_live_gate confirming it"

  printf '%s\n' "$("$bin" --help 2>&1)" | grep -qE -- '--list-models' \
    || fail "pi --help no longer advertises --list-models; pi_model_qualify's invocation assumption no longer holds"

  listing=$("$bin" --list-models 2>&1) || fail "pi --list-models failed"$'\n'"$listing"
  printf '%s\n' "$listing" | awk 'NR>1 {print $1, $2}' | grep -q . \
    || fail "pi --list-models returned no models"$'\n'"$listing"

  pass "pi --list-models works ($(printf '%s\n' "$listing" | awk 'NR>1' | wc -l | tr -d ' ') models)"
}

test_pi_model_listing
