#!/usr/bin/env bash
# Tests for bin/fm-remote-adopt.sh: converging a firstmate home onto the fleet's
# approved update source, and the hook that runs it from bin/fm-update.sh.
#
# The guarantees under test, mirroring docs/configuration.md ("Firstmate update
# source remotes"):
#   - origin becomes the approved fork whether the home had no origin, the
#     retired parent as origin, or a local seed path equal to the primary root.
#   - the upstream remote becomes the reference, with a push URL that cannot
#     resolve, so publishing to the parent by accident fails instead of working.
#   - a home already on the contract is reported current and written not at all.
#   - neither a foreign origin nor an unrecognized upstream URL is ever
#     repointed, and in both cases the home is left byte-identical rather than
#     half-adopted.
#   - no case fetches, pushes, resets, or moves HEAD; the script only edits
#     remote configuration.
#   - bin/fm-update.sh runs the adoption for every home it touches, before the
#     fetch, without changing its own status or action lines.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADOPT="$ROOT/bin/fm-remote-adopt.sh"
UPDATE="$ROOT/bin/fm-update.sh"

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-remote-adopt-tests)

# A fork bare repo, a reference bare repo, and a primary checkout cloned from the
# fork. Echoes the world dir; exports FORK and REF for the callers below.
FORK=""
REF=""
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  git init -q --bare "$w/fork.git"
  git -C "$w/fork.git" symbolic-ref HEAD refs/heads/main
  git init -q --bare "$w/ref.git"
  git -C "$w/ref.git" symbolic-ref HEAD refs/heads/main
  git init -q "$w/seed"
  git -C "$w/seed" symbolic-ref HEAD refs/heads/main
  printf 'v1\n' > "$w/seed/AGENTS.md"
  mkdir -p "$w/seed/bin"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" remote add origin "$w/fork.git"
  git -C "$w/seed" push -q origin main
  git clone -q "$w/fork.git" "$w/primary"
  printf '%s\n' "$w"
}

run_adopt() {  # <args...>
  FM_FIRSTMATE_SOURCE_URL="$FORK" FM_FIRSTMATE_REFERENCE_URL="$REF" "$ADOPT" "$@"
}

# A bare home repo with a commit, so remote configuration can be exercised
# without a working tree or a default branch. Args: <path>.
new_home_repo() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git init -q "$dir"
  printf 'x\n' > "$dir/file"
  git -C "$dir" add -A
  git -C "$dir" commit -qm home
}

# --- T1: adoption adds the missing reference and is idempotent --------------
test_adopts_fork_origin_and_reference() {
  local w home out
  w=$(new_world t1)
  FORK="$w/fork.git"; REF="$w/ref.git"
  new_home_repo "$w/home-a"
  git -C "$w/home-a" remote add origin "$FORK"

  out=$(run_adopt --primary-root "$w/primary" --label home-a "$w/home-a")
  assert_contains "$out" "home-a: source adopted" "an origin-only home adopts the missing reference"
  [ "$(git -C "$w/home-a" remote get-url origin)" = "$FORK" ] \
    || fail "origin was not left on the fork"
  [ "$(git -C "$w/home-a" remote get-url upstream)" = "$REF" ] \
    || fail "upstream was not set to the reference"
  [ "$(git -C "$w/home-a" remote get-url --push upstream)" = "fm-read-only-reference" ] \
    || fail "the reference remote kept a usable push URL"

  out=$(run_adopt --primary-root "$w/primary" --label home-a "$w/home-a")
  assert_contains "$out" "home-a: source current" "a converged home reports current"
  pass "T1 adoption adds the reference, and a converged home reports current"
}

# --- T2: a home still pointed at the retired parent is repointed ------------
test_repoints_retired_parent_origin() {
  local w out
  w=$(new_world t2)
  FORK="$w/fork.git"; REF="$w/ref.git"
  new_home_repo "$w/home-b"
  git -C "$w/home-b" remote add origin "$REF"

  out=$(run_adopt --primary-root "$w/primary" --label home-b "$w/home-b")
  assert_contains "$out" "home-b: source adopted" "a parent-pointed home is repointed"
  [ "$(git -C "$w/home-b" remote get-url origin)" = "$FORK" ] \
    || fail "origin still points at the retired parent"
  pass "T2 a home whose origin is the retired parent is repointed to the fork"
}

# --- T3: a home seeded from the primary path is repointed ------------------
test_repoints_local_seed_origin() {
  local w out
  w=$(new_world t3)
  FORK="$w/fork.git"; REF="$w/ref.git"
  new_home_repo "$w/home-c"
  git -C "$w/home-c" remote add origin "$w/primary"

  out=$(run_adopt --primary-root "$w/primary" --label home-c "$w/home-c")
  assert_contains "$out" "home-c: source adopted" "a seed-pointed home is repointed"
  [ "$(git -C "$w/home-c" remote get-url origin)" = "$FORK" ] \
    || fail "origin still points at the local seed path"
  pass "T3 a home whose origin is the primary checkout path is repointed to the fork"
}

# --- T3b: the primary root defaults to this script's own repo root ----------
# The seed-path recognition must work with no --primary-root at all, or a home
# seeded from the running checkout is misread as a foreign source.
test_seed_origin_without_primary_root_flag() {
  local w out
  w=$(new_world t3b)
  FORK="$w/fork.git"; REF="$w/ref.git"
  new_home_repo "$w/home-c2"
  git -C "$w/home-c2" remote add origin "$ROOT"

  out=$(run_adopt --label home-c2 "$w/home-c2")
  assert_contains "$out" "home-c2: source adopted" \
    "the default primary root still recognizes a seed-pointed home"
  [ "$(git -C "$w/home-c2" remote get-url origin)" = "$FORK" ] \
    || fail "the seed path was not repointed without --primary-root"
  pass "T3b the primary root defaults to this script's own repo root"
}

# --- T4: a foreign origin is never repointed -------------------------------
test_foreign_origin_untouched() {
  local w out before
  w=$(new_world t4)
  FORK="$w/fork.git"; REF="$w/ref.git"
  new_home_repo "$w/home-d"
  git -C "$w/home-d" remote add origin "https://example.invalid/other/firstmate"
  before=$(git -C "$w/home-d" remote get-url origin)

  out=$(run_adopt --primary-root "$w/primary" --label home-d "$w/home-d")
  assert_contains "$out" "home-d: source skipped: origin is not a firstmate update source" \
    "a foreign origin is reported rather than repointed"
  [ "$(git -C "$w/home-d" remote get-url origin)" = "$before" ] \
    || fail "a foreign origin was changed"
  if git -C "$w/home-d" remote get-url upstream >/dev/null 2>&1; then
    fail "a skipped home gained an upstream remote it was never meant to have"
  fi
  pass "T4 a foreign origin is reported and left untouched"
}

# --- T5: an unrecognized upstream is never half-adopted --------------------
test_unrecognized_reference_leaves_home_untouched() {
  local w out before_origin
  w=$(new_world t5)
  FORK="$w/fork.git"; REF="$w/ref.git"
  new_home_repo "$w/home-e"
  git -C "$w/home-e" remote add origin "$REF"
  git -C "$w/home-e" remote add upstream "https://example.invalid/other/upstream"
  before_origin=$(git -C "$w/home-e" remote get-url origin)

  out=$(run_adopt --primary-root "$w/primary" --label home-e "$w/home-e")
  assert_contains "$out" "home-e: source skipped: upstream remote carries a different URL" \
    "an unrecognized upstream is reported"
  [ "$(git -C "$w/home-e" remote get-url origin)" = "$before_origin" ] \
    || fail "the home was half-adopted: origin changed on a skipped home"
  [ "$(git -C "$w/home-e" remote get-url upstream)" = "https://example.invalid/other/upstream" ] \
    || fail "the unrecognized upstream was rewritten"
  pass "T5 an unrecognized upstream leaves the home byte-identical, origin included"
}

# --- T6: a non-repo target is skipped, and HEAD never moves ----------------
test_non_repo_skipped_and_head_untouched() {
  local w out before
  w=$(new_world t6)
  FORK="$w/fork.git"; REF="$w/ref.git"
  mkdir -p "$w/not-a-repo"
  printf 'x\n' > "$w/not-a-repo/file"

  out=$(run_adopt --primary-root "$w/primary" --label plain "$w/not-a-repo")
  assert_contains "$out" "plain: source skipped: not a git work tree" \
    "a non-repo target is skipped"
  assert_absent "$w/not-a-repo/.git" "adoption did not create a repository"

  new_home_repo "$w/home-f"
  before=$(git -C "$w/home-f" rev-parse HEAD)
  run_adopt --primary-root "$w/primary" --label home-f "$w/home-f" >/dev/null
  [ "$(git -C "$w/home-f" rev-parse HEAD)" = "$before" ] \
    || fail "adoption moved HEAD"
  pass "T6 a non-repo target is skipped and adoption never moves HEAD"
}

# --- T7: the reference remote genuinely cannot be published to -------------
test_reference_push_is_refused() {
  local w rc
  w=$(new_world t7)
  FORK="$w/fork.git"; REF="$w/ref.git"
  new_home_repo "$w/home-g"
  run_adopt --primary-root "$w/primary" --label home-g "$w/home-g" >/dev/null

  # The reference bare repo would accept this push if the sentinel were absent,
  # so a refusal proves the read-only push URL, not a missing repository.
  set +e
  git -C "$w/home-g" push --quiet upstream HEAD:refs/heads/leak >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a push to the reference remote succeeded"
  [ -z "$(git -C "$w/ref.git" for-each-ref --count=1 refs/heads/leak)" ] \
    || fail "the reference bare repo received a branch from this home"
  pass "T7 a push to the reference remote is refused and lands nothing"
}

# --- T8: fm-update.sh adopts every home it touches -------------------------
test_update_adopts_every_home() {
  local w out rc
  w=$(new_world t8)
  FORK="$w/fork.git"; REF="$w/ref.git"
  cat > "$w/home/data/secondmates.md" <<EOF
- mate-one - test scope. (home: $w/mate-one; scope: test scope.; projects: ; added 2026-01-01)
EOF
  # A seeded secondmate home as a standalone clone pointed at the local primary
  # path, so the update pass is what repoints it onto the fork.
  git clone -q "$w/primary" "$w/mate-one"
  printf 'mate-one\n' > "$w/mate-one/.fm-secondmate-home"

  set +e
  out=$(FM_STATE_OVERRIDE="$w/home/state" FM_ROOT_OVERRIDE="$w/primary" FM_HOME="$w/home" \
    FM_FIRSTMATE_SOURCE_URL="$FORK" FM_FIRSTMATE_REFERENCE_URL="$REF" \
    "$UPDATE" 2>/dev/null)
  rc=$?
  set -e
  expect_code 0 "$rc" "the update still succeeds while adopting the source"
  assert_contains "$out" "firstmate: source " "the primary home's source is reported"
  assert_contains "$out" "firstmate: already current" "the update's own status line is unchanged"

  [ "$(git -C "$w/primary" remote get-url upstream)" = "$REF" ] \
    || fail "the primary home did not gain the reference remote"
  [ "$(git -C "$w/primary" remote get-url --push upstream)" = "fm-read-only-reference" ] \
    || fail "the primary home's reference remote is not read-only"

  # A registered home without a live meta is reached through the registry backstop.
  assert_contains "$out" "mate-one: source adopted" "the registry-backstop home is converged"
  [ "$(git -C "$w/mate-one" remote get-url origin)" = "$FORK" ] \
    || fail "a seeded secondmate home was not repointed onto the fork"
  [ "$(git -C "$w/mate-one" remote get-url upstream)" = "$REF" ] \
    || fail "a seeded secondmate home did not gain the reference remote"
  [ "$(git -C "$w/mate-one" remote get-url --push upstream)" = "fm-read-only-reference" ] \
    || fail "a seeded secondmate home's reference remote is not read-only"
  pass "T8 fm-update.sh converges the source of every home it touches"
}

# --- T9: adoption never redirects a foreign source or blocks the update ----
test_update_leaves_foreign_source_alone() {
  local w out
  w=$(new_world t9)
  FORK="$w/fork.git"; REF="$w/ref.git"
  git -C "$w/primary" remote set-url origin "https://example.invalid/other/firstmate"

  set +e
  out=$(FM_STATE_OVERRIDE="$w/home/state" FM_ROOT_OVERRIDE="$w/primary" FM_HOME="$w/home" \
    FM_FIRSTMATE_SOURCE_URL="$FORK" FM_FIRSTMATE_REFERENCE_URL="$REF" \
    "$UPDATE" 2>/dev/null)
  set -e
  assert_contains "$out" "firstmate: source skipped: origin is not a firstmate update source" \
    "a foreign update source is reported"
  assert_contains "$out" "firstmate: skipped: fetch failed" \
    "the update still ran against the home's own source"
  [ "$(git -C "$w/primary" remote get-url origin)" = "https://example.invalid/other/firstmate" ] \
    || fail "a foreign update source was redirected"
  pass "T9 a foreign update source is left alone and never blocks the update"
}

test_adopts_fork_origin_and_reference
test_repoints_retired_parent_origin
test_repoints_local_seed_origin
test_seed_origin_without_primary_root_flag
test_foreign_origin_untouched
test_unrecognized_reference_leaves_home_untouched
test_non_repo_skipped_and_head_untouched
test_reference_push_is_refused
test_update_adopts_every_home
test_update_leaves_foreign_source_alone

echo "# all fm-remote-adopt tests passed"
