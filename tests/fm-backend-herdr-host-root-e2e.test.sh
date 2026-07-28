#!/usr/bin/env bash
# Isolated real-Herdr acceptance for host-root spawn, completion, and teardown.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-host-root-e2e.XXXXXX")
SESSION="fm-lab-host-root-e2e-$$"
ID=host-root-e2e
WT=

cleanup() {
  [ -z "$WT" ] || treehouse return --force "$WT" >/dev/null 2>&1 || true
  herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$TMP_ROOT"
}
fail() {
  printf 'not ok - %s\n' "$1" >&2
  cleanup
  exit 1
}
assert_line() {
  grep -Fx -- "$2" "$1" >/dev/null 2>&1 || fail "$3"
}

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
export HERDR_SESSION="$SESSION"
export FM_HERDR_LAB_STATE_DIR="$TMP_ROOT/lab-state"
trap cleanup EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab"

make_repo() {
  local dir=$1
  shift
  mkdir -p "$dir"
  git -C "$dir" init -q
  "$@" "$dir"
  git -C "$dir" add .
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}
make_host() {
  printf 'host instructions\n' > "$1/AGENTS.md"
}
make_target() {
  printf 'target instructions\n' > "$1/AGENTS.md"
  printf 'target\n' > "$1/README.md"
}

HOST="$TMP_ROOT/host"
PROJECT="$TMP_ROOT/target"
HOME_ROOT="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
OBS="$TMP_ROOT/worker-observation"
make_repo "$HOST" make_host
make_repo "$PROJECT" make_target
mkdir -p "$HOME_ROOT/data" "$HOME_ROOT/state" "$HOME_ROOT/config" "$FAKEBIN"

cat > "$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
set -u
{
  printf 'cwd=%s\n' "$(pwd -P)"
  printf 'host=%s\n' "$FM_HOST_ROOT"
  printf 'target=%s\n' "$FM_TARGET_WORKTREE"
  printf 'target_top=%s\n' "$(git -C "$FM_TARGET_WORKTREE" rev-parse --show-toplevel)"
  printf 'host_instructions=%s\n' "$(cat "$FM_HOST_ROOT/AGENTS.md")"
  printf 'target_instructions=%s\n' "$(cat "$FM_TARGET_WORKTREE/AGENTS.md")"
} > "$FM_E2E_OBS"
printf 'worker edit\n' > "$FM_TARGET_WORKTREE/worker-edit.txt"
mkdir -p "$FM_HOME/data/$FM_E2E_TASK_ID"
printf '# Real Herdr host-root report\n' > "$FM_HOME/data/$FM_E2E_TASK_ID/report.md"
printf 'done: real Herdr host-root worker completed\n' >> "$FM_HOME/state/$FM_E2E_TASK_ID.status"
touch "$FM_HOME/state/$FM_E2E_TASK_ID.turn-ended"
SH
chmod +x "$FAKEBIN/codex"

(cd "$HOST" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_ROOT" FM_HOST_ROOT="$HOST" \
  "$ROOT/bin/fm-brief.sh" "$ID" "$(basename "$PROJECT")" >/dev/null) \
  || fail "could not create host-root brief"

SPAWN_OUT="$TMP_ROOT/spawn.out"
(cd "$HOST" && PATH="$FAKEBIN:$PATH" FM_SPAWN_NO_GUARD=1 \
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_ROOT" FM_HOST_ROOT="$HOST" \
  FM_E2E_OBS="$OBS" FM_E2E_TASK_ID="$ID" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --harness codex --backend herdr --scout \
  > "$SPAWN_OUT" 2>&1) || fail "real Herdr host-root spawn failed: $(cat "$SPAWN_OUT")"

for _ in $(seq 1 100); do
  [ -s "$OBS" ] && [ -e "$HOME_ROOT/state/$ID.turn-ended" ] && break
  sleep 0.1
done
[ -s "$OBS" ] || fail "worker did not publish host-root observations"
[ -e "$HOME_ROOT/state/$ID.turn-ended" ] || fail "worker completion lifecycle signal was absent"

META="$HOME_ROOT/state/$ID.meta"
[ -f "$META" ] || fail "spawn did not publish task metadata"
WT=$(sed -n 's/^worktree=//p' "$META")
PANE=$(sed -n 's/^herdr_pane_id=//p' "$META")
[ -n "$WT" ] && [ -d "$WT" ] || fail "spawn did not retain an isolated target worktree"
[ -n "$PANE" ] || fail "spawn did not record the Herdr pane"
HOST_REAL=$(cd "$HOST" && pwd -P)
WT_REAL=$(cd "$WT" && pwd -P)
assert_line "$OBS" "cwd=$HOST_REAL" "worker cwd was not the authoritative host"
assert_line "$OBS" "host=$HOST_REAL" "worker FM_HOST_ROOT was incorrect"
assert_line "$OBS" "target=$WT_REAL" "worker FM_TARGET_WORKTREE was incorrect"
assert_line "$OBS" "target_top=$WT_REAL" "worker target was not the isolated Git root"
assert_line "$OBS" "host_instructions=host instructions" "worker could not read host instructions"
assert_line "$OBS" "target_instructions=target instructions" "worker could not read target instructions"
assert_line "$META" "backend=herdr" "metadata did not retain the Herdr backend"
assert_line "$META" "host_root=$HOST_REAL" "metadata did not retain host authority"
[ -z "$(git -C "$HOST" status --short)" ] || fail "worker changed the host repository"
[ -z "$(git -C "$PROJECT" status --short)" ] || fail "worker changed the target primary checkout"
[ -f "$WT/worker-edit.txt" ] || fail "worker edit did not stay in the target worktree"
STATE_OUT=$(cd "$HOST" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_ROOT" FM_HOST_ROOT="$HOST_REAL" \
  "$ROOT/bin/fm-crew-state.sh" "$ID")
case "$STATE_OUT" in
  'state: done'* ) ;;
  *) fail "completion did not reconcile to done: $STATE_OUT" ;;
esac

TEARDOWN_OUT="$TMP_ROOT/teardown.out"
(cd "$HOST" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_ROOT" FM_HOST_ROOT="$HOST_REAL" \
  "$ROOT/bin/fm-teardown.sh" "$ID" > "$TEARDOWN_OUT" 2>&1) \
  || fail "real Herdr host-root teardown failed: $(cat "$TEARDOWN_OUT")"
[ ! -e "$META" ] || fail "teardown retained task metadata"
[ ! -d "$WT" ] || fail "teardown retained the target worktree"
if herdr pane get "$PANE" --session "$SESSION" >/dev/null 2>&1; then
  fail "teardown retained the Herdr pane"
fi
WT=
[ -z "$(git -C "$HOST" status --short)" ] || fail "teardown changed the host repository"
[ -z "$(git -C "$PROJECT" status --short)" ] || fail "teardown changed the target primary checkout"

herdr_safe_stop_and_delete "$SESSION" >/dev/null || fail "isolated Herdr lab teardown failed"
trap - EXIT
rm -rf "$TMP_ROOT"
printf 'ok - real Herdr host-root spawn, completion, and teardown\n'
