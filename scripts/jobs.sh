#!/bin/sh
# jobs.sh - validate a bounded schedule inventory and plan an owner cutover.
# No scheduler, lease, client settings or registry is changed.
set -u
usage() {
  cat <<'HELP'
Usage: jobs.sh check REGISTRY
       jobs.sh plan REGISTRY OWNER claude|codex

REGISTRY is literal TSV, nine nonempty fields, with # comments/blank lines:
  job_id owner executor_side cadence model desired enabled binding mirror_group
IDs, owner, model, binding and mirror_group: [A-Za-z0-9._-]+ (not '-').
executor_side: neutral|claude|codex. cadence: opaque printable schedule text;
no schedule is parsed or executed. model may be 'none'. desired: enabled|paused.
enabled: enabled|disabled, an explicitly supplied snapshot, NOT live readback.
binding: the opaque scheduler-native ID, unique per executor side.
mirror_group: '-' for a standalone job; otherwise exactly one claude and one
codex row with equal owner, cadence and desired. Models may differ. At most
one peer may currently be enabled. Neutral jobs cannot have a mirror group.
Bounds: 1024 jobs, 2048 bytes per line (LC_ALL=C); no empty/control fields.

check validates the complete inventory. plan validates first, then prints TSV:
  action job_id owner executor_side binding from to reason
Rows sort by action (disable, enable, nochange), then job_id. Only OWNER is
included. Neutral jobs stay unchanged. Mirrored peers follow the target side
unless desired=paused, which keeps both disabled. Standalone jobs on the target
side follow desired. An enabled standalone on the other side BLOCKS the plan;
a disabled standalone on that side stays disabled (no counterpart is invented).
Unknown states, invalid mirrors or an unknown owner fail before any plan output.

A plan is an advisory snapshot, not authorization or execution. The caller must
authorize cutover after draining in-flight work and verifying current state.
No apply verb or native adapters are shipped. Automated execution needs a
supported adapter with fresh exact-ID readback, disable-before-enable ordering,
verified postconditions and failure recovery; this planner does not provide it.
Exit: 0 valid/plan returned; 2 usage, invalid inventory or blocked plan; 1 I/O.
HELP
}
fail() { printf 'jobs.sh: %s\n' "$*" >&2; exit 2; }
[ $# -gt 0 ] || { usage >&2; exit 2; }
case $1 in -h|--help|help) [ $# -eq 1 ] || fail 'unexpected help arguments'; usage; exit 0 ;; esac
verb=$1
case $verb in
  check) [ $# -eq 2 ] || fail 'expected: check REGISTRY'; owner='' target='' ;;
  plan) [ $# -eq 4 ] || fail 'expected: plan REGISTRY OWNER claude|codex'
    owner=$3 target=$4
    case $owner in ''|-|*[!A-Za-z0-9._-]*) fail 'invalid owner' ;; esac
    case $target in claude|codex) ;; *) fail 'target must be claude or codex' ;; esac ;;
  *) fail 'unknown verb (see --help)' ;;
esac
[ -f "$2" ] && [ -r "$2" ] || { printf 'jobs.sh: registry must be a readable regular file\n' >&2; exit 1; }
# One read: validation and output use the same snapshot. Buffer all plan rows
# until END so even a final invalid row cannot leak a partial cutover plan.
LC_ALL=C awk -F '\t' -v verb="$verb" -v owner="$owner" -v target="$target" '
function error(message) {
  print "jobs.sh: line " NR ": " message > "/dev/stderr"
  bad = 1
}
function token(value) { return value != "-" && value ~ /^[A-Za-z0-9._-]+$/ }
# Prefix both operands so awk cannot compare numeric-looking text as numbers.
function same(a, b) { return ("@" a) == ("@" b) }
function row(action, i, to, reason) {
  return action OFS id[i] OFS own[i] OFS side[i] OFS binding[i] OFS state[i] OFS to OFS reason
}
BEGIN { OFS = "\t" }
{
  if (length($0) > 2048) { error("line exceeds 2048 bytes"); next }
  if ($0 == "" || $0 ~ /^#/) next
  if (++n > 1024) { error("registry exceeds 1024 jobs"); exit 2 }
  if (NF != 9) { error("expected nine TSV fields"); next }
  valid = 1
  for (j = 1; j <= 9; j++) {
    if ($j == "" || $j ~ /[[:cntrl:]]/) { error("empty or control field"); valid = 0 }
  }
  if (!valid) next
  if ($4 !~ /[^ ]/) { error("cadence must not be blank"); next }
  if (!token($1) || !token($2) || !token($5) || !token($8) || ($9 != "-" && !token($9))) {
    error("invalid identifier"); next
  }
  if ($3 != "neutral" && $3 != "claude" && $3 != "codex") { error("invalid executor side"); next }
  if ($6 != "enabled" && $6 != "paused") { error("desired must be enabled or paused"); next }
  if ($7 != "enabled" && $7 != "disabled") { error("unknown enabled state"); next }
  if (seen[$1]++) { error("duplicate job_id " $1); next }
  if (bindings[$3 SUBSEP $8]++) { error("duplicate binding for executor side"); next }
  id[n]=$1; own[n]=$2; side[n]=$3
  desired[n]=$6; state[n]=$7; binding[n]=$8; mirror[n]=$9
  if (same($2, owner)) found = 1
  if ($9 != "-") {
    if ($3 == "neutral") error("neutral job cannot be mirrored")
    g = $9
    if (++group_side[g SUBSEP $3] > 1) error("duplicate side in mirror group " g)
    count[g]++
    if (count[g] == 1) { group_owner[g]=$2; group_cadence[g]=$4; group_desired[g]=$6 }
    else if (!same(group_owner[g], $2) || !same(group_cadence[g], $4) || group_desired[g] != $6)
      error("mirror owner, cadence or desired mismatch: " g)
    if ($7 == "enabled" && ++active[g] > 1) error("both mirror peers enabled: " g)
  }
}
END {
  for (g in count) {
    if (count[g] != 2 || group_side[g SUBSEP "claude"] != 1 || group_side[g SUBSEP "codex"] != 1)
      error("mirror group requires one claude and one codex row: " g)
  }
  if (verb == "plan" && !found) error("unknown owner " owner)
  # Validate every blocker before emitting even the header.
  if (verb == "plan") for (i=1; i<=n; i++) {
    if (same(own[i], owner) && side[i] != "neutral" && side[i] != target && mirror[i] == "-" && state[i] == "enabled")
      error("blocked: enabled standalone job has no target peer: " id[i])
  }
  if (bad) exit 2
  if (verb == "check") exit 0
  for (i=1; i<=n; i++) {
    if (!same(own[i], owner)) continue
    to = state[i]; reason = "neutral"
    if (side[i] != "neutral") {
      to = "disabled"
      if (desired[i] == "paused") reason = "paused"
      else if (side[i] == target) { to = "enabled"; reason = "target" }
      else if (mirror[i] == "-") reason = "standalone-other-side"
      else reason = "inactive-peer"
    }
    action = (to == state[i] ? "nochange" : (to == "enabled" ? "enable" : "disable"))
    output[i] = row(action, i, to, reason)
    # Insertion sort gives portable, deterministic ordering without a pipeline
    # that could hide awk validation failures or emit a partial header.
    rank = action SUBSEP id[i]
    k=++total
    while (k > 1 && order[k-1] > rank) { order[k]=order[k-1]; index_at[k]=index_at[k-1]; k-- }
    order[k]=rank; index_at[k]=i
  }
  print "action", "job_id", "owner", "executor_side", "binding", "from", "to", "reason"
  for (i=1; i<=total; i++) print output[index_at[i]]
}' <"$2"
