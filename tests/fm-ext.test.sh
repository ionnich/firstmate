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
  mkdir -p "$w/.local/share/firstmate/profiles/resident/npm" "$w/.local/share/firstmate/profiles/crew/npm" "$w/home/state" "$w/fakebin"
  ln -s .local/share/firstmate/profiles "$w/profiles"
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
for arg in "$@"; do
  if [ "$arg" = "${FM_TEST_NPM_BLOCK_PACKAGE:-}" ] && [[ "$(pwd)" == *"${FM_TEST_NPM_BLOCK_IN:-}"* ]]; then
    : > "$FM_TEST_NPM_BLOCKED"
    while [ ! -e "$FM_TEST_NPM_RELEASE" ]; do sleep 0.01; done
  fi
  if [ "$arg" = beta ] && [ -n "${FM_TEST_NPM_BETA_STARTED:-}" ]; then
    : > "$FM_TEST_NPM_BETA_STARTED"
  fi
done
case "$1" in
  install)
    echo '{"name":"pi-extensions","private":true,"dependencies":{"pi-existing":"^1.0.0","newpkg":"^1.0.0"}}' > package.json
    mkdir -p node_modules/newpkg
    ;;
  uninstall)
    echo '{"name":"pi-extensions","private":true,"dependencies":{}}' > package.json
    rm -rf node_modules/pi-existing
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
  cp "$EXT" "$w/fakebin/fm-ext.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$w/fakebin/fm-wake-lib.sh"
  printf '%s\n' "$w"
}

run_ext() {  # <world> <fm-ext args...>
  local w=$1
  shift
  PATH="$w/fakebin:$PATH" \
    HOME="$w" \
    FM_HOME="$w/home" \
    FM_TEST_SEND_LOG="$w/sendlog" \
    bash "$w/fakebin/fm-ext.sh" "$@"
}

# --- 1. dry-run writes nothing, reports both profiles ------------------------

w=$(make_world)
out=$(run_ext "$w" install newpkg --dry-run) || fail "dry-run install should exit 0"
assert_contains "$out" "resident/npm" "dry-run mentions resident profile"
assert_contains "$out" "crew/npm" "dry-run mentions crew profile"
assert_contains "$out" "would run: npm install --save -- newpkg" "dry-run states the exact command"
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
[ ! -e "$w/profiles/resident/npm/node_modules/newpkg" ] \
  || fail "resident installed tree was not reverted after crew's npm call failed"
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
cat > "$w/home/state/remote-mgr.meta" <<'EOF'
harness=pi
kind=secondmate
endpoint_task_id=remote-mgr
remote_host=example.test
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
assert_no_grep remote-mgr "$w/sendlog" "remote secondmate never nudged"
assert_no_grep other-harness "$w/sendlog" "non-pi harness session never nudged"
pass "successful apply nudges every live harness=pi session touched by the change"

w=$(make_world)
printf '%s' '{"name":"pi-extensions","private":true,"dependencies":{"foo-bar":"^1.0.0"}}' > "$w/profiles/resident/npm/package.json"
out=$(run_ext "$w" install foo.bar --dry-run) || fail "dry-run exact dependency lookup should exit 0"
assert_contains "$out" "foo.bar currently present=no" "dry-run uses exact package key lookup"
pass "dry-run distinguishes punctuation in package names"

w=$(make_world)
printf '%s' '{not json' > "$w/profiles/resident/npm/package.json"
run_ext "$w" install newpkg --dry-run >/dev/null 2>&1
rc=$?
assert_not_equals 0 "$rc" "dry-run rejects unreadable package manifests"
pass "dry-run refuses malformed package manifests"

# --- 7. option-like package arguments never reach npm -----------------------

w=$(make_world)
run_ext "$w" install --package-lock-only >/dev/null 2>&1
rc=$?
assert_not_equals 0 "$rc" "option-like package is refused"
assert_equals "$PKG_JSON" "$(cat "$w/profiles/resident/npm/package.json")" \
  "option-like package leaves resident untouched"
assert_equals "$PKG_JSON" "$(cat "$w/profiles/crew/npm/package.json")" \
  "option-like package leaves crew untouched"
pass "option-like package arguments are refused before npm"

# --- 8. concurrent applies serialize the full profile transaction ------------

w=$(make_world)
FM_TEST_NPM_BLOCK_PACKAGE=alpha \
  FM_TEST_NPM_BLOCK_IN=resident/npm \
  FM_TEST_NPM_BLOCKED="$w/blocked" \
  FM_TEST_NPM_RELEASE="$w/release" \
  FM_TEST_NPM_BETA_STARTED="$w/beta-started" \
  run_ext "$w" install alpha >/dev/null 2>&1 &
alpha_pid=$!
while [ ! -e "$w/blocked" ]; do sleep 0.01; done
FM_TEST_NPM_BLOCK_PACKAGE=alpha \
  FM_TEST_NPM_BLOCK_IN=resident/npm \
  FM_TEST_NPM_BLOCKED="$w/blocked" \
  FM_TEST_NPM_RELEASE="$w/release" \
  FM_TEST_NPM_BETA_STARTED="$w/beta-started" \
  run_ext "$w" install beta >/dev/null 2>&1 &
beta_pid=$!
for _ in $(seq 1 50); do
  [ -e "$w/beta-started" ] && break
  sleep 0.01
done
if [ -e "$w/beta-started" ]; then
  beta_started=yes
else
  beta_started=no
fi
: > "$w/release"
wait "$alpha_pid" || fail "first concurrent install should succeed"
wait "$beta_pid" || fail "second concurrent install should succeed"
assert_equals no "$beta_started" "second install waits for first transaction"
pass "concurrent installs serialize profile transactions"

w=$(make_world)
mkdir "$w/profiles/.fm-ext.lock"
touch -t 200001010000 "$w/profiles/.fm-ext.lock"
run_ext "$w" install newpkg >/dev/null 2>&1 &
stale_lock_pid=$!
for _ in $(seq 1 50); do
  kill -0 "$stale_lock_pid" 2>/dev/null || break
  sleep 0.01
done
if kill -0 "$stale_lock_pid" 2>/dev/null; then
  stale_lock_recovered=no
  kill "$stale_lock_pid" 2>/dev/null || true
  wait "$stale_lock_pid" 2>/dev/null || true
else
  wait "$stale_lock_pid" || fail "stale profile lock recovery should succeed"
  stale_lock_recovered=yes
fi
assert_equals yes "$stale_lock_recovered" "stale profile lock is reclaimed"
pass "stale profile lock does not block extension installs"
