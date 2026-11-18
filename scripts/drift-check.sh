#!/bin/sh
# drift-check.sh - weekly consistency audit: deterministic duplicate-text
# check plus a cheap-worker judgment pass.
#
# Usage: drift-check.sh [--deterministic-only] [--print]
#
# 1. Collects the files to audit: drift_rules (the canonical rules file),
#    every match of the drift_files globs (relative to oracle_home), and
#    each name in drift_repo_files (default: AGENTS.md CLAUDE.md) found at
#    the root of a registry row's project directory.
# 2. Runs `check.sh dupes` over them (drift_min_words, default 10).
# 3. If the worker role is configured, composes drift_prompt (default: the
#    kit's drift-prompt.md) + drift_prompt_extra (optional local supplement)
#    + the file list + the duplicate findings, and hands it to worker-run.sh
#    as job `drift-check`, which routes the answer to drift_to (default: the
#    Oracle) unless it is NOTHING. Without a worker role, or with
#    --deterministic-only, any duplicate findings go straight to drift_to.
#
# Options:
#   --deterministic-only  skip the worker pass
#   --print               print the files, findings and composed prompt;
#                         write and run nothing
#   -h, --help            this text
#
# Meant for <hooks_dir>/weekly/ (see examples/hooks/).
# Globs in drift_files must not contain whitespace.
#
# Environment: AO_PROFILE.
#
# Exit codes: 0 done (findings are routed, not failures); 1 the report could
# not be written; 2 usage or configuration error; otherwise worker-run.sh's
# status.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"

drift_add() {
  [ -f "$1" ] && printf '%s\n' "$1" >>"$files"
}

drift_repo_row() {
  for _n in $repo_files; do drift_add "$OP_DIR/$_n"; done
}

# drift_collect  Write the de-duplicated list of files to audit to $files.
drift_collect() {
  rules=$(ao_cfg_path drift_rules '')
  [ -z "$rules" ] || [ -f "$rules" ] || ao_die "$AO_E_USAGE" "drift_rules not found: $rules"
  [ -z "$rules" ] || drift_add "$rules"
  globs=$(ao_cfg drift_files '')
  repo_files=$(ao_cfg drift_repo_files 'AGENTS.md CLAUDE.md')
  (
    cd "$AO_HOME" || exit
    # One expansion: split the configured patterns on whitespace and glob
    # each; matched names (even with spaces) are not split again.
    # shellcheck disable=SC2086
    for _f in $globs; do drift_add "$AO_HOME/$_f"; done
  )
  ao_registry_each drift_repo_row
  sort -u "$files" -o "$files"
  [ -s "$files" ] || ao_die "$AO_E_USAGE" "nothing to audit: set drift_rules and drift_files in $AO_PROFILE"
}

# drift_dupes  Run the duplicate-text check over $files into $dupes.
drift_dupes() {
  set --
  while IFS= read -r _f; do set -- "$@" "$_f"; done <"$files"
  "$AO_SCRIPTS/check.sh" dupes --min-words "$min_words" "$@" >"$dupes"
  [ $? -le 1 ] || ao_die "$AO_E_FAIL" "duplicate check failed"
}

drift_compose() {
  {
    cat "$prompt_file"
    [ -z "$extra" ] || { printf '\n'; cat "$extra"; }
    printf '\n## Files to audit\n'
    [ -z "$rules" ] || printf 'Canonical rules: %s\n' "$rules"
    cat "$files"
    printf '\n## Deterministic duplicate-text findings\n'
    if [ -s "$dupes" ]; then cat "$dupes"; else printf 'none\n'; fi
  } >"$prompt"
}

main() {
  only_det='' print=''
  while [ $# -gt 0 ]; do
    case $1 in
      --deterministic-only) only_det=1 ;;
      --print) print=1 ;;
      -h | --help) ao_usage; exit 0 ;;
      *) ao_die "$AO_E_USAGE" "unknown argument '$1' (see --help)" ;;
    esac
    shift
  done
  ao_load
  files=$(ao_tmp files) dupes=$(ao_tmp dupes) prompt=$(ao_tmp prompt)
  min_words=$(ao_cfg_uint drift_min_words 10) || exit
  to=$(ao_cfg drift_to "$AO_ORACLE_KEY")
  prompt_file=$(ao_cfg_path drift_prompt "$AO_SCRIPTS/drift-prompt.md")
  extra=$(ao_cfg_path drift_prompt_extra '')
  for _p in "$prompt_file" ${extra:+"$extra"}; do
    [ -r "$_p" ] || ao_die "$AO_E_USAGE" "prompt file not readable: $_p"
  done
  drift_collect
  drift_dupes
  [ "$(ao_cfg worker_client none)" != none ] || only_det=1
  if [ -n "$print" ]; then
    drift_compose
    cat "$prompt"
    exit 0
  fi
  if [ -n "$only_det" ]; then
    [ -s "$dupes" ] || exit 0
    {
      printf 'Drift check (deterministic only) at %s: passages duplicated across files. Keep each rule in one home and point to it.\n\n' "$AO_T_STAMP"
      cat "$dupes"
    } | ao_inbox_put "$to" drift-check >/dev/null || exit "$AO_E_FAIL"
    exit 0
  fi
  drift_compose
  "$AO_SCRIPTS/worker-run.sh" drift-check "$to" "$prompt" "$(ao_cfg_path drift_workdir "$AO_HOME")"
}

main "$@"
