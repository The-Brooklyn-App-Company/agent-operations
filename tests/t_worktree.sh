#!/bin/sh
# t_worktree.sh - isolated Git repositories and a fake Time Machine CLI.
. "$(dirname -- "$0")/lib.sh"

worktree_setup() {
  repo="$T/example repo"
  slug=20300102-example
  container=$repo/worktrees.noindex
  seat=$container/$slug
  mkdir "$repo" || exit 2
  GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_GLOBAL
  git -C "$repo" init -q && printf 'example\n' >"$repo/example.txt" &&
    git -C "$repo" add example.txt &&
    git -C "$repo" -c user.name=Example -c user.email=editor@example.com commit -qm initial || exit 2
  cat >"$T/bin/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "${FAKE_HOST:-Darwin}"
EOF
  cat >"$T/bin/tmutil" <<'EOF'
#!/bin/sh
[ "$#" -eq 2 ] || exit 8
case $1 in
  addexclusion)
    printf 'add %s\n' "$2" >>"$FAKE_LOG"
    [ "${FAKE_TM:-}" != add-fails ] || exit 9
    [ -d "$2" ] && [ "${2##*/}" = worktrees.noindex ] && : >"$FAKE_LOG.excluded"
    ;;
  isexcluded)
    [ -d "$2" ] || exit 8
    phase=empty
    [ ! -e "$2/.git" ] || phase=checked-out
    [ "${2##*/}" != worktrees.noindex ] || phase=container
    printf 'check %s %s\n' "$phase" "$2" >>"$FAKE_LOG"
    if [ ! -e "$FAKE_LOG.excluded" ]; then
      printf '[Included] %s\n' "$2"
      exit 0
    fi
    case ${FAKE_TM:-}:$phase in
      before-fails:empty | after-fails:checked-out) printf '[Included] %s\n' "$2" ;;
      *) printf '[Excluded] %s\n' "$2" ;;
    esac
    ;;
  *) exit 8 ;;
esac
EOF
  chmod +x "$T/bin/uname" "$T/bin/tmutil"
}

test_worktree_is_ignored_and_excluded_before_and_after_checkout() {
  worktree_setup
  run worktree.sh "$repo" "$slug"
  assert_rc 0
  assert_has "$T/out" "Created and verified"
  assert_file "$seat/.git"
  assert_has "$seat/example.txt" "example"
  assert_eq "$(git -C "$seat" branch --show-current)" "work/$slug"
  assert_has "$repo/.git/info/exclude" "/worktrees.noindex/"
  git -C "$repo" check-ignore -q "worktrees.noindex/$slug" || _fail "seat must be ignored"
  assert_eq "$(sed -n '1p' "$FAKE_LOG")" "add $container"
  assert_eq "$(sed -n '2p' "$FAKE_LOG")" "check empty $seat"
  assert_eq "$(sed -n '3p' "$FAKE_LOG")" "check checked-out $seat"
}

test_missing_sticky_exclusion_blocks_checkout() {
  worktree_setup
  FAKE_TM=add-fails run worktree.sh "$repo" "$slug"
  assert_rc 1
  assert_no_file "$seat"
  FAKE_TM=before-fails run worktree.sh "$repo" "$slug"
  assert_rc 1
  assert_no_file "$seat"
  assert_lacks "$FAKE_LOG" "checked-out"
  assert_eq "$(git -C "$repo" branch --list "work/$slug")" ""
}

test_nonempty_included_container_stays_in_backups() {
  worktree_setup
  mkdir "$container"
  printf 'unique draft\n' >"$container/.draft"
  run worktree.sh "$repo" "$slug"
  assert_rc 1
  assert_has "$T/err" "Preserve existing contents in a backed-up location"
  assert_eq "$(cat "$FAKE_LOG")" "check container $container"
  assert_has "$container/.draft" "unique draft"
  assert_no_file "$seat"
  assert_lacks "$repo/.git/info/exclude" "/worktrees.noindex/"
  assert_eq "$(git -C "$repo" branch --list "work/$slug")" ""
}

test_dangling_link_also_makes_an_included_container_nonempty() {
  worktree_setup
  mkdir "$container"
  ln -s "$T/missing" "$container/..draft"
  run worktree.sh "$repo" "$slug"
  assert_rc 1
  assert_eq "$(cat "$FAKE_LOG")" "check container $container"
  [ -L "$container/..draft" ] || _fail "dangling link was removed"
  assert_no_file "$seat"
}

test_nonempty_excluded_container_is_reused_without_changing_exclusion() {
  worktree_setup
  mkdir "$container"
  printf 'existing work\n' >"$container/other.txt"
  : >"$FAKE_LOG.excluded"
  run worktree.sh "$repo" "$slug"
  assert_rc 0
  assert_has "$container/other.txt" "existing work"
  assert_file "$seat/.git"
  assert_eq "$(sed -n '1p' "$FAKE_LOG")" "check container $container"
  assert_eq "$(sed -n '2p' "$FAKE_LOG")" "check empty $seat"
  assert_lacks "$FAKE_LOG" "add $container"
}

test_failed_post_checkout_verification_preserves_the_seat() {
  worktree_setup
  FAKE_TM=after-fails run worktree.sh "$repo" "$slug" "topic/example" HEAD
  assert_rc 1
  assert_has "$T/err" "exclusion could not be reverified"
  assert_file "$seat/.git"
  assert_eq "$(git -C "$seat" branch --show-current)" "topic/example"
}

test_worktree_rejects_aliases_and_an_escaping_container() {
  worktree_setup
  ln -s "$repo" "$T/alias"
  run worktree.sh "$T/alias" "$slug"
  assert_rc 2
  assert_has "$T/err" "physical absolute repository path"
  mkdir "$T/outside"
  ln -s "$T/outside" "$container"
  run worktree.sh "$repo" "$slug"
  assert_rc 2
  assert_has "$T/err" "must be a real directory"
  assert_count "$T/outside" 0
  assert_no_file "$FAKE_LOG"
}

test_worktree_refuses_to_reuse_a_seat_or_branch() {
  worktree_setup
  mkdir -p "$seat"
  printf 'unique edit\n' >"$seat/local.txt"
  run worktree.sh "$repo" "$slug"
  assert_rc 2
  assert_has "$seat/local.txt" "unique edit"
  git -C "$repo" branch working
  run worktree.sh "$repo" "20300102-unused" working
  assert_rc 2
  assert_has "$T/err" "branch already exists"
  assert_no_file "$FAKE_LOG"
}

test_worktree_refuses_tracked_seat_container() {
  worktree_setup
  mkdir "$container"
  printf 'existing tracked file\n' >"$container/example"
  git -C "$repo" add "$container/example"
  run worktree.sh "$repo" "$slug"
  assert_rc 2
  assert_has "$T/err" "tracked in the index or start revision"
  assert_has "$container/example" "existing tracked file"
  assert_no_file "$FAKE_LOG"
}

test_worktree_refuses_unsupported_host_before_mutating() {
  worktree_setup
  FAKE_HOST=Linux run worktree.sh "$repo" "$slug"
  assert_rc 2
  assert_no_file "$container"
  assert_no_file "$FAKE_LOG"
}

ao_test_main "$0"
