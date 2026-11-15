#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

herdr_forget_inherited_pane
command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_TREEHOUSE=$(command -v treehouse)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(fm_test_tmproot fm-herdr-leased-worktree-e2e)
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
PROJECT_DIR="$TMP_ROOT/project"
POOL="$TMP_ROOT/pool"
HANG_FLAG="$TMP_ROOT/hang-shell"
HERDR_CALL_LOG="$TMP_ROOT/herdr-calls.log"
TREEHOUSE_CALL_LOG="$TMP_ROOT/treehouse-calls.log"
mkdir -p "$FAKEBIN" "$POOL" "$HOME_DIR/state" "$HOME_DIR/config"
: > "$HERDR_CALL_LOG"
: > "$TREEHOUSE_CALL_LOG"
touch "$HOME_DIR/state/.last-watcher-beat"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-leased)
TREEHOUSE_ROOT=$POOL
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH HERDR_CALL_LOG
export REAL_TREEHOUSE TREEHOUSE_CALL_LOG TREEHOUSE_ROOT

LAB_READY=0
cleanup() {
  local status=$?
  if [ "$LAB_READY" -eq 1 ]; then
    env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || status=1
  fi
  "$REAL_TREEHOUSE" status --json 2>/dev/null | jq -r '.[]? | select(.status == "leased") | .path' 2>/dev/null |
    while IFS= read -r wt; do
      [ -n "$wt" ] || continue
      (cd "$PROJECT_DIR" && "$REAL_TREEHOUSE" return --force "$wt") >/dev/null 2>&1 || true
    done
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT

cat > "$FAKEBIN/lab-shell" <<SH
#!/bin/bash
[ ! -e $(printf '%q' "$HANG_FLAG") ] || sleep 600
exec /bin/bash --noprofile --norc -i
SH
chmod +x "$FAKEBIN/lab-shell"

SHELL="$FAKEBIN/lab-shell" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab"
LAB_READY=1
export HERDR_SESSION="$HERDR_LAB_SESSION"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 0 ] && printf '\t'
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "$HERDR_CALL_LOG"
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" herdr "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
{
  first=1
  for arg in "$@"; do
    [ "$first" -eq 0 ] && printf '\t'
    printf '%s' "$arg"
    first=0
  done
  printf '\n'
} >> "$TREEHOUSE_CALL_LOG"
exec "$REAL_TREEHOUSE" "$@"
SH
chmod +x "$FAKEBIN/treehouse"

mkdir -p "$PROJECT_DIR"
git -C "$PROJECT_DIR" init -q
printf '# Leased worktree E2E fixture\n' > "$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJECT_DIR" "$PROJECT_DIR.origin.git"
git -C "$PROJECT_DIR" remote add origin "file://$PROJECT_DIR.origin.git"

write_ship_brief() {  # <id>
  mkdir -p "$HOME_DIR/data/$1"
  printf '# Task\n## Captain%ss intent\nLeased worktree fixture %s.\n\n## Firstmate spec\nNothing to do.\n' "'" "$1" \
    > "$HOME_DIR/data/$1/brief.md"
}

spawn_task() {  # <id>
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    fm_run_timed 150 "$ROOT/bin/fm-spawn.sh" "$1" "$PROJECT_DIR" "sh -c 'while :; do sleep 60; done'" \
    --mode no-mistakes --yolo off --backend herdr
}

teardown_task() {  # <id>
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-teardown.sh" "$1" --force
}

lease_of() {  # <worktree>
  (cd "$PROJECT_DIR" && "$REAL_TREEHOUSE" status --json 2>/dev/null) |
    jq -r --arg wt "$(cd -P -- "$1" 2>/dev/null && pwd -P || printf '%s' "$1")" '
      .[]? | select((.path) == $wt) | "\(.status) \(.lease_holder // "")"
    '
}

write_ship_brief lease-ok
if ! spawn_task lease-ok > "$TMP_ROOT/lease-ok.out" 2> "$TMP_ROOT/lease-ok.err"; then
  fail "a crew spawn into a pane whose shell starts normally failed: $(cat "$TMP_ROOT/lease-ok.err")"
fi
META="$HOME_DIR/state/lease-ok.meta"
[ -f "$META" ] || fail "the spawn published no task record"
WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
case "$(cd -P -- "$WT" && pwd -P)" in
  "$(cd -P -- "$POOL" && pwd -P)"/*) ;;
  *) fail "the recorded worktree '$WT' is not a slot of the fixture pool '$POOL'" ;;
esac
grep -Fx "$(printf 'get\t--lease\t--lease-holder\tlease-ok')" "$TREEHOUSE_CALL_LOG" >/dev/null \
  || fail "the spawn did not lease its worktree with 'treehouse get --lease --lease-holder lease-ok'; treehouse calls: $(cat "$TREEHOUSE_CALL_LOG")"
if tr '\t' '\n' < "$HERDR_CALL_LOG" | grep -Fx 'treehouse get' >/dev/null; then
  fail "the spawn still typed 'treehouse get' into the pane shell"
fi
grep -F "$(printf 'fm-lease-ok')" "$HERDR_CALL_LOG" | grep -F -e "$(printf -- '--cwd\t%s' "$WT")" >/dev/null \
  || fail "the task pane was not opened with its cwd at the leased worktree $WT; herdr calls: $(grep -F fm-lease-ok "$HERDR_CALL_LOG")"
[ "$(lease_of "$WT")" = "leased lease-ok" ] \
  || fail "the recorded worktree is not leased to lease-ok: '$(lease_of "$WT")'"
pass "a herdr crew spawn leases its worktree outside the pane and opens the pane inside it"

teardown_task lease-ok > "$TMP_ROOT/lease-ok-teardown.out" 2> "$TMP_ROOT/lease-ok-teardown.err" \
  || fail "teardown of the leased crew failed: $(cat "$TMP_ROOT/lease-ok-teardown.err")"
[ "$(lease_of "$WT")" = "available " ] \
  || fail "teardown did not hand the leased worktree back to the pool: '$(lease_of "$WT")'"
pass "teardown returns the leased worktree to the pool"

write_ship_brief lease-hung
touch "$HANG_FLAG"
: > "$TREEHOUSE_CALL_LOG"
if FM_SPAWN_SHELL_READY_SECS=5 spawn_task lease-hung > "$TMP_ROOT/lease-hung.out" 2> "$TMP_ROOT/lease-hung.err"; then
  fail "a crew spawn whose pane shell never finishes starting reported success"
fi
grep -F "never ran the command firstmate typed into it within 5s" "$TMP_ROOT/lease-hung.err" >/dev/null \
  || fail "the spawn did not say that the pane shell never ran its command: $(cat "$TMP_ROOT/lease-hung.err")"
[ ! -e "$HOME_DIR/state/lease-hung.meta" ] || fail "a spawn that launched nothing published a task record"
HUNG_WT=$(awk -F '\t' '$1 == "return" { print $NF }' "$TREEHOUSE_CALL_LOG" | tail -n 1)
[ -n "$HUNG_WT" ] || fail "the spawn did not hand its lease back; treehouse calls: $(cat "$TREEHOUSE_CALL_LOG")"
grep -Fx "$(printf 'return\t--force\t--if-lease-holder\tlease-hung\t%s' "$HUNG_WT")" "$TREEHOUSE_CALL_LOG" >/dev/null \
  || fail "the lease was not returned on the condition that lease-hung still holds it: $(cat "$TREEHOUSE_CALL_LOG")"
[ "$(lease_of "$HUNG_WT")" = "available " ] \
  || fail "the hung spawn's worktree is still held: '$(lease_of "$HUNG_WT")'"
pass "a pane shell that never runs firstmate's command is reported as such, and its lease goes back to the pool"
