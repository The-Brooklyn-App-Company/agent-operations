#!/bin/sh
# shellcheck disable=SC2016,SC2034
# (SC2016: single-quoted code is passed to other shells on purpose;
#  SC2034: rc and friends are read by the harness in lib.sh.)
# t_operator.sh - the pre-baked operator routines: create (models decided
# once, at creation), archive (worktrees to verified local bundles), the
# owner-only model change, session ids, and Codex thread recovery.
. "$(dirname -- "$0")/lib.sh"

reg() { cat "$T/home/operators/REGISTRY.tsv"; }

test_create_decides_models_once_and_walks_the_checklist() {
  run operator.sh --yes create web --name "Web Op" --client codex --embedded \
    --model-claude big-c --effort-claude high --model-codex big-x --effort-codex medium
  assert_rc 1
  conf=$T/home/operators/web/operator.conf
  assert_has "$conf" "model.codex=big-x"
  assert_has "$conf" "effort.codex=medium"
  assert_has "$conf" "model.claude=big-c"
  assert_has "$T/out" "PASS  home"
  assert_has "$T/out" "PASS  models        codex: big-x, effort medium"
  assert_has "$T/out" "TODO  session       create the codex session in $T/home/operators/web with model big-x and effort medium chosen at creation"
  assert_has "$T/out" "TODO  mandate"
  # One session per row; a free id is recorded.
  run operator.sh session web sid-alpha
  assert_rc 5
  run operator.sh session web thread-web
  assert_rc 0
  reg | grep -q "^web${TAB}Web Op${TAB}.*${TAB}thread-web${TAB}codex\$" || _fail "session not recorded"
  run operator.sh mark web title
  run operator.sh mark web pin
  sed 's/^What the human wants.*/Ship the web app./' "$T/home/operators/web/MANDATE.md" >"$T/m" && mv "$T/m" "$T/home/operators/web/MANDATE.md"
  run operator.sh verify web
  assert_rc 0
  assert_has "$T/out" "create of web complete."
  assert_no_file "$T/state/routine/web"
  # A second create of the same key does not open another routine.
  run operator.sh --yes create web --model-claude a --effort-claude b --model-codex c --effort-codex d
  assert_lacks "$T/out" "of web (opened"
}

test_create_without_a_model_decision_is_refused() {
  run operator.sh --yes create web --embedded --model-claude big-c --effort-claude high
  assert_rc 2
  assert_has "$T/err" "Codex model"
  assert_no_file "$T/home/operators/web"
}

test_model_change_needs_the_owners_words_and_never_the_operator_itself() {
  run operator.sh model alpha --client claude --model m2
  assert_rc 5
  assert_has "$T/err" "owner's decision"
  (cd "$T/proj/alpha" && CLAUDECODE=1 && export CLAUDECODE && run operator.sh model alpha --client claude --model m2 --words "use m2" && exit "$rc")
  rc=$?
  assert_rc 5
  run operator.sh model alpha --client claude --model m2 --effort high --words "use m2 for alpha from today"
  assert_rc 1
  assert_has "$T/proj/alpha/operator.conf" "model.claude=m2"
  assert_has "$T/home/JOURNAL.md" '"use m2 for alpha from today" (operator.sh model)'
  assert_has "$T/out" "TODO  apply"
  assert_has "$T/out" "never by a message to the thread"
  run operator.sh mark alpha apply
  run operator.sh verify alpha
  assert_rc 0
  # A change for the parked client passes by itself.
  run operator.sh model alpha --client codex --model x2 --words "codex side: x2"
  assert_rc 0
  assert_has "$T/out" "PASS  apply         codex is not the active side"
}

test_archive_bundles_worktrees_and_retires_the_row_last() {
  profile_set work_root "$T/src"
  mkdir -p "$T/src/app" && git -C "$T/src/app" init -q && git -C "$T/src/app" config user.email t@example.com &&
    git -C "$T/src/app" config user.name T && git -C "$T/src/app" commit -q --allow-empty -m init
  wt=$T/src/.worktrees/alpha/app
  git -C "$T/src/app" worktree add -q -b alpha/main "$wt" && git -C "$wt" commit -q --allow-empty -m "alpha work"
  head=$(git -C "$wt" rev-parse HEAD)
  run operator.sh --yes archive alpha
  assert_rc 1
  assert_has "$(ls "$T/home/inbox/alpha"/*archive.md)" "write a warm HANDOFF.md"
  assert_has "$T/out" "WAIT  handoff"
  assert_has "$T/out" "WAIT  registry"
  run operator.sh mark alpha handoff
  assert_rc 2
  run operator.sh mark alpha handoff --cold "session gone"
  # Uncommitted work stops it; nothing is removed.
  printf 'x\n' >"$wt/dirty.txt"
  run operator.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "has uncommitted work"
  assert_file "$wt/dirty.txt"
  rm "$wt/dirty.txt"
  run operator.sh verify alpha
  assert_rc 1
  b=$(ls "$T/archive/alpha"/app-*.bundle)
  assert_file "$b"
  git bundle list-heads "$b" | grep -q "^$head refs/heads/alpha/main\$" || _fail "bundle lacks alpha/main at $head"
  assert_no_file "$wt"
  git -C "$T/src/app" show-ref --verify --quiet refs/heads/alpha/main && _fail "branch alpha/main not removed"
  assert_has "$T/out" "PASS  worktrees"
  assert_has "$T/out" "TODO  sidebar"
  assert_has "$T/out" "Inactive Operators"
  reg | grep -q "^alpha${TAB}" || _fail "row retired before the last step"
  run operator.sh mark alpha sidebar
  run operator.sh verify alpha
  assert_rc 0
  reg | grep -q "^#archived${TAB}.*${TAB}alpha${TAB}Alpha Op" || _fail "row not commented out"
  assert_has "$T/proj/alpha/operator.conf" "archived="
  run lane.sh check
  assert_lacks "$T/out" "alpha"
}

test_archive_keeps_a_detached_head_in_the_bundle() {
  profile_set work_root "$T/src"
  mkdir -p "$T/src/app" && git -C "$T/src/app" init -q && git -C "$T/src/app" config user.email t@example.com &&
    git -C "$T/src/app" config user.name T && git -C "$T/src/app" commit -q --allow-empty -m init
  wt=$T/src/.worktrees/alpha/app
  git -C "$T/src/app" worktree add -q -b alpha/main "$wt" && git -C "$wt" checkout -q --detach &&
    git -C "$wt" commit -q --allow-empty -m "unique detached work"
  head=$(git -C "$wt" rev-parse HEAD)
  run operator.sh --yes archive alpha
  run operator.sh mark alpha handoff --cold "gone"
  # Ignored files are in no bundle: the human decides, nothing is removed.
  printf 'build/\n' >>"$T/src/app/.git/info/exclude"
  mkdir -p "$wt/build" && printf 'unique\n' >"$wt/build/out.txt"
  run operator.sh verify alpha
  assert_rc 1
  assert_has "$T/out" "ignored path(s)"
  assert_file "$wt/build/out.txt"
  rm -rf "$wt/build"
  run operator.sh verify alpha
  assert_no_file "$wt"
  b=$(ls "$T/archive/alpha"/app-*.bundle)
  git bundle list-heads "$b" | grep -q "^$head refs/heads/alpha/archived-head-" || _fail "the detached HEAD is not in the bundle"
  git -C "$T/src/app" branch --list 'alpha/*' | grep -q . && _fail "archive branches left behind"
}

# ------------------------------------------------------------ thread recovery

rollout() {
  mkdir -p "$T/codex/sessions/2026/11/19"
  ROLLOUT=$T/codex/sessions/2026/11/19/rollout-2026-11-19T00-00-00-$1.jsonl
  printf '{"type":"session_meta"}\n' >>"$ROLLOUT"
}
turn_complete() { printf '{"type":"event_msg","payload":{"type":"task_complete"}}\n' >>"$ROLLOUT"; }
row() { # RING STATUS AGE
  mkdir -p "$MR/codex/delivered"
  _e=$(($(date +%s) - $3))
  printf '2026-11-19T00:00:00Z\t%s\t%s\tt1-native\tsteer\t%s\t10\t-\n' "$_e" "$1" "$2" >>"$MR/codex/delivered/log.tsv"
}
gamma() {
  profile_set relay_bridge on
  MR=$T/home/inbox/.mailroom
  printf 'gamma\tGamma Op\t%s\tthread-gamma\tcodex\n' "$T/proj/beta" >>"$T/home/operators/REGISTRY.tsv"
  printf 'model.codex=big-x\neffort.codex=high\n' >"$T/proj/beta/operator.conf"
  rollout thread-gamma
}

test_an_unresponsive_thread_is_detected_and_revived() {
  gamma
  row thread-gamma--gamma-1--steer.md unknown 300
  row thread-other--o-1--steer.md ok 250
  row thread-gamma--gamma-2--steer.md unknown 200
  run mailroom.sh supervise
  assert_file "$T/state/mailroom/unhealthy/thread-gamma"
  assert_file "$T/state/routine/gamma"
  ls "$T/home/inbox/oracle"/*mailroom-thread-gamma* >/dev/null 2>&1 || _fail "no thread alarm"
  assert_has "$FAKE_LOG" "arg: queue"
  assert_has "$FAKE_LOG" "arg: thread-gamma"
  assert_has "$FAKE_LOG" "Recovery check"
  # Once only: the next pass opens nothing new and sends no second no-op.
  n=$(grep -c 'arg: queue' "$FAKE_LOG")
  run mailroom.sh supervise
  assert_eq "$(grep -c 'arg: queue' "$FAKE_LOG")" "$n" "one queued no-op"
  # The thread answers: the routine closes and the mark clears.
  turn_complete
  run operator.sh verify gamma
  assert_rc 0
  assert_has "$T/out" "PASS  revive-queue  the thread answered"
  assert_has "$T/out" "recover of gamma complete."
  assert_no_file "$T/state/mailroom/unhealthy/thread-gamma"
  assert_has "$MR/codex/delivered/log.tsv" "${TAB}none${TAB}resolve${TAB}ok${TAB}0${TAB}revived"
  run mailroom.sh supervise
  assert_no_file "$T/state/mailroom/unhealthy/thread-gamma"
  assert_no_file "$T/state/routine/gamma"
}

test_a_dead_thread_is_replaced_and_the_lane_switched() {
  gamma
  run operator.sh recover gamma
  assert_rc 1
  assert_has "$T/out" "WAIT  revive-queue"
  # No answer within 3 minutes; the native path needs an armed watcher.
  AO_NOW=$(($(date +%s) + 200))
  export AO_NOW
  run operator.sh verify gamma
  assert_rc 1
  assert_has "$T/out" "FAIL  revive-queue  no turn-complete event"
  assert_has "$T/out" "FAIL  revive-native the Codex watcher is not armed"
  assert_has "$T/out" "TODO  replace       in the Codex app, create a new thread in $T/proj/beta titled \"Gamma Op\" with model big-x and effort high chosen at creation"
  ls "$T/home/inbox/oracle"/*recover-gamma* >/dev/null 2>&1 || _fail "no replace request to the Oracle"
  run operator.sh recover gamma --replaced thread-gamma
  assert_rc 2
  run operator.sh recover gamma --replaced thread-new
  assert_rc 1
  assert_has "$T/out" "PASS  replace       new thread thread-new"
  assert_has "$T/out" "WAIT  switch        finish the lane switch: lane.sh verify gamma"
  assert_has "$T/state/switch/gamma" "to_sid=thread-new"
  assert_has "$T/state/switch/gamma" "done_handoff="
  run operator.sh mark gamma archive-old
  # The lane switch finishes (its own tests walk every step).
  mv "$T/state/switch/gamma" "$T/state/gamma.closed"
  run operator.sh session gamma thread-new
  run operator.sh verify gamma
  assert_rc 0
  assert_has "$T/out" "PASS  switch        registry names thread-new"
}

ao_test_main "$0"
