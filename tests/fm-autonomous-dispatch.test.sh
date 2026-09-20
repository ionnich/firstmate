#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPT="$ROOT/bin/fm-autonomous-dispatch.sh"
TMP_ROOT=$(fm_test_tmproot fm-autonomous-dispatch)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data"
RECORD="$TMP_ROOT/dispatch.json"
cat > "$RECORD" <<JSON
{"schema":"fm-autonomous-dispatch.v1","id":"dispatch-1","state":"active","expires_at":null,"members":[{"home":"$HOME_DIR","task_id":"task-1","full_autonomy":true}]}
JSON
FM_HOME="$HOME_DIR" "$SCRIPT" approve --record "$RECORD" >/dev/null
[ "$(FM_HOME="$HOME_DIR" "$SCRIPT" member --home "$HOME_DIR" --task task-1)" = grant ] || fail 'exact member denied'
if FM_HOME="$HOME_DIR" "$SCRIPT" member --home "$HOME_DIR" --task task-2 >/dev/null 2>&1; then fail 'unlisted task granted'; fi
FM_HOME="$HOME_DIR" "$SCRIPT" revoke >/dev/null
if FM_HOME="$HOME_DIR" "$SCRIPT" member --home "$HOME_DIR" --task task-1 >/dev/null 2>&1; then fail 'revoked dispatch granted'; fi
pass 'exact active dispatch membership grants only listed member'
