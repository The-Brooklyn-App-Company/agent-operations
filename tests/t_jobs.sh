#!/bin/sh
# shellcheck disable=SC2034
# t_jobs.sh - schedule inventory and advisory cutover plans; no native calls.
. "$(dirname -- "$0")/lib.sh"

job() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >>"$T/jobs"; }
jsetup() {
  : >"$T/jobs"
  job z-old ws claude weekly strong enabled enabled native-old review
  job a-new ws codex weekly small enabled disabled native-new review
  job p-old ws claude daily small paused disabled pause-old pause
  job p-new ws codex daily small paused disabled pause-new pause
  job timer ws neutral 'every 10 minutes' none enabled enabled timer -
  job other other codex daily small enabled enabled other-native -
}
reject() {
  run jobs.sh "$@"
  assert_rc 2
  assert_eq "$(cat "$T/out")" '' 'no partial plan'
}

test_jobs_template_validates() {
  run jobs.sh check "$SCRIPTS/../templates/oracle/JOBS.tsv"
  assert_rc 0
  assert_eq "$(cat "$T/out")" ''
}

test_jobs_plan_orders_disables_before_enables() {
  jsetup
  cp "$T/jobs" "$T/before"
  run jobs.sh plan "$T/jobs" ws codex
  assert_rc 0
  assert_eq "$(sed -n '2p' "$T/out")" "disable${TAB}z-old${TAB}ws${TAB}claude${TAB}native-old${TAB}enabled${TAB}disabled${TAB}inactive-peer"
  assert_eq "$(sed -n '3p' "$T/out")" "enable${TAB}a-new${TAB}ws${TAB}codex${TAB}native-new${TAB}disabled${TAB}enabled${TAB}target"
  assert_has "$T/out" "nochange${TAB}p-new${TAB}ws${TAB}codex${TAB}pause-new${TAB}disabled${TAB}disabled${TAB}paused"
  assert_has "$T/out" "nochange${TAB}timer${TAB}ws${TAB}neutral${TAB}timer${TAB}enabled${TAB}enabled${TAB}neutral"
  assert_lacks "$T/out" other-native
  assert_eq "$(cksum <"$T/jobs")" "$(cksum <"$T/before")" 'registry unchanged'
  assert_no_file "$FAKE_LOG"
  cp "$T/out" "$T/plan"
  # Physical row order must not affect the returned plan.
  awk '{ line[NR]=$0 } END { for(i=NR;i>0;i--) print line[i] }' "$T/jobs" >"$T/reversed"
  run jobs.sh plan "$T/reversed" ws codex
  assert_rc 0
  assert_eq "$(cat "$T/out")" "$(cat "$T/plan")" 'deterministic plan'
}

test_jobs_same_side_is_idempotent() {
  jsetup
  run jobs.sh plan "$T/jobs" ws claude
  assert_rc 0
  assert_lacks "$T/out" "enable${TAB}"
  assert_lacks "$T/out" "disable${TAB}"
  assert_has "$T/out" "nochange${TAB}z-old"
}

test_jobs_single_subscription_is_explicit() {
  : >"$T/jobs"
  job single ws claude weekly small enabled enabled one -
  run jobs.sh plan "$T/jobs" ws claude
  assert_rc 0
  assert_has "$T/out" "nochange${TAB}single"
  reject plan "$T/jobs" ws codex
  assert_has "$T/err" 'blocked: enabled standalone job has no target peer: single'
  : >"$T/jobs"
  job single ws claude weekly small paused disabled one -
  run jobs.sh plan "$T/jobs" ws codex
  assert_rc 0
  assert_has "$T/out" "disabled${TAB}disabled${TAB}paused"
  : >"$T/jobs"
  job single ws claude weekly small enabled disabled one -
  run jobs.sh plan "$T/jobs" ws codex
  assert_rc 0
  assert_has "$T/out" standalone-other-side
}

test_jobs_paused_intent_is_not_inactive_peer() {
  jsetup
  # Explicitly pausing a running group plans disable, never enables its peer.
  sed 's/weekly\tstrong\tenabled/weekly\tstrong\tpaused/;s/weekly\tsmall\tenabled/weekly\tsmall\tpaused/' "$T/jobs" >"$T/paused"
  run jobs.sh plan "$T/paused" ws codex
  assert_rc 0
  assert_has "$T/out" "disable${TAB}z-old${TAB}ws${TAB}claude${TAB}native-old${TAB}enabled${TAB}disabled${TAB}paused"
  assert_lacks "$T/out" "enable${TAB}"
  # A provider switch does not reconcile even a neutral timer with paused intent.
  : >"$T/jobs"
  job timer ws neutral daily none paused enabled timer -
  run jobs.sh plan "$T/jobs" ws codex
  assert_rc 0
  assert_has "$T/out" "enabled${TAB}enabled${TAB}neutral"
}

test_jobs_unknown_states_and_partial_rows_fail_closed() {
  jsetup
  job last ws neutral daily none enabled unknown last -
  reject plan "$T/jobs" ws codex
  assert_has "$T/err" 'unknown enabled state'
  reject check "$T/jobs"
  jsetup
  printf 'short\trow\n' >>"$T/jobs"
  reject plan "$T/jobs" ws codex
  assert_has "$T/err" 'expected nine TSV fields'
  jsetup
  printf 'last\tws\tneutral\tdaily\t\tenabled\tdisabled\tlast\t-\n' >>"$T/jobs"
  reject check "$T/jobs"
  assert_has "$T/err" 'empty or control field'
}

test_jobs_duplicate_identifiers_and_bindings_rejected() {
  jsetup
  job timer another neutral daily none enabled disabled another -
  reject check "$T/jobs"
  assert_has "$T/err" 'duplicate job_id'
  jsetup
  job new another neutral daily none enabled disabled timer -
  reject plan "$T/jobs" ws codex
  assert_has "$T/err" 'duplicate binding'
}

test_jobs_mirrors_require_one_peer_each() {
  : >"$T/jobs"
  job old ws claude weekly small enabled enabled old review
  reject plan "$T/jobs" ws codex
  assert_has "$T/err" 'requires one claude and one codex'
  job duplicate ws claude weekly small enabled disabled dup review
  reject check "$T/jobs"
  assert_has "$T/err" 'duplicate side'
  : >"$T/jobs"
  job timer ws neutral weekly none enabled disabled timer review
  reject check "$T/jobs"
  assert_has "$T/err" 'neutral job cannot be mirrored'
}

test_jobs_mirror_disagreements_and_dual_enabled_rejected() {
  for field in owner cadence desired enabled; do
    : >"$T/jobs"
    job old ws claude weekly strong enabled enabled old review
    case $field in
      owner) job new other codex weekly small enabled disabled new review ;;
      cadence) job new ws codex daily small enabled disabled new review ;;
      desired) job new ws codex weekly small paused disabled new review ;;
      enabled) job new ws codex weekly small enabled enabled new review ;;
    esac
    reject plan "$T/jobs" ws codex
    case $field in
      enabled) assert_has "$T/err" 'both mirror peers enabled' ;;
      *) assert_has "$T/err" 'mirror owner, cadence or desired mismatch' ;;
    esac
  done
}

test_jobs_numeric_owners_are_literal() {
  : >"$T/jobs"
  job selected 01 neutral daily none enabled enabled selected-binding -
  job unrelated 1 neutral daily none enabled enabled unrelated-binding -
  run jobs.sh plan "$T/jobs" 01 codex
  assert_rc 0
  assert_has "$T/out" "nochange${TAB}selected${TAB}01${TAB}"
  assert_lacks "$T/out" unrelated-binding
  run jobs.sh plan "$T/jobs" 1 codex
  assert_rc 0
  assert_has "$T/out" "nochange${TAB}unrelated${TAB}1${TAB}"
  assert_lacks "$T/out" selected-binding
  # Another numeric-looking owner must neither block nor satisfy this owner.
  job foreign 1 claude daily small enabled enabled foreign-binding -
  run jobs.sh plan "$T/jobs" 01 codex
  assert_rc 0
  assert_lacks "$T/out" foreign-binding
  reject plan "$T/jobs" 001 codex
  assert_has "$T/err" 'unknown owner 001'
}

test_jobs_numeric_mirror_fields_are_literal() {
  for field in owner cadence; do
    : >"$T/jobs"
    case $field in
      owner)
        job old 01 claude weekly strong enabled enabled old review
        job new 1 codex weekly small enabled disabled new review ;;
      cadence)
        job old ws claude 01 strong enabled enabled old review
        job new ws codex 1 small enabled disabled new review ;;
    esac
    reject check "$T/jobs"
    assert_has "$T/err" 'mirror owner, cadence or desired mismatch'
  done
  : >"$T/jobs"
  job old 01 claude 01 strong enabled enabled old review
  job new 01 codex 01 small enabled disabled new review
  run jobs.sh plan "$T/jobs" 01 codex
  assert_rc 0
  assert_has "$T/out" "disable${TAB}old${TAB}01${TAB}"
  assert_has "$T/out" "enable${TAB}new${TAB}01${TAB}"
}

test_jobs_invalid_tokens_and_controls_rejected() {
  for field in side desired model binding cadence; do
    : >"$T/jobs"
    case $field in
      side) job one ws other daily small enabled disabled native - ;;
      desired) job one ws codex daily small maybe disabled native - ;;
      model) job one ws codex daily 'bad model' enabled disabled native - ;;
      binding) job one ws codex daily small enabled disabled - - ;;
      cadence) job one ws codex '   ' small enabled disabled native - ;;
    esac
    reject check "$T/jobs"
  done
  : >"$T/jobs"
  job one ws neutral "$(printf 'daily\r')" none enabled disabled native -
  reject check "$T/jobs"
  assert_has "$T/err" 'control field'
}

test_jobs_limits_and_unterminated_line() {
  : >"$T/jobs"
  awk 'BEGIN { for(i=1;i<=1025;i++) printf "job%s\tws\tneutral\tdaily\tnone\tenabled\tdisabled\tb%s\t-\n",i,i }' >"$T/jobs"
  reject plan "$T/jobs" ws codex
  assert_has "$T/err" 'exceeds 1024 jobs'
  awk 'BEGIN { printf "#"; for(i=1;i<=2048;i++) printf "x"; printf "\n" }' >"$T/jobs"
  reject check "$T/jobs"
  assert_has "$T/err" 'exceeds 2048 bytes'
  printf 'single\tws\tcodex\tdaily\tsmall\tenabled\tdisabled\tnative\t-' >"$T/jobs"
  run jobs.sh plan "$T/jobs" ws codex
  assert_rc 0
  assert_has "$T/out" "enable${TAB}single"
}

test_jobs_usage_and_no_apply() {
  jsetup
  reject plan "$T/jobs" missing codex
  assert_has "$T/err" 'unknown owner'
  reject plan "$T/jobs" ws other
  reject plan "$T/jobs" 'bad owner' codex
  reject apply "$T/jobs" ws codex
  reject check "$T/jobs" unexpected
  run jobs.sh check "$T/missing"
  assert_rc 1
  run jobs.sh check "$T"
  assert_rc 1
  run jobs.sh --help
  assert_rc 0
  assert_has "$T/out" 'No apply verb or native adapters are shipped.'
  assert_no_file "$FAKE_LOG"
}

ao_test_main "$0"
