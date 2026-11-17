# shellcheck shell=sh disable=SC2034
# (SC2034: the globals below are read by the test files.)
# lib.sh - tiny test harness for the kit's shell scripts. Sourced by each
# tests/t_*.sh file, which defines test_* functions and ends with
# `ao_test_main "$0"`. Each test runs in a subshell with a fresh sandbox:
#   $T            sandbox root (removed afterwards)
#   $T/home       the Oracle home (registry, inbox, hooks)
#   $T/state      state_dir
#   $T/bin        fake claude, codex and agent CLIs (first on PATH)
#   $FAKE_LOG     what the fakes were called with
# HOME, CLAUDE_CONFIG_DIR and CODEX_HOME point into the sandbox, so tests
# never read or write the real user's files. Scripts run under
# $AO_TEST_SHELL (default: sh).

TESTS_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SCRIPTS=$(CDPATH='' cd -- "$TESTS_DIR/../scripts" && pwd)
AO_TEST_SHELL=${AO_TEST_SHELL:-sh}
TAB=$(printf '\t')

ao_test_setup() {
  T=$(mktemp -d "${TMPDIR:-/tmp}/aotest.XXXXXX") && T=$(cd "$T" && pwd -P)
  mkdir -p "$T/bin" "$T/home/operators" "$T/home/inbox" "$T/state" \
    "$T/claude/projects" "$T/codex/sessions" "$T/proj/alpha" "$T/proj/beta" "$T/user"
  for _n in claude codex agent; do
    cp "$TESTS_DIR/fakes/fake-agent" "$T/bin/$_n"
    chmod +x "$T/bin/$_n"
  done
  PATH="$T/bin:$PATH" HOME=$T/user CLAUDE_CONFIG_DIR=$T/claude CODEX_HOME=$T/codex
  AO_PROFILE=$T/profile FAKE_LOG=$T/fake.log
  export PATH HOME CLAUDE_CONFIG_DIR CODEX_HOME AO_PROFILE FAKE_LOG
  unset XDG_CONFIG_HOME XDG_STATE_HOME AO_NOW FAKE_MODE FAKE_OUTPUT AO_TIMEOUT_BIN AO_PRIVACY_DENYLIST
  cat >"$T/profile" <<EOF
oracle_home=$T/home
state_dir=$T/state
relay_claude_model=haiku
relay_claude_max_turns=4
worker_client=codex
worker_model=small-model
worker_mcp_disable=trade,ui
reviewer_client=codex
reviewer_model=big-model
reviewer_effort=high
EOF
  {
    printf '# key\tname\tdir\tsession\n'
    printf 'oracle\tOracle\t%s\tsid-oracle\n' "$T/home"
    printf 'alpha\tAlpha Op\t%s\tsid-alpha\n' "$T/proj/alpha"
    printf 'beta\tBeta Op\t%s\tsid-beta\n' "$T/proj/beta"
  } >"$T/home/operators/REGISTRY.tsv"
}

# profile_set KEY VALUE  Append (later lines win).
profile_set() { printf '%s=%s\n' "$1" "$2" >>"$T/profile"; }

# note KEY NAME TEXT  Drop a note into an inbox.
note() {
  mkdir -p "$T/home/inbox/$1"
  printf '%s\n' "$3" >"$T/home/inbox/$1/$2"
}

# run SCRIPT ARG...  Run a kit script; sets $rc, $T/out, $T/err.
run() {
  _s=$1
  shift
  "$AO_TEST_SHELL" "$SCRIPTS/$_s" "$@" </dev/null >"$T/out" 2>"$T/err"
  rc=$?
}

# epoch_of "YYYY-MM-DD HH:MM"  Local time to epoch seconds (BSD or GNU).
epoch_of() {
  date -j -f '%Y-%m-%d %H:%M:%S' "$1:00" +%s 2>/dev/null || date -d "$1" +%s
}

# transcript KEY_DIR STAMP  Fake a Claude transcript for a project dir with
# mtime STAMP (touch -t format, e.g. 202611170900).
transcript() {
  _slug=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')
  mkdir -p "$T/claude/projects/$_slug"
  : >"$T/claude/projects/$_slug/0000-test.jsonl"
  touch -t "$2" "$T/claude/projects/$_slug/0000-test.jsonl"
}

count_files() {
  set -- "$1"/*
  if [ -e "$1" ]; then echo $#; else echo 0; fi
}

_fail() {
  printf '    %s\n' "$*"
  _failed=1
}
assert_eq() { [ "$1" = "$2" ] || _fail "${3:-assert_eq}: expected '$2', got '$1'"; }
assert_rc() { [ "$rc" = "$1" ] || _fail "exit code: expected $1, got $rc; stderr: $(head -c 400 "$T/err")"; }
assert_has() { grep -qF -- "$2" "$1" 2>/dev/null || _fail "$1 lacks: $2"; }
assert_lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null || _fail "$1 unexpectedly has: $2"; }
assert_file() { [ -e "$1" ] || _fail "missing file: $1"; }
assert_no_file() { [ ! -e "$1" ] || _fail "unexpected file: $1"; }
assert_count() { assert_eq "$(count_files "$1")" "$2" "files in ${1#"$T"/}"; }

ao_test_main() {
  _pass=0 _nfail=0
  _list=$(sed -n 's/^\(test_[a-z0-9_]*\)().*/\1/p' "$1")
  for _t in $_list; do
    if (
      ao_test_setup
      _failed=0
      "$_t"
      _r=$_failed
      rm -rf "$T"
      exit "$_r"
    ); then
      _pass=$((_pass + 1))
      printf 'ok     %s\n' "$_t"
    else
      _nfail=$((_nfail + 1))
      printf 'FAIL   %s\n' "$_t"
    fi
  done
  printf '%s: %s passed, %s failed (shell: %s)\n' "${1##*/}" "$_pass" "$_nfail" "$AO_TEST_SHELL"
  [ "$_nfail" -eq 0 ]
}
