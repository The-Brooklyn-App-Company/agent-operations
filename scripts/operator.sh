#!/bin/sh
# operator.sh - the pre-baked operator routines, each a guided script with a
# verifier (K-36): create an operator, archive one, change its model on the
# owner's word, record a session id, and recover an unresponsive Codex
# thread. Switching an operator between clients is `lane.sh switch` (or
# `operator.sh switch`, which runs it).
#
# Usage: operator.sh [--yes] create KEY [--name NAME] [--client CLIENT]
#                    [--embedded | --home DIR]
#                    [--model-claude M] [--effort-claude E]
#                    [--model-codex M] [--effort-codex E]
#                    [--owns URL]... [--contributes URL]...
#        operator.sh [--yes] archive KEY
#        operator.sh model KEY --client CLIENT --model M [--effort E] --words TEXT
#        operator.sh session KEY ID [--client CLIENT]
#        operator.sh recover KEY [--replaced THREAD]
#        operator.sh verify KEY
#        operator.sh mark KEY STEP [--cold REASON]
#        operator.sh switch KEY ...        (runs lane.sh switch)
#        operator.sh list
#
# Each routine opens a checklist (<state_dir>/routine/KEY, one open routine
# per operator) that `verify` checks in order: steps a script can do it
# does; steps only a person or the app's own tools can do (titles, pins,
# archiving a thread) are printed with what to do and marked with `mark`
# once done. A routine closes only when every step passes. Re-running any
# command is safe.
#
# create   Asks (or takes from the options) the display name, the active
#          client, and the model and effort for BOTH clients: decided once,
#          now, with the owner, and recorded in operator.conf
#          (model.<client>, effort.<client>). Then `install.sh operator`.
#          Steps: home, models, session (the session is created with that
#          model and effort; `operator.sh session KEY ID` records it),
#          title, pin, mandate (written from the owner's words), check
#          (check.sh home).
# archive  Steps: handoff (a warm HANDOFF.md committed since the archive
#          opened, or `mark KEY handoff --cold REASON`), worktrees (every
#          worktree under <work_root>/.worktrees/KEY/ becomes a verified
#          local git bundle in <archive_dir>/KEY/ holding its KEY/*
#          branches and its HEAD; only then are the worktree and those
#          branches removed; uncommitted work stops it),
#          jobs (no JOBS.tsv row names KEY), sidebar (mark: unpinned, in
#          "Inactive Operators" on Claude, archived on Codex), registry
#          (last: the row is commented out as #archived and operator.conf
#          gets archived=DATE; the Oracle home is committed).
# model    The one path that changes an operator's model, and only on the
#          owner's word: --words quotes them (K-01, K-26). Refused from the
#          operator's own session: an operator orchestrates and may spawn
#          cheaper or stronger subagents, but never changes its own model.
#          Records operator.conf and the journal, then one in-app step: the
#          change is applied through the app's own model setting, or by
#          creating a new session with the new model and switching to it,
#          never by a message to the thread.
# session  Record a session or thread id in KEY's registry row (also for the
#          Oracle and the mailroom-claude / mailroom-codex bridges).
# recover  An unresponsive Codex thread (the mailroom supervisor opens this
#          by itself when one thread keeps timing out while others
#          deliver). Steps: revive-queue (one queued no-op turn by the CLI;
#          passes on a new turn-complete event in the thread's rollout
#          within 3 min), revive-native (one native no-op through the Codex
#          watcher, steered; same check), replace (a new thread in the
#          operator's home, same title, model and effort set at creation
#          from operator.conf; then `recover KEY --replaced THREAD`),
#          archive-old (mark), switch (lane.sh switch to the new thread with
#          a cold handoff, then lane.sh verify). A revive that works closes
#          the routine.
#
# --yes: take every choice from the options and defaults without asking
# (also the behaviour when stdin is not a terminal).
#
# Environment: AO_PROFILE.
#
# Exit codes: 0 done (verify: every step passes); 1 steps remain or a step
# failed; 2 usage or configuration error; 3 busy; 5 refused.
set -u
AO_SCRIPTS=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$AO_SCRIPTS/lib/core.sh"
. "$AO_SCRIPTS/lib/registry.sh"
. "$AO_SCRIPTS/lib/vendor.sh"
. "$AO_SCRIPTS/lib/mailroom.sh"
. "$AO_SCRIPTS/lib/guide.sh"

E_REFUSED=5
REVIVE_WAIT=180
NOOP='Recovery check (the Oracle'"'"'s supervisor, automated, not from the human): no action is needed. Reply with one word and end the turn.'

refuse() {
  ao_msg "refused: $*"
  exit "$E_REFUSED"
}

# op_row KEY  Set R_NAME, R_DIR, R_SID, R_CLIENT from the registry.
_op_row_cb() {
  [ "$OP_KEY" = "$_op_want" ] || return 0
  R_FOUND=1 R_NAME=$OP_NAME R_DIR=$OP_DIR R_SID=$OP_SID R_CLIENT=$OP_CLIENT
}
op_row() {
  _op_want=$1 R_FOUND='' R_NAME='' R_DIR='' R_SID='' R_CLIENT=''
  ao_registry_each _op_row_cb
  [ -n "$R_FOUND" ]
}

op_key() {
  ao_is_name "${1-}" || ao_die "$AO_E_USAGE" "invalid key '${1-}'"
  ! ao_is_bridge_key "$1" || refuse "$1 is a mailroom bridge, not an operator"
  [ "$1" != "$AO_ORACLE_KEY" ] || refuse "$1 is the Oracle"
}

op_state() { printf '%s/routine/%s\n' "$AO_STATE" "$1"; }
op_marked() { [ -n "$(ao_st_get "$_st" "done_$1")" ]; }

op_sid_set() { case ${1:-} in '' | - | pending) return 1 ;; esac; return 0; }

# op_cfg_model CLIENT KIND  The profile default for a client's model or
# effort (implementer_<client>_<kind>), ignoring placeholders.
op_cfg_model() {
  _v=$(ao_cfg "implementer_$1_$2" '')
  case $_v in CHANGE-ME*) _v='' ;; esac
  printf '%s\n' "$_v"
}

# ---------------------------------------------------------------- create

op_create() {
  _key=${1-}
  shift || true
  op_key "$_key"
  _name='' _client='' _where='' _wdir=''
  _mc='' _ec='' _mx='' _ex=''
  _pass=$(ao_tmp pass)
  : >"$_pass"
  while [ $# -gt 0 ]; do
    case $1 in
      --name | --client | --home | --model-claude | --effort-claude | --model-codex | --effort-codex | --owns | --contributes)
        [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "$1 needs a value"
        case $1 in
          --name) _name=$2 ;;
          --client) _client=$2 ;;
          --home) _where=home _wdir=$2 ;;
          --model-claude) _mc=$2 ;;
          --effort-claude) _ec=$2 ;;
          --model-codex) _mx=$2 ;;
          --effort-codex) _ex=$2 ;;
          --owns | --contributes) printf '%s\n%s\n' "$1" "$2" >>"$_pass" ;;
        esac
        shift ;;
      --embedded) _where=embedded ;;
      *) ao_die "$AO_E_USAGE" "unknown option '$1' (see --help)" ;;
    esac
    shift
  done
  _st=$(op_state "$_key")
  [ ! -f "$_st" ] || refuse "a $(ao_st_get "$_st" kind) routine for $_key is open: operator.sh verify $_key"
  ao_explain "Create the operator \"$_key\"" \
    "An operator owns one outcome: one home (its own repository) plus the work" \
    "repositories it declares. Its model and effort are decided now, with you," \
    "for both clients, and never changed by the operator itself."
  ao_ask _name "Display name (the session title)" "${_name:-$_key}" ao_is_line
  ao_ask _client "Client it starts on (claude or codex)" "${_client:-$(ao_cfg relay_default claude)}" ao_is_client
  ao_explain "Model and effort" \
    "Set once, at creation, for each client. The operator spawns cheaper or" \
    "stronger subagents as its work needs, but its own model changes only" \
    "through \`operator.sh model\`, on your word."
  ao_ask _mc "Claude model" "${_mc:-$(op_cfg_model claude model)}" ao_is_word
  ao_ask _ec "Claude effort" "${_ec:-$(op_cfg_model claude effort)}" ao_is_effort
  ao_ask _mx "Codex model" "${_mx:-$(op_cfg_model codex model)}" ao_is_word
  ao_ask _ex "Codex effort" "${_ex:-$(op_cfg_model codex effort)}" ao_is_effort
  ao_confirm "Create \"$_name\" ($_key) on $_client now?" || refuse "not confirmed"
  set -- "$_key" --name "$_name" --client "$_client"
  case $_where in embedded) set -- "$@" --embedded ;; home) set -- "$@" --home "$_wdir" ;; esac
  while IFS= read -r _o && IFS= read -r _u; do set -- "$@" "$_o" "$_u"; done <"$_pass"
  sh "$AO_SCRIPTS/install.sh" operator "$@" </dev/null || ao_die "$AO_E_FAIL" "install.sh operator failed"
  op_row "$_key" || ao_die "$AO_E_FAIL" "no registry row for $_key after install"
  _conf=$R_DIR/operator.conf
  for _kv in "model.claude=$_mc" "effort.claude=$_ec" "model.codex=$_mx" "effort.codex=$_ex"; do
    ao_conf_set "$_conf" "${_kv%%=*}" "${_kv#*=}" || ao_die "$AO_E_FAIL" "cannot write $_conf"
  done
  ao_git_commit "$R_DIR" "Record $_key's models, chosen at creation" operator.conf ||
    ao_warn "could not commit $_conf"
  {
    printf 'kind=create\nstarted=%s\nclient=%s\nname=%s\n' "$AO_T_EPOCH" "$_client" "$_name"
  } | ao_write_atomic "$_st" || ao_die "$AO_E_FAIL" "cannot write $_st"
  op_verify "$_key"
}

op_verify_create() {
  _cl=$(ao_st_get "$_st" client)
  _nm=$(ao_st_get "$_st" name)
  _conf=$R_DIR/operator.conf
  if [ -f "$_conf" ]; then ao_step PASS home "$R_DIR"; else ao_step TODO home "no $_conf: install.sh operator $_key"; fi
  _m=$(ao_conf_get "$_conf" "model.$_cl") _e=$(ao_conf_get "$_conf" "effort.$_cl")
  if [ -n "$_m" ]; then ao_step PASS models "$_cl: $_m${_e:+, effort $_e} (other client: $(ao_conf_get "$_conf" "model.$( [ "$_cl" = claude ] && echo codex || echo claude)"))"
  else ao_step TODO models "decide the $_cl model with the owner, then: operator.sh model $_key --client $_cl --model M --words \"...\""; fi
  if op_sid_set "$R_SID"; then ao_step PASS session "registry: $R_CLIENT $R_SID"
  else ao_step TODO session "create the $_cl session in $R_DIR with model ${_m:-?}${_e:+ and effort $_e} chosen at creation; then: operator.sh session $_key <id>"; fi
  for _mk in title pin; do
    if op_marked "$_mk"; then ao_step PASS "$_mk" "marked"; continue; fi
    case $_mk in
      title) _do="title the session \"$_nm\"" ;;
      pin) _do="pin it in the $_cl sidebar (active operators are pinned; docs/conventions.md)" ;;
    esac
    ao_step TODO "$_mk" "$_do, then: operator.sh mark $_key $_mk"
  done
  if [ -f "$R_DIR/MANDATE.md" ] && ! grep -q '^What the human wants to be able to use' "$R_DIR/MANDATE.md"; then
    ao_step PASS mandate "written"
  else
    ao_step TODO mandate "write $R_DIR/MANDATE.md from the owner's own words (outcome, scope, finish line)"
  fi
  if sh "$AO_SCRIPTS/check.sh" home "$R_DIR" >"$_tmpo" 2>&1; then ao_step PASS check "check.sh home"
  else ao_step TODO check "check.sh home: $(head -n 1 "$_tmpo")"; fi
}

# ---------------------------------------------------------------- archive

op_archive() {
  _key=${1-}
  op_key "$_key"
  op_row "$_key" || ao_die "$AO_E_USAGE" "no registry row for '$_key'"
  _st=$(op_state "$_key")
  if [ -f "$_st" ]; then
    [ "$(ao_st_get "$_st" kind)" = archive ] || refuse "a $(ao_st_get "$_st" kind) routine for $_key is open: operator.sh verify $_key"
    op_verify "$_key"
  fi
  [ ! -f "$AO_STATE/switch/$_key" ] || refuse "a lane switch of $_key is open: lane.sh verify $_key"
  ao_explain "Archive the operator \"$_key\" ($R_NAME)" \
    "Its outgoing session writes a warm handoff; each of its worktrees becomes a" \
    "verified local git bundle in $(op_archive_dir)/$_key/ (nothing is pushed)," \
    "then the worktree and its $_key/* branches are removed; its registry row is" \
    "commented out last. Uncommitted work stops the routine (K-29)."
  ao_confirm "Archive $_key?" || refuse "not confirmed"
  printf 'kind=archive\nstarted=%s\n' "$AO_T_EPOCH" | ao_write_atomic "$_st" || ao_die "$AO_E_FAIL" "cannot write $_st"
  # shellcheck disable=SC2016 # backticks are Markdown in the note
  printf 'Operator archive (the Oracle, by operator.sh; automated, not from the human): %s is being archived.\nBefore anything else: write a warm HANDOFF.md in your home (state, open items, where things are), commit it, and take no new work.\n' \
    "$R_NAME" | ao_inbox_put "$_key" archive >/dev/null
  op_verify "$_key"
}

op_archive_dir() { ao_cfg_path archive_dir "$(dirname -- "$AO_HOME")/archive"; }

# op_bundle WT  Bundle a worktree's KEY/* branches, verify, then remove the
# worktree and those branches. Returns 1 (with a step line) when it cannot.
op_bundle() {
  _wt=$1 _repo=${1##*/}
  if [ -n "$(git -C "$_wt" status --porcelain 2>/dev/null)" ]; then
    ao_step TODO worktrees "$_wt has uncommitted work: commit it on its branch or move it, then verify again (K-29)"
    return 1
  fi
  # Ignored files are not in any bundle and `git worktree remove` deletes
  # them: the human decides what is churn (K-29).
  _ign=$(git -C "$_wt" status --porcelain --ignored 2>/dev/null | grep -c '^!!')
  if [ "${_ign:-0}" -gt 0 ]; then
    ao_step TODO worktrees "$_wt has $_ign ignored path(s) a bundle cannot keep (git -C $_wt status --ignored): move anything unique out and delete the rest yourself, then verify again (K-29)"
    return 1
  fi
  _main=$(git -C "$_wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || _main=
  _main=${_main%/.git}
  [ -n "$_main" ] || { ao_step TODO worktrees "$_wt: its main checkout was not found; archive it by hand"; return 1; }
  _head=$(git -C "$_wt" rev-parse --verify -q HEAD 2>/dev/null) || _head=''
  _refs=$(git -C "$_wt" for-each-ref --format='%(refname)' "refs/heads/$_key/" 2>/dev/null)
  # The worktree's HEAD must be in the bundle too (a detached or other
  # branch commit would otherwise be lost): when no KEY/* branch contains
  # it, it gets one of its own, bundled and removed with the rest.
  if [ -n "$_head" ]; then
    _in=''
    for _r in $_refs; do git -C "$_wt" merge-base --is-ancestor "$_head" "$_r" 2>/dev/null && { _in=1; break; }; done
    if [ -z "$_in" ]; then
      git -C "$_wt" branch "$_key/archived-head-$AO_T_STAMP" "$_head" >/dev/null 2>&1 ||
        { ao_step TODO worktrees "$_wt: cannot name its HEAD for the bundle; nothing removed"; return 1; }
      _refs="$_refs refs/heads/$_key/archived-head-$AO_T_STAMP"
    fi
  fi
  [ -n "$_refs" ] || { ao_step TODO worktrees "$_wt: nothing to bundle (no commit); archive it by hand"; return 1; }
  _ad=$(op_archive_dir)/$_key
  _b=$_ad/$_repo-$AO_T_STAMP.bundle
  mkdir -p "$_ad" || { ao_step TODO worktrees "cannot create $_ad"; return 1; }
  # shellcheck disable=SC2086 # ref names are git's, one word each
  if ! git -C "$_wt" bundle create "$_b" $_refs >/dev/null 2>&1 || ! git -C "$_main" bundle verify "$_b" >/dev/null 2>&1; then
    rm -f "$_b"
    ao_step TODO worktrees "$_wt: the bundle could not be written and verified; nothing removed"
    return 1
  fi
  for _r in $_refs; do
    git bundle list-heads "$_b" 2>/dev/null | grep -q " $_r\$" || { ao_step TODO worktrees "$_b lacks $_r; nothing removed"; return 1; }
  done
  if [ -n "$_head" ]; then
    # Prove HEAD is reachable from what the bundle carries before removing.
    _hok=''
    for _r in $_refs; do
      _t=$(git bundle list-heads "$_b" 2>/dev/null | awk -v r="$_r" '$2 == r { print $1; exit }')
      [ -n "$_t" ] && git -C "$_main" merge-base --is-ancestor "$_head" "$_t" 2>/dev/null && { _hok=1; break; }
    done
    [ -n "$_hok" ] || { ao_step TODO worktrees "$_b does not contain $_wt's HEAD; nothing removed"; return 1; }
  fi
  git -C "$_main" worktree remove "$_wt" >/dev/null 2>&1 || { ao_step TODO worktrees "$_wt: git worktree remove failed (bundle kept: $_b)"; return 1; }
  for _r in $_refs; do git -C "$_main" branch -D "${_r#refs/heads/}" >/dev/null 2>&1 || true; done
  ao_st_set "$_st" "bundle_$(ao_slug "$_repo")" "$_b"
  printf '      bundled %s -> %s (restore: git -C %s fetch %s "refs/heads/%s/*:refs/heads/%s/*")\n' "$_wt" "$_b" "$_main" "$_b" "$_key" "$_key"
}

op_verify_archive() {
  _since=$(ao_st_get "$_st" started)
  _hc=$(git -C "$R_DIR" log --since="@$_since" --format=%ct -1 -- HANDOFF.md 2>/dev/null)
  if [ -n "$_hc" ]; then ao_step PASS handoff "HANDOFF.md committed $(ao_utc "$_hc") UTC"
  elif op_marked handoff; then ao_step PASS handoff "cold: $(ao_st_get "$_st" done_handoff | cut -d ' ' -f 2-)"
  else ao_step WAIT handoff "no HANDOFF.md committed in $R_DIR yet (session gone? operator.sh mark $_key handoff --cold REASON)"; fi
  _wr=$(ao_cfg_path work_root "$HOME/src")/.worktrees/$_key
  if [ "$AO_STEPS_LEFT" -gt 0 ]; then
    ao_step WAIT worktrees "after the handoff"
  else
    _ok=1
    for _wt in "$_wr"/*; do
      [ -d "$_wt" ] || continue
      op_bundle "$_wt" || _ok=''
    done
    if [ -n "$_ok" ]; then
      rmdir "$_wr" 2>/dev/null || true
      ao_step PASS worktrees "none left ($(grep -c '^bundle_' "$_st" 2>/dev/null || echo 0) bundle(s) in $(op_archive_dir)/$_key)"
    fi
  fi
  _j=$AO_HOME/JOBS.tsv
  if [ -r "$_j" ] && awk -F'\t' -v k="$_key" -v s="$R_SID" '!/^#/ { for (i = 1; i <= NF; i++) if ($i == k || (s != "-" && s != "pending" && $i == s)) f = 1 } END { exit !f }' "$_j"; then
    ao_step TODO jobs "$_j still has rows naming $_key or its session: move or remove them"
  else
    ao_step PASS jobs "no timed job names $_key"
  fi
  if op_marked sidebar; then ao_step PASS sidebar "marked"
  elif [ "$R_CLIENT" = codex ]; then ao_step TODO sidebar "unpin and archive the Codex thread \"$R_NAME\", then: operator.sh mark $_key sidebar"
  else ao_step TODO sidebar "unpin the Claude session \"$R_NAME\" and move it to \"Inactive Operators\" (or archive it), then: operator.sh mark $_key sidebar"; fi
  if [ "$AO_STEPS_LEFT" -gt 0 ]; then
    ao_step WAIT registry "last, once every other step passes"
    return
  fi
  _tmp=$(ao_tmp registry)
  if ! awk -F'\t' -v k="$_key" -v t="$AO_T_ISO" '$1 == k { printf "#archived\t%s\t%s\n", t, $0; next } { print }' "$AO_REGISTRY" >"$_tmp" ||
    ! ao_write_atomic "$AO_REGISTRY" <"$_tmp"; then
    ao_die "$AO_E_FAIL" "cannot update $AO_REGISTRY"
  fi
  [ ! -d "$R_DIR" ] || ao_conf_set "$R_DIR/operator.conf" archived "$AO_T_DATE" || ao_warn "cannot mark $R_DIR/operator.conf archived"
  ao_git_commit "$R_DIR" "Archive operator $_key" operator.conf || ao_warn "could not commit $R_DIR"
  ao_git_commit "$AO_HOME" "Archive operator $_key" "$AO_REGISTRY" || ao_warn "could not commit $AO_HOME"
  ao_step PASS registry "row commented out as #archived; the relay, watchdog and reviews skip it"
}

# ---------------------------------------------------------------- model

op_model() {
  _key=${1-}
  shift || true
  op_key "$_key"
  op_row "$_key" || ao_die "$AO_E_USAGE" "no registry row for '$_key'"
  _c='' _m='' _e='' _w=''
  while [ $# -gt 0 ]; do
    case $1 in
      --client | --model | --effort | --words)
        [ $# -ge 2 ] || ao_die "$AO_E_USAGE" "$1 needs a value"
        case $1 in --client) _c=$2 ;; --model) _m=$2 ;; --effort) _e=$2 ;; --words) _w=$2 ;; esac
        shift ;;
      *) ao_die "$AO_E_USAGE" "unknown option '$1'" ;;
    esac
    shift
  done
  ao_is_client "$_c" || ao_die "$AO_E_USAGE" "--client must be claude or codex"
  ao_is_word "$_m" || ao_die "$AO_E_USAGE" "--model needs a model id"
  [ -z "$_e" ] || ao_is_effort "$_e" || ao_die "$AO_E_USAGE" "--effort must be a lowercase word"
  ao_is_line "$_w" || refuse "a model change is the owner's decision (K-26): quote their words on one line with --words"
  # An operator never changes its own model.
  if [ -n "${CODEX_THREAD_ID:-}" ] && [ "$CODEX_THREAD_ID" = "$R_SID" ]; then refuse "this is $_key's own thread: an operator never changes its own model"; fi
  if [ -n "${CLAUDECODE:-}" ]; then
    case $(pwd -P 2>/dev/null)/ in "$(CDPATH='' cd -- "$R_DIR" 2>/dev/null && pwd -P)"/*) refuse "this looks like $_key's own session (its home): an operator never changes its own model" ;; esac
  fi
  _st=$(op_state "$_key")
  [ ! -f "$_st" ] || refuse "a $(ao_st_get "$_st" kind) routine for $_key is open: operator.sh verify $_key"
  _conf=$R_DIR/operator.conf
  _was=$(ao_conf_get "$_conf" "model.$_c")
  ao_conf_set "$_conf" "model.$_c" "$_m" || ao_die "$AO_E_FAIL" "cannot write $_conf"
  [ -z "$_e" ] || ao_conf_set "$_conf" "effort.$_c" "$_e" || ao_die "$AO_E_FAIL" "cannot write $_conf"
  printf -- '- %s: the %s model of %s changes from %s to %s%s, on the owner'"'"'s word: "%s" (operator.sh model).\n' \
    "$AO_T_DATE" "$_c" "$_key" "${_was:-unset}" "$_m" "${_e:+ (effort $_e)}" "$_w" >>"$AO_HOME/JOURNAL.md" ||
    ao_die "$AO_E_FAIL" "cannot write $AO_HOME/JOURNAL.md"
  ao_git_commit "$R_DIR" "Model of $_key on $_c: $_m (owner's word)" operator.conf || ao_warn "could not commit $_conf"
  ao_git_commit "$AO_HOME" "Journal: model of $_key on $_c" JOURNAL.md || ao_warn "could not commit the journal"
  printf 'kind=model\nstarted=%s\nclient=%s\nmodel=%s\neffort=%s\n' "$AO_T_EPOCH" "$_c" "$_m" "$_e" |
    ao_write_atomic "$_st" || ao_die "$AO_E_FAIL" "cannot write $_st"
  op_verify "$_key"
}

op_verify_model() {
  _c=$(ao_st_get "$_st" client) _m=$(ao_st_get "$_st" model)
  ao_step PASS record "operator.conf and the journal (owner's words quoted)"
  if [ "$R_CLIENT" != "$_c" ]; then ao_step PASS apply "$_c is not the active side: the next session there is created with $_m"
  elif op_marked apply; then ao_step PASS apply "marked"
  else ao_step TODO apply "set the session's model to $_m with the app's own model setting, or create a new session with it and switch (lane.sh switch); never by a message to the thread. Then: operator.sh mark $_key apply"; fi
}

# ---------------------------------------------------------------- session

op_session() {
  _key=${1-} _id=${2-}
  shift 2 2>/dev/null || ao_die "$AO_E_USAGE" "usage: operator.sh session KEY ID [--client CLIENT]"
  _c=''
  if [ "${1-}" = --client ]; then
    ao_is_client "${2-}" || ao_die "$AO_E_USAGE" "--client must be claude or codex"
    _c=$2
  fi
  if ! ao_is_name "$_key" || ! ao_registry_has "$_key"; then ao_die "$AO_E_USAGE" "no registry row for '$_key'"; fi
  if ! ao_mr_addressable "$_id" || ! op_sid_set "$_id"; then ao_die "$AO_E_USAGE" "invalid session id '$_id'"; fi
  ao_lock registry || ao_die "$AO_E_BUSY" "the registry is being written; try again"
  # Checked under the lock, so two assignments cannot both pass.
  _other=$(awk -F'\t' -v k="$_key" -v s="$_id" '$1 !~ /^#/ && $1 != k && $4 == s { print $1; exit }' "$AO_REGISTRY")
  [ -z "$_other" ] || refuse "$_id already leads '$_other': one session per row"
  ao_registry_session "$_key" "$_id" "$_c" || ao_die "$AO_E_FAIL" "cannot write $AO_REGISTRY"
  ao_git_commit "$AO_HOME" "Session id for $_key" "$AO_REGISTRY" || ao_warn "could not commit $AO_REGISTRY"
  echo "recorded: $_key -> $_id${_c:+ ($_c)}"
}

# ---------------------------------------------------------------- recover

# op_rollout THREAD  The thread's newest rollout file, or nothing.
op_rollout() {
  _rr=${CODEX_HOME:-$HOME/.codex}/sessions
  [ -d "$_rr" ] && ao_is_name "$1" || return 0
  find "$_rr" -type f -name "rollout-*-$1.jsonl" 2>/dev/null | sort | tail -n 1
}

# op_size FILE  Byte size (0 when missing).
op_size() { if [ -f "$1" ]; then wc -c <"$1" | tr -d ' '; else echo 0; fi; }

# op_turned THREAD FROM  True when the thread's rollout has a turn-complete
# event after byte FROM.
op_turned() {
  _f=$(op_rollout "$1")
  [ -n "$_f" ] || return 1
  tail -c +"$(($2 + 1))" "$_f" 2>/dev/null | grep -q '"type":"task_complete"'
}

op_recover() {
  _key=${1-}
  shift || true
  op_key "$_key"
  op_row "$_key" || ao_die "$AO_E_USAGE" "no registry row for '$_key'"
  _new=''
  case ${1-} in
    --replaced) ao_codex_thread_addressable "${2-}" || ao_die "$AO_E_USAGE" "--replaced needs the new thread id"; _new=$2 ;;
    --auto | '') ;;
    *) ao_die "$AO_E_USAGE" "usage: operator.sh recover KEY [--replaced THREAD]" ;;
  esac
  _st=$(op_state "$_key")
  if [ ! -f "$_st" ]; then
    if [ "$R_CLIENT" != codex ] || ! op_sid_set "$R_SID"; then refuse "$_key does not run on a Codex thread"; fi
    printf 'kind=recover\nstarted=%s\nold=%s\n' "$AO_T_EPOCH" "$R_SID" | ao_write_atomic "$_st" || ao_die "$AO_E_FAIL" "cannot write $_st"
  fi
  [ "$(ao_st_get "$_st" kind)" = recover ] || refuse "a $(ao_st_get "$_st" kind) routine for $_key is open: operator.sh verify $_key"
  [ -z "$_new" ] || [ "$_new" != "$(ao_st_get "$_st" old)" ] || ao_die "$AO_E_USAGE" "--replaced must name a new thread"
  [ -z "$_new" ] || ao_st_set "$_st" new "$_new"
  op_verify "$_key"
}

# op_revive STEP  One revive attempt: send once, then pass on a new
# turn-complete event, fail after REVIVE_WAIT seconds or a refused send.
op_revive() {
  _s=$1 _at=$(ao_st_get "$_st" "${1}_at") _r=$(ao_st_get "$_st" "${1}_result")
  case $_r in ok) ao_step PASS "$_s" "the thread answered"; return 0 ;; fail*) ao_step FAIL "$_s" "${_r#fail }"; return 1 ;; esac
  if [ -z "$_at" ]; then
    _pos=$(op_size "$(op_rollout "$_old")")
    _msg=$(ao_tmp noop)
    printf '%s\n' "$NOOP" >"$_msg"
    if [ "$_s" = revive-queue ]; then
      _out=$(ao_tmp out)
      if (ao_role_load relay_codex codex >"$_out" 2>&1 && ao_role_deliver "$_old" "$_old" "$_msg" "$_out" "recover-$_key"); then :
      elif grep -q 'queue acceptance unconfirmed' "$_out" 2>/dev/null; then :
      else
        ao_st_set "$_st" "${_s}_result" "fail the CLI queue was refused: $(tr '\n' ' ' <"$_out" | cut -c 1-160)"
        ao_step FAIL "$_s" "the CLI queue was refused"
        return 1
      fi
    else
      ao_mr_init
      if [ "$AO_MR_ON" != on ] || ! ao_mr_watcher_up codex; then
        ao_st_set "$_st" "${_s}_result" "fail the Codex watcher is not armed (no native path)"
        ao_step FAIL "$_s" "the Codex watcher is not armed (no native path)"
        return 1
      fi
      { cat "$_msg"; printf 'doorbell-id: recover-%s-%s\n' "$_key" "$AO_T_STAMP"; } |
        ao_mr_ring codex "$_old" .doorbell steer >/dev/null || { ao_step FAIL "$_s" "cannot write the ring"; return 1; }
    fi
    ao_st_set "$_st" "${_s}_at" "$AO_T_EPOCH"
    ao_st_set "$_st" "${_s}_pos" "$_pos"
    ao_step WAIT "$_s" "no-op sent; waiting up to ${REVIVE_WAIT}s for a turn-complete event"
    return 2
  fi
  if op_turned "$_old" "$(ao_st_get "$_st" "${_s}_pos")"; then
    ao_st_set "$_st" "${_s}_result" ok
    ao_step PASS "$_s" "the thread answered"
    return 0
  fi
  if [ $((AO_T_EPOCH - _at)) -ge "$REVIVE_WAIT" ]; then
    ao_st_set "$_st" "${_s}_result" "fail no turn-complete event in ${REVIVE_WAIT}s"
    ao_step FAIL "$_s" "no turn-complete event in ${REVIVE_WAIT}s"
    return 1
  fi
  ao_step WAIT "$_s" "sent $((AO_T_EPOCH - _at))s ago; waiting for a turn-complete event"
  return 2
}

op_verify_recover() {
  _old=$(ao_st_get "$_st" old) _new=$(ao_st_get "$_st" new)
  _conf=$R_DIR/operator.conf
  printf 'Thread %s of %s: revive, else replace.\n' "$_old" "$_key"
  _revived=''
  if [ -z "$_new" ]; then
    op_revive revive-queue
    case $? in
      0) _revived=1 ;;
      2) return ;;
      *) op_revive revive-native
         case $? in 0) _revived=1 ;; 2) return ;; *) _revived='' ;; esac ;;
    esac
    if [ -n "$_revived" ]; then
      # A revive that works ends the routine; an earlier failed try is history.
      AO_STEPS_LEFT=0
      rm -f "$AO_STATE/mailroom/unhealthy/$_old"
      return
    fi
  fi
  _m=$(ao_conf_get "$_conf" model.codex) _e=$(ao_conf_get "$_conf" effort.codex)
  if [ -n "$_new" ]; then
    ao_step PASS replace "new thread $_new"
  else
    _do="in the Codex app, create a new thread in $R_DIR titled \"$R_NAME\" with model ${_m:-?}${_e:+ and effort $_e} chosen at creation; send it: \"You are $R_NAME. Read AGENTS.md, then HANDOFF.md if present, then NOTES.md.\" Then: operator.sh recover $_key --replaced <thread-id>"
    ao_step TODO replace "$_do"
    if [ -z "$(ao_st_get "$_st" asked)" ]; then
      ao_note_oracle "recover-$_key" "Codex thread recovery (operator.sh, automated, not from the human): the thread of $_key ($_old) did not answer a queued or a native no-op. Replace it: $_do" &&
        ao_st_set "$_st" asked "$AO_T_EPOCH"
    fi
  fi
  if op_marked archive-old; then ao_step PASS archive-old "marked"
  else ao_step TODO archive-old "archive the old thread $_old in the Codex app, then: operator.sh mark $_key archive-old"; fi
  if [ -z "$_new" ]; then ao_step WAIT switch "once the new thread is recorded"; return; fi
  if [ "$R_SID" = "$_new" ] && [ ! -f "$AO_STATE/switch/$_key" ]; then
    ao_step PASS switch "registry names $_new; lane switch closed"
    rm -f "$AO_STATE/mailroom/unhealthy/$_old"
    return
  fi
  if [ ! -f "$AO_STATE/switch/$_key" ]; then
    # lane.sh takes the same registry lock in its own process.
    ao_unlock
    if ! sh "$AO_SCRIPTS/lane.sh" switch "$_key" --to codex --session "$_new" </dev/null >"$_tmpo" 2>&1 ||
      ! sh "$AO_SCRIPTS/lane.sh" mark "$_key" handoff --cold "thread $_old unresponsive; replaced by operator.sh recover" </dev/null >>"$_tmpo" 2>&1; then
      ao_step TODO switch "lane.sh switch failed: $(tail -n 1 "$_tmpo")"
      return
    fi
  fi
  ao_step WAIT switch "finish the lane switch: lane.sh verify $_key"
}

# ---------------------------------------------------------------- verify, mark

op_verify() {
  _key=${1-}
  op_key "$_key"
  op_row "$_key" || ao_die "$AO_E_USAGE" "no registry row for '$_key'"
  _st=$(op_state "$_key")
  [ -f "$_st" ] || ao_die "$AO_E_USAGE" "no open routine for $_key"
  ao_lock registry || ao_die "$AO_E_BUSY" "the registry is being changed by another command; try again"
  _kind=$(ao_st_get "$_st" kind)
  _tmpo=$(ao_tmp out)
  AO_STEPS_LEFT=0
  printf '\n%s of %s (opened %s UTC):\n' "$_kind" "$_key" "$(ao_utc "$(ao_st_get "$_st" started)")"
  case $_kind in
    create) op_verify_create ;;
    archive) op_verify_archive ;;
    model) op_verify_model ;;
    recover) op_verify_recover ;;
    *) ao_die "$AO_E_FAIL" "unreadable routine $_st" ;;
  esac
  if [ "$AO_STEPS_LEFT" -gt 0 ]; then
    printf '%s step(s) left: operator.sh verify %s\n' "$AO_STEPS_LEFT" "$_key"
    exit "$AO_E_FAIL"
  fi
  _newsid=$(ao_st_get "$_st" new)
  mkdir -p "$AO_STATE/routine/done" && mv -f "$_st" "$AO_STATE/routine/done/$_key.$_kind.$AO_T_STAMP"
  if [ "$_kind" = recover ]; then
    # A resolve row tells the supervisor's thread check that the earlier
    # unknown sends to the old thread are settled.
    ao_mr_init
    ao_mr_row codex "$(ao_st_get "$AO_STATE/routine/done/$_key.$_kind.$AO_T_STAMP" old)--.recover-$AO_T_STAMP.md" none resolve ok 0 "${_newsid:+replaced}${_newsid:-revived}" ||
      ao_warn "could not record the recovery in the delivered log"
    ao_note_oracle "recovered-$_key" "Codex thread recovery (operator.sh, automated, not from the human): $_key answers again, on thread ${_newsid:-$R_SID}." ||
      ao_warn "could not write the recovery note"
  fi
  echo "$_kind of $_key complete."
}

OP_MARKS='title pin handoff sidebar apply archive-old'

op_mark() {
  _key=${1-} _step=${2-}
  op_key "$_key"
  shift 2 2>/dev/null || ao_die "$AO_E_USAGE" "usage: operator.sh mark KEY STEP [--cold REASON]"
  case " $OP_MARKS " in *" $_step "*) ;; *) ao_die "$AO_E_USAGE" "STEP must be one of: $OP_MARKS" ;; esac
  _note=-
  if [ "$_step" = handoff ]; then
    if [ "${1-}" != --cold ] || ! ao_is_line "${2-}"; then ao_die "$AO_E_USAGE" "handoff is read from git; mark it only as: operator.sh mark KEY handoff --cold REASON"; fi
    _note=$2
  fi
  _st=$(op_state "$_key")
  [ -f "$_st" ] || ao_die "$AO_E_USAGE" "no open routine for $_key"
  ao_st_set "$_st" "done_$_step" "$AO_T_EPOCH $_note"
  echo "marked $_step for $_key"
}

op_list() {
  _any=''
  for _f in "$AO_STATE/routine"/*; do
    [ -f "$_f" ] || continue
    _any=1
    printf '%s\t%s\topened %s UTC\n' "${_f##*/}" "$(ao_st_get "$_f" kind)" "$(ao_utc "$(ao_st_get "$_f" started)")"
  done
  [ -n "$_any" ] || echo "no open routines"
}

main() {
  _yes=''
  while :; do
    case ${1-} in
      -h | --help) ao_usage; exit 0 ;;
      --yes) _yes=1; shift ;;
      '') ao_usage; exit "$AO_E_USAGE" ;;
      *) break ;;
    esac
  done
  ao_guide_init "$_yes"
  cmd=$1
  shift
  if [ "$cmd" = switch ]; then exec sh "$AO_SCRIPTS/lane.sh" switch "$@"; fi
  ao_load
  case $cmd in
    create) op_create "$@" ;;
    archive) op_archive "$@" ;;
    model) op_model "$@" ;;
    session) op_session "$@" ;;
    recover) op_recover "$@" ;;
    verify) op_verify "$@" ;;
    mark) op_mark "$@" ;;
    list) op_list ;;
    *) ao_die "$AO_E_USAGE" "unknown command '$cmd' (see --help)" ;;
  esac
}

main "$@"
