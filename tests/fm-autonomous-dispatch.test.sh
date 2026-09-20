#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="$ROOT/bin/fm-autonomous-dispatch.sh"
DEPLOY="$ROOT/bin/fm-autonomous-deploy.sh"
TMP_ROOT=$(fm_test_tmproot fm-autonomous-dispatch)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data/autonomous-dispatch" "$HOME_DIR/state"
cat > "$HOME_DIR/data/autonomous-dispatch/active.json" <<JSON
{"schema":"fm-autonomous-dispatch.v1","id":"dispatch-1","reviewed_revision":"review-1","reviewed_by":"captain","expires_at":null,"members":[{"home":"$HOME_DIR","task_id":"task-1","mode":"no-mistakes","project":"/project","launch":{"project":"/project","mode":"no-mistakes","yolo":"off"},"deploy_environments":["staging"],"excluded_deploy_environments":["production"],"full_autonomy":true,"spawn_gen":"s1"}]}
JSON
cat > "$HOME_DIR/state/task-1.meta" <<META
spawn_gen=s1
META

[ "$(FM_HOME="$HOME_DIR" "$SCRIPT" member --home "$HOME_DIR" --task task-1 --spawn-gen s1 --action merge)" = grant ] || fail 'reviewed member merge denied'
if FM_HOME="$HOME_DIR" "$SCRIPT" member --home "$HOME_DIR" --task task-1 --spawn-gen s1 --action deploy --environment production >/dev/null 2>&1; then fail 'excluded deployment granted'; fi
entrypoint="$TMP_ROOT/deploy"
printf '#!/usr/bin/env bash\nprintf deployed\n' > "$entrypoint"
chmod +x "$entrypoint"
[ "$(FM_HOME="$HOME_DIR" FM_TASK_ID=task-1 "$DEPLOY" --environment staging -- "$entrypoint")" = deployed ] || fail 'reviewed deployment did not execute entrypoint'
if FM_HOME="$HOME_DIR" FM_TASK_ID=task-1 "$DEPLOY" --environment production -- "$entrypoint" >/dev/null 2>&1; then fail 'excluded deployment executed entrypoint'; fi
FM_HOME="$HOME_DIR" "$SCRIPT" revoke >/dev/null
if FM_HOME="$HOME_DIR" "$SCRIPT" member --home "$HOME_DIR" --task task-1 --spawn-gen s1 --action merge >/dev/null 2>&1; then fail 'revoked dispatch granted'; fi
pass 'reviewed dispatch grants exact generation and deployment environment only'
