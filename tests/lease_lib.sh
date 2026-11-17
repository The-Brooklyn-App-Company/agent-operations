# shellcheck shell=sh disable=SC2034
# lease_lib.sh - helpers for the EXPERIMENTAL lease, mail and ask tests.
# Sourced after lib.sh. Every test calls lsetup first: it clears agent
# environment markers inherited from whatever runs the suite, gives git a
# sandboxed identity, makes the Oracle home a git repo with a lease-able
# operator.conf, and creates operator homes:
#   $T/ops/ws    key ws, "Workshop" (registry row, git repo, .operator/)
#   $T/work/app  a work repo the ws operator owns (for cold notes)

lsetup() {
  unset CLAUDECODE CLAUDE_PID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID CODEX_SANDBOX \
    CODEX_SESSION_ID AO_OPERATOR_HOME AO_TEST_CRASH_AT GIT_DIR GIT_WORK_TREE
  GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=tester@example.invalid
  GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=tester@example.invalid
  export GIT_CONFIG_NOSYSTEM GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  printf '[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n' >"$T/user/.gitconfig"
  profile_set work_root "$T/work"
  # The Oracle home: same layout and lease as an operator.
  printf 'key=oracle\nsession.claude=Oracle\n' >"$T/home/operator.conf"
  printf '.operator/\ninbox/\n' >"$T/home/.gitignore"
  git_init "$T/home"
  "$AO_TEST_SHELL" "$SCRIPTS/lease.sh" --home "$T/home" init >/dev/null 2>&1
  mkhome ws Workshop
  mkdir -p "$T/work/app"
  git_init "$T/work/app"
}

git_init() {
  git -C "$1" init -q && git -C "$1" add -A && git -C "$1" commit -q -m init --allow-empty
}

# mkhome KEY NAME  An operator home with a registry row.
mkhome() {
  _h=$T/ops/$1
  mkdir -p "$_h"
  printf 'key=%s\nsession.claude=%s\nsession.codex=ops-%s\nwork.app=git@host:org/app.git|owner\n' "$1" "$2" "$1" >"$_h/operator.conf"
  printf '.operator/\n' >"$_h/.gitignore"
  git_init "$_h"
  "$AO_TEST_SHELL" "$SCRIPTS/lease.sh" --home "$_h" init >/dev/null 2>&1
  printf '%s\t%s\t%s\t-\n' "$1" "$2" "$_h" >>"$T/home/operators/REGISTRY.tsv"
}

# lease ARG...  lease.sh in the ws home.
lease() { run lease.sh --home "$T/ops/ws" "$@"; }

# acq PROVIDER SESSION [HOME]  Acquire; sets TOK and EP.
acq() {
  run lease.sh --home "${3:-$T/ops/ws}" acquire --provider "$1" --session "$2"
  TOK=$(sed -n 's/^instance: //p' "$T/out")
  EP=$(sed -n 's/^epoch: //p' "$T/out")
}

# holder_args  The current token pair, as words.
lget() { sed -n "s/^$1=//p" "${2:-$T/ops/ws}/.operator/lease"; }

# with_tty INPUT SCRIPT ARG...  Run a kit script on a pseudo-terminal and
# type INPUT at its prompt (BSD script(1); util-linux script uses -c).
# Arguments must not contain spaces. Sets rc and $T/out (stderr included).
with_tty() {
  _in=$1
  shift
  _s=$1
  shift
  if script -q /dev/null true </dev/null >/dev/null 2>&1; then
    (sleep 1; printf '%s\n' "$_in"; sleep 3) |
      script -q /dev/null "$AO_TEST_SHELL" "$SCRIPTS/$_s" "$@" >"$T/out" 2>&1
    rc=$?
  else
    (sleep 1; printf '%s\n' "$_in"; sleep 3) |
      script -qec "$AO_TEST_SHELL $SCRIPTS/$_s $*" /dev/null >"$T/out" 2>&1
    rc=$?
  fi
  tr -d '\r' <"$T/out" >"$T/out.n" && mv "$T/out.n" "$T/out"
}

# old_lock DIR  Fake a lease lock left 1 minute ago by a dead process.
old_lock() {
  mkdir -p "$1/.operator/lease.lock"
  echo 999999 >"$1/.operator/lease.lock/pid"
  touch -t "$(date -r $(($(date +%s) - 60)) +%Y%m%d%H%M.%S 2>/dev/null || date -d @$(($(date +%s) - 60)) +%Y%m%d%H%M.%S)" "$1/.operator/lease.lock"
}

# srun SCRIPT ARG...  As run, but stdin is passed through (for piped input).
srun() {
  _s=$1
  shift
  "$AO_TEST_SHELL" "$SCRIPTS/$_s" "$@" >"$T/out" 2>"$T/err"
  rc=$?
}
