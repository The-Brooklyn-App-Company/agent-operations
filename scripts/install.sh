#!/bin/sh
# install.sh - create the Oracle home, operator homes, skill links and the
# tick unit from this kit checkout.
#
# Usage: install.sh [--dry-run] oracle HOME [--team DIR] [--name NAME]
#                   [--client CLIENT] [--profile-example NAME]
#        install.sh [--dry-run] operator KEY [--embedded | --home DIR]
#                   [--name NAME] [--client CLIENT]
#                   [--owns URL]... [--contributes URL]...
#        install.sh [--dry-run] skills --target DIR
#        install.sh [--dry-run] timers [--launchd | --systemd]
#
# --dry-run lists every directory, file, link, worktree and timer the
# command would create, and changes nothing. Without it the same list is
# printed as the work is done. The installer only ever creates what is
# missing: an existing file is kept as it is and reported. It never uses
# sudo, never edits a client's settings, never loads a timer and never
# clones over the network; it prints those steps for you instead.
#
# oracle    Creates the Oracle home: AGENTS.md, CLAUDE.md, MANDATE.md,
#           NOTES.md, BACKLOG.md, JOURNAL.md, FACTS.md, SCHEDULES.md,
#           KIT.local.md (with the kit pin), operators/REGISTRY.tsv, a
#           .gitignore and the hourly cross-review hook; copies a profile
#           example (default: both) to the profile path if none exists,
#           pointing oracle_home at HOME; then commits the home.
# operator  Needs the profile. Creates the operator's home (its own repo
#           beside the Oracle home, or --embedded under
#           <oracle_home>/operators/KEY, or --home DIR), its operator.conf
#           and registry row, and, for each --contributes repository already
#           checked out under work_root, a worktree at
#           <work_root>/.worktrees/KEY/<repo> on branch KEY/main. Refuses a
#           repository another local operator already owns.
# skills    Links each kit skill into DIR (a client's skills folder); an
#           existing entry that is not this kit's link is reported, never
#           replaced.
# timers    Needs the profile. Renders the tick unit for this machine
#           (launchd on macOS, systemd user units elsewhere) into your
#           user's unit folder and prints the command that loads it.
#
# Options:
#   --name NAME              session display name (default: Oracle, or KEY)
#   --client CLIENT          claude | codex | custom | file-only (default:
#                            claude)
#   --team DIR               record the team repository in KIT.local.md
#   --profile-example NAME   claude-only | codex-only | both | custom
#
# Environment: AO_PROFILE (default ~/.config/agent-operations/profile).
#
# Exit codes: 0 done; 1 something could not be created; 2 usage error or
# refusal (conflict, already owned, missing profile).
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"

KIT=$(CDPATH='' cd -- "$AO_SCRIPTS/.." && pwd)
TPL=$KIT/templates
dry_run=
failures=0
# Paths this run created, one per line, for inst_commit.
created=$(ao_tmp created)

# ---------------------------------------------------------------- helpers

# inst_abs PATH  Absolute form of PATH (~/ expanded, relative to $PWD).
inst_abs() {
  ao_expand_path "$1" "$PWD"
}

# inst_tilde PATH  PATH with $HOME shown as ~, for the registry.
inst_tilde() {
  # shellcheck disable=SC2088 # a literal ~ is the point
  case $1 in "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;; *) printf '%s\n' "$1" ;; esac
}

inst_say() {
  if [ -n "$dry_run" ]; then printf 'would %s\n' "$*"; else printf '%s\n' "$*"; fi
}

inst_dir() {
  [ -d "$1" ] && return 0
  inst_say "create  $1/"
  [ -n "$dry_run" ] || mkdir -p "$1" || { ao_warn "cannot create $1"; failures=$((failures + 1)); }
}

# inst_sed_value VALUE  Escape VALUE for the right side of a sed s|||.
inst_sed_value() {
  printf '%s\n' "$1" | sed -e 's/[\\|&]/\\&/g'
}

# inst_render SRC DEST [MODE]  Copy a template with its @NAME@ placeholders
# filled in, unless DEST exists.
inst_render() {
  if [ -e "$2" ]; then
    printf 'keep    %s (exists)\n' "$2"
    return 0
  fi
  inst_say "create  $2"
  [ -z "$dry_run" ] || return 0
  if ! { mkdir -p "$(dirname -- "$2")" &&
    sed -e "s|@KEY@|$(inst_sed_value "$v_key")|g" \
      -e "s|@NAME@|$(inst_sed_value "$v_name")|g" \
      -e "s|@CLIENT@|$(inst_sed_value "$v_client")|g" \
      -e "s|@KIT_DIR@|$(inst_sed_value "$KIT")|g" \
      -e "s|@KIT_VERSION@|$(inst_sed_value "$kit_version")|g" \
      -e "s|@KIT_COMMIT@|$(inst_sed_value "$kit_commit")|g" \
      -e "s|@TEAM@|$(inst_sed_value "$v_team")|g" \
      -e "s|@DATE@|$AO_T_DATE|g" "$1" | ao_write_atomic "$2" &&
    chmod "${3:-644}" "$2"; }; then
    ao_warn "cannot write $2"
    failures=$((failures + 1))
    return 0
  fi
  printf '%s\n' "$2" >>"$created"
}

# inst_append FILE LINE  Append a line to a file.
inst_append() {
  inst_say "append  $1: $(printf '%s' "$2" | tr '\t' ' ')"
  [ -z "$dry_run" ] || return 0
  if printf '%s\n' "$2" >>"$1"; then
    grep -Fxq -- "$1" "$created" || printf '%s\n' "$1" >>"$created"
  else
    ao_warn "cannot append to $1"
    failures=$((failures + 1))
  fi
}

# inst_commit DIR MESSAGE  Commit the files this run created under DIR in
# DIR's repository (created with git init if needed).
inst_commit() {
  [ -z "$dry_run" ] || { inst_say "commit  $1: $2"; return 0; }
  _mine=$(ao_tmp mine)
  while IFS= read -r _f; do
    case $_f in "$1"/*) printf '%s\n' "$_f" >>"$_mine" ;; esac
  done <"$created"
  [ -s "$_mine" ] || return 0
  if ! git -C "$1" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$1" init -q || { ao_warn "git init failed in $1"; failures=$((failures + 1)); return 0; }
  fi
  # Only these paths: anything else already staged stays out of the commit.
  if git -C "$1" add --pathspec-from-file="$_mine" >/dev/null 2>&1 &&
    git -C "$1" commit -q -m "$2" --pathspec-from-file="$_mine" >/dev/null 2>&1; then
    printf 'commit  %s: %s\n' "$1" "$2"
  else
    ao_warn "could not commit in $1 (is git user.name set?); commit it yourself"
  fi
}

inst_client() {
  case $1 in claude | codex | custom | file-only) ;; *) ao_die "$AO_E_USAGE" "--client must be claude, codex, custom or file-only" ;; esac
}

inst_kit_facts() {
  kit_version=$(cat "$KIT/VERSION" 2>/dev/null) || kit_version=unknown
  kit_commit=$(git -C "$KIT" rev-parse --short HEAD 2>/dev/null) || kit_commit=unknown
}

# ---------------------------------------------------------------- oracle

inst_oracle() {
  [ $# -ge 1 ] || ao_die "$AO_E_USAGE" "usage: install.sh oracle HOME [options]"
  home=$(inst_abs "$1")
  shift
  v_key=oracle v_name=Oracle v_client=claude v_team=none example=both
  while [ $# -gt 0 ]; do
    case $1 in
      --team) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--team needs a directory"; v_team=$(inst_abs "$2"); shift ;;
      --name) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--name needs a value"; v_name=$2; shift ;;
      --client) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--client needs a value"; v_client=$2; shift ;;
      --profile-example) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--profile-example needs a name"; example=$2; shift ;;
      *) ao_die "$AO_E_USAGE" "unknown option '$1' (see --help)" ;;
    esac
    shift
  done
  inst_client "$v_client"
  [ -r "$KIT/profiles/$example.profile" ] || ao_die "$AO_E_USAGE" "no profile example '$example' (see profiles/)"
  case $home/ in "$KIT"/*) ao_die "$AO_E_USAGE" "the Oracle home must be outside the kit checkout" ;; esac
  profile=$(ao_profile_path)
  case $profile in "$home"/* | "$KIT"/*) ao_die "$AO_E_USAGE" "the profile must live outside git: $profile" ;; esac
  inst_dir "$home"
  inst_dir "$home/operators"
  inst_dir "$home/hooks/hourly"
  inst_render "$TPL/oracle/AGENTS.md" "$home/AGENTS.md"
  inst_render "$TPL/home/CLAUDE.md" "$home/CLAUDE.md"
  inst_render "$TPL/home/MANDATE.md" "$home/MANDATE.md"
  inst_render "$TPL/home/NOTES.md" "$home/NOTES.md"
  for _f in BACKLOG.md JOURNAL.md FACTS.md SCHEDULES.md KIT.local.md; do
    inst_render "$TPL/oracle/$_f" "$home/$_f"
  done
  inst_render "$TPL/home/gitignore.template" "$home/.gitignore"
  inst_render "$KIT/examples/hooks/hourly/60-cross-review" "$home/hooks/hourly/60-cross-review" 755
  reg=$home/operators/REGISTRY.tsv
  if [ ! -e "$reg" ]; then
    inst_render "$TPL/oracle/REGISTRY.tsv" "$reg"
    inst_append "$reg" "oracle$AO_TAB$v_name$AO_TAB$(inst_tilde "$home")${AO_TAB}pending$AO_TAB$v_client"
  else
    printf 'keep    %s (exists)\n' "$reg"
  fi
  if [ -e "$profile" ]; then
    printf 'keep    %s (exists; check its oracle_home)\n' "$profile"
  else
    inst_say "create  $profile (from profiles/$example.profile)"
    if [ -z "$dry_run" ] && ! { mkdir -p "$(dirname -- "$profile")" &&
      sed "s|^oracle_home=.*|oracle_home=$(inst_sed_value "$(inst_tilde "$home")")|" \
        "$KIT/profiles/$example.profile" | ao_write_atomic "$profile" &&
      chmod 600 "$profile"; }; then
      ao_warn "cannot write $profile"
      failures=$((failures + 1))
    fi
  fi
  inst_commit "$home" "Create the Oracle home from Agent Operations $kit_version"
  cat <<EOF

Next, by hand:
  1. Edit $profile: replace every CHANGE-ME. Put any client token in the
     OS secret store yourself and name it in the profile.
  2. Start a session in $home and name it "$v_name". Then replace
     "pending" in its registry row with the session id.
  3. Write the charter in $home/MANDATE.md in your own words.
  4. Add operators: $0 operator <key> ...
  5. Check: $AO_SCRIPTS/check.sh home $home && $AO_SCRIPTS/status.sh
  6. Timers: $0 timers
EOF
}

# ---------------------------------------------------------------- operator

# inst_repo_name URL  The repository's folder name: the URL's last part
# without .git.
inst_repo_name() {
  _n=${1%/}
  _n=${_n##*/}
  _n=${_n##*:}
  _n=${_n%.git}
  ao_is_name "$_n" || ao_die "$AO_E_USAGE" "cannot derive a repository name from '$1'"
  printf '%s\n' "$_n"
}

# inst_url_key URL  A repository URL without a trailing slash or .git, so
# two spellings of one repository compare equal.
inst_url_key() {
  _uk=${1%/}
  printf '%s\n' "${_uk%.git}"
}

# inst_owned_elsewhere URL  Print the key of another operator owning URL.
inst_owned_elsewhere() {
  _url=$(inst_url_key "$1")
  while IFS="$AO_TAB" read -r _k _nm _d _rest; do
    case $_k in '' | '#'*) continue ;; esac
    [ "$_k" != "$v_key" ] || continue
    _conf=$(ao_expand_path "$_d" /)/operator.conf
    [ -r "$_conf" ] || continue
    while IFS= read -r _l; do
      case $_l in work.*'|owner')
        _o=${_l#*=}
        [ "$(inst_url_key "${_o%|owner}")" != "$_url" ] || { printf '%s\n' "$_k"; return 0; } ;;
      esac
    done <"$_conf"
  done <"$AO_REGISTRY"
  return 1
}

inst_operator() {
  [ $# -ge 1 ] || ao_die "$AO_E_USAGE" "usage: install.sh operator KEY [options]"
  v_key=$1
  shift
  ao_is_name "$v_key" || ao_die "$AO_E_USAGE" "invalid key '$v_key' (use [A-Za-z0-9._-])"
  embedded='' home='' v_name=$v_key v_client=claude v_team=none
  owns=$(ao_tmp owns) contribs=$(ao_tmp contribs)
  while [ $# -gt 0 ]; do
    case $1 in
      --embedded) embedded=1 ;;
      --home) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--home needs a directory"; home=$(inst_abs "$2"); shift ;;
      --name) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--name needs a value"; v_name=$2; shift ;;
      --client) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--client needs a value"; v_client=$2; shift ;;
      --owns) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--owns needs a URL"; printf '%s\n' "$2" >>"$owns"; shift ;;
      --contributes) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--contributes needs a URL"; printf '%s\n' "$2" >>"$contribs"; shift ;;
      *) ao_die "$AO_E_USAGE" "unknown option '$1' (see --help)" ;;
    esac
    shift
  done
  inst_client "$v_client"
  case $v_name in *"$AO_TAB"* | *"$AO_NL"*) ao_die "$AO_E_USAGE" "--name must be one line without tabs" ;; esac
  [ -z "$embedded" ] || [ -z "$home" ] || ao_die "$AO_E_USAGE" "use --embedded or --home, not both"
  ao_load --no-state
  [ "$v_key" != "$AO_ORACLE_KEY" ] || ao_die "$AO_E_USAGE" "'$v_key' is the Oracle's key"
  [ "$v_key" != "$(basename -- "$AO_SENT")" ] || ao_die "$AO_E_USAGE" "'$v_key' collides with the sent archive folder"
  [ -r "$AO_REGISTRY" ] || ao_die "$AO_E_USAGE" "registry not found: $AO_REGISTRY (run install.sh oracle first)"
  work_root=$(ao_cfg_path work_root "$HOME/src")
  if [ -n "$embedded" ]; then home=$AO_HOME/operators/$v_key
  elif [ -z "$home" ]; then home=$(dirname -- "$AO_HOME")/$v_key
  fi
  case $home/ in "$KIT"/*) ao_die "$AO_E_USAGE" "the operator home must be outside the kit checkout" ;; esac
  row=$(awk -F'\t' -v k="$v_key" '$1 == k { print; exit }' "$AO_REGISTRY")
  if [ -n "$row" ]; then
    _rh=$(printf '%s\n' "$row" | cut -f 3)
    [ "$(ao_expand_path "$_rh" /)" = "$home" ] ||
      ao_die "$AO_E_USAGE" "'$v_key' is already in the registry with home $_rh"
  fi
  while IFS= read -r _u; do
    if _other=$(inst_owned_elsewhere "$_u"); then
      ao_die "$AO_E_USAGE" "$_u is already owned by operator '$_other' (one merge owner per repository, K-16)"
    fi
  done <"$owns"
  inst_kit_facts
  inst_dir "$home"
  inst_dir "$home/settings"
  inst_render "$TPL/home/AGENTS.md" "$home/AGENTS.md"
  inst_render "$TPL/home/CLAUDE.md" "$home/CLAUDE.md"
  inst_render "$TPL/home/MANDATE.md" "$home/MANDATE.md"
  inst_render "$TPL/home/NOTES.md" "$home/NOTES.md"
  inst_render "$TPL/home/settings/README.md" "$home/settings/README.md"
  [ -n "$embedded" ] || inst_render "$TPL/home/gitignore.template" "$home/.gitignore"
  conf=$home/operator.conf
  if [ -e "$conf" ]; then
    printf 'keep    %s (exists; add work lines by hand)\n' "$conf"
  else
    inst_render "$TPL/home/operator.conf" "$conf"
    while IFS= read -r _u; do
      inst_append "$conf" "work.$(inst_repo_name "$_u")=$_u|owner"
    done <"$owns"
    while IFS= read -r _u; do
      inst_append "$conf" "work.$(inst_repo_name "$_u")=$_u|contributor"
    done <"$contribs"
  fi
  [ -n "$row" ] || inst_append "$AO_REGISTRY" "$v_key$AO_TAB$v_name$AO_TAB$(inst_tilde "$home")${AO_TAB}pending$AO_TAB$v_client"
  clones=
  while IFS= read -r _u; do
    _r=$(inst_repo_name "$_u")
    [ -d "$work_root/$_r" ] || clones="$clones
  git clone $_u $work_root/$_r"
  done <"$owns"
  while IFS= read -r _u; do
    _r=$(inst_repo_name "$_u")
    if [ ! -d "$work_root/$_r" ]; then
      clones="$clones
  git clone $_u $work_root/$_r   # then rerun this command for the worktree"
      continue
    fi
    _wt=$work_root/.worktrees/$v_key/$_r
    [ ! -e "$_wt" ] || { printf 'keep    %s (exists)\n' "$_wt"; continue; }
    inst_say "create  $_wt (worktree, branch $v_key/main)"
    [ -z "$dry_run" ] || continue
    mkdir -p "$(dirname -- "$_wt")"
    if git -C "$work_root/$_r" show-ref --verify --quiet "refs/heads/$v_key/main"; then
      git -C "$work_root/$_r" worktree add -q "$_wt" "$v_key/main"
    else
      git -C "$work_root/$_r" worktree add -q -b "$v_key/main" "$_wt"
    fi || { ao_warn "cannot create worktree $_wt"; failures=$((failures + 1)); }
  done <"$contribs"
  [ -n "$embedded" ] || inst_commit "$home" "Create operator home $v_key from Agent Operations $kit_version"
  inst_commit "$AO_HOME" "Add operator $v_key"
  [ -z "$clones" ] || printf '\nClone these yourself (the installer uses no network):%s\n' "$clones"
  cat <<EOF

Next, by hand:
  1. Start a session in $home on $v_client and name it "$v_name".
     Then replace "pending" in its row of $AO_REGISTRY with the session id.
  2. Write its mandate in $home/MANDATE.md from your own words.
  3. Apply $home/settings/README.md to the client yourself.
  4. Check: $AO_SCRIPTS/check.sh home $home
EOF
}

# ---------------------------------------------------------------- skills

inst_skills() {
  [ "${1-}" = --target ] && [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "usage: install.sh skills --target DIR"
  target=$(inst_abs "$2")
  inst_dir "$target"
  for _s in "$KIT"/skills/*/; do
    _s=${_s%/}
    _n=${_s##*/}
    _dest=$target/$_n
    if [ -L "$_dest" ] && [ "$(readlink "$_dest")" = "$_s" ]; then
      printf 'keep    %s (already linked)\n' "$_dest"
    elif [ -e "$_dest" ] || [ -L "$_dest" ]; then
      ao_warn "$_dest exists and is not this kit's link; left alone"
      failures=$((failures + 1))
    else
      inst_say "link    $_dest -> $_s"
      [ -n "$dry_run" ] || ln -s "$_s" "$_dest" || { ao_warn "cannot link $_dest"; failures=$((failures + 1)); }
    fi
  done
  printf '\nNext: start a fresh session and check the client lists the skills.\n'
}

# ---------------------------------------------------------------- timers

inst_timers() {
  kind=
  case ${1-} in
    --launchd) kind=launchd ;;
    --systemd) kind=systemd ;;
    '') if [ "$(uname -s)" = Darwin ]; then kind=launchd; else kind=systemd; fi ;;
    *) ao_die "$AO_E_USAGE" "usage: install.sh timers [--launchd | --systemd]" ;;
  esac
  ao_load --no-state
  logs=$AO_STATE/logs
  inst_dir "$logs"
  label=local.agent-operations.tick
  v_key=$label v_name='' v_client='' v_team='' kit_version='' kit_commit=''

  if [ "$kind" = launchd ]; then
    unit=$HOME/Library/LaunchAgents/$label.plist
    inst_unit "$KIT/scripts/units/tick.plist.in" "$unit"
    load="launchctl bootstrap gui/\$(id -u) $unit"
  else
    unit=$HOME/.config/systemd/user/agent-operations-tick.service
    inst_unit "$KIT/scripts/units/tick.service.in" "$unit"
    inst_unit "$KIT/scripts/units/tick.timer.in" "${unit%.service}.timer"
    load="systemctl --user daemon-reload && systemctl --user enable --now agent-operations-tick.timer"
  fi
  cat <<EOF

The unit is written but not loaded. Load it yourself:
  $load
Then add the tick to SCHEDULES.md in the Oracle home if it is not there.
EOF
}

# inst_unit SRC DEST  Render a unit template (its own @NAME@ set).
inst_unit() {
  if [ -e "$2" ]; then
    printf 'keep    %s (exists; compare it with %s)\n' "$2" "$1"
    return 0
  fi
  inst_say "create  $2"
  [ -z "$dry_run" ] || return 0
  if ! { mkdir -p "$(dirname -- "$2")" &&
    sed -e "s|@LABEL@|$(inst_sed_value "$label")|g" \
      -e "s|@KIT_DIR@|$(inst_sed_value "$KIT")|g" \
      -e "s|@PROFILE@|$(inst_sed_value "$AO_PROFILE")|g" \
      -e "s|@LOG_DIR@|$(inst_sed_value "$logs")|g" "$1" | ao_write_atomic "$2"; }; then
    ao_warn "cannot write $2"
    failures=$((failures + 1))
  fi
}

# ---------------------------------------------------------------- main

main() {
  if [ "${1-}" = --dry-run ]; then dry_run=1; shift; fi
  [ $# -gt 0 ] || { ao_usage; exit "$AO_E_USAGE"; }
  cmd=$1
  shift
  if [ "${1-}" = --dry-run ]; then dry_run=1; shift; fi
  ao_clock
  case $cmd in
    oracle) inst_kit_facts; inst_oracle "$@" ;;
    operator) inst_operator "$@" ;;
    skills) inst_skills "$@" ;;
    timers) inst_timers "$@" ;;
    -h | --help) ao_usage; exit 0 ;;
    *) ao_die "$AO_E_USAGE" "unknown command '$cmd' (see --help)" ;;
  esac
  [ "$failures" -eq 0 ] || exit "$AO_E_FAIL"
}

main "$@"
