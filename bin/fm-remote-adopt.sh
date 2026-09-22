#!/usr/bin/env bash
# Point a firstmate home at the fleet's approved update source.
#
# A firstmate home - the primary checkout or any registered secondmate home - has
# exactly two meaningful remotes:
#   origin    the UPDATE SOURCE it fast-forwards from (bin/fm-update.sh's
#             base_mode "origin" and the /updatefirstmate path).
#   upstream  the READ-ONLY REFERENCE it never publishes to.
# The approved fleet source is the downstream fork; the retired parent stays
# reachable as the reference. docs/configuration.md ("Firstmate update source
# remotes") owns the contract, its URLs, and the read-only sentinel; this script
# is the one implementation that converges a home onto it.
#
# Three writes only, each a local git-config edit:
#   - origin's fetch and push URL become the fork's URL,
#   - the upstream remote's fetch URL becomes the reference URL,
#   - the upstream remote's push URL becomes the read-only sentinel, so an
#     accidental `git push upstream` fails instead of publishing to the parent.
#
# GUARDS - this script never advances, discards, or publishes anything:
#   - No fetch, no push, no checkout, no reset, no ref write. It edits remote
#     configuration and nothing else, so unlanded work and every branch state
#     survive untouched, and it needs no network.
#   - Both remotes are classified BEFORE either is written, so a home this script
#     declines to converge is left exactly as it was - never half-adopted.
#   - An origin that is neither the fork, the reference, nor a local seed path
#     equal to the primary root is left as it is and reported: someone else's
#     fork is not ours to repoint.
#   - An upstream remote carrying an unrecognized URL is left as it is and
#     reported, for the same reason.
#   - A target that is not a git work tree is skipped.
#   - Every case is idempotent: converging an already-converged home writes
#     nothing and reports "source current".
#
# It prints one line per home and always exits 0, because a home it declines to
# repoint is a report for the caller, never a failure of the surrounding update.
#
# Usage: fm-remote-adopt.sh [--primary-root <dir>] [--label <name>] <home>...
#        fm-remote-adopt.sh --help
#
# --primary-root names this fleet's primary checkout, which is what lets a home
# seeded from a local path recognize that path as its own former source; it
# defaults to this script's repo root.
# --label sets the report label for the next home argument, which is what
# bin/fm-update.sh passes for the home it is updating.
#
# FM_FIRSTMATE_SOURCE_URL and FM_FIRSTMATE_REFERENCE_URL override the two fleet
# URLs. Tests set them to local bare repositories; an operator never needs them.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

SOURCE_URL="${FM_FIRSTMATE_SOURCE_URL:-https://github.com/ionnich/firstmate}"
REFERENCE_URL="${FM_FIRSTMATE_REFERENCE_URL:-https://github.com/kunchenguid/firstmate}"
READ_ONLY_PUSH_URL="fm-read-only-reference"

usage() {
  cat >&2 <<'EOF'
usage: fm-remote-adopt.sh [--primary-root <dir>] [--label <name>] <home>...

Points each named firstmate home at the fleet's approved update source: origin
becomes the downstream fork, and the upstream remote becomes a fetch-only
reference whose push URL is a sentinel that cannot resolve.

Options:
  --primary-root <dir>  this fleet's primary checkout; a home whose origin is
                        that local path is recognized as seed-pointed and
                        repointed. Defaults to this script's repo root.
  --label <name>        report label for the NEXT home argument, which is what
                        bin/fm-update.sh passes for the home it is updating.
                        Repeat the flag to label several homes; an unlabelled
                        home is reported under its own path.
  --help                print this help.

Prints one line per home (source current / source adopted / source skipped:
<reason>) and always exits 0. Never fetches, pushes, resets, or checks out.
EOF
}

primary_root=""
label=""
homes=""
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --primary-root) [ $# -ge 2 ] || { usage; exit 1; }; primary_root=$2; shift 2 ;;
    --label) [ $# -ge 2 ] || { usage; exit 1; }; label=$2; shift 2 ;;
    --) shift; while [ $# -gt 0 ]; do homes="$homes $1"; shift; done ;;
    -*) usage; exit 1 ;;
    *) homes="$homes $1"; shift ;;
  esac
done

[ -n "$homes" ] || { usage; exit 1; }

# The primary checkout this script's own repo root names by default is what lets
# a seed-pointed home recognize its former source path.
[ -n "$primary_root" ] || primary_root=$FM_ROOT

# Reduce a remote URL to an owner/repo slug so an https URL and an scp-style ssh
# URL name the same remote. A local filesystem path keeps its own shape, which is
# what the primary-root comparison below works against.
fm_source_slug() {  # <url>
  local url=$1 rest
  case "$url" in
    git@*:*) rest=${url#*:} ;;
    *://*) rest=${url#*://}; rest=${rest#*/} ;;
    *) rest=$url ;;
  esac
  rest=${rest%.git}
  rest=${rest%/}
  printf '%s' "$rest"
}

# Resolve a path to its physical form when it exists; otherwise echo it as given
# so a missing directory still compares consistently.
fm_source_physical() {  # <path>
  local path=$1
  if [ -d "$path" ]; then
    (CDPATH='' cd -- "$path" && pwd -P)
  else
    printf '%s' "$path"
  fi
}

source_slug=$(fm_source_slug "$SOURCE_URL")
reference_slug=$(fm_source_slug "$REFERENCE_URL")
primary_physical=$(fm_source_physical "$primary_root")

# Classify the origin remote against the approved source: fork, none (no origin
# yet), seed (the retired parent, or a local seed path equal to the primary
# root), or foreign (not ours to repoint).
fm_classify_origin() {  # <dir>
  local dir=$1 current
  current=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
  if [ -z "$current" ]; then
    printf 'none'
    return 0
  fi
  if [ "$(fm_source_slug "$current")" = "$source_slug" ]; then
    printf 'fork'
    return 0
  fi
  if [ "$(fm_source_slug "$current")" = "$reference_slug" ]; then
    printf 'seed'
    return 0
  fi
  case "$current" in
    /*)
      if [ -n "$primary_physical" ] \
        && [ "$(fm_source_physical "$current")" = "$primary_physical" ]; then
        printf 'seed'
        return 0
      fi
      ;;
  esac
  printf 'foreign'
}

# Classify the upstream remote: reference, none, or foreign.
fm_classify_reference() {  # <dir>
  local dir=$1 current
  current=$(git -C "$dir" remote get-url upstream 2>/dev/null || true)
  if [ -z "$current" ]; then
    printf 'none'
    return 0
  fi
  if [ "$(fm_source_slug "$current")" = "$reference_slug" ]; then
    printf 'reference'
    return 0
  fi
  printf 'foreign'
}

# Apply the contract for an already-classified home. Sets FM_ADOPT_CHANGED.
fm_apply_source() {  # <dir> <origin-state> <reference-state>
  local dir=$1 origin_state=$2 reference_state=$3
  FM_ADOPT_CHANGED=no

  case "$origin_state" in
    none)
      git -C "$dir" remote add origin "$SOURCE_URL"
      FM_ADOPT_CHANGED=yes
      ;;
    seed)
      git -C "$dir" remote set-url origin "$SOURCE_URL"
      FM_ADOPT_CHANGED=yes
      ;;
    fork)
      # The same repository can be reached by another spelling (an ssh URL, or
      # the same URL with a .git suffix); normalize it to the documented URL.
      if [ "$(git -C "$dir" remote get-url origin)" != "$SOURCE_URL" ]; then
        git -C "$dir" remote set-url origin "$SOURCE_URL"
        FM_ADOPT_CHANGED=yes
      fi
      ;;
  esac

  case "$reference_state" in
    none)
      git -C "$dir" remote add upstream "$REFERENCE_URL"
      git -C "$dir" remote set-url --push upstream "$READ_ONLY_PUSH_URL"
      FM_ADOPT_CHANGED=yes
      ;;
    reference)
      if [ "$(git -C "$dir" remote get-url upstream)" != "$REFERENCE_URL" ]; then
        git -C "$dir" remote set-url upstream "$REFERENCE_URL"
        FM_ADOPT_CHANGED=yes
      fi
      if [ "$(git -C "$dir" remote get-url --push upstream 2>/dev/null || true)" \
        != "$READ_ONLY_PUSH_URL" ]; then
        git -C "$dir" remote set-url --push upstream "$READ_ONLY_PUSH_URL"
        FM_ADOPT_CHANGED=yes
      fi
      ;;
  esac
}

# Adopt one home's remotes. Prints its single report line.
fm_adopt_home() {  # <home> <label>
  local home=$1 name=${2:-$1} origin_state reference_state
  [ -n "$label" ] && name=$label

  if [ ! -d "$home" ]; then
    echo "$name: source skipped: not a directory"
    return 0
  fi
  if ! git -C "$home" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$name: source skipped: not a git work tree"
    return 0
  fi

  origin_state=$(fm_classify_origin "$home")
  if [ "$origin_state" = foreign ]; then
    echo "$name: source skipped: origin is not a firstmate update source"
    return 0
  fi
  reference_state=$(fm_classify_reference "$home")
  if [ "$reference_state" = foreign ]; then
    echo "$name: source skipped: upstream remote carries a different URL"
    return 0
  fi

  fm_apply_source "$home" "$origin_state" "$reference_state"
  if [ "$FM_ADOPT_CHANGED" = yes ]; then
    echo "$name: source adopted (origin -> fork, upstream -> read-only reference)"
  else
    echo "$name: source current"
  fi
  return 0
}

for home in $homes; do
  fm_adopt_home "$home" "$label"
  label=""
done
