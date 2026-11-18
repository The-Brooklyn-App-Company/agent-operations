#!/bin/sh
# worktree.sh - create a new, repo-local seat on macOS.
#
# Usage: worktree.sh CANONICAL_REPO YYYYMMDD-SLUG [BRANCH [START]]
#
# CANONICAL_REPO is the physical absolute path to the main checkout of
# a repository. BRANCH defaults to work/YYYYMMDD-SLUG; START defaults
# to HEAD. Use an unused branch and seat. The helper adds the container
# to the repository's local Git excludes. It applies a sticky Time Machine
# exclusion only to an empty container. An existing nonempty container
# must already be excluded. The seat is checked before and after checkout.
#
# Exit codes: 0 created and verified; 1 operation failed; 2 bad arguments
# or unsupported host. Git failures may leave a seat for inspection.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"

# path_excluded PATH  A status other than an explicit exclusion fails closed.
path_excluded() {
  _status=$(LC_ALL=C tmutil isexcluded "$1") || return 1
  case $_status in
    *"$AO_NL"*) return 1 ;;
    '[Excluded]'[[:blank:]]*) return 0 ;;
    *) return 1 ;;
  esac
}

prepare_exclusion() {
  [ -r "$container" ] && [ -x "$container" ] ||
    ao_die "$AO_E_FAIL" "cannot inspect worktree container contents: $container"
  # Include hidden entries and dangling symlinks without traversing them.
  for entry in "$container"/* "$container"/.[!.]* "$container"/..?*; do
    if [ -e "$entry" ] || [ -L "$entry" ]; then
      path_excluded "$container" ||
        ao_die "$AO_E_FAIL" "nonempty container lacks a verified Time Machine exclusion: $container. Preserve existing contents in a backed-up location before changing its exclusion."
      return 0
    fi
  done
  tmutil addexclusion "$container" ||
    ao_die "$AO_E_FAIL" "cannot set sticky Time Machine exclusion on $container"
}

main() {
  case ${1-} in -h | --help) ao_usage; exit 0 ;; esac
  [ "$#" -ge 2 ] && [ "$#" -le 4 ] ||
    ao_die "$AO_E_USAGE" "usage: worktree.sh CANONICAL_REPO YYYYMMDD-SLUG [BRANCH [START]]"
  [ "$(uname -s)" = Darwin ] ||
    ao_die "$AO_E_USAGE" "worktree.sh requires macOS and Time Machine exclusion tools"
  command -v tmutil >/dev/null 2>&1 || ao_die "$AO_E_USAGE" "tmutil not found"
  repo=${1%/} slug=$2 branch=${3-work/$2} start=${4-HEAD}
  case $repo in
    *"$AO_NL"* | *"$AO_TAB"* | [!/]* | '') ao_die "$AO_E_USAGE" "give the physical absolute repository path" ;;
  esac
  [ "$(CDPATH='' cd -- "$repo" 2>/dev/null && pwd -P)" = "$repo" ] ||
    ao_die "$AO_E_USAGE" "give the physical absolute repository path"
  case $slug in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[A-Za-z0-9]*) ;;
    *) ao_die "$AO_E_USAGE" "seat slug must start with YYYYMMDD- followed by a name" ;;
  esac
  ao_is_name "$slug" || ao_die "$AO_E_USAGE" "invalid seat slug '$slug'"
  case $branch in
    '' | -*) ao_die "$AO_E_USAGE" "invalid branch '$branch'" ;;
  esac

  # The canonical checkout, rather than inherited Git environment overrides,
  # defines where all Git writes go. Git prints fixed variable names here.
  git_env=$(git rev-parse --local-env-vars) || ao_die "$AO_E_USAGE" "cannot inspect Git environment"
  # shellcheck disable=SC2086
  unset $git_env
  [ -d "$repo/.git" ] && [ ! -L "$repo/.git" ] &&
    [ "$(git -C "$repo" rev-parse --show-toplevel)" = "$repo" ] &&
    [ "$(git -C "$repo" rev-parse --absolute-git-dir)" = "$repo/.git" ] &&
    [ "$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)" = "$repo/.git" ] ||
    ao_die "$AO_E_USAGE" "expected a canonical repository checkout with its own .git directory"
  git -C "$repo" check-ref-format "refs/heads/$branch" ||
    ao_die "$AO_E_USAGE" "invalid branch '$branch'"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    ao_die "$AO_E_USAGE" "branch already exists: $branch"
  fi
  oid=$(git -C "$repo" rev-parse --verify --quiet --end-of-options "$start^{commit}") ||
    ao_die "$AO_E_USAGE" "start revision does not name a commit: $start"

  container=$repo/worktrees.noindex seat=$repo/worktrees.noindex/$slug
  if [ -L "$container" ] || { [ -e "$container" ] && [ ! -d "$container" ]; }; then
    ao_die "$AO_E_USAGE" "worktree container must be a real directory: $container"
  fi
  [ ! -e "$seat" ] && [ ! -L "$seat" ] ||
    ao_die "$AO_E_USAGE" "seat already exists: $seat"
  index_seats=$(git -C "$repo" ls-files -- worktrees.noindex) ||
    ao_die "$AO_E_FAIL" "cannot read Git index in $repo"
  start_seats=$(git -C "$repo" ls-tree "$oid" -- worktrees.noindex) ||
    ao_die "$AO_E_FAIL" "cannot inspect start revision $start"
  [ -z "$index_seats$start_seats" ] ||
    ao_die "$AO_E_USAGE" "worktrees.noindex is tracked in the index or start revision"

  info=$repo/.git/info exclude=$repo/.git/info/exclude
  if [ -L "$info" ] || [ -L "$exclude" ] || { [ -e "$exclude" ] && [ ! -f "$exclude" ]; }; then
    ao_die "$AO_E_USAGE" "expected a regular local Git exclude file: $exclude"
  fi
  mkdir -p "$container" || ao_die "$AO_E_FAIL" "cannot prepare worktree container"
  [ "$(CDPATH='' cd -- "$container" && pwd -P)" = "$container" ] ||
    ao_die "$AO_E_FAIL" "worktree container must stay inside the repository: $container"
  prepare_exclusion
  mkdir -p "$info" || ao_die "$AO_E_FAIL" "cannot prepare local Git excludes"
  if ! grep -qxF '/worktrees.noindex/' "$exclude" 2>/dev/null; then
    printf '\n/worktrees.noindex/\n' >>"$exclude" ||
      ao_die "$AO_E_FAIL" "cannot write $exclude"
  fi
  git -C "$repo" check-ignore -q -- "worktrees.noindex/$slug" ||
    ao_die "$AO_E_FAIL" "seat path must be Git-ignored: $seat"
  mkdir "$seat" || ao_die "$AO_E_FAIL" "cannot reserve new seat $seat"
  if ! path_excluded "$seat"; then
    # Only the empty directory this invocation just reserved may be removed.
    rmdir "$seat" 2>/dev/null || ao_warn "inspect the seat left at $seat"
    ao_die "$AO_E_FAIL" "Time Machine exclusion not verified on empty seat $seat"
  fi
  git -C "$repo" worktree add -q -b "$branch" -- "$seat" "$oid" ||
    ao_die "$AO_E_FAIL" "worktree add failed; inspect $seat and branch $branch"
  path_excluded "$seat" ||
    ao_die "$AO_E_FAIL" "worktree created at $seat, but Time Machine exclusion could not be reverified"
  printf 'Created and verified %s (branch %s)\n' "$seat" "$branch"
}

main "$@"
