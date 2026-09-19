#!/usr/bin/env bash
# fm-ext.sh - install or remove a Pi extension npm package fleet-wide.
#
# The resident profile (primary plus every persistent secondmate home) and the
# crew profile (crewmates and scouts) each carry their own runtime-owned npm
# project under profiles/<name>/npm. This installs or removes one package in
# both in a single call instead of two manual `npm install` runs, then nudges
# live harness=pi sessions in THIS home to pick up the change without
# disturbing a worker mid-turn.
#
# Usage:
#   fm-ext.sh install <package>[@version] [--resident-only|--crew-only] [--dry-run]
#   fm-ext.sh remove <package> [--resident-only|--crew-only] [--dry-run]
#   fm-ext.sh --help
#
# `remove` takes a bare package name, never a version spec: npm uninstall
# only ever needs the name, and accepting one here would just be a second,
# unused way to spell the same request.
#
# Atomicity: before mutating a profile's npm project this backs up its
# package.json and package-lock.json. If one profile's `npm install` or
# `npm uninstall` fails, that profile is restored from its backup and any
# profile already applied earlier in the same call is restored too, so a run
# never leaves one profile changed and the other not; nothing is committed to
# either profile unless every selected profile succeeds.
#
# --dry-run reports the exact npm command each selected profile would run and
# whether the package is currently present, without invoking npm and without
# writing anything.
#
# Reload nudge: after a successful (non-dry-run) apply, this reads
# state/*.meta in $FM_HOME for harness=pi records. A record with kind=secondmate
# uses the resident profile; every other kind uses the crew profile. For each
# live record whose profile was just changed, this sends one durable steering
# message through fm-send.sh (local and remote alike) asking that session to
# call its own `pi_extension_dev_reload_self` tool - the native in-place
# reload - when convenient. That is advisory only: a send failure is reported
# but does not fail the overall command, since the install or removal itself
# already succeeded. This process's own session (if it uses the resident
# profile) is not a task recorded in state/*.meta, so it is reminded with a
# printed line instead of a steering message.
#
# Out of scope: the per-home .pi/extensions/*.ts layer, Nix packaging of this
# helper, and retiring the legacy CoS Pi profiles - all separate, already
# routed elsewhere.
#
# Environment:
#   FM_HOME                 operational home whose state/ is scanned for
#                            sessions to nudge. Default: this repo's root.
#   FM_PROFILES_ROOT_OVERRIDE  root containing resident/ and crew/ profile
#                            dirs. Default: ~/.local/share/firstmate/profiles.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROFILES_ROOT="${FM_PROFILES_ROOT_OVERRIDE:-$HOME/.local/share/firstmate/profiles}"
FM_SEND="${FM_SEND_OVERRIDE:-$SCRIPT_DIR/fm-send.sh}"

fail() {
  printf 'fm-ext: %s\n' "$*" >&2
  exit 1
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

[ "$#" -ge 2 ] || { usage >&2; exit 2; }

ACTION=$1
shift
case "$ACTION" in
  install|remove) ;;
  *) fail "unknown action '$ACTION' (expected install or remove)" ;;
esac

PKG=$1
shift
[ -n "$PKG" ] || fail "package name required"

SCOPE=both
DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --resident-only) SCOPE=resident ;;
    --crew-only) SCOPE=crew ;;
    --dry-run) DRY_RUN=1 ;;
    *) fail "unknown argument: $1" ;;
  esac
  shift
done

if [ "$ACTION" = remove ]; then
  # Reject anything after a scoped package's own "@scope/name" segment, and
  # anything after position 0 for an unscoped name - both mean a version spec
  # was passed where only a bare name belongs.
  rest=$PKG
  case "$rest" in
    @*/*) rest=${rest#@*/} ;;
  esac
  case "$rest" in
    *@*) fail "remove takes a bare package name, not a version spec: $PKG" ;;
  esac
fi

command -v npm >/dev/null 2>&1 || fail "npm not found on PATH"

profile_npm_dir() {  # <resident|crew>
  printf '%s/%s/npm' "$PROFILES_ROOT" "$1"
}

targets=""
case "$SCOPE" in
  both) targets="resident crew" ;;
  resident) targets="resident" ;;
  crew) targets="crew" ;;
esac

for p in $targets; do
  dir=$(profile_npm_dir "$p")
  [ -f "$dir/package.json" ] || fail "no package.json in $dir (profile not provisioned)"
done

pkg_present() {  # <profile-npm-dir> <bare-name>
  # Cheap membership check against package.json's dependency block; avoids a
  # jq dependency for a single boolean.
  grep -q "\"$2\"[[:space:]]*:" "$1/package.json"
}

bare_name() {  # <spec> -> name with any @version stripped
  local spec=$1
  local rest=$spec prefix=""
  case "$rest" in
    @*/*) prefix="${rest%%/*}/"; rest=${rest#*/} ;;
  esac
  rest=${rest%%@*}
  printf '%s%s' "$prefix" "$rest"
}

NAME=$(bare_name "$PKG")

if [ "$DRY_RUN" = 1 ]; then
  for p in $targets; do
    dir=$(profile_npm_dir "$p")
    if pkg_present "$dir" "$NAME"; then present=yes; else present=no; fi
    if [ "$ACTION" = install ]; then
      printf 'dry-run: %s currently present=%s; would run: npm install %s --save (in %s)\n' \
        "$NAME" "$present" "$PKG" "$dir"
    else
      printf 'dry-run: %s currently present=%s; would run: npm uninstall %s --save (in %s)\n' \
        "$NAME" "$present" "$PKG" "$dir"
    fi
  done
  exit 0
fi

# --- apply, with whole-set rollback on any profile failure ------------------

BACKUP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-ext.XXXXXX") || fail "could not create backup dir"
trap 'rm -rf "$BACKUP_ROOT"' EXIT

applied=""

backup_profile() {  # <profile-npm-dir> <profile-name>
  mkdir -p "$BACKUP_ROOT/$2" || { printf 'fm-ext: could not create backup dir for %s\n' "$2" >&2; return 1; }
  cp "$1/package.json" "$BACKUP_ROOT/$2/package.json" || { printf 'fm-ext: could not back up %s/package.json\n' "$1" >&2; return 1; }
  if [ -f "$1/package-lock.json" ]; then
    cp "$1/package-lock.json" "$BACKUP_ROOT/$2/package-lock.json" || { printf 'fm-ext: could not back up %s/package-lock.json\n' "$1" >&2; return 1; }
  fi
  return 0
}

restore_profile() {  # <profile-npm-dir> <profile-name>
  cp "$BACKUP_ROOT/$2/package.json" "$1/package.json" || { printf 'fm-ext: could not restore %s/package.json from backup\n' "$1" >&2; return 1; }
  if [ -f "$BACKUP_ROOT/$2/package-lock.json" ]; then
    cp "$BACKUP_ROOT/$2/package-lock.json" "$1/package-lock.json" || { printf 'fm-ext: could not restore %s/package-lock.json from backup\n' "$1" >&2; return 1; }
  fi
  return 0
}

rollback_all() {
  local rp rc=0
  for rp in $applied; do
    restore_profile "$(profile_npm_dir "$rp")" "$rp" || rc=1
  done
  return $rc
}

for p in $targets; do
  dir=$(profile_npm_dir "$p")
  backup_profile "$dir" "$p" || {
    rollback_all || printf 'fm-ext: reverting one or more already-applied profiles failed; check them manually\n' >&2
    fail "could not back up $p profile ($dir) before npm $ACTION; reverted every profile already applied this run ($applied)"
  }
  if [ "$ACTION" = install ]; then
    npm_out=$(cd "$dir" && npm install "$PKG" --save 2>&1)
  else
    npm_out=$(cd "$dir" && npm uninstall "$NAME" --save 2>&1)
  fi
  npm_rc=$?
  if [ "$npm_rc" -ne 0 ]; then
    printf '%s\n' "$npm_out" >&2
    restore_profile "$dir" "$p" || printf 'fm-ext: could not revert %s profile (%s); it may be left in a partially-changed state\n' "$p" "$dir" >&2
    rollback_all || printf 'fm-ext: reverting one or more already-applied profiles failed; check them manually\n' >&2
    fail "npm $ACTION failed in $p profile ($dir); reverted $p and every profile already applied this run ($applied)"
  fi
  applied="$applied $p"
done

printf 'fm-ext: %s %s applied to profile(s):%s\n' "$ACTION" "$PKG" "$applied"

# --- reload nudge -------------------------------------------------------

meta_get() {  # <meta-file> <key>
  local line
  line=$(grep -m1 "^$2=" "$1" 2>/dev/null) || return 0
  printf '%s' "${line#*=}"
}

nudge_message() {
  printf 'fm-ext: %s %s just landed in the Pi profile this session uses. Call the pi_extension_dev_reload_self tool whenever convenient to pick it up in place; no restart needed, no rush.' \
    "$ACTION" "$PKG"
}

nudged=0
nudge_failed=""
if [ -d "$STATE" ]; then
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(meta_get "$meta" harness)" = pi ] || continue
    if [ "$(meta_get "$meta" kind)" = secondmate ]; then
      mprofile=resident
    else
      mprofile=crew
    fi
    case " $applied " in
      *" $mprofile "*) ;;
      *) continue ;;
    esac
    id=$(meta_get "$meta" endpoint_task_id)
    [ -n "$id" ] || id=$(basename "$meta" .meta)
    if "$FM_SEND" "$id" "$(nudge_message)" >/dev/null 2>&1; then
      nudged=$((nudged + 1))
    else
      nudge_failed="$nudge_failed $id"
    fi
  done
fi
printf 'fm-ext: nudged %d live session(s)' "$nudged"
if [ -n "$nudge_failed" ]; then
  printf '; nudge send failed (advisory only, install already applied) for:%s' "$nudge_failed"
fi
printf '\n'

case " $applied " in
  *" resident "*)
    printf 'fm-ext: this session, if it uses the resident profile, is not a tracked task - reload it yourself with pi_extension_dev_reload_self when convenient.\n'
    ;;
esac

exit 0
