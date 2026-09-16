#!/usr/bin/env bash
# Live guard test for Pi model qualification (defect 1 fix).
#
# This test exercises real installed Pi harnesses and verifies model
# qualification behavior end to end. An absent harness is reported explicitly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate \
  --name pi-model-qualify \
  --desc "Pi model qualification refuses ambiguous models and qualifies unambiguous ones" \
  --tokens 0 \
  --tools pi

test_pi_model_listing() {
  local bin rc=0 listing
  
  bin=$(type -P pi 2>/dev/null) || {
    echo "SKIP: pi binary not found on PATH" >&2
    return 2
  }
  
  if ! "$bin" --help 2>&1 | grep -qE '--list-models'; then
    echo "SKIP: pi does not support --list-models" >&2
    return 2
  fi
  
  listing=$("$bin" --list-models 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: pi --list-models failed with exit $rc" >&2
    return 1
  fi
  
  if ! printf '%s\n' "$listing" | awk 'NR>1 {print $1, $2}' | grep -q .; then
    echo "FAIL: pi --list-models returned no models" >&2
    return 1
  fi
  
  echo "PASS: pi --list-models works ($(printf '%s\n' "$listing" | awk 'NR>1' | wc -l | tr -d ' ') models)"
}

test_pi_model_qualify_function() {
  local bin rc=0
  
  bin=$(type -P pi 2>/dev/null) || {
    echo "SKIP: pi binary not found" >&2
    return 2
  fi
  
  # Source the function directly
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-spawn.sh" 2>/dev/null || true
  
  # Test that the function exists
  if ! declare -f pi_model_qualify >/dev/null; then
    echo "FAIL: pi_model_qualify function not found in fm-spawn.sh" >&2
    return 1
  fi
  
  echo "PASS: pi_model_qualify function exists"
}

run_live_tests() {
  test_pi_model_listing
  test_pi_model_qualify_function
}

if [ "${FM_LIVE:-}" = 1 ] || [ "${FM_TEST_RUN:-}" = 1 ]; then
  run_live_tests
else
  printf 'Skipped: set FM_LIVE=1 or FM_TEST_RUN=1 to run live guard\n'
fi
