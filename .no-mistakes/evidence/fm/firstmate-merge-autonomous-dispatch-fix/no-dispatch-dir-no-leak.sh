#!/usr/bin/env bash
# Adversarial: a generation-bound merge with NO data/autonomous-dispatch dir
# must still succeed and must NOT leak "invalid dispatch directory" to stderr
# (the caller silences lock-path's new validate_root via 2>/dev/null).
set -u
ROOT=/Users/nich/.no-mistakes/worktrees/3bc3ee2d971b/01M34RBX90FXTDMD2XFGSXTHK4
EVDIR=/Users/nich/.no-mistakes/evidence/01M34RBX90FXTDMD2XFGSXTHK4

. "$ROOT/tests/_tmp_defs.sh"

case_dir=$(make_case direct-no-dispatch-dir)
mkdir -p "$case_dir/wt"
head=afafafafafafafafafafafafafafafafafafafaf
url=https://github.com/example/repo/pull/82
add_gh_mocks "$case_dir" "$head"
printf '\nspawn_gen=fixture-task-x1\nyolo=on\n' >> "$case_dir/state/task-x1.meta"
write_away_record "$case_dir"
[ ! -e "$case_dir/home/data/autonomous-dispatch" ] || { echo "fixture leaked dispatch state"; exit 1; }

set +e
run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr"
rc=$?
set -e

{
  echo "== rc =="
  echo "$rc"
  echo "== stderr =="
  cat "$case_dir/stderr"
  echo "== leak check: grep 'invalid dispatch directory' stderr =="
  if grep -Fq 'invalid dispatch directory' "$case_dir/stderr"; then
    echo "LEAK: found 'invalid dispatch directory' on stderr"
  else
    echo "CLEAN: no 'invalid dispatch directory' on stderr"
  fi
  echo "== state/.wake-queue =="
  cat "$case_dir/state/.wake-queue" 2>/dev/null || echo "(no wake-queue)"
  echo "== dispatch dir still absent? =="
  [ -e "$case_dir/home/data/autonomous-dispatch" ] && echo "PRESENT (unexpected)" || echo "ABSENT (correct)"
} > "$EVDIR/no-dispatch-dir-no-leak.stdout"

cat "$EVDIR/no-dispatch-dir-no-leak.stdout"
