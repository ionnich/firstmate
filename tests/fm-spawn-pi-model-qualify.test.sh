#!/usr/bin/env bash
# Test Pi model qualification (defect 1 fix).
#
# Verifies that fm-spawn refuses ambiguous bare model ids and auto-qualifies
# unambiguous ones before launching a Pi worker.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pi-model-qualify)

# Fake Pi binary that reports model listings
make_fake_pi() {
  local fakebin=$1
  cat > "$fakebin/pi" <<'EOF'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode> --model <pattern> --list-models [search]'
  exit 0
fi
if [ "${1:-}" = --list-models ]; then
  # Simulate listing with ambiguous claude-sonnet-4-5 across two providers
  cat <<LISTING
provider   model                    context  max-out  thinking  images
anthropic  claude-sonnet-4-5        1M       64K      yes       yes
anthropic  claude-haiku-4           200K     16K      no        yes
cursor     claude-sonnet-4-5        200K     64K      no        yes
cursor     claude-haiku-4           200K     16K      no        yes
google     gemini-3-8-flash         1M       32K      no        no
LISTING
  exit 0
fi
exit 0
EOF
  chmod +x "$fakebin/pi"
}

make_fake_backend() {
  local fakebin=$1
  # Minimal fake tmux
  cat > "$fakebin/tmux" <<'EOF'
#!/usr/bin/env bash
# Fake tmux that accepts send-keys and reports window exists
case "${1:-}" in
  new-window) printf 'test-session:1\n' ;;
  send-keys) exit 0 ;;
  list-windows) printf '1: test-window\n' ;;
  list-panes) printf '%%1 1 active\n' ;;
  display-message) printf '/tmp/test-wt\n' ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fakebin/tmux"
}

test_ambiguous_model_refused() {
  local test_home fakebin proj wt brief out rc=0
  test_home=$(fm_test_make_home "$TMP_ROOT/ambiguous")
  fakebin="$test_home/fakebin"
  mkdir -p "$fakebin"
  make_fake_pi "$fakebin"
  make_fake_backend "$fakebin"
  
  proj=$(fm_test_make_project "$test_home/proj")
  wt=$(fm_test_make_worktree "$proj" task-wt)
  brief="$test_home/data/test-task/brief.md"
  mkdir -p "$(dirname "$brief")"
  printf '# Test brief\nTest task\n' > "$brief"
  
  # Spawn with ambiguous bare model should refuse
  PATH="$fakebin:$PATH" FM_HOME="$test_home" \
    "$SPAWN" test-task "$proj" --mode no-mistakes --yolo off \
    --harness pi --model claude-sonnet-4-5 > "$TMP_ROOT/ambiguous.out" 2>&1 || rc=$?
  
  out=$(cat "$TMP_ROOT/ambiguous.out")
  
  if [ "$rc" -eq 0 ]; then
    printf 'FAIL: ambiguous model spawn succeeded when it should have refused\n' >&2
    return 1
  fi
  
  if ! printf '%s\n' "$out" | grep -qE 'error.*ambiguous.*2 providers'; then
    printf 'FAIL: error did not mention ambiguity across 2 providers\n' >&2
    printf 'Output:\n%s\n' "$out" >&2
    return 1
  fi
  
  if ! printf '%s\n' "$out" | grep -qE 'anthropic.*cursor'; then
    printf 'FAIL: error did not list both providers\n' >&2
    printf 'Output:\n%s\n' "$out" >&2
    return 1
  fi
  
  if ! printf '%s\n' "$out" | grep -qE 'anthropic/claude-sonnet-4-5'; then
    printf 'FAIL: error did not suggest qualified form\n' >&2
    printf 'Output:\n%s\n' "$out" >&2
    return 1
  fi
  
  printf 'PASS: ambiguous model refused with actionable error\n'
}

test_unambiguous_model_qualified() {
  local test_home fakebin proj wt brief out rc=0
  test_home=$(fm_test_make_home "$TMP_ROOT/unambiguous")
  fakebin="$test_home/fakebin"
  mkdir -p "$fakebin"
  make_fake_pi "$fakebin"
  make_fake_backend "$fakebin"
  
  proj=$(fm_test_make_project "$test_home/proj")
  wt=$(fm_test_make_worktree "$proj" task-wt)
  brief="$test_home/data/test-task/brief.md"
  mkdir -p "$(dirname "$brief")"
  printf '# Test brief\nTest task\n' > "$brief"
  
  # Spawn with unambiguous bare model should auto-qualify
  PATH="$fakebin:$PATH" FM_HOME="$test_home" TMUX=fake-session \
    "$SPAWN" test-task "$proj" --mode no-mistakes --yolo off \
    --harness pi --model gemini-3-8-flash > "$TMP_ROOT/unambiguous.out" 2>&1 || rc=$?
  
  out=$(cat "$TMP_ROOT/unambiguous.out")
  
  # Should succeed (spawn completes, though fake backend may not fully simulate)
  # The key check is the notice about qualification
  if ! printf '%s\n' "$out" | grep -qE "notice.*qualifying.*'gemini-3-8-flash'.*'google/gemini-3-8-flash'"; then
    printf 'FAIL: unambiguous model was not auto-qualified\n' >&2
    printf 'Output:\n%s\n' "$out" >&2
    return 1
  fi
  
  printf 'PASS: unambiguous model auto-qualified\n'
}

test_qualified_model_passes() {
  local test_home fakebin proj wt brief out rc=0
  test_home=$(fm_test_make_home "$TMP_ROOT/qualified")
  fakebin="$test_home/fakebin"
  mkdir -p "$fakebin"
  make_fake_pi "$fakebin"
  make_fake_backend "$fakebin"
  
  proj=$(fm_test_make_project "$test_home/proj")
  wt=$(fm_test_make_worktree "$proj" task-wt)
  brief="$test_home/data/test-task/brief.md"
  mkdir -p "$(dirname "$brief")"
  printf '# Test brief\nTest task\n' > "$brief"
  
  # Spawn with already-qualified model should pass through
  PATH="$fakebin:$PATH" FM_HOME="$test_home" TMUX=fake-session \
    "$SPAWN" test-task "$proj" --mode no-mistakes --yolo off \
    --harness pi --model anthropic/claude-sonnet-4-5 > "$TMP_ROOT/qualified.out" 2>&1 || rc=$?
  
  out=$(cat "$TMP_ROOT/qualified.out")
  
  # Should not print qualification notice (model already qualified)
  if printf '%s\n' "$out" | grep -qE "notice.*qualifying"; then
    printf 'FAIL: already-qualified model triggered qualification\n' >&2
    printf 'Output:\n%s\n' "$out" >&2
    return 1
  fi
  
  printf 'PASS: qualified model passed through\n'
}

run_tests() {
  test_ambiguous_model_refused
  test_unambiguous_model_qualified
  test_qualified_model_passes
}

if [ "${FM_TEST_RUN:-}" = 1 ]; then
  run_tests
else
  printf 'Skipped: set FM_TEST_RUN=1 to run\n'
fi
