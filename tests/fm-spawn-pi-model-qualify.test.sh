#!/usr/bin/env bash
# Test Pi model qualification (defect 1 fix) and the post-launch liveness gate
# (defect 2 fix).
#
# Verifies that fm-spawn refuses ambiguous bare model ids, auto-qualifies
# unambiguous ones, and refuses a Pi/pi-signed worker that exits immediately
# after launch instead of reporting it as working.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pi-model-qualify)

# make_fake_pi <fakebin>: --help advertises --list-models; --list-models
# prints a catalog with claude-sonnet-4-5 offered by two providers (anthropic,
# cursor) and gemini-3-8-flash offered by exactly one (google).
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

make_case() {
  local name=$1 id=$2 case_dir home fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir" pi)
  make_fake_pi "$fakebin"
  fm_test_spawn_home "$home" pi
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$fakebin"
}

read_case() {
  IFS='|' read -r _ HOME_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

test_ambiguous_model_refused() {
  local rec id out status
  id=pi-qualify-ambiguous-z1
  rec=$(make_case ambiguous "$id")
  read_case "$rec"

  out=$(fm_test_run_spawn "$HOME_DIR" "$HOME_DIR/projects/proj" "$FAKEBIN_DIR" \
    "$id" nonexistent-project --mode no-mistakes --yolo off \
    --harness pi --model claude-sonnet-4-5)
  status=$?

  [ "$status" -ne 0 ] || fail "ambiguous model spawn succeeded when it should have refused"$'\n'"$out"
  assert_contains "$out" "ambiguous across 2 providers" "error did not mention ambiguity across 2 providers"$'\n'"$out"
  assert_contains "$out" "anthropic" "error did not list the anthropic provider"$'\n'"$out"
  assert_contains "$out" "cursor" "error did not list the cursor provider"$'\n'"$out"
  assert_contains "$out" "anthropic/claude-sonnet-4-5" "error did not suggest the qualified form"$'\n'"$out"
  assert_absent "$HOME_DIR/state/$id.meta" "ambiguous model refusal published task metadata"
  pass "ambiguous model refused with actionable error"
}

test_unambiguous_model_qualified() {
  local rec id out
  id=pi-qualify-unambiguous-z2
  rec=$(make_case unambiguous "$id")
  read_case "$rec"

  # Auto-qualification happens before the post-launch liveness gate, so its
  # notice is proven here regardless of what a fake, non-liveness-aware pane
  # later reports about the (never real) launched process.
  out=$(fm_test_run_spawn "$HOME_DIR" "$HOME_DIR/projects/proj" "$FAKEBIN_DIR" \
    "$id" nonexistent-project --mode no-mistakes --yolo off \
    --harness pi --model gemini-3-8-flash)

  assert_contains "$out" "notice: qualifying bare Pi model 'gemini-3-8-flash' as 'google/gemini-3-8-flash'" \
    "unambiguous model was not auto-qualified"$'\n'"$out"
  pass "unambiguous model auto-qualified"
}

test_qualified_model_passes() {
  local rec id out
  id=pi-qualify-passthrough-z3
  rec=$(make_case qualified "$id")
  read_case "$rec"

  out=$(fm_test_run_spawn "$HOME_DIR" "$HOME_DIR/projects/proj" "$FAKEBIN_DIR" \
    "$id" nonexistent-project --mode no-mistakes --yolo off \
    --harness pi --model anthropic/claude-sonnet-4-5)

  assert_not_contains "$out" "notice: qualifying" \
    "already-qualified model triggered qualification"$'\n'"$out"
  pass "qualified model passed through"
}

test_ambiguous_model_refused
test_unambiguous_model_qualified
test_qualified_model_passes

# --- defect 2: post-launch liveness gate -----------------------------------
#
# fm_backend_tmux_agent_state (bin/backends/tmux.sh) reads `ps -t <pane-tty>`,
# which only exists for a real pty, so the canned-response fake tmux used
# above cannot exercise it: it never lists the window it "creates", let alone
# the process running inside it. This drives the real bin/fm-spawn.sh against
# a REAL, private tmux server instead - the same technique
# tests/fm-tmux-agent-liveness.test.sh uses to test the classifier itself - so
# the gate's ps-backed liveness read is the genuine one, not a stand-in.
#
# The secondmate path is used because it skips treehouse/worktree acquisition
# entirely (bin/fm-spawn.sh only runs that block for ship/scout kinds),
# leaving just the window-create-and-launch shape the gate actually guards.

LIVENESS_SOCKETS=()
cleanup_liveness_sockets() {
  local s tmux_bin
  tmux_bin=$(command -v tmux) || return 0
  for s in "${LIVENESS_SOCKETS[@]:-}"; do
    [ -n "$s" ] && "$tmux_bin" -L "$s" kill-server >/dev/null 2>&1
  done
  return 0
}
trap cleanup_liveness_sockets EXIT

# run_pi_liveness_case <alive:0|1> <name>: spawns a pi secondmate against a
# private tmux server whose launched "pi" either stays running (alive=1, via
# a real symlink to sleep - kernel process identity, not argv, is what the
# classifier reads) or exits immediately (alive=0). Sets LIVENESS_STATUS and
# LIVENESS_OUT.
run_pi_liveness_case() {
  local alive=$1 name=$2
  local case_dir home sm id socket real_tmux sleep_bin fakebin agentbin

  case_dir="$TMP_ROOT/liveness-$name"
  home="$case_dir/home"
  sm="$case_dir/secondmate-home"
  id="pi-liveness-$name"
  socket="fm-pi-liveness-$name-$$"
  fakebin="$case_dir/fakebin"
  agentbin="$case_dir/agentbin"

  real_tmux=$(command -v tmux) || fail "tmux not found; cannot test the real liveness gate"
  sleep_bin=$(command -v sleep) || fail "sleep not found; cannot test the real liveness gate"
  LIVENESS_SOCKETS+=("$socket")

  fm_test_spawn_home "$home" pi
  mkdir -p "$sm/bin" "$sm/data" "$fakebin" "$agentbin"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"

  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
exec "$real_tmux" -L "$socket" "\$@"
SH
  chmod +x "$fakebin/tmux"

  # A real symlink (not a copy) to sleep: the kernel records the invoked
  # path's own basename as the process identity, which is exactly what the
  # anchored 'pi' match in bin/fm-agent-process-lib.sh classifies as an agent.
  ln -s "$sleep_bin" "$agentbin/pi"

  cat > "$fakebin/pi" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode>'
  exit 0
fi
if [ "$alive" -eq 1 ]; then
  exec "$agentbin/pi" 300
fi
exit 1
SH
  chmod +x "$fakebin/pi"

  LIVENESS_OUT=$(PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$sm" --secondmate --harness pi 2>&1)
  LIVENESS_STATUS=$?

  "$real_tmux" -L "$socket" kill-server >/dev/null 2>&1
}

test_liveness_gate_refuses_dead_worker() {
  command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; return 0; }
  run_pi_liveness_case 0 dead
  [ "$LIVENESS_STATUS" -ne 0 ] || fail "spawn succeeded for a pi worker that exited immediately after launch"$'\n'"$LIVENESS_OUT"
  assert_contains "$LIVENESS_OUT" "exited immediately after launch" \
    "refusal did not name the post-launch liveness failure"$'\n'"$LIVENESS_OUT"
  pass "the post-launch liveness gate refuses a pi worker that exits immediately"
}

test_liveness_gate_allows_alive_worker() {
  command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; return 0; }
  run_pi_liveness_case 1 alive
  [ "$LIVENESS_STATUS" -eq 0 ] || fail "spawn refused a pi worker that stayed alive after launch"$'\n'"$LIVENESS_OUT"
  assert_contains "$LIVENESS_OUT" "spawned pi-liveness-alive" \
    "a live pi worker was not reported as spawned"$'\n'"$LIVENESS_OUT"
  pass "the post-launch liveness gate allows a pi worker that stays alive"
}

test_liveness_gate_refuses_dead_worker
test_liveness_gate_allows_alive_worker

echo "# all fm-spawn-pi-model-qualify tests passed"
