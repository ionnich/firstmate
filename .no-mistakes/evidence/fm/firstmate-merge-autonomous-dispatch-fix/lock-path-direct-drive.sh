#!/usr/bin/env bash
# Direct drive of bin/fm-autonomous-dispatch.sh lock-path: the changed surface.
set -u
ROOT=/Users/nich/.no-mistakes/worktrees/3bc3ee2d971b/01M34RBX90FXTDMD2XFGSXTHK4
DISPATCH="$ROOT/bin/fm-autonomous-dispatch.sh"
TMP=$(mktemp -d /tmp/fm-lockpath.XXXXXX)

echo "== case 1: valid dispatch root -> lock-path prints path, rc 0 =="
mkdir -p "$TMP/home/data/autonomous-dispatch"
out=$(FM_HOME="$TMP/home" "$DISPATCH" lock-path 2>"$TMP/err1"); rc=$?
echo "rc=$rc stdout=[$out] stderr=[$(cat "$TMP/err1")]"

echo "== case 2: missing dispatch root -> lock-path dies 'invalid dispatch directory', rc 1 =="
mkdir -p "$TMP/nohome/data"
set +e
out=$(FM_HOME="$TMP/nohome" "$DISPATCH" lock-path 2>"$TMP/err2"); rc=$?
set -e
echo "rc=$rc stdout=[$out] stderr=[$(cat "$TMP/err2")]"

echo "== case 3: missing dispatch root with 2>/dev/null (merge caller) -> silent, rc 1 =="
set +e
out=$(FM_HOME="$TMP/nohome" "$DISPATCH" lock-path 2>/dev/null); rc=$?
set -e
echo "rc=$rc stdout=[$out]"

echo "== case 4: symlink dispatch root -> dies 'invalid dispatch directory' =="
mkdir -p "$TMP/real-dir" "$TMP/linkhome/data"
ln -s "$TMP/real-dir" "$TMP/linkhome/data/autonomous-dispatch"
set +e
out=$(FM_HOME="$TMP/linkhome" "$DISPATCH" lock-path 2>"$TMP/err4"); rc=$?
set -e
echo "rc=$rc stdout=[$out] stderr=[$(cat "$TMP/err4")]"

rm -rf "$TMP"
