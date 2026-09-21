# shellcheck shell=bash
# Shared data/projects.md registry-line helpers. Single owner of "read one
# project's verbatim registry line" and "converge a secondmate's subset of
# that registry against the primary's copy". Used by bin/fm-home-seed.sh (the
# initial seed), bin/fm-config-inherit-lib.sh (ongoing convergence at the
# bootstrap secondmate sweep, mid-session config push, and spawn pre-launch),
# and bin/fm-remote-inherit.sh (the merge a remote route now receives),
# so a project's registered posture can drift out of sync after seeding
# without ever being silently re-obeyed (AGENTS.md section 6).
#
# The registry line format itself is owned by bin/fm-project-mode.sh's header
# comment; this file only locates and copies whole lines verbatim and never
# interprets mode/yolo semantics.
#
# Usage: . bin/fm-project-registry-lib.sh   (no FM_* setup required)

# fm_project_registry_line <registry-file> <project-name>
# Prints the project's registry line verbatim if present; returns 1 if the
# registry file or the project entry is absent.
fm_project_registry_line() {
  local reg=$1 project=$2 line
  [ -f "$reg" ] || return 1
  line=$(awk -v n="$project" '$1=="-" && $2==n { print; exit }' "$reg")
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

# fm_project_registry_names <registry-file>
# Prints every registered project name, one per line. Empty output (not an
# error) when the registry file is absent.
fm_project_registry_names() {
  local reg=$1
  [ -f "$reg" ] || return 0
  awk '$1 == "-" && $2 != "" { print $2 }' "$reg"
}

# fm_project_registry_converge <primary-registry-file> <dest-registry-file>
# The primary is authoritative for any project BOTH registries know about: for
# every project name already present in dest that the primary also registers,
# overwrite dest's line with the primary's verbatim line when they differ. A
# project entry known only to dest (e.g. a secondmate-local project the
# primary never registered) is left untouched, so this never clobbers
# independently registered local work.
# Prints one line per changed entry as "<project>\t<old-line>\t<new-line>" to
# stdout so callers can report the drift instead of silently correcting it;
# prints nothing when nothing changed. Returns non-zero only on a real I/O
# failure; a missing primary or dest registry is a no-op, not a failure.
fm_project_registry_converge() {
  local primary_reg=$1 dest_reg=$2 project old new tmp changed=0
  [ -f "$dest_reg" ] || return 0
  [ -f "$primary_reg" ] || return 0
  tmp="$dest_reg.tmp.$$"
  cp "$dest_reg" "$tmp" || return 1
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    new=$(fm_project_registry_line "$primary_reg" "$project") || continue
    old=$(fm_project_registry_line "$dest_reg" "$project") || continue
    [ "$old" = "$new" ] && continue
    awk -v n="$project" -v newline="$new" '
      $1 == "-" && $2 == n { print newline; next }
      { print }
    ' "$tmp" > "$tmp.next" || { rm -f "$tmp" "$tmp.next"; return 1; }
    mv "$tmp.next" "$tmp" || { rm -f "$tmp" "$tmp.next"; return 1; }
    printf '%s\t%s\t%s\n' "$project" "$old" "$new"
    changed=1
  done < <(fm_project_registry_names "$dest_reg")
  if [ "$changed" = 1 ]; then
    mv "$tmp" "$dest_reg" || return 1
  else
    rm -f "$tmp"
  fi
  return 0
}
