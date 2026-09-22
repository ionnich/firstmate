#!/usr/bin/env bash
# End-to-end direct drive of bin/fm-pr-merge.sh (the real product) under a
# reviewed autonomous dispatch. Only the external `gh` forge CLI is shimmed;
# the merge script, dispatch script, and outcome lib run for real.
set -u
ROOT=/Users/nich/.no-mistakes/worktrees/3bc3ee2d971b/01M34RBX90FXTDMD2XFGSXTHK4
EVDIR=/Users/nich/.no-mistakes/evidence/01M34RBX90FXTDMD2XFGSXTHK4

# Load the shared test helpers + the merge test's fixture builders (no test
# bodies execute: the runner block was stripped from this copy).
. "$ROOT/tests/_tmp_defs.sh"

case_dir=$(make_case direct-dispatch-merge)
mkdir -p "$case_dir/wt"
head=cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd
url=https://github.com/example/repo/pull/90
add_gh_mocks "$case_dir" "$head"
gen=fixture-task-x1
printf '\nspawn_gen=%s\nyolo=off\n' "$gen" >> "$case_dir/state/task-x1.meta"
home=$(cd "$case_dir/home" && pwd -P)
mkdir -p "$home/data/autonomous-dispatch"
cat > "$home/data/autonomous-dispatch/active.json" <<JSON
{"schema":"fm-autonomous-dispatch.v1","id":"dispatch-1","reviewed_revision":"review-1","reviewed_by":"captain","expires_at":null,"members":[{"home":"$home","task_id":"task-x1","mode":"no-mistakes","project":"$case_dir/project","launch":{"project":"$case_dir/project","mode":"no-mistakes","yolo":"off"},"deploy_environments":[],"excluded_deploy_environments":[],"full_autonomy":true,"spawn_gen":"$gen"}]}
JSON

set +e
run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr"
rc=$?
set -e

{
  echo "== rc =="
  echo "$rc"
  echo "== stdout =="
  cat "$case_dir/stdout"
  echo "== stderr =="
  cat "$case_dir/stderr"
  echo "== state/.wake-queue =="
  cat "$case_dir/state/.wake-queue" 2>/dev/null || echo "(no wake-queue)"
  echo "== gh.log (forge merge call) =="
  cat "$case_dir/gh.log"
} > "$EVDIR/dispatch-merge-outcome.stdout"

cat "$EVDIR/dispatch-merge-outcome.stdout"
