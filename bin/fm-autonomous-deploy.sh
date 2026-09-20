#!/usr/bin/env bash
# Gate one explicit task deployment through reviewed dispatch membership.
set -euo pipefail

[ "${1:-}" = --environment ] && [ -n "${2:-}" ] && [ "${3:-}" = -- ] && [ -n "${4:-}" ] || { echo 'usage: fm-autonomous-deploy.sh --environment NAME -- ENTRYPOINT [ARGS...]' >&2; exit 2; }
environment=$2
shift 3
home=${FM_HOME:?FM_HOME is required}
task=${FM_TASK_ID:?FM_TASK_ID is required}
meta="$home/state/$task.meta"
[ -f "$meta" ] && [ ! -L "$meta" ] || { echo 'error: task metadata is unavailable' >&2; exit 1; }
generation=$(awk -F= '$1 == "spawn_gen" { print substr($0, index($0, "=") + 1); exit }' "$meta")
[ -n "$generation" ] || { echo 'error: task generation is unavailable' >&2; exit 1; }
"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-autonomous-dispatch.sh" member --home "$home" --task "$task" --spawn-gen "$generation" --action deploy --environment "$environment" >/dev/null || { echo 'error: reviewed dispatch does not authorize this deployment' >&2; exit 1; }
[ -x "$1" ] && [ ! -L "$1" ] || { echo 'error: deployment entrypoint must be an explicit regular executable' >&2; exit 1; }
exec "$@"
