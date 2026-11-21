#!/bin/sh
# install.sh - create the Oracle home, operator homes, skill links and the
# tick unit from this kit checkout.
#
# Usage: install.sh [--dry-run] oracle HOME [--team DIR] [--name NAME]
#                   [--client CLIENT] [--profile-example NAME]
#        install.sh [--dry-run] operator KEY [--embedded | --home DIR]
#                   [--name NAME] [--client CLIENT]
#                   [--owns URL]... [--contributes URL]...
#        install.sh [--dry-run] sync CLIENT
#        install.sh [--dry-run] skills --target DIR
#        install.sh [--dry-run] timers [--launchd | --systemd]
#        install.sh [--dry-run] bridge claude|codex [--home DIR] [--name NAME]
#        install.sh [--dry-run] host [--apply]
#
# --dry-run lists every directory, file, link, worktree and timer the
# command would create, and changes nothing. Without it the same list is
# printed as the work is done. The installer only ever creates what is
# missing: an existing file is kept as it is and reported. It never uses
# sudo, never edits a client's settings, never loads a timer and never
# clones over the network; it prints those steps for you instead. The
# exceptions are all in `host`: the per-app App Nap default, and, with
# `host --apply`, writing and loading the kit's own two launchd units.
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
#           checked out under work_root (its origin must match the URL), a
#           worktree at
#           <work_root>/.worktrees/KEY/<repo> on branch KEY/main. Refuses a
#           repository another local operator already owns.
# sync      Needs the profile. Brings every registry row up to date for
#           CLIENT (claude or codex), typically a second client: each
#           existing home gets what is missing of AGENTS.md (read by Codex),
#           CLAUDE.md (`@AGENTS.md`, read by Claude Code),
#           settings/README.md and settings/handoff.md (patterns for both
#           clients), and a `session.CLIENT=` line in operator.conf (the
#           registry name, unless one is there); then it prints, per
#           operator, how to start and name the CLIENT session. A missing
#           home is reported, never created. Check with status.sh --drift.
# skills    Links each kit skill into DIR (a client's skills folder); an
#           existing entry that is not this kit's link is reported, never
#           replaced.
# timers    Needs the profile. Renders the tick unit and the relay unit
#           (the mailroom's trigger: every inbox folder watched, plus a run
#           every minute) for this machine (launchd on macOS, systemd user
#           units elsewhere) into your user's unit folder and prints the
#           commands that load them. Both run as ProcessType Standard.
# bridge    Needs the profile. EXPERIMENTAL (docs/mailroom.md). Creates a
#           mailroom bridge's own home (default: beside the Oracle home,
#           mailroom-CLIENT) with the bridge's whole duty in its AGENTS.md,
#           and its registry row under the reserved key mailroom-CLIENT
#           (session pending): the one file the relay and the supervisor
#           read for bridge ids. Then prints how to start and name the
#           session and record its id.
# host      An always-on host, turnkey: check then set, idempotent; prints
#           one table row per item (item, state, action), then the few
#           in-app steps only a person can do, each marked done or to do.
#           Always: App Nap off for each desktop app in host_apps (default:
#           com.anthropic.claudefordesktop and com.openai.codex), read back,
#           effective after each app restarts; power (pmset, check only);
#           the mailroom folders. With --apply also: the tick and relay
#           launchd units rendered from their templates (the relay unit
#           watches every registry inbox), replaced when stale (old copy in
#           <state_dir>/backup) and loaded in your user's launchd domain;
#           each bridge's home and lean duty file; the retired probes'
#           state removed. Checked only: bridge ids in the registry, the
#           Claude tier-1 switch, the supervisor pause and lane holds (owner
#           and expiry), the Oracle lock, and `check.sh host` (App Nap,
#           launchd ProcessType Background or Adaptive). It never uses sudo
#           and never opens an app.
#
# Options:
#   --name NAME              session display name (default: Oracle, or KEY)
#   --client CLIENT          claude | codex | custom | file-only (default:
#                            claude; for oracle, follows the profile example)
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

# inst_physical PATH  PATH with symlinks and .. resolved through its nearest
# existing ancestor, so a containment check cannot be fooled by a link.
inst_physical() {
  _ph_rest='' _ph_p=$1
  while [ ! -d "$_ph_p" ]; do
    _ph_rest=/${_ph_p##*/}$_ph_rest
    _ph_p=$(dirname -- "$_ph_p")
  done
  printf '%s%s\n' "$(CDPATH='' cd -- "$_ph_p" && pwd -P)" "$_ph_rest"
}

# inst_outside_kit PATH WHAT  Refuse a home inside the kit checkout.
inst_outside_kit() {
  _ok_kit=$(CDPATH='' cd -- "$KIT" && pwd -P)
  case $(inst_physical "$1")/ in "$_ok_kit"/*) ao_die "$AO_E_USAGE" "the $2 home must be outside the kit checkout" ;; esac
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

# inst_exists PATH  True for anything at PATH, a dangling link included.
inst_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

# inst_publish DEST  Write stdin to DEST without ever replacing anything:
# a temp file beside it is hard-linked to DEST, which fails if DEST exists.
inst_publish() {
  _ip_dir=$(dirname -- "$1")
  mkdir -p "$_ip_dir" || return 1
  _ip_tmp=$(mktemp "$_ip_dir/.tmp.XXXXXX") || return 1
  if cat >"$_ip_tmp" && ln "$_ip_tmp" "$1" 2>/dev/null; then
    rm -f "$_ip_tmp"
    return 0
  fi
  rm -f "$_ip_tmp"
  return 1
}

# inst_fill SRC  Print a template with its @NAME@ placeholders filled in.
inst_fill() {
  sed -e "s|@KEY@|$(inst_sed_value "${v_key-}")|g" \
    -e "s|@NAME@|$(inst_sed_value "${v_name-}")|g" \
    -e "s|@CLIENT@|$(inst_sed_value "${v_client-}")|g" \
    -e "s|@KIT_DIR@|$(inst_sed_value "$KIT")|g" \
    -e "s|@KIT_VERSION@|$(inst_sed_value "${kit_version-}")|g" \
    -e "s|@KIT_COMMIT@|$(inst_sed_value "${kit_commit-}")|g" \
    -e "s|@TEAM@|$(inst_sed_value "${v_team-}")|g" \
    -e "s|@DATE@|$AO_T_DATE|g" "$1"
}

# inst_render SRC DEST [MODE]  Copy a template with its @NAME@ placeholders
# filled in, unless DEST exists.
inst_render() {
  if inst_exists "$2"; then
    printf 'keep    %s (exists)\n' "$2"
    return 0
  fi
  inst_say "create  $2"
  [ -z "$dry_run" ] || return 0
  if ! { inst_fill "$1" | inst_publish "$2" && chmod "${3:-644}" "$2"; }; then
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
  v_key=oracle v_name=Oracle v_client='' v_team=none example=both
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
  [ -r "$KIT/profiles/$example.profile" ] || ao_die "$AO_E_USAGE" "no profile example '$example' (see profiles/)"
  # The Oracle's client follows the profile example unless given.
  if [ -z "$v_client" ]; then
    case $example in codex-only) v_client=codex ;; custom) v_client=custom ;; *) v_client=claude ;; esac
  fi
  inst_client "$v_client"
  inst_outside_kit "$home" Oracle
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
  if ! inst_exists "$reg"; then
    _before=$failures
    inst_render "$TPL/oracle/REGISTRY.tsv" "$reg"
    [ "$failures" -ne "$_before" ] ||
      inst_append "$reg" "oracle$AO_TAB$v_name$AO_TAB$(inst_tilde "$home")${AO_TAB}pending$AO_TAB$v_client"
  else
    printf 'keep    %s (exists)\n' "$reg"
  fi
  if inst_exists "$profile"; then
    printf 'keep    %s (exists; check its oracle_home)\n' "$profile"
  else
    inst_say "create  $profile (from profiles/$example.profile)"
    if [ -z "$dry_run" ] && ! { sed "s|^oracle_home=.*|oracle_home=$(inst_sed_value "$(inst_tilde "$home")")|" \
        "$KIT/profiles/$example.profile" | inst_publish "$profile" &&
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

# inst_owned_elsewhere URL  Print the key of another operator owning URL.
inst_owned_elsewhere() {
  _url=$(ao_repo_key "$1")
  while IFS="$AO_TAB" read -r _k _nm _d _rest; do
    case $_k in '' | '#'*) continue ;; esac
    [ "$_k" != "$v_key" ] || continue
    _conf=$(ao_expand_path "$_d" /)/operator.conf
    [ -r "$_conf" ] || continue
    while IFS= read -r _l; do
      case $_l in work.*'|owner')
        _o=${_l#*=}
        [ "$(ao_repo_key "${_o%|owner}")" != "$_url" ] || { printf '%s\n' "$_k"; return 0; } ;;
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
  # One installer at a time: the ownership check and the registry row must
  # not interleave with another run's. A dry run writes nothing, not even
  # the lock.
  if [ -z "$dry_run" ]; then
    mkdir -p "$AO_STATE" || ao_die "$AO_E_FAIL" "cannot create $AO_STATE"
    ao_lock registry || ao_die "$AO_E_USAGE" "the registry is being changed by another command; try again"
  fi
  [ "$v_key" != "$AO_ORACLE_KEY" ] || ao_die "$AO_E_USAGE" "'$v_key' is the Oracle's key"
  case $v_key in mailroom-claude | mailroom-codex) ao_die "$AO_E_USAGE" "'$v_key' is reserved for a mailroom bridge (install.sh bridge)" ;; esac
  [ "$v_key" != "$(basename -- "$AO_SENT")" ] || ao_die "$AO_E_USAGE" "'$v_key' collides with the sent archive folder"
  [ -r "$AO_REGISTRY" ] || ao_die "$AO_E_USAGE" "registry not found: $AO_REGISTRY (run install.sh oracle first)"
  work_root=$(ao_cfg_path work_root "$HOME/src")
  if [ -n "$embedded" ]; then home=$AO_HOME/operators/$v_key
  elif [ -z "$home" ]; then home=$(dirname -- "$AO_HOME")/$v_key
  fi
  inst_outside_kit "$home" operator
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
  inst_render "$TPL/home/settings/handoff.md" "$home/settings/handoff.md"
  [ -n "$embedded" ] || inst_render "$TPL/home/gitignore.template" "$home/.gitignore"
  conf=$home/operator.conf
  if inst_exists "$conf"; then
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
    _origin=$(git -C "$work_root/$_r" remote get-url origin 2>/dev/null) || _origin=
    if [ "$(ao_repo_key "$_origin")" != "$(ao_repo_key "$_u")" ]; then
      ao_warn "$work_root/$_r is not a checkout of $_u (origin: ${_origin:-none}); no worktree made"
      failures=$((failures + 1))
      continue
    fi
    _wt=$work_root/.worktrees/$v_key/$_r
    inst_exists "$_wt" && { printf 'keep    %s (exists)\n' "$_wt"; continue; }
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

# ---------------------------------------------------------------- sync

# inst_sync_row  Registry callback: bring one home up to date for $v_sync.
inst_sync_row() {
  v_key=$OP_KEY v_name=$OP_NAME v_client=$v_sync v_team=none
  _rh=$OP_DIR
  if [ ! -d "$_rh" ]; then
    ao_warn "$v_key: home $_rh not found; create it (install.sh operator $v_key --home $_rh) or remove the row"
    failures=$((failures + 1))
    return 0
  fi
  _agents=$TPL/home/AGENTS.md
  [ "$v_key" != "$AO_ORACLE_KEY" ] || _agents=$TPL/oracle/AGENTS.md
  inst_dir "$_rh/settings"
  inst_render "$_agents" "$_rh/AGENTS.md"
  inst_render "$TPL/home/CLAUDE.md" "$_rh/CLAUDE.md"
  if [ -f "$_rh/CLAUDE.md" ] && ! grep -qxF '@AGENTS.md' "$_rh/CLAUDE.md"; then
    ao_warn "$v_key: $_rh/CLAUDE.md does not import @AGENTS.md; add that line yourself"
  fi
  inst_render "$TPL/home/settings/README.md" "$_rh/settings/README.md"
  inst_render "$TPL/home/settings/handoff.md" "$_rh/settings/handoff.md"
  _sname=$v_name
  _conf=$_rh/operator.conf
  if [ -L "$_conf" ] || { inst_exists "$_conf" && [ ! -f "$_conf" ]; }; then
    ao_warn "$v_key: $_conf is a link or not a regular file; not touched. Add 'session.$v_sync=$v_name' yourself"
    failures=$((failures + 1))
  elif ! inst_exists "$_conf"; then
    # The Oracle home has none from install.sh oracle; the lease layer and
    # the drift check read the session names from it.
    v_client=$OP_PROVIDER
    ao_is_family "$v_client" || v_client=$v_sync
    inst_render "$TPL/home/operator.conf" "$_conf"
    v_client=$v_sync
    [ "$OP_PROVIDER" = "$v_sync" ] || ! ao_is_family "$OP_PROVIDER" || inst_append "$_conf" "session.$v_sync=$v_name"
  else
    _have=$(ao_conf_get "$_rh" "session.$v_sync") || _have=
    if [ -n "$_have" ]; then
      _sname=$_have
      printf 'keep    %s (session.%s=%s)\n' "$_conf" "$v_sync" "$_have"
    elif ! inst_conf_clean "$_rh"; then
      ao_warn "$v_key: $_conf has uncommitted changes or is untracked; not touched. Add 'session.$v_sync=$v_name' yourself"
      failures=$((failures + 1))
    else
      # Never glue the new line onto a last line without a newline.
      if [ -z "$dry_run" ] && [ -s "$_conf" ] && [ -n "$(tail -c 1 "$_conf")" ]; then
        printf '\n' >>"$_conf"
      fi
      inst_append "$_conf" "session.$v_sync=$v_name"
    fi
  fi
  # A home inside the Oracle home's repository is committed with it; any
  # other home in its own repository.
  _top=$(git -C "$_rh" rev-parse --show-toplevel 2>/dev/null) && _top=$(CDPATH='' cd -- "$_top" && pwd -P) || _top=
  if [ -z "$_top" ] || [ "$_top" != "$oracle_top" ]; then
    inst_commit "$_rh" "Sync operator home $v_key for $v_sync (Agent Operations $kit_version)"
  fi
  printf '%s\t%s\t%s\t%s\n' "$v_key" "$_rh" "$_sname" "$OP_LEASE" >>"$sync_steps"
}

# inst_conf_clean HOME  True when HOME/operator.conf has no uncommitted
# change (or HOME is not in a git repository): appending to it then commits
# only the new line.
inst_conf_clean() {
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || return 0
  GIT_LITERAL_PATHSPECS=1 git -C "$1" ls-files --error-unmatch -- operator.conf >/dev/null 2>&1 &&
    GIT_LITERAL_PATHSPECS=1 git -C "$1" diff --quiet HEAD -- operator.conf &&
    GIT_LITERAL_PATHSPECS=1 git -C "$1" diff --cached --quiet HEAD -- operator.conf
}

inst_sync() {
  [ $# -eq 1 ] || ao_die "$AO_E_USAGE" "usage: install.sh sync claude|codex"
  case $1 in claude | codex) v_sync=$1 ;; *) ao_die "$AO_E_USAGE" "sync needs a client: claude or codex" ;; esac
  ao_load --no-state
  # shellcheck disable=SC1091 # followed from the scripts and checked itself
  . "$AO_SCRIPTS/lib/registry.sh"
  if [ -z "$dry_run" ]; then
    mkdir -p "$AO_STATE" || ao_die "$AO_E_FAIL" "cannot create $AO_STATE"
    ao_lock registry || ao_die "$AO_E_USAGE" "the registry is being changed by another command; try again"
  fi
  inst_kit_facts
  oracle_top=$(git -C "$AO_HOME" rev-parse --show-toplevel 2>/dev/null) && oracle_top=$(CDPATH='' cd -- "$oracle_top" && pwd -P) || oracle_top=
  sync_steps=$(ao_tmp steps)
  ao_registry_each inst_sync_row
  inst_commit "$AO_HOME" "Sync operator homes for $v_sync"
  printf '\nNext, by hand, for each operator on %s:\n' "$v_sync"
  while IFS="$AO_TAB" read -r _k _h _n _l; do
    printf '  %s: start a %s session in %s and name it "%s".\n' "$_k" "$v_sync" "$_h" "$_n"
    if [ "$_l" = none ]; then
      printf '      It is the second session: the registry row stays as it is until you move %s\n      to %s (change the client column; a switch-in audit follows).\n' "$_k" "$v_sync"
    else
      printf '      %s has a lease: the new session is the standby until a release or takeover\n      (lease.sh --home %s status).\n' "$_k" "$_h"
    fi
  done <"$sync_steps"
  cat <<EOF
  Then apply settings/handoff.md in each home to $v_sync yourself, and check:
  $AO_SCRIPTS/status.sh --drift
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
    label=local.agent-operations.relay
    runit=$HOME/Library/LaunchAgents/$label.plist
    watch=$(ao_tmp watch)
    inst_watch_paths >"$watch"
    inst_unit "$KIT/scripts/units/relay.plist.in" "$runit" "$watch"
    load="launchctl bootstrap gui/\$(id -u) $unit
  launchctl bootstrap gui/\$(id -u) $runit"
  else
    unit=$HOME/.config/systemd/user/agent-operations-tick.service
    inst_unit "$KIT/scripts/units/tick.service.in" "$unit"
    inst_unit "$KIT/scripts/units/tick.timer.in" "${unit%.service}.timer"
    runit=$HOME/.config/systemd/user/agent-operations-relay.service
    inst_unit "$KIT/scripts/units/relay.service.in" "$runit"
    inst_unit "$KIT/scripts/units/relay.timer.in" "${runit%.service}.timer"
    load="systemctl --user daemon-reload && systemctl --user enable --now agent-operations-tick.timer agent-operations-relay.timer"
  fi
  cat <<EOF

The units are written but not loaded. Load them yourself:
  $load
Then add the tick and the relay to SCHEDULES.md in the Oracle home if they
are not there.
EOF
}

# inst_watch_paths  WatchPaths entries for the relay unit: each registry
# key's inbox folder (created if missing), XML-escaped.
inst_watch_paths() {
  [ -r "$AO_REGISTRY" ] || return 0
  awk -F'\t' '$1 != "" && $1 !~ /^#/ { print $1 }' "$AO_REGISTRY" | while IFS= read -r _k; do
    ao_is_name "$_k" || continue
    inst_dir "$AO_INBOX/$_k" >&2
    printf '    <string>%s</string>\n' "$(printf '%s' "$AO_INBOX/$_k" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
  done
}

# ---------------------------------------------------------------- bridge

inst_bridge() {
  case ${1-} in claude | codex) v_client=$1 ;; *) ao_die "$AO_E_USAGE" "usage: install.sh bridge claude|codex [--home DIR] [--name NAME]" ;; esac
  shift
  # Both bridges are titled Mailroom (docs/conventions.md); the registry
  # key says which app.
  v_key=mailroom-$v_client home='' v_team=none v_name=Mailroom
  while [ $# -gt 0 ]; do
    case $1 in
      --home) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--home needs a directory"; home=$(inst_abs "$2"); shift ;;
      --name) [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "--name needs a value"; v_name=$2; shift ;;
      *) ao_die "$AO_E_USAGE" "unknown option '$1' (see --help)" ;;
    esac
    shift
  done
  case $v_name in *"$AO_TAB"* | *"$AO_NL"* | *'"'* | *\\*) ao_die "$AO_E_USAGE" "--name must be one line without tabs, quotes or backslashes" ;; esac
  ao_load --no-state
  [ -r "$AO_REGISTRY" ] || ao_die "$AO_E_USAGE" "registry not found: $AO_REGISTRY (run install.sh oracle first)"
  if [ -z "$dry_run" ]; then
    ao_lock registry || ao_die "$AO_E_USAGE" "the registry is being changed by another command; try again"
  fi
  [ -n "$home" ] || home=$(dirname -- "$AO_HOME")/$v_key
  inst_outside_kit "$home" bridge
  row=$(awk -F'\t' -v k="$v_key" '$1 == k { print; exit }' "$AO_REGISTRY")
  if [ -n "$row" ]; then
    _rh=$(printf '%s\n' "$row" | cut -f 3)
    [ "$(ao_expand_path "$_rh" /)" = "$home" ] ||
      ao_die "$AO_E_USAGE" "'$v_key' is already in the registry with home $_rh"
  fi
  inst_kit_facts
  inst_dir "$home"
  inst_render "$TPL/mailroom/$v_client-AGENTS.md" "$home/AGENTS.md"
  [ "$v_client" != claude ] || inst_render "$TPL/home/CLAUDE.md" "$home/CLAUDE.md"
  [ -n "$row" ] || inst_append "$AO_REGISTRY" "$v_key$AO_TAB$v_name$AO_TAB$(inst_tilde "$home")${AO_TAB}pending$AO_TAB$v_client"
  inst_commit "$home" "Create the $v_client mailroom bridge home from Agent Operations $kit_version"
  inst_commit "$AO_HOME" "Add the $v_client mailroom bridge"
  cat <<EOT

Next, in the $v_client app (install.sh host lists these with their state):
$(inst_bridge_steps "$v_client" "$home" "$v_name")
EOT
}

# inst_bridge_steps CLIENT HOME NAME  The in-app steps for one bridge.
inst_bridge_steps() {
  if [ "$1" = claude ]; then
    cat <<EOT
  - Start a Claude Code session in $2 on the cheapest model, title it
    "$3", allow it to run $AO_SCRIPTS/mailroom.sh without asking, and send
    it "Re-arm". It may sit nested under the Oracle in the sidebar.
  - Put its session id in place of "pending" in its row of $AO_REGISTRY.
EOT
  else
    cat <<EOT
  - Create a Codex thread in $2 titled "$3" on the cheapest model and pin
    it. Set bridge_codex_node and bridge_codex_server in the profile, then
    send it "Re-arm doorbell watcher".
  - Put its thread id in place of "pending" in its row of $AO_REGISTRY.
EOT
  fi
}

# ---------------------------------------------------------------- host

# host_row ITEM STATE ACTION  One row of the host table. States that are
# done (ok, set, created, installed, updated, loaded, removed, opt-in) do
# not count as needing you.
host_row() {
  printf '%-34s %-40s %s\n' "$1" "$2" "${3:--}"
  case $2 in ok* | set* | created* | installed* | updated* | loaded* | removed* | off\ \(opt-in*) ;; *) host_todo=$((host_todo + 1)) ;; esac
}

# host_step DONE TEXT  One line of the closing in-app checklist.
host_step() {
  if [ "$1" = 1 ]; then printf '  [done]  %s\n' "$2"; else printf '  [to do] %s\n' "$2"; fi
}

# host_backup FILE  Copy FILE into <state_dir>/backup/ before replacing it.
host_backup() {
  [ -f "$1" ] || return 0
  mkdir -p "$AO_STATE/backup" && cp -p "$1" "$AO_STATE/backup/${1##*/}.$AO_T_STAMP"
}

# host_unit NAME  The launchd unit NAME (tick or relay): rendered from its
# template (the relay unit watches every registry inbox), compared with the
# installed file, written (old copy backed up) and loaded with --apply.
host_unit() {
  label=local.agent-operations.$1
  _f=$HOME/Library/LaunchAgents/$label.plist
  _want=$(ao_tmp "unit-$1")
  _watch=$(ao_tmp watch)
  : >"$_watch"
  [ "$1" != relay ] || inst_watch_paths >"$_watch" 2>/dev/null
  inst_unit_text "$KIT/scripts/units/$1.plist.in" "$_watch" >"$_want" || { host_row "unit $1" FAILED "cannot render"; failures=$((failures + 1)); return; }
  _dom=gui/$(id -u)
  if [ -f "$_f" ] && cmp -s "$_want" "$_f"; then
    if launchctl print "$_dom/$label" >/dev/null 2>&1; then host_row "unit $1" "ok (loaded)"
    elif [ -n "$_apply" ] && [ -n "$dry_run" ]; then host_row "unit $1" "not loaded" "would load: launchctl bootstrap $_dom $_f"
    elif [ -n "$_apply" ] && launchctl bootstrap "$_dom" "$_f" >/dev/null 2>&1; then host_row "unit $1" "loaded"
    elif [ -n "$_apply" ]; then host_row "unit $1" "FAILED to load" "launchctl bootstrap $_dom $_f"; failures=$((failures + 1))
    else host_row "unit $1" "not loaded" "install.sh host --apply"; fi
    return
  fi
  if [ -f "$_f" ]; then _was="stale (differs from the template or the registry)"; else _was=missing; fi
  if [ -z "$_apply" ] || [ -n "$dry_run" ]; then
    host_row "unit $1" "$_was" "install.sh host --apply"
    return
  fi
  mkdir -p "$logs" "${_f%/*}"
  if host_backup "$_f" && cp "$_want" "$_f.tmp.$$" && mv -f "$_f.tmp.$$" "$_f"; then
    launchctl bootout "$_dom/$label" >/dev/null 2>&1
    if launchctl bootstrap "$_dom" "$_f" >/dev/null 2>&1; then
      if [ "$_was" = missing ]; then host_row "unit $1" "installed and loaded"; else host_row "unit $1" "updated and reloaded (old copy in state/backup)"; fi
    else
      host_row "unit $1" "written, FAILED to load" "launchctl bootstrap $_dom $_f"; failures=$((failures + 1))
    fi
  else
    rm -f "$_f.tmp.$$"
    host_row "unit $1" "FAILED to write" "$_f"; failures=$((failures + 1))
  fi
}

# host_bridge CLIENT  The bridge's home and duty file (created or brought
# up to date with --apply) and its id in the registry (a human step).
host_bridge() {
  _row=$(awk -F'\t' -v k="mailroom-$1" '$1 == k { print; exit }' "$AO_REGISTRY" 2>/dev/null)
  if [ -z "$_row" ]; then
    if [ -n "$_apply" ] && [ -z "$dry_run" ]; then
      if sh "$AO_SCRIPTS/install.sh" bridge "$1" </dev/null >/dev/null 2>&1; then host_row "bridge $1 home" "created (install.sh bridge $1)"
      else host_row "bridge $1 home" FAILED "install.sh bridge $1"; failures=$((failures + 1)); fi
      _row=$(awk -F'\t' -v k="mailroom-$1" '$1 == k { print; exit }' "$AO_REGISTRY" 2>/dev/null)
    else
      host_row "bridge $1 home" "no row" "install.sh host --apply"
      return
    fi
  fi
  _bh=$(ao_expand_path "$(printf '%s\n' "$_row" | cut -f 3)" /)
  _duty=$(ao_tmp "duty-$1")
  inst_fill "$TPL/mailroom/$1-AGENTS.md" >"$_duty"
  if cmp -s "$_duty" "$_bh/AGENTS.md"; then host_row "bridge $1 duty file" "ok ($(wc -c <"$_duty" | tr -d ' ') bytes)"
  elif [ -n "$_apply" ] && [ -z "$dry_run" ] && mkdir -p "$_bh" && host_backup "$_bh/AGENTS.md" &&
    cp "$_duty" "$_bh/AGENTS.md.tmp.$$" && mv -f "$_bh/AGENTS.md.tmp.$$" "$_bh/AGENTS.md"; then
    host_row "bridge $1 duty file" "updated (a running bridge reads it at its next start)"
  else
    host_row "bridge $1 duty file" "differs from the template" "install.sh host --apply"
  fi
  _sid=$(printf '%s\n' "$_row" | cut -f 4)
  case $_sid in '' | - | pending) host_row "bridge $1 id" pending "the in-app steps below" ;; *) host_row "bridge $1 id" "ok (recorded in the registry)" ;; esac
}

inst_host() {
  _apply=
  case ${1-} in --apply) _apply=1; shift ;; esac
  [ $# -eq 0 ] || ao_die "$AO_E_USAGE" "usage: install.sh [--dry-run] host [--apply]"
  host_todo=0 _napset=
  _pf=$(ao_profile_path)
  _prof=
  if [ -r "$_pf" ]; then ao_load --no-state; _prof=1; fi
  apps=$(ao_cfg host_apps "$AO_HOST_APPS")
  printf '%-34s %-40s %s\n' ITEM STATE ACTION
  # 1. App Nap, per app: check, set, read back.
  if ! command -v defaults >/dev/null 2>&1; then
    host_row app-nap "n/a (not macOS)"
  elif [ "$apps" != none ]; then
    for _id in $apps; do
      case $_id in *[!A-Za-z0-9.-]*) host_row "app-nap $_id" "invalid bundle id" "fix host_apps"; continue ;; esac
      if [ "$(defaults read "$_id" NSAppSleepDisabled 2>/dev/null)" = 1 ]; then
        host_row "app-nap $_id" ok
      elif [ -n "$dry_run" ]; then
        host_row "app-nap $_id" "would set" "defaults write $_id NSAppSleepDisabled -bool YES"
      elif defaults write "$_id" NSAppSleepDisabled -bool YES &&
        [ "$(defaults read "$_id" NSAppSleepDisabled 2>/dev/null)" = 1 ]; then
        host_row "app-nap $_id" "set (restart needed)" "quit and reopen the app"
        _napset=1
      else
        host_row "app-nap $_id" FAILED "defaults write $_id NSAppSleepDisabled -bool YES"
        failures=$((failures + 1))
      fi
    done
  fi
  # 2. Power: check only.
  if command -v pmset >/dev/null 2>&1; then
    _sl=$(pmset -g 2>/dev/null | awk '$1 == "sleep" { print $2; exit }')
    case $_sl in
      0) host_row power "ok (system sleep off)" ;;
      '') host_row power "unknown" "check pmset -g" ;;
      *) host_row power "system sleeps after ${_sl} min" "turn system sleep off in Settings (check only here)" ;;
    esac
  fi
  if [ -z "$_prof" ]; then
    host_row profile "none" "copy a profile, then run host again"
  else
    # shellcheck disable=SC1091 # followed from the scripts and checked itself
    . "$AO_SCRIPTS/lib/registry.sh"
    logs=$AO_STATE/logs
    v_key='' v_name='' v_client='' v_team='' kit_version='' kit_commit=''
    # 3. Folders.
    ao_mr_dir=$(ao_cfg_path bridge_dir "$AO_INBOX/.mailroom")
    for _d in "$ao_mr_dir/claude/delivered" "$ao_mr_dir/codex/delivered"; do
      if [ -d "$_d" ]; then host_row "folder ${_d#"$AO_HOME"/}" ok
      elif [ -n "$dry_run" ]; then host_row "folder ${_d#"$AO_HOME"/}" "would create"
      elif mkdir -p "$_d"; then host_row "folder ${_d#"$AO_HOME"/}" created
      else host_row "folder ${_d#"$AO_HOME"/}" FAILED; failures=$((failures + 1)); fi
    done
    # 4. Bridges: homes, lean duty files, ids in the registry (one file);
    #    first, so the relay unit below watches their inboxes too.
    host_bridge claude
    host_bridge codex
    # 5. Units, generated from the templates and the registry.
    if [ "$(uname -s)" = Darwin ] && command -v launchctl >/dev/null 2>&1; then
      host_unit tick
      host_unit relay
    else
      host_row units "not macOS: not checked" "install.sh timers, then load them"
    fi
    # 6. Switches and holds: each is off unless someone turned it on, and
    #    one that is on names its owner and expiry (K-07).
    if [ "$(ao_cfg bridge_claude_t1 off)" = socket ]; then
      if [ -e "$ao_mr_dir/claude/.watcher/t1-off" ]; then host_row "claude tier 1" "ON in the profile, kill switch set" "rm $ao_mr_dir/claude/.watcher/t1-off"
      else host_row "claude tier 1" "ok (socket)"; fi
    else
      host_row "claude tier 1" "off (opt-in: bridge_claude_t1=socket)"
    fi
    if [ -f "$AO_STATE/mailroom-pause" ]; then
      if ao_hold_active "$AO_STATE/mailroom-pause"; then host_row "supervisor" "PAUSED until $AO_H_UNTIL by $AO_H_OWNER" "lane.sh unhold mailroom"
      else host_row "supervisor" "pause file expired or without owner" "lane.sh unhold mailroom"; fi
    else
      host_row "supervisor" "ok (not paused)"
    fi
    _nh=0
    for _h in "$AO_STATE/holds"/*; do [ -f "$_h" ] && _nh=$((_nh + 1)); done
    if [ "$_nh" -eq 0 ]; then host_row "lane holds" "ok (none)"; else host_row "lane holds" "$_nh held" "lane.sh check"; fi
    # 7. The retired hourly probes' state.
    if [ ! -d "$AO_STATE/mailroom-probe" ]; then host_row "retired hourly probes" "ok (none left)"
    elif [ -n "$_apply" ] && [ -z "$dry_run" ] && rm -rf "$AO_STATE/mailroom-probe"; then host_row "retired hourly probes" "removed"
    else host_row "retired hourly probes" "state left in $AO_STATE/mailroom-probe" "install.sh host --apply"; fi
    # 8. One active Oracle (K-13).
    if [ -f "$AO_HOME/operators/ORACLE-LOCK" ]; then
      host_row "oracle lock" "ok ($(sed -n 's/^holder=//p' "$AO_HOME/operators/ORACLE-LOCK" | head -n 1))"
    else
      host_row "oracle lock" missing "lane.sh oracle-lock take CLIENT --session ID (on the human's word)"
    fi
  fi
  # 9. Verify App Nap and launchd priority.
  _ch=$(ao_tmp check-host)
  if "$AO_SCRIPTS/check.sh" host >"$_ch" 2>&1; then
    host_row check.sh "ok (App Nap, ProcessType)"
  else
    while IFS= read -r _l; do host_row check.sh "finding" "$_l"; done <"$_ch"
  fi
  printf '\n%s item(s) need you.\n' "$host_todo"
  [ -n "$_prof" ] || return 0
  # The few steps only a person can do, in the apps (docs/conventions.md).
  _cs=0 _xs=0
  _r=$(awk -F'\t' '$1 == "mailroom-claude" { print $4; exit }' "$AO_REGISTRY" 2>/dev/null)
  case $_r in '' | - | pending) ;; *) _cs=1 ;; esac
  _r=$(awk -F'\t' '$1 == "mailroom-codex" { print $4; exit }' "$AO_REGISTRY" 2>/dev/null)
  case $_r in '' | - | pending) ;; *) _xs=1 ;; esac
  printf '\nIn the apps (once; a person does these):\n'
  [ -z "$_napset" ] || host_step 0 "Quit and reopen both desktop apps (App Nap takes effect)."
  host_step "$_cs" "Claude: the Mailroom session in the bridge home, cheapest model, titled \"Mailroom\", sent \"Re-arm\"; its id in the registry."
  host_step "$_xs" "Codex: the Mailroom thread in the bridge home, cheapest model, titled \"Mailroom\", pinned, sent \"Re-arm doorbell watcher\"; its id in the registry."
  host_step 0 "Claude sidebar: pin the active operators; keep inactive operators in a section named \"Inactive Operators\"; the Mailroom may sit nested under the Oracle."
  host_step 0 "Codex sidebar: pin the threads of the operators active on Codex, and the Mailroom."
  [ -n "$_apply" ] || printf '  (Rows that say "install.sh host --apply" are done by: %s/install.sh host --apply)\n' "$AO_SCRIPTS"
}

# inst_unit_text SRC [LINES]  Print a unit template rendered (its own @NAME@
# set); a line holding only @WATCH_PATHS@ becomes the contents of file LINES.
inst_unit_text() {
  sed -e "s|@LABEL@|$(inst_sed_value "$label")|g" \
    -e "s|@KIT_DIR@|$(inst_sed_value "$KIT")|g" \
    -e "s|@PROFILE@|$(inst_sed_value "$AO_PROFILE")|g" \
    -e "s|@LOG_DIR@|$(inst_sed_value "$logs")|g" "$1" |
    awk -v f="${2:-/dev/null}" '$1 == "@WATCH_PATHS@" { while ((getline l < f) > 0) print l; next } { print }'
}

# inst_unit SRC DEST [LINES]  Render a unit template, unless DEST exists.
inst_unit() {
  if inst_exists "$2"; then
    printf 'keep    %s (exists; compare it with %s)\n' "$2" "$1"
    return 0
  fi
  inst_say "create  $2"
  [ -z "$dry_run" ] || return 0
  if ! inst_unit_text "$1" "${3:-}" | inst_publish "$2"; then
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
    sync) inst_sync "$@" ;;
    skills) inst_skills "$@" ;;
    timers) inst_timers "$@" ;;
    host) inst_host "$@" ;;
    bridge) inst_bridge "$@" ;;
    -h | --help) ao_usage; exit 0 ;;
    *) ao_die "$AO_E_USAGE" "unknown command '$cmd' (see --help)" ;;
  esac
  [ "$failures" -eq 0 ] || exit "$AO_E_FAIL"
}

main "$@"
