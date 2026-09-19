#!/usr/bin/env bash
# tests/fm-ext.test.sh - bin/fm-ext.sh: fleet-wide Pi extension install/remove.
#
# Pins:
#   1. --dry-run reports intent for both profiles and writes nothing.
#   2. A successful install/remove applies to both profiles.
#   3. --resident-only / --crew-only scope which profile is touched.
#   4. A failure in one profile's npm call rolls back that profile AND any
#      profile already applied earlier in the same run - nothing is left
#      partially applied.
#   5. remove refuses a version-spec argument instead of guessing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXT="$ROOT/bin/fm-ext.sh"

TMP_ROOT=$(fm_test_tmproot fm-ext)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

PKG_JSON='{"name":"pi-extensions","private":true,"dependencies":{"pi-existing":"^1.0.0"}}'

make_world() {  # -> echoes world dir
  local w="$TMP_ROOT/world-$RANDOM"
  mkdir -p "$w/profiles/resident/npm" "$w/profiles/crew/npm" "$w/home/state" "$w/fakebin"
  printf '%s' "$PKG_JSON" > "$w/profiles/resident/npm/package.json"
  printf '%s' "$PKG_JSON" > "$w/profiles/crew/npm/package.json"
  echo '{}' > "$w/profiles/resident/npm/package-lock.json"
  echo '{}' > "$w/profiles/crew/npm/package-lock.json"
  cat > "$w/fakebin/npm" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_TEST_NPM_FAIL_IN:-}" ] && [[ "$(pwd)" == *"$FM_TEST_NPM_FAIL_IN"* ]]; then
  echo "fake npm failure" >&2
  exit 1
fi
case "$1" in
  install)
    echo '{"name":"pi-extensions","private":true,"dependencies":{"pi-existing":"^1.0.0","newpkg":"^1.0.0"}}' > package.json
    ;;
  uninstall)
    echo '{"name":"pi-extensions","private":true,"dependencies":{}}' > package.json
    ;;
esac
exit 0
SH
  chmod +x "$w/fakebin/npm"
  cat > "$w/fakebin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$FM_TEST_SEND_LOG"
exit 0
SH
  chmod +x "$w/fakebin/fm-send.sh"
  printf '%s\n' "$w"
}

run_ext() {  # <world> <fm-ext args...>
  local w=$1
  shift
  PATH="$w/fakebin:$PATH" \
    FM_HOME="$w/home" \
    FM_PROFILES_ROOT_OVERRIDE="$w/profiles" \
    FM_SEND_OVERRIDE="$w/fakebin/fm-send.sh" \
    FM_TEST_SEND_LOG="$w/sendlog" \
    bash "$EXT" "$@"
}

# --- 1. dry-run writes nothing, reports both profiles ------------------------

w=$(make_world)
out=$(run_ext "$w" install newpkg --dry-run) || fail "dry-run install should exit 0"
assert_contains "$out" "resident/npm" "dry-run mentions resident profile"
assert_contains "$out" "crew/npm" "dry-run mentions crew profile"
assert_contains "$out" "would run: npm install newpkg --save" "dry-run states the exact command"
assert_equals "$PKG_JSON" "$(cat "$w/profiles/resident/npm/package.json")" "dry-run leaves resident package.json untouched"
assert_equals "$PKG_JSON" "$(cat "$w/profiles/crew/npm/package.json")" "dry-run leaves crew package.json untouched"
pass "dry-run reports intent and writes nothing"

# --- 2. real install applies to both profiles --------------------------------

w=$(make_world)
run_ext "$w" install newpkg >/dev/null || fail "install should exit 0"
assert_grep newpkg "$w/profiles/resident/npm/package.json" "install applied to resident"
assert_grep newpkg "$w/profiles/crew/npm/package.json" "install applied to crew"
pass "install applies to both profiles"

# --- 3. --resident-only touches only the resident profile --------------------

w=$(make_world)
run_ext "$w" install newpkg --resident-only >/dev/null || fail "scoped install should exit 0"
assert_grep newpkg "$w/profiles/resident/npm/package.json" "scoped install applied to resident"
assert_equals "$PKG_JSON" "$(cat "$w/profiles/crew/npm/package.json")" "scoped install left crew untouched"
pass "--resident-only scopes to one profile"

# --- 4. a failure in one profile rolls back the whole run ---------------------

w=$(make_world)
FM_TEST_NPM_FAIL_IN=crew/npm run_ext "$w" install newpkg >/dev/null 2>&1
rc=$?
assert_not_equals 0 "$rc" "install with a failing profile exits nonzero"
assert_equals "$PKG_JSON" "$(cat "$w/profiles/resident/npm/package.json")" \
  "resident reverted after crew's npm call failed"
assert_equals "$PKG_JSON" "$(cat "$w/profiles/crew/npm/package.json")" \
  "crew left at its pre-failure state"
pass "one profile's npm failure rolls back every profile applied this run"

# --- 5. remove refuses a version-spec argument --------------------------------

w=$(make_world)
run_ext "$w" remove newpkg@1.2.3 >/dev/null 2>&1
rc=$?
assert_not_equals 0 "$rc" "remove with a version spec is refused"
pass "remove refuses a version-spec package argument"

# --- 6. successful apply nudges harness=pi sessions by profile ---------------

w=$(make_world)
cat > "$w/home/state/crewtask.meta" <<'EOF'
harness=pi
kind=ship
endpoint_task_id=crewtask
EOF
cat > "$w/home/state/mgr-x.meta" <<'EOF'
harness=pi
kind=secondmate
endpoint_task_id=mgr-x
EOF
cat > "$w/home/state/other-harness.meta" <<'EOF'
harness=claude
kind=ship
endpoint_task_id=other-harness
EOF
: > "$w/sendlog"
run_ext "$w" install newpkg >/dev/null || fail "install with meta records present should exit 0"
assert_grep crewtask "$w/sendlog" "crew-scoped ship task nudged"
assert_grep mgr-x "$w/sendlog" "resident-scoped secondmate nudged"
assert_no_grep other-harness "$w/sendlog" "non-pi harness session never nudged"
pass "successful apply nudges every live harness=pi session touched by the change"
