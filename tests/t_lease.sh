#!/bin/sh
# shellcheck disable=SC2034,SC2016
# (SC2034: rc and friends are read by the harness in lib.sh; SC2016:
#  backticks and $(...) in single quotes are literal on purpose.)
# t_lease.sh - EXPERIMENTAL lease: acquire, renew, markers, release,
# takeover, locks, routing and the switch-in audit.
. "$(dirname -- "$0")/lib.sh"
. "$(dirname -- "$0")/lease_lib.sh"

test_acquire_prints_token_once_and_hides_it() {
  lsetup
  acq claude Workshop
  assert_rc 0
  assert_eq "$EP" 1
  [ ${#TOK} -eq 32 ] || _fail "token: '$TOK'"
  assert_lacks "$T/ops/ws/.operator/lease" "$TOK"
  assert_eq "$(lget state)" held
  assert_eq "$(lget provider)" claude
  # Replay by the holder: same epoch, no new token.
  lease acquire --provider claude --session Workshop --instance "$TOK"
  assert_rc 0
  assert_has "$T/out" "epoch: 1"
  assert_lacks "$T/out" "instance:"
  # Anyone else is refused and told who holds it.
  lease acquire --provider codex --session ops-ws
  assert_rc 5
  assert_has "$T/err" 'held by claude `Workshop`'
}

test_renew_and_check_need_token_and_epoch() {
  lsetup
  acq claude Workshop
  lease renew --instance "$TOK" --epoch "$EP"
  assert_rc 0
  lease check --instance "$TOK" --epoch "$EP"
  assert_rc 0
  lease check --instance "$TOK" --epoch 2
  assert_rc 5
  lease renew --instance deadbeef --epoch "$EP"
  assert_rc 5
  assert_has "$T/err" "You are the standby"
  # A name match is never enough.
  lease renew --instance Workshop --epoch "$EP"
  assert_rc 5
}

test_two_holders_cannot_both_acquire() {
  lsetup
  for round in 1 2 3 4 5; do
    rm -f "$T/ops/ws/.operator/lease"
    "$AO_TEST_SHELL" "$SCRIPTS/lease.sh" --home "$T/ops/ws" acquire --provider claude --session A >"$T/a.out" 2>"$T/a.err" &
    pa=$!
    "$AO_TEST_SHELL" "$SCRIPTS/lease.sh" --home "$T/ops/ws" acquire --provider codex --session B >"$T/b.out" 2>"$T/b.err" &
    pb=$!
    wait "$pa"
    ra=$?
    wait "$pb"
    rb=$?
    # Count tokens, not just files containing one. A successful contender
    # must be the final holder; a refusal must publish no acquisition.
    na=$(grep -c '^instance: ' "$T/a.out")
    nb=$(grep -c '^instance: ' "$T/b.out")
    assert_eq "$((na + nb))" 1 "round $round tokens (A=$ra, B=$rb)"
    case "$ra:$rb" in
      0:5) winner=a loser=b provider=claude session=A ;;
      5:0) winner=b loser=a provider=codex session=B ;;
      *) _fail "round $round exit codes A=$ra B=$rb; A stderr: $(cat "$T/a.err"); B stderr: $(cat "$T/b.err")"; continue ;;
    esac
    assert_eq "$(cat "$T/$loser.out")" '' "round $round loser stdout"
    assert_has "$T/$loser.err" "held by $provider"
    assert_eq "$(cat "$T/$winner.err")" '' "round $round winner stderr"
    assert_eq "$(lget state)" held "round $round lease state"
    assert_eq "$(lget provider)" "$provider" "round $round lease provider"
    assert_eq "$(lget session)" "$session" "round $round lease session"
    token=$(sed -n 's/^instance: //p' "$T/$winner.out")
    epoch=$(sed -n 's/^epoch: //p' "$T/$winner.out")
    assert_eq "$epoch" 1 "round $round epoch"
    lease check --instance "$token" --epoch "$epoch"
    assert_rc 0
    assert_no_file "$T/ops/ws/.operator/lease.lock"
    assert_no_file "$T/ops/ws/.operator/lease.guard"
  done
}


test_acquire_retries_a_guard_removed_after_contention() {
  lsetup
  acq claude Workshop
  cp "$T/ops/ws/.operator/lease" "$T/baseline"
  GUARD_RACE_PATH=$T/ops/ws/.operator/lease.guard
  GUARD_RACE_ONCE=$T/guard-race-injected
  export GUARD_RACE_PATH GUARD_RACE_ONCE
  # Model an owner removing its guard after a contender's mkdir failed,
  # before that contender can inspect the directory. All other I/O is real.
  cat >"$T/bin/mkdir" <<'MKDIR'
#!/bin/sh
if [ "$#" -eq 1 ] && [ "$1" = "$GUARD_RACE_PATH" ] && [ ! -e "$GUARD_RACE_ONCE" ]; then
  : >"$GUARD_RACE_ONCE"
  /bin/mkdir "$1" || exit 1
  /bin/rmdir "$1" || exit 1
  exit 1
fi
exec /bin/mkdir "$@"
MKDIR
  chmod +x "$T/bin/mkdir"
  lease acquire --provider codex --session B
  assert_rc 5
  assert_file "$GUARD_RACE_ONCE"
  assert_eq "$(cat "$T/out")" '' "refused contender stdout"
  assert_has "$T/err" 'held by claude `Workshop`'
  cmp -s "$T/baseline" "$T/ops/ws/.operator/lease" || _fail "refused contender changed the lease"
  lease check --instance "$TOK" --epoch "$EP"
  assert_rc 0
  assert_no_file "$GUARD_RACE_PATH"
  assert_no_file "$T/ops/ws/.operator/lease.lock"
}

test_release_needs_warm_note_and_bumps_epoch_on_acquire() {
  lsetup
  acq claude Workshop
  t1=$TOK
  lease release --instance "$t1" --epoch 1
  assert_rc 5
  assert_has "$T/err" "HANDOFF.md must start"
  lease note --instance "$t1" --epoch 1
  assert_rc 0
  cp "$T/out" "$T/ops/ws/HANDOFF.md"
  assert_has "$T/ops/ws/HANDOFF.md" "kind: warm"
  assert_has "$T/ops/ws/HANDOFF.md" "## Switch-in audit"
  assert_has "$T/ops/ws/HANDOFF.md" "## In flight"
  lease release --instance "$t1" --epoch 1
  assert_rc 0
  assert_eq "$(lget state)" released
  sha=$(git -C "$T/ops/ws" log -1 --format=%h -- HANDOFF.md)
  assert_eq "$(lget prev_note)" "$sha"
  # Idempotent replay after a crash.
  lease release --instance "$t1" --epoch 1
  assert_rc 0
  assert_has "$T/out" "already"
  # The old holder is now the standby.
  lease renew --instance "$t1" --epoch 1
  assert_rc 5
  acq claude Workshop
  assert_eq "$EP" 2
  assert_has "$T/out" "resume from: HANDOFF.md at $sha"
  # Same client: no switch-in audit.
  assert_eq "$(lget audit)" -
}

test_dispatch_marker_blocks_release() {
  lsetup
  acq claude Workshop
  lease dispatch-begin --instance "$TOK" --epoch "$EP" --what "deploy web" --pid $$
  assert_rc 0
  mk=$(sed -n 's/^marker: //p' "$T/out")
  assert_file "$T/ops/ws/.operator/markers/$mk"
  lease note --instance "$TOK" --epoch "$EP"
  cp "$T/out" "$T/ops/ws/HANDOFF.md"
  lease release --instance "$TOK" --epoch "$EP"
  assert_rc 5
  assert_has "$T/err" "dispatch marker is open"
  # Only the holder can dispatch.
  lease dispatch-begin --instance nottoken --epoch "$EP" --what x --pid $$
  assert_rc 5
  lease dispatch-end --instance "$TOK" --epoch "$EP" --marker "$mk"
  assert_rc 0
  assert_no_file "$T/ops/ws/.operator/markers/$mk"
  lease release --instance "$TOK" --epoch "$EP"
  assert_rc 0
}

test_crash_inside_lock_fails_closed_until_unlock() {
  lsetup
  acq claude Workshop
  AO_TEST_CRASH_AT=lease-before-rename lease renew --instance "$TOK" --epoch "$EP"
  [ "$rc" -ne 0 ] || _fail "crash point not reached"
  assert_file "$T/ops/ws/.operator/lease.lock"
  # The lease itself is intact (rename never happened).
  assert_eq "$(lget state)" held
  touch -t 202001010000 "$T/ops/ws/.operator/lease.lock"
  lease renew --instance "$TOK" --epoch "$EP"
  assert_rc 3
  assert_has "$T/err" "failing closed"
  assert_count "$T/home/inbox/oracle" 1
  # Told once, not on every verb.
  lease check --instance "$TOK" --epoch "$EP"
  assert_rc 3
  lease acquire --provider codex --session x
  assert_rc 3
  assert_count "$T/home/inbox/oracle" 1
  # unlock is human-only and needs the assertions.
  lease unlock
  assert_rc 5
  CLAUDECODE=1 lease unlock --timers-off --sessions-stopped
  assert_rc 5
  assert_has "$T/err" "human-only"
  lease unlock --timers-off --sessions-stopped
  assert_rc 5
  assert_has "$T/err" "terminal"
  with_tty "unlock ws" lease.sh --home "$T/ops/ws" unlock --timers-off --sessions-stopped
  assert_eq "$rc" 0 "unlock rc"
  assert_no_file "$T/ops/ws/.operator/lease.lock"
  lease renew --instance "$TOK" --epoch "$EP"
  assert_rc 0
}

test_takeover_refused_paths() {
  lsetup
  acq claude Workshop
  # Refused inside an agent tool shell.
  CLAUDECODE=1 lease takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  assert_rc 5
  CODEX_THREAD_ID=x lease takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  assert_rc 5
  # Without the human's assertion.
  lease takeover --expect-epoch 1 --provider codex --session ops-ws
  assert_rc 5
  assert_has "$T/err" "holder-stopped"
  # Wrong epoch.
  lease takeover --expect-epoch 7 --holder-stopped --provider codex --session ops-ws
  assert_rc 5
  # Without the confirmed prompt (no terminal).
  lease takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  assert_rc 5
  assert_has "$T/err" "confirmed by a human at a terminal"
  # A wrong confirmation.
  with_tty "yes" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  assert_eq "$rc" 5 "wrong confirmation rc"
  assert_eq "$(lget state)" held
  assert_eq "$(lget epoch)" 1
}

test_takeover_refused_while_dispatcher_paused() {
  lsetup
  acq claude Workshop
  sleep 60 &
  disp=$!
  lease dispatch-begin --instance "$TOK" --epoch "$EP" --what "publish release" --pid "$disp"
  mk=$(sed -n 's/^marker: //p' "$T/out")
  kill -STOP "$disp"
  lease status
  assert_has "$T/out" "stopped (pid $disp)"
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  assert_eq "$rc" 5 "paused dispatcher rc"
  assert_has "$T/out" "dispatch marker exists"
  # The dispatcher dies: the marker stays as an unresolved effect.
  kill -KILL "$disp"
  wait "$disp" 2>/dev/null
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  assert_eq "$rc" 5 "dead marker rc"
  # The human settles it; then takeover proceeds.
  with_tty "settle $mk unknown" lease.sh --home "$T/ops/ws" settle --marker "$mk" --outcome unknown
  assert_eq "$rc" 0 "settle rc"
  assert_file "$T/ops/ws/.operator/markers/settled/$mk"
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  assert_eq "$rc" 0 "takeover rc"
  assert_has "$T/ops/ws/HANDOFF.md" "effect $mk: publish release (outcome unknown"
}

test_takeover_cold_note_assign_audit_and_old_holder() {
  lsetup
  acq claude Workshop
  old=$TOK
  printf 'wip\n' >"$T/work/app/dirty.txt"
  git -C "$T/work/app" checkout -q -b ws/feature
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  assert_eq "$rc" 0 "takeover rc"
  h=$T/ops/ws/HANDOFF.md
  assert_has "$h" "epoch: 1   from: claude/"
  assert_has "$h" "kind: cold"
  assert_has "$h" "## Switch-in audit"
  assert_has "$h" "REQUIRED FIRST STEP for the incoming codex session"
  assert_has "$h" "- app (owner) $T/work/app"
  assert_has "$h" "branch ws/feature"
  assert_has "$h" "dirty: 1 file(s): dirty.txt"
  assert_has "$h" "## On hold"
  assert_has "$h" "## Grants in play"
  # Committed first, and the lease points at it.
  git -C "$T/ops/ws" diff --quiet HEAD -- HANDOFF.md || _fail "cold note not committed"
  assert_eq "$(lget prev_note)" "$(git -C "$T/ops/ws" log -1 --format=%h -- HANDOFF.md)"
  assert_eq "$(lget state)" assigned
  assert_eq "$(lget epoch)" 2
  assert_eq "$(lget audit)" pending
  # The old holder wakes: its renew fails and it redirects.
  lease renew --instance "$old" --epoch 1
  assert_rc 5
  # Only the assigned provider and session may acquire.
  acq claude Workshop
  assert_rc 5
  acq codex ops-ws
  assert_rc 0
  assert_eq "$EP" 2
  assert_has "$T/out" "REQUIRED FIRST STEP: switch-in audit"
  new=$TOK
  # No new work until the audit is recorded.
  lease dispatch-begin --instance "$new" --epoch 2 --what "deploy" --pid $$
  assert_rc 5
  assert_has "$T/err" "switch-in audit pending"
  lease audit-brief --instance "$new" --epoch 2
  assert_rc 0
  assert_has "$T/out" "# Switch-in audit: ws, generation"
  assert_has "$T/out" "epoch 2 (claude -> codex)"
  head -n 1 "$T/out" >"$T/hdr"
  assert_has "$T/out" "Leftovers"
  mkdir -p "$T/ops/ws/audits"
  { cat "$T/hdr"; printf 'findings: none\n'; } >"$T/ops/ws/audits/a.md"
  lease audit-done --instance "$new" --epoch 2 --report audits/a.md
  assert_rc 5
  assert_has "$T/err" "commit the report first"
  git -C "$T/ops/ws" add audits/a.md && git -C "$T/ops/ws" commit -q -m audit
  lease audit-done --instance "$new" --epoch 2 --report audits/a.md
  assert_rc 0
  assert_eq "$(lget audit)" "done"
  lease dispatch-begin --instance "$new" --epoch 2 --what "deploy" --pid $$
  assert_rc 0
}

test_warm_switch_to_other_client_needs_audit() {
  lsetup
  acq claude Workshop
  lease note --instance "$TOK" --epoch 1
  cp "$T/out" "$T/ops/ws/HANDOFF.md"
  lease release --instance "$TOK" --epoch 1
  acq codex ops-ws
  assert_eq "$(lget audit)" pending
  assert_eq "$(lget prev_provider)" claude
}

test_registry_audit_also_gates_the_holder() {
  lsetup
  acq claude Workshop
  # cross-review.sh recorded a family change of ws before the lease existed.
  mkdir -p "$T/state/audit"
  printf 'provider=claude\nfrom=codex\nto=claude\nchange=1\nsince=2030-01-02T03:04:05Z\n' >"$T/state/audit/ws"
  lease renew --instance "$TOK" --epoch 1
  assert_has "$T/out" "REQUIRED FIRST STEP: switch-in audit (this operator moved codex -> claude)"
  lease dispatch-begin --instance "$TOK" --epoch 1 --what deploy --pid $$
  assert_rc 5
  assert_has "$T/err" "switch-in audit pending (moved codex -> claude)"
  run ask.sh new --home "$T/ops/ws" --instance "$TOK" --epoch 1 --action noop --target t --revision 1 --risk none --rollback none
  assert_rc 5
  assert_has "$T/err" "registry change codex -> claude"
  lease status
  assert_has "$T/out" "switch-in audit: pending (registry, codex -> claude)"
  lease audit-brief --instance "$TOK" --epoch 1
  head -n 1 "$T/out" >"$T/hdr"
  assert_eq "$(cat "$T/hdr")" "# Switch-in audit: ws, registry change 1 at 2030-01-02T03:04:05Z (codex -> claude)"
  mkdir -p "$T/ops/ws/audits"
  { cat "$T/hdr"; printf 'findings: none\n'; } >"$T/ops/ws/audits/r.md"
  git -C "$T/ops/ws" add audits/r.md && git -C "$T/ops/ws" commit -q -m audit
  # With a lease, only the holder records it.
  lease audit-done --report audits/r.md
  assert_rc 2
  lease audit-done --instance "$TOK" --epoch 1 --report audits/r.md
  assert_rc 0
  assert_has "$T/state/audit/ws.done" "change=1"
  assert_eq "$(lget audit)" -
  lease dispatch-begin --instance "$TOK" --epoch 1 --what deploy --pid $$
  assert_rc 0
  # A completion cut down to its change number proves nothing.
  printf 'change=1\n' >"$T/state/audit/ws.done"
  lease dispatch-begin --instance "$TOK" --epoch 1 --what deploy --pid $$
  assert_rc 5
  assert_has "$T/err" "unreadable or invalid"
}

test_invalid_audit_record_fails_closed() {
  lsetup
  acq claude Workshop
  mkdir -p "$T/state/audit"
  printf 'provider=claude\nfrom=codex\nto=claude\nchange=one\nsince=2030-01-02T03:04:05Z\n' >"$T/state/audit/ws"
  lease dispatch-begin --instance "$TOK" --epoch 1 --what deploy --pid $$
  assert_rc 5
  assert_has "$T/err" "unreadable or invalid"
  run ask.sh new --home "$T/ops/ws" --instance "$TOK" --epoch 1 --action noop --target t --revision 1 --risk none --rollback none
  assert_rc 5
  assert_has "$T/err" "unreadable or invalid"
  lease audit-done --instance "$TOK" --epoch 1 --report HANDOFF.md
  assert_rc 5
  run status.sh --tsv
  assert_eq "$(awk -F'\t' '$1 == "ws" { print $7 }' "$T/out")" invalid
  # An empty or truncated record is invalid too, never "no audit".
  : >"$T/state/audit/ws"
  lease dispatch-begin --instance "$TOK" --epoch 1 --what deploy --pid $$
  assert_rc 5
  printf 'provider=claude\n' >"$T/state/audit/ws"
  lease dispatch-begin --instance "$TOK" --epoch 1 --what deploy --pid $$
  assert_rc 5
  assert_has "$T/err" "unreadable or invalid"
}

test_first_lease_on_the_other_family_is_a_switch() {
  lsetup
  mkdir -p "$T/state/audit"
  printf 'provider=claude\nfrom=\nto=\nchange=\nsince=\n' >"$T/state/audit/ws"
  acq codex ops-ws
  assert_has "$T/out" "REQUIRED FIRST STEP: switch-in audit (this operator moved claude -> codex)"
  assert_eq "$(lget audit)" pending
  assert_eq "$(lget prev_provider)" claude
}

test_first_lease_reads_a_020_client_marker() {
  lsetup
  mkdir -p "$T/state/cross-review"
  echo claude >"$T/state/cross-review/ws.client"
  acq codex ops-ws
  assert_eq "$(lget audit)" pending
  assert_eq "$(lget prev_provider)" claude
}

test_takeover_refuses_a_deleted_asks_file() {
  lsetup
  acq claude Workshop
  printf '# asks\n' >"$T/ops/ws/ASKS.md"
  git -C "$T/ops/ws" add ASKS.md && git -C "$T/ops/ws" commit -q -m asks
  rm "$T/ops/ws/ASKS.md"
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  assert_eq "$rc" 5 "rc"
  assert_has "$T/out" "ASKS.md has uncommitted changes (or was deleted)"
}

test_takeover_refuses_uncommitted_note_files() {
  lsetup
  acq claude Workshop
  printf 'draft\n' >"$T/ops/ws/HANDOFF.md"
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  assert_eq "$rc" 5 "rc"
  assert_has "$T/out" "HANDOFF.md is untracked"
  assert_eq "$(cat "$T/ops/ws/HANDOFF.md")" draft
  assert_eq "$(lget epoch)" 1
}

test_drift_compares_the_lease_holder() {
  lsetup
  acq codex ops-ws-new
  run status.sh --drift
  assert_rc 1
  assert_has "$T/out" 'ws: name: the lease holder is codex "ops-ws-new", operator.conf session.codex="ops-ws"'
  printf 'garbage\n' >"$T/ops/ws/.operator/lease"
  run status.sh --drift --tsv
  assert_rc 1
  assert_has "$T/out" "ws${TAB}lease${TAB}"
}

test_restore_starts_new_generation() {
  lsetup
  acq claude Workshop
  g1=$(lget generation)
  rm -rf "$T/ops/ws/.operator"
  acq claude Workshop
  assert_rc 0
  assert_eq "$EP" 1
  [ "$(lget generation)" != "$g1" ] || _fail "generation did not change"
}

test_invalid_or_foreign_lease_fails_closed() {
  lsetup
  acq claude Workshop
  sed 's/^host=.*/host=elsewhere/' "$T/ops/ws/.operator/lease" >"$T/l" && mv "$T/l" "$T/ops/ws/.operator/lease"
  lease renew --instance "$TOK" --epoch 1
  assert_rc 5
  assert_has "$T/err" "from host 'elsewhere'"
  printf 'operator=ws\n$(touch %s/pwned)\n' "$T" >"$T/ops/ws/.operator/lease"
  lease status
  assert_rc 1
  assert_has "$T/err" "invalid"
  assert_no_file "$T/pwned"
}

test_redirect_text_and_offer() {
  lsetup
  acq claude Workshop
  lease redirect --provider codex
  assert_rc 0
  assert_has "$T/out" 'ws is held by claude `Workshop` since'
  assert_has "$T/out" "Go there."
  assert_lacks "$T/out" "looks down"
  # Five hours later, nothing in flight: the offer appears.
  AO_NOW=$(($(date +%s) + 18000)) lease redirect --provider codex
  assert_has "$T/out" "The holder looks down"
  # A live dispatch suppresses the offer.
  lease dispatch-begin --instance "$TOK" --epoch 1 --what x --pid $$
  AO_NOW=$(($(date +%s) + 18000)) lease redirect --provider codex
  assert_lacks "$T/out" "looks down"
}

test_concurrent_launch_with_same_token_is_standby() {
  lsetup
  sleep 60 &
  first=$!
  CLAUDECODE=1 CLAUDE_PID=$first acq claude Workshop
  assert_eq "$(lget client_pid)" "$first"
  # A second launch of the same conversation (same token, other process).
  CLAUDECODE=1 CLAUDE_PID=$$ lease renew --instance "$TOK" --epoch 1
  assert_rc 5
  assert_has "$T/err" "another live claude launch"
  # The first launch is gone: the relaunch carries on as the holder.
  kill "$first"
  wait "$first" 2>/dev/null
  CLAUDECODE=1 CLAUDE_PID=$$ lease renew --instance "$TOK" --epoch 1
  assert_rc 0
  assert_eq "$(lget client_pid)" "$$"
}

test_takeover_refused_while_client_process_runs() {
  lsetup
  sleep 60 &
  cl=$!
  CLAUDECODE=1 CLAUDE_PID=$cl acq claude Workshop
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  assert_eq "$rc" 5 "rc"
  assert_has "$T/out" "still running"
  kill "$cl"
}

test_routing_follows_the_lease() {
  lsetup
  mkdir -p "$T/home/inbox/ws"
  printf 'hello\n' >"$T/home/inbox/ws/n.md"
  # Released (or absent holder): the relay holds the note.
  acq claude Workshop
  lease note --instance "$TOK" --epoch 1
  cp "$T/out" "$T/ops/ws/HANDOFF.md"
  lease release --instance "$TOK" --epoch 1
  FAKE_MODE=sent run relay.sh --key ws
  assert_rc 0
  assert_count "$T/home/inbox/ws" 1
  assert_has "$T/state/relay.log" "to=ws held by gate"
  # Status keeps the display name; delivery uses the holder's native ID.
  lease acquire --provider codex --session ops-ws --session-id sid-ws
  assert_rc 0
  TOK=$(sed -n 's/^instance: //p' "$T/out")
  EP=$(sed -n 's/^epoch: //p' "$T/out")
  run status.sh --tsv
  assert_has "$T/out" "ws${TAB}ops-ws${TAB}codex"
  run relay.sh --key ws
  assert_rc 0
  assert_has "$FAKE_LOG" "arg: sid-ws"
  assert_lacks "$FAKE_LOG" "arg: ops-ws"
  assert_lacks "$FAKE_LOG" "== claude"
  assert_count "$T/home/inbox/ws" 0
  lease note --instance "$TOK" --epoch 2
  cp "$T/out" "$T/ops/ws/HANDOFF.md"
  lease release --instance "$TOK" --epoch 2
  run status.sh --tsv
  assert_has "$T/out" "${TAB}codex${TAB}"
  acq claude "Workshop-2"
  note ws follow-up.md "next owner"
  FAKE_MODE=sent run relay.sh --key ws
  assert_rc 0
  assert_has "$FAKE_LOG" 'to "Workshop-2"'
  assert_count "$T/home/inbox/ws" 0
}

test_dispatch_run_wraps_the_effect() {
  lsetup
  acq claude Workshop
  lease dispatch-run --instance "$TOK" --epoch "$EP" --what "touch file" -- touch "$T/effect"
  assert_rc 0
  assert_file "$T/effect"
  assert_count "$T/ops/ws/.operator/markers" 1
  assert_has "$T/err" "ended: "
  # A failed effect leaves the marker: its outcome is unknown.
  lease dispatch-run --instance "$TOK" --epoch "$EP" --what "flaky publish" -- sh -c "exit 3"
  assert_rc 3
  assert_count "$T/ops/ws/.operator/markers" 2
  lease status
  assert_has "$T/out" "flaky publish"
  lease dispatch-run --instance other --epoch "$EP" --what x -- touch "$T/never"
  assert_rc 5
  assert_no_file "$T/never"
}

test_takeover_commit_failure_changes_nothing() {
  lsetup
  acq claude Workshop
  printf '#!/bin/sh\nexit 1\n' >"$T/ops/ws/.git/hooks/pre-commit"
  chmod +x "$T/ops/ws/.git/hooks/pre-commit"
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  assert_eq "$rc" 1 "rc"
  assert_has "$T/out" "lease unchanged"
  assert_no_file "$T/ops/ws/HANDOFF.md"
  assert_no_file "$T/ops/ws/.operator/lease.lock"
  assert_eq "$(lget state)" held
  assert_eq "$(lget epoch)" 1
}

# resolve KEY  Print what ao_operator_resolve reports for KEY.
resolve() {
  cat >"$T/resolve.sh" <<EOF
AO_SCRIPTS=$SCRIPTS
. "\$AO_SCRIPTS/lib/core.sh"
. "\$AO_SCRIPTS/lib/registry.sh"
ao_load --no-state
show() { [ "\$OP_KEY" = "$1" ] && echo "client=\$OP_CLIENT provider=\$OP_PROVIDER lease=\$OP_LEASE audit=\$OP_AUDIT name=\$OP_NAME${2:+ sid=\$OP_SID}"; return 0; }
ao_registry_each show
EOF
  "$AO_TEST_SHELL" "$T/resolve.sh" 2>"$T/err"
}

test_resolver_reports_provider_across_handoff() {
  lsetup
  printf 'wd\tWd\t%s\tsid-wd\tclaude\n' "$T/ops/wd" >>"$T/home/operators/REGISTRY.tsv"
  mkdir -p "$T/ops/wd"
  printf 'key=wd\n' >"$T/ops/wd/operator.conf"
  git_init "$T/ops/wd"
  # Same client as the registry: its session id stays (the watchdog needs it).
  acq claude Wd "$T/ops/wd"
  assert_eq "$(resolve wd sid)" "client=claude provider=claude lease=held audit=- name=Wd sid=sid-wd"
  with_tty "takeover wd 1" lease.sh --home "$T/ops/wd" takeover --expect-epoch 1 --holder-stopped --provider codex --session wd-x
  assert_eq "$(resolve wd sid)" "client=codex provider=codex lease=assigned audit=pending name=wd-x sid="
  printf 'fo\tFo\t%s\t-\tfile-only\n' "$T/ops/fo" >>"$T/home/operators/REGISTRY.tsv"
  mkdir -p "$T/ops/fo"
  printf 'key=fo\n' >"$T/ops/fo/operator.conf"
  git_init "$T/ops/fo"
  assert_eq "$(resolve ws)" "client=claude provider=claude lease=none audit=- name=Workshop"
  acq claude Workshop
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  assert_eq "$(resolve ws)" "client=codex provider=codex lease=assigned audit=pending name=ops-ws"
  # A file-only transport still reports the owning family.
  acq codex ops-fo "$T/ops/fo"
  assert_eq "$(resolve fo)" "client=file-only provider=codex lease=held audit=- name=ops-fo"
}

test_dead_marker_needs_settle_not_dispatch_end() {
  lsetup
  acq claude Workshop
  sh -c 'sleep 30' &
  w=$!
  lease dispatch-begin --instance "$TOK" --epoch "$EP" --what "publish" --pid "$w"
  mk=$(sed -n 's/^marker: //p' "$T/out")
  kill "$w"
  wait "$w" 2>/dev/null
  lease dispatch-end --instance "$TOK" --epoch "$EP" --marker "$mk"
  assert_rc 5
  assert_has "$T/err" "process is dead"
  assert_file "$T/ops/ws/.operator/markers/$mk"
  # dispatch-begin refuses a pid that is not running, or none.
  lease dispatch-begin --instance "$TOK" --epoch "$EP" --what x --pid "$w"
  assert_rc 2
  lease dispatch-begin --instance "$TOK" --epoch "$EP" --what x
  assert_rc 2
}

test_stuck_lock_fails_closed_for_check_and_mail() {
  lsetup
  acq claude Workshop
  old_lock "$T/ops/ws"
  lease check --instance "$TOK" --epoch "$EP"
  assert_rc 3
  run mail.sh claim --home "$T/ops/ws" --instance "$TOK" --epoch "$EP"
  assert_rc 3
}

test_unwritable_operator_dir_fails_promptly() {
  lsetup
  acq claude Workshop
  chmod 500 "$T/ops/ws/.operator"
  lease renew --instance "$TOK" --epoch "$EP"
  chmod 700 "$T/ops/ws/.operator"
  assert_rc 1
  assert_has "$T/err" "cannot create"
}

test_audit_report_is_bound_to_the_handoff() {
  lsetup
  acq claude Workshop
  mkdir -p "$T/ops/ws/audits"
  printf 'old findings\n' >"$T/ops/ws/audits/old.md"
  git -C "$T/ops/ws" add audits/old.md && git -C "$T/ops/ws" commit -q -m old
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  acq codex ops-ws
  for bad in operator.conf audits/old.md ../ops/ws/operator.conf "$T/ops/ws/operator.conf"; do
    lease audit-done --instance "$TOK" --epoch 2 --report "$bad"
    assert_rc 5
  done
  assert_eq "$(lget audit)" pending
  # A report committed before the handoff, even with the right header.
  lease audit-brief --instance "$TOK" --epoch 2
  head -n 1 "$T/out" >"$T/hdr"
  assert_has "$T/hdr" "generation $(lget generation), epoch 2 (claude -> codex)"
  cp "$T/hdr" "$T/ops/ws/audits/new.md"
  printf 'no findings\n' >>"$T/ops/ws/audits/new.md"
  git -C "$T/ops/ws" add audits/new.md && git -C "$T/ops/ws" commit -q -m audit
  lease audit-done --instance "$TOK" --epoch 2 --report audits/new.md
  assert_rc 0
  assert_eq "$(lget audit)" "done"
}

test_foreign_host_lease_is_not_routed() {
  lsetup
  acq codex ops-ws
  sed 's/^host=.*/host=elsewhere/' "$T/ops/ws/.operator/lease" >"$T/l" && mv "$T/l" "$T/ops/ws/.operator/lease"
  assert_eq "$(resolve ws)" "client=claude provider=claude lease=invalid audit=- name=Workshop"
}

test_failed_publish_is_not_reported_as_sent() {
  lsetup
  chmod 500 "$T/ops/ws/.operator/inbox/new"
  printf 'hello\n' >"$T/body"
  srun mail.sh send ws --kind notice --from oracle/claude <"$T/body"
  chmod 700 "$T/ops/ws/.operator/inbox/new"
  assert_rc 1
  assert_lacks "$T/out" "sent:"
}

test_rejected_launch_cannot_end_a_marker() {
  lsetup
  sleep 60 &
  first=$!
  CLAUDECODE=1 CLAUDE_PID=$first acq claude Workshop
  sleep 60 &
  w=$!
  CLAUDECODE=1 CLAUDE_PID=$first lease dispatch-begin --instance "$TOK" --epoch 1 --what deploy --pid "$w"
  mk=$(sed -n 's/^marker: //p' "$T/out")
  CLAUDECODE=1 CLAUDE_PID=$$ lease dispatch-end --instance "$TOK" --epoch 1 --marker "$mk"
  assert_rc 5
  assert_file "$T/ops/ws/.operator/markers/$mk"
  kill "$first" "$w"
}

test_zombie_dispatcher_counts_as_dead() {
  lsetup
  acq claude Workshop
  # The child exits but its parent never reaps it: a zombie.
  sh -c 'sleep 2 & echo $! >"$1"; exec sleep 30' sh "$T/zpid" &
  parent=$!
  i=0
  while [ ! -s "$T/zpid" ] && [ "$i" -lt 5 ]; do sleep 1; i=$((i + 1)); done
  z=$(cat "$T/zpid")
  lease dispatch-begin --instance "$TOK" --epoch "$EP" --what publish --pid "$z"
  assert_rc 0
  mk=$(sed -n 's/^marker: //p' "$T/out")
  sleep 3
  lease status
  assert_has "$T/out" "dead (pid $z)"
  lease dispatch-end --instance "$TOK" --epoch "$EP" --marker "$mk"
  assert_rc 5
  kill "$parent"
}

test_audit_report_must_be_a_committed_literal_path() {
  lsetup
  acq claude Workshop
  with_tty "takeover ws 1" lease.sh --home "$T/ops/ws" takeover --expect-epoch 1 --holder-stopped --provider codex --session ops-ws
  acq codex ops-ws
  lease audit-brief --instance "$TOK" --epoch 2
  head -n 1 "$T/out" >"$T/hdr"
  # An untracked file with the right header, named like pathspec magic.
  cp "$T/hdr" "$T/ops/ws/:(glob)**"
  printf 'x\n' >"$T/ops/ws/later.txt"
  git -C "$T/ops/ws" add later.txt && git -C "$T/ops/ws" commit -q -m later
  lease audit-done --instance "$TOK" --epoch 2 --report ':(glob)**'
  assert_rc 5
  cp "$T/hdr" "$T/ops/ws/untracked.md"
  lease audit-done --instance "$TOK" --epoch 2 --report untracked.md
  assert_rc 5
  assert_eq "$(lget audit)" pending
}

test_unlock_refuses_a_replaced_lock() {
  lsetup
  acq claude Workshop
  old_lock "$T/ops/ws"
  # While the human is typing, a live process takes a fresh lock.
  (sleep 0.5 2>/dev/null || sleep 1; rm -rf "$T/ops/ws/.operator/lease.lock"; mkdir "$T/ops/ws/.operator/lease.lock"; echo $$ >"$T/ops/ws/.operator/lease.lock/pid") &
  with_tty "unlock ws" lease.sh --home "$T/ops/ws" unlock --timers-off --sessions-stopped
  wait
  assert_eq "$rc" 5 "rc"
  assert_has "$T/out" "replaced"
  assert_eq "$(cat "$T/ops/ws/.operator/lease.lock/pid")" "$$"
}

test_release_with_stuck_lock_commits_nothing() {
  lsetup
  acq claude Workshop
  lease note --instance "$TOK" --epoch 1
  cp "$T/out" "$T/ops/ws/HANDOFF.md"
  head0=$(git -C "$T/ops/ws" rev-parse HEAD)
  old_lock "$T/ops/ws"
  lease release --instance "$TOK" --epoch 1
  assert_rc 3
  assert_eq "$(git -C "$T/ops/ws" rev-parse HEAD)" "$head0"
}

test_same_client_other_session_does_not_inherit_the_session_id() {
  lsetup
  printf 'cx\tOldThread\t%s\tsid-old\tcodex\n' "$T/ops/cx" >>"$T/home/operators/REGISTRY.tsv"
  mkdir -p "$T/ops/cx"
  printf 'key=cx\n' >"$T/ops/cx/operator.conf"
  git_init "$T/ops/cx"
  acq codex NewThread "$T/ops/cx"
  assert_eq "$(resolve cx sid)" "client=codex provider=codex lease=held audit=- name=NewThread sid="
}

# no_ps_path  A PATH with every usual tool except ps.
no_ps_path() {
  mkdir -p "$T/nops"
  for d in "$T/bin" /bin /usr/bin /usr/sbin /sbin /opt/homebrew/bin /usr/local/bin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      n=${f##*/}
      [ "$n" != ps ] && [ ! -e "$T/nops/$n" ] && ln -s "$f" "$T/nops/$n"
    done
  done
  echo "$T/nops"
}

test_without_ps_markers_end_only_in_process() {
  lsetup
  acq claude Workshop
  sleep 60 &
  w=$!
  lease dispatch-begin --instance "$TOK" --epoch "$EP" --what publish --pid "$w"
  mk=$(sed -n 's/^marker: //p' "$T/out")
  np=$(no_ps_path)
  PATH=$np lease dispatch-end --instance "$TOK" --epoch "$EP" --marker "$mk"
  assert_rc 5
  assert_has "$T/err" "is unknown"
  assert_file "$T/ops/ws/.operator/markers/$mk"
  # dispatch-run ends its own marker without asking ps.
  PATH=$np lease dispatch-run --instance "$TOK" --epoch "$EP" --what "touch" -- touch "$T/e"
  assert_rc 0
  assert_count "$T/ops/ws/.operator/markers" 2
  # A live --pid cannot be proven without ps, and pid 0 is never a process.
  PATH=$np lease dispatch-begin --instance "$TOK" --epoch "$EP" --what x --pid "$w"
  assert_rc 2
  lease dispatch-begin --instance "$TOK" --epoch "$EP" --what x --pid 0
  assert_rc 2
  kill "$w"
}

test_guard_serializes_lock_and_unlock() {
  lsetup
  acq claude Workshop
  # A guard that stays taken: lock acquisition fails closed.
  mkdir "$T/ops/ws/.operator/lease.guard"
  lease renew --instance "$TOK" --epoch "$EP"
  assert_rc 3
  assert_has "$T/err" "lease guard"
  # unlock also waits for the guard, and removes nothing without it.
  old_lock "$T/ops/ws"
  with_tty "unlock ws" lease.sh --home "$T/ops/ws" unlock --timers-off --sessions-stopped
  assert_eq "$rc" 5 "unlock without the guard"
  assert_file "$T/ops/ws/.operator/lease.lock"
  rmdir "$T/ops/ws/.operator/lease.guard"
  with_tty "unlock ws" lease.sh --home "$T/ops/ws" unlock --timers-off --sessions-stopped
  assert_eq "$rc" 0 "unlock"
  lease renew --instance "$TOK" --epoch "$EP"
  assert_rc 0
  assert_no_file "$T/ops/ws/.operator/lease.guard"
}

ao_test_main "$0"
