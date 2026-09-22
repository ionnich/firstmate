#!/usr/bin/env bash
# fm-secondmate-report.sh - optional helper to append a correlated parent report.
#
# A secondmate answering a marked from-firstmate request must report on the
# parent status channel with the request's corr=<id> token. This helper makes
# that easy, but correctness must not depend on using it: a plain echo of a
# status line that includes the same corr token is equally valid
# (bin/fm-pending-reply-lib.sh).
#
# The write destination is mechanical: this helper never takes a status path.
# It resolves the parent channel through fm_parent_channel_destination
# (bin/fm-parent-channel-lib.sh): a local mate writes the parent home's
# state/<id>.status, and a remote mate writes this home's
# state/parent-replies.status. Call it from the secondmate home with FM_HOME
# set to that home.
#
# Usage:
#   fm-secondmate-report.sh [--key <slug>] <verb> <corr_id> <note...>
#   fm-secondmate-report.sh [--key <slug>] --doc <verb> <corr_id> <doc-path> <note...>
#
# --key <slug> is required to close a decision that was opened with a stated
# key (needs-decision [key=<slug>]: ... or blocked [key=<slug>]: ...); a
# resolved line with no --key only closes the unkeyed "default" decision
# (bin/fm-classify-lib.sh's status-fold contract), so answering a keyed record
# through this helper without --key silently leaves it open. Pass the exact
# slug named in the record you are answering; this helper never guesses it.
#
# Examples:
#   fm-secondmate-report.sh done abcdef0123456789 "audit clean"
#   fm-secondmate-report.sh --key session-lock-bun resolved abcdef0123456789 "rotated the lock"
#   fm-secondmate-report.sh --doc done abcdef0123456789 data/x/report.md "see report"
set -eu

CALLER_FM_HOME=${FM_HOME:-}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  fm-secondmate-report.sh [--key <slug>] <verb> <corr_id> <note...>
  fm-secondmate-report.sh [--key <slug>] --doc <verb> <corr_id> <doc-path> <note...>
EOF
  exit 2
}

DOC_MODE=0
KEY=
while [ $# -gt 0 ]; do
  case "$1" in
    --doc) DOC_MODE=1; shift ;;
    --key)
      [ $# -ge 2 ] && [ -n "$2" ] || usage
      KEY=$2
      shift 2
      ;;
    *) break ;;
  esac
done
# Same charset rule as fm-classify-lib.sh's _fm_decision_slug_ok and
# fm-send.sh's --resolve-key (A-Za-z0-9._- only), stated inline rather than
# sourcing the whole classify library into this small helper; the SHAPE is
# deliberately duplicated here the same way bin/fm-classify-lib.sh already
# duplicates the corr token shape, not a second interpretation of the fold.
if [ -n "$KEY" ]; then
  case "$KEY" in
    *[!A-Za-z0-9._-]*)
      echo "error: --key '$KEY' is not a valid decision key (allowed: A-Z a-z 0-9 . _ -)" >&2
      exit 1
      ;;
  esac
fi

[ $# -ge 2 ] || usage
VERB=$1
CORR=$2
shift 2
if [ "$DOC_MODE" = 1 ]; then
  [ $# -ge 1 ] && [ -n "$1" ] || usage
else
  [ $# -ge 1 ] && [ -n "$*" ] || usage
fi

case "$CORR" in
  corr=*) CORR=${CORR#corr=} ;;
esac
case "$CORR" in
  [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
  *)
    echo "error: corr_id must be 16 hex characters (got '$CORR')" >&2
    exit 1
    ;;
esac

HOME_DIR=$CALLER_FM_HOME
case "$HOME_DIR" in
  '')
    echo "error: FM_HOME is required so the helper can resolve the parent channel" >&2
    exit 1
    ;;
esac
STATE_DIR="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"

DESTINATION=
DEST_RC=0
DESTINATION=$(fm_parent_channel_destination "$HOME_DIR" "$STATE_DIR") || DEST_RC=$?
if [ "$DEST_RC" -ne 0 ] || [ -z "$DESTINATION" ]; then
  echo "error: cannot resolve the parent channel from this home (not a seeded secondmate?)" >&2
  exit 1
fi
mkdir -p "$(dirname "$DESTINATION")" 2>/dev/null || true
if [ ! -d "$(dirname "$DESTINATION")" ]; then
  echo "error: cannot create parent directory for status file '$DESTINATION'" >&2
  exit 1
fi

token=$(fm_pending_reply_corr_token "$CORR")
TAGS="[$token]"
[ -n "$KEY" ] && TAGS="$TAGS [key=$KEY]"
if [ "$DOC_MODE" = 1 ]; then
  DOC_PATH=$1
  shift
  NOTE=$*
  if [ -n "$NOTE" ]; then
    printf -v line '%s %s: %s (%s via-helper)' "$VERB" "$TAGS" "$NOTE" "$DOC_PATH"
  else
    printf -v line '%s %s: %s (via-helper)' "$VERB" "$TAGS" "$DOC_PATH"
  fi
else
  NOTE=$*
  printf -v line '%s %s: %s (via-helper)' "$VERB" "$TAGS" "$NOTE"
fi
printf '%s\n' "$(status_stamp_line "$line")" >> "$DESTINATION"
