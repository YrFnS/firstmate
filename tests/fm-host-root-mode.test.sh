#!/usr/bin/env bash
# Focused behavior tests for the opt-in FM_HOST_ROOT four-root contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-host-root-mode)
LIB="$ROOT/bin/fm-host-root-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

make_host() {
  local path=$1
  fm_git_init_commit "$path"
  : > "$path/AGENTS.md"
  git -C "$path" add AGENTS.md
  git -C "$path" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm instructions
}

resolve_host() {
  FM_HOST_ROOT=$1 bash -c '. "$1"; fm_host_root_resolve "$2"' _ "$LIB" "$ROOT"
}

paths_overlap() {
  bash -c '. "$1"; fm_host_root_paths_overlap "$2" "$3"' _ "$LIB" "$1" "$2"
}

test_resolution_and_validation() {
  local host="$TMP/host with spaces and apostrophe's" link="$TMP/host-link" unsafe_target out status=0
  make_host "$host"
  ln -s "$host" "$link"
  out=$(resolve_host "$link") || status=$?
  expect_code 0 "$status" "symlinked host root should resolve"
  [ "$out" = "$(cd "$host" && pwd -P)" ] || fail "host root did not resolve physically: $out"

  status=0
  FM_HOST_ROOT="$TMP/missing" bash -c '. "$1"; fm_host_root_resolve "$2"' _ "$LIB" "$ROOT" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "missing host root must fail"
  status=0
  FM_HOST_ROOT="$ROOT" bash -c '. "$1"; fm_host_root_resolve "$2"' _ "$LIB" "$ROOT" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "host root equal to FM_ROOT must fail"
  status=0
  FM_HOST_ROOT=$'bad\nroot' bash -c '. "$1"; fm_host_root_resolve "$2"' _ "$LIB" "$ROOT" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "newline-unsafe host root must fail"
  status=0
  FM_HOST_ROOT=$'bad\aroot' bash -c '. "$1"; fm_host_root_resolve "$2"' _ "$LIB" "$ROOT" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "all metadata-unsafe control characters must fail"
  unsafe_target="$TMP/resolved"$'\n'"host"
  make_host "$unsafe_target"
  ln -s "$unsafe_target" "$TMP/clean-host-link"
  status=0
  FM_HOST_ROOT="$TMP/clean-host-link" bash -c '. "$1"; fm_host_root_resolve "$2"' _ "$LIB" "$ROOT" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "control characters introduced by physical resolution must fail"
  mkdir -p "$TMP/claude-only-host"
  : > "$TMP/claude-only-host/CLAUDE.md"
  status=0
  FM_HOST_ROOT="$TMP/claude-only-host" bash -c '. "$1"; fm_host_root_resolve "$2"' _ "$LIB" "$ROOT" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "a Claude-only instruction surface must not admit non-Claude workers"
  paths_overlap "$host" "$host" || fail "equal host and target roots were not classified as overlapping"
  paths_overlap "$host" "$host/nested-target" || fail "target nested under host was not classified as overlapping"
  paths_overlap "$host/nested-host" "$host" || fail "host nested under target was not classified as overlapping"
  if paths_overlap "$host" "$TMP/host-with-similar-prefix"; then
    fail "sibling paths with a shared prefix were classified as overlapping"
  fi
  pass "host-root library resolves physical paths and rejects unsafe, harness-specific, or overlapping roots"
}

test_session_cwd_mismatch_precedes_mutation() {
  local host="$TMP/session-host" home="$TMP/session-home" other="$TMP/session-other" fake_root out status=0
  make_host "$host"; mkdir -p "$home/state" "$home/data" "$home/config" "$other"
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-session-start.sh" 2>&1) || status=$?
  expect_code 2 "$status" "session-start host cwd mismatch must fail"
  assert_contains "$out" 'requires the supervisor cwd' "session-start mismatch did not explain the host cwd"
  [ -z "$(find "$home/state" -mindepth 1 -print -quit)" ] || fail "session-start mismatch mutated state before refusal"

  fake_root="$TMP/guard-root"
  mkdir -p "$fake_root/bin"
  : > "$fake_root/AGENTS.md"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_GUARD_MUTATION"
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  status=0
  (cd "$other" && FM_GUARD_MUTATION="$TMP/guard-ran" FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-spawn.sh" guarded "$TMP/missing-project" codex >/dev/null 2>&1) || status=$?
  expect_code 2 "$status" "spawn host cwd mismatch must fail"
  assert_absent "$TMP/guard-ran" "spawn ran the supervision guard before host validation"

  status=0
  (cd "$other" && FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-brief.sh" guarded-mate --secondmate --no-projects >/dev/null 2>&1) || status=$?
  expect_code 2 "$status" "secondmate brief host cwd mismatch must fail"
  assert_absent "$home/data/guarded-mate" "secondmate brief mutated task data before host validation"

  status=0
  (cd "$other" && FM_GUARD_MUTATION="$TMP/guard-ran" FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-spawn.sh" guarded-mate "$TMP/missing-home" codex --secondmate >/dev/null 2>&1) || status=$?
  expect_code 2 "$status" "secondmate spawn host cwd mismatch must fail"
  assert_absent "$TMP/guard-ran" "secondmate spawn ran the supervision guard before host validation"
  pass "host cwd mismatch is rejected before session, brief, or spawn mutation"
}

test_host_command_rendering() {
  local host="$TMP/render & host" home="$TMP/render-home" fake_root="$TMP/FirstMate & root's copy" rendered supervision command argv
  make_host "$host"; mkdir -p "$home/state" "$home/config" "$fake_root/bin"
  argv="$TMP/rendered-argv"
  cat > "$fake_root/bin/argv-probe" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_ARGV_LOG"
SH
  cp "$fake_root/bin/argv-probe" "$fake_root/bin/fm-watch-checkpoint.sh"
  chmod +x "$fake_root/bin/argv-probe" "$fake_root/bin/fm-watch-checkpoint.sh"
  rendered=$(FM_HOST_ROOT="$host" bash -c '. "$1"; fm_host_root_command "$2" bin/argv-probe' _ "$LIB" "$fake_root")
  FM_ARGV_LOG="$argv" bash -c "$rendered one 'two words' \"apostrophe's\""
  [ "$(cat "$argv")" = $'one\ntwo words\napostrophe\x27s' ] || fail "quoted host command did not preserve argv"

  supervision=$(FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness codex --repair-line)
  assert_contains "$supervision" "FirstMate & root'\\''s copy/bin'/fm-watch-checkpoint.sh" \
    "host supervision did not shell-quote its absolute command"
  command=$(printf '%s\n' "$supervision" | sed -n 's/.*checkpoint: \(.*\) --seconds.*/\1/p')
  FM_ARGV_LOG="$argv" bash -c "$command --seconds 7"
  [ "$(cat "$argv")" = $'--seconds\n7' ] || fail "rendered supervision command did not preserve argv"
  pass "host mode shell-quotes absolute commands and preserves argv"
}

test_brief_variants() {
  local host="$TMP/brief & host" home="$TMP/brief-home" brief normal_home="$TMP/normal-home"
  make_host "$host"
  mkdir -p "$home/data" "$normal_home/data"
  (cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-brief.sh" lane-host alpha >/dev/null 2>&1)
  brief="$home/data/lane-host/brief.md"
  assert_grep '<!-- firstmate-execution-mode: host-root -->' "$brief" "host brief marker missing"
  assert_contains "$(cat "$brief")" "$host" "host brief corrupted the literal host path"
  # shellcheck disable=SC2016  # Assertions intentionally match literal worker variables.
  assert_contains "$(cat "$brief")" 'git -C "$FM_TARGET_WORKTREE"' "host brief does not scope Git to the target"
  assert_grep 'Read the target worktree root instructions' "$brief" "host brief does not require target instructions"
  assert_grep 'top-level process cwd at the host root' "$brief" "host brief does not preserve host cwd"
  # shellcheck disable=SC2016
  assert_contains "$(cat "$brief")" '(cd "$FM_TARGET_WORKTREE" && no-mistakes doctor)' "host brief does not scope no-mistakes setup"
  # shellcheck disable=SC2016
  assert_contains "$(cat "$brief")" '(cd "$FM_TARGET_WORKTREE" && no-mistakes axi run --help)' "host brief does not scope no-mistakes help"
  # shellcheck disable=SC2016
  assert_contains "$(cat "$brief")" '(cd "$FM_TARGET_WORKTREE" && no-mistakes axi respond ...)' "host brief does not scope no-mistakes responses"
  assert_no_grep '`no-mistakes axi' "$brief" "host brief leaves a bare no-mistakes CLI command"

  FM_HOME="$normal_home" "$ROOT/bin/fm-brief.sh" lane-normal 'alpha & beta' >/dev/null 2>&1
  assert_no_grep 'firstmate-execution-mode: host-root' "$normal_home/data/lane-normal/brief.md" "default brief changed execution mode"
  assert_contains "$(cat "$normal_home/data/lane-normal/brief.md")" 'alpha & beta' "default brief corrupted the literal repository name"
  assert_grep 'git checkout -b fm/lane-normal' "$normal_home/data/lane-normal/brief.md" "default brief lost its normal branch command"
  pass "brief scaffolding has an explicit host variant and unchanged default variant"
}

make_fakebin() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\037' "$@" >> "$FM_TMUX_LOG"; printf '\n' >> "$FM_TMUX_LOG"
endpoint=${FM_ENDPOINT_ALIVE:-$FM_CURRENT_PATH.endpoint}
if [ "${1:-}" = send-keys ] && printf '%s\n' "$*" | grep -q -- ' -l '; then
  case "${*: -1}" in
    'Read the brief at '*' and follow it exactly.') : ;;
    *) printf '%s' "${*: -1}" > "$FM_LAUNCH_FILE" ;;
  esac
  : > "$FM_LAUNCH_FILE.literal"
  [ "${FM_FAIL_LAUNCH_SEND:-0}" != 1 ] || exit 91
fi
if [ "${1:-}" = send-keys ] && [ "${*: -1}" = Enter ] && [ -f "$FM_LAUNCH_FILE.literal" ]; then
  [ "${FM_FAIL_LAUNCH_ENTER:-0}" != 1 ] || exit 92
fi
case "${1:-}" in
  display-message)
    case "$*" in
      *'#{pane_current_path}'*) [ -f "$endpoint" ] && cat "$FM_CURRENT_PATH" ;;
      *'#{cursor_y}'*) printf '0\n' ;;
      *'#{window_id}'*) [ -f "$endpoint" ] && printf '%%1\n' ;;
      *'#{pane_id}'*) [ -f "$endpoint" ] && printf '%%1\n' ;;
      *) printf 'test-session\n' ;;
    esac
    ;;
  capture-pane)
    if [ "${FM_FAKE_KIMI:-0}" = 1 ]; then
      printf 'Welcome to Kimi Code!\n│ > │\ncontext: 1%%\n'
    fi
    ;;
  list-windows) [ -z "${FM_EXISTING_WINDOW:-}" ] || printf '%s\n' "$FM_EXISTING_WINDOW" ;;
  list-panes) [ ! -f "$endpoint" ] || printf '%%1|@1|test-session:fm-rollback-stuck|test-session:1.0\n' ;;
  has-session|new-session|set-window-option) ;;
  new-window) : > "$endpoint"; printf '%%1\n' ;;
  kill-window) [ "${FM_REFUSE_STOP:-0}" = 1 ] || rm -f "$endpoint" ;;
  send-keys)
    case "$*" in
      *'treehouse get'*) printf '%s\n' "$FM_TARGET_PATH" > "$FM_CURRENT_PATH" ;;
      *'cd -- '* ) [ "${FM_REFUSE_HOST_MOVE:-0}" = 1 ] || printf '%s\n' "$FM_HOST_PATH" > "$FM_CURRENT_PATH" ;;
    esac
    ;;
esac
SH
  chmod +x "$fb/tmux"
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_TREEHOUSE_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_TREEHOUSE_LOG"
exit 0
SH
  chmod +x "$fb/treehouse"
  cat > "$fb/codex" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_CODEX_ARGV:-}" ] || printf '%s\0' "$@" > "$FM_CODEX_ARGV"
printf 'cwd=%s\nhost=%s\ntarget=%s\n' "$(pwd -P)" "${FM_HOST_ROOT:-}" "${FM_TARGET_WORKTREE:-}" > "$FM_WORKER_OBS"
printf 'target edit\n' > "$FM_TARGET_WORKTREE/worker-edit.txt"
SH
  chmod +x "$fb/codex"
  cat > "$fb/kimi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/kimi"
  printf '%s\n' "$fb"
}

test_spawn_separates_roots() {
  local host="$TMP/spawn & host" home="$TMP/spawn home's & #%?" project="$TMP/target & repo" wt="$TMP/target & worktree" fb log current launch obs argv turnend meta before after tree_line cd_line launch_line
  make_host "$host"
  mkdir -p "$home/data/lane" "$home/state" "$home/config"
  fm_git_init_commit "$project"
  git -C "$project" worktree add -q --detach "$wt"
  (cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-brief.sh" lane "$(basename "$project")" >/dev/null 2>&1)
  fb=$(make_fakebin "$TMP/fake")
  log="$TMP/tmux.log"; current="$TMP/current"; launch="$TMP/launch"; obs="$TMP/worker-observation"; argv="$TMP/codex.argv"
  printf '%s\n' "$project" > "$current"
  before=$(git -C "$host" status --porcelain)
  (cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$launch" FM_CURRENT_PATH="$current" FM_TARGET_PATH="$wt" FM_HOST_PATH="$host" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" lane "$project" codex > "$TMP/spawn.out" 2>&1) \
    || fail "host-root spawn failed: $(cat "$TMP/spawn.out")"
  meta="$home/state/lane.meta"
  assert_grep "worktree=$wt" "$meta" "spawn meta lost target worktree"
  assert_grep "host_root=$host" "$meta" "spawn meta lost host root"
  assert_contains "$(cat "$log")" "FM_TARGET_WORKTREE='$wt'" "child launch did not export exact target worktree"
  assert_contains "$(cat "$log")" "FM_HOST_ROOT='$host'" "child launch did not export exact host root"
  assert_contains "$(cat "$log")" 'notify=[' "Codex FirstMate turn-end safeguard was not retained"
  [ "$(cat "$current")" = "$host" ] || fail "endpoint did not finish at physical host root"
  tree_line=$(grep -nF 'treehouse get' "$log" | head -1 | cut -d: -f1)
  cd_line=$(grep -nF 'cd --' "$log" | head -1 | cut -d: -f1)
  launch_line=$(grep -nF 'FM_TARGET_WORKTREE=' "$log" | head -1 | cut -d: -f1)
  [ "$tree_line" -lt "$cd_line" ] && [ "$cd_line" -lt "$launch_line" ] || fail "spawn order was not worktree then host root then harness"
  (cd "$host" && PATH="$fb:$PATH" FM_WORKER_OBS="$obs" FM_CODEX_ARGV="$argv" bash -c "$(cat "$launch")")
  assert_grep "cwd=$host" "$obs" "worker harness did not start from the host root"
  assert_grep "host=$host" "$obs" "worker did not receive the exact host root"
  assert_grep "target=$wt" "$obs" "worker did not receive the exact target worktree"
  turnend="$(cd "$home/state" && pwd -P)/lane.turn-ended"
  python3 - "$argv" "$turnend" <<'PY' || fail "Codex notify argv did not preserve the hostile turn-end path"
import pathlib, subprocess, sys
args = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")
args = [a.decode() for a in args if a]
assert args.count("-c") == 1, args
i = args.index("-c")
config = args[i + 1]
assert config.startswith('notify=["bash","-c","touch -- '), config
assert config.endswith('"]'), config
subprocess.run(["bash", "-c", config[len('notify=["bash","-c","'):-2]], check=True)
PY
  assert_present "$turnend" "Codex notify command did not touch the exact hostile path"
  assert_present "$wt/worker-edit.txt" "disposable worker probe did not edit the target worktree"
  assert_absent "$host/worker-edit.txt" "disposable worker probe edited the host root"
  after=$(git -C "$host" status --porcelain)
  [ "$before" = "$after" ] || fail "host working tree changed during spawn or worker probe"
  pass "spawn orders and separates host cwd, target metadata, child environment, and target-only edits"
}

test_duplicate_spawn_preserves_existing_task() {
  local host="$TMP/duplicate-host" home="$TMP/duplicate-home" project="$TMP/duplicate-target" fb log current launch out status=0
  make_host "$host"
  fm_git_init_commit "$project"
  mkdir -p "$home/data/lane" "$home/state" "$home/config"
  (cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-brief.sh" lane target >/dev/null 2>&1)
  printf 'window=test-session:fm-lane\nworktree=/tmp/existing-worktree\nhost_root=%s\nproject=%s\nkind=ship\n' \
    "$host" "$project" > "$home/state/lane.meta"
  printf 'working: existing task\n' > "$home/state/lane.status"
  cp "$home/state/lane.meta" "$TMP/existing.meta"
  cp "$home/state/lane.status" "$TMP/existing.status"
  fb=$(make_fakebin "$TMP/fake-duplicate")
  log="$TMP/duplicate.log"; current="$TMP/duplicate.current"; launch="$TMP/duplicate.launch"
  printf '%s\n' "$project" > "$current"
  : > "$current.endpoint"

  out=$(cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_EXISTING_WINDOW=fm-lane FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$launch" FM_CURRENT_PATH="$current" \
    FM_TARGET_PATH=/tmp/unused FM_HOST_PATH="$host" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" lane "$project" codex 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "duplicate spawn unexpectedly succeeded"
  assert_contains "$out" 'window test-session:fm-lane already exists' "duplicate spawn refusal was not explicit"
  assert_no_grep 'kill-window' "$log" "duplicate spawn killed the existing task endpoint"
  cmp -s "$TMP/existing.meta" "$home/state/lane.meta" || fail "duplicate spawn changed existing metadata"
  cmp -s "$TMP/existing.status" "$home/state/lane.status" || fail "duplicate spawn changed existing status"
  assert_present "$current.endpoint" "duplicate spawn removed the existing endpoint"
  pass "duplicate spawn preserves the existing endpoint and task records"
}

test_spawn_rejects_host_as_target_and_cleans_failed_transition() {
  local host="$TMP/refusal-host" home="$TMP/refusal-home" project="$TMP/refusal-target" wt="$TMP/refusal-wt" fb log current tree_log out status=0
  make_host "$host"
  mkdir -p "$home/data/host-target" "$home/data/move-fail" "$home/state" "$home/config"
  fm_git_init_commit "$project"
  git -C "$project" worktree add -q --detach "$wt"
  (cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-brief.sh" host-target target >/dev/null 2>&1)
  (cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-brief.sh" move-fail target >/dev/null 2>&1)
  fb=$(make_fakebin "$TMP/fake-refusals")
  log="$TMP/refusals.log"; current="$TMP/refusals.current"; tree_log="$TMP/treehouse.log"

  printf '%s\n' "$project" > "$current"
  out=$(cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$TMP/refusal.launch" FM_CURRENT_PATH="$current" FM_TARGET_PATH="$host" \
    FM_HOST_PATH="$host" FM_TREEHOUSE_LOG="$tree_log" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" host-target "$project" codex 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted FM_HOST_ROOT as the target worktree"
  assert_contains "$out" 'overlapping host and target roots' "host-as-target refusal was not explicit"
  assert_contains "$(cat "$log")" 'kill-window' "host-as-target refusal leaked its tmux endpoint"
  assert_no_grep 'return --force' "$tree_log" "host-as-target refusal tried to recycle the authoritative host path"
  assert_present "$home/state/host-target.meta" "host-as-target refusal lost recovery metadata for the preserved path"

  : > "$log"; : > "$tree_log"; printf '%s\n' "$project" > "$current"; status=0
  out=$(cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_HOST_CWD_ATTEMPTS=1 FM_HOST_CWD_DELAY=0 FM_REFUSE_HOST_MOVE=1 \
    FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$TMP/move-fail.launch" FM_CURRENT_PATH="$current" FM_TARGET_PATH="$wt" \
    FM_HOST_PATH="$host" FM_TREEHOUSE_LOG="$tree_log" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" move-fail "$project" codex 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a backend that never entered FM_HOST_ROOT"
  assert_contains "$out" 'did not enter FM_HOST_ROOT' "host transition failure was not explicit"
  assert_contains "$(cat "$log")" 'kill-window' "failed host transition leaked its tmux endpoint"
  assert_grep 'return --force' "$tree_log" "failed host transition did not return the acquired worktree"
  assert_absent "$home/state/move-fail.meta" "successful transition cleanup left recovery metadata"
  pass "host overlap preserves the path while ordinary transition failures clean their resources"
}

test_orca_active_cwd_probe() {
  local out
  out=$(bash -c '
    . "$1/bin/backends/orca.sh"
    fm_backend_orca_send_text_line() {
      markers=$(printf "%s\n" "$2" | grep -o "__FM_ORCA_CWD_[A-Z]*_[A-Za-z0-9_]*__")
      begin=$(printf "%s\n" "$markers" | head -1)
      end=$(printf "%s\n" "$markers" | tail -1)
    }
    fm_backend_orca_read_text_paged() {
      printf "%s\n" "$begin" "/tmp/orca host" "$end"
    }
    fm_backend_orca_current_path terminal-1
  ' _ "$ROOT")
  [ "$out" = "/tmp/orca host" ] || fail "Orca active cwd probe returned '$out'"
  pass "Orca backend reads the live shell cwd through a bounded marker probe"
}

test_all_harnesses_add_one_task_safeguard() {
  local host="$TMP/adapters-host" home="$TMP/adapter home's #%?" project="$TMP/adapters-target" before after harness id wt fb log current launch text count out status=0
  make_host "$host"
  fm_git_init_commit "$project"
  mkdir -p "$home/data" "$home/state" "$home/config"
  mkdir -p "$TMP/harness-home/.kimi-code"
  printf 'default_model = "test"\n' > "$TMP/harness-home/.kimi-code/config.toml"
  before=$(git -C "$host" status --porcelain)
  for harness in claude codex opencode pi grok kimi; do
    id="adapter-$harness"
    wt="$TMP/$id-wt"
    git -C "$project" worktree add -q --detach "$wt"
    (cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-brief.sh" "$id" "$(basename "$project")" >/dev/null 2>&1)
    fb=$(make_fakebin "$TMP/fake-$harness")
    log="$TMP/$id.log"; current="$TMP/$id.current"; launch="$TMP/$id.launch"
    printf '%s\n' "$project" > "$current"
    (cd "$host" && HOME="$TMP/harness-home" PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
      FM_FAKE_KIMI=1 FM_KIMI_READY_POLLS=1 FM_KIMI_DELIVERY_POLLS=1 FM_KIMI_POLL_INTERVAL=0 \
      FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$launch" FM_CURRENT_PATH="$current" FM_TARGET_PATH="$wt" FM_HOST_PATH="$host" TMUX=fake \
      "$ROOT/bin/fm-spawn.sh" "$id" "$project" "$harness" >/dev/null)
    text=$(cat "$launch")
    bash -n -c "$text" || fail "$harness host-root launch is not valid shell"
    case "$harness" in
      claude)
        count=$(printf '%s' "$text" | grep -o -- '--settings' | wc -l | tr -d ' ')
        [ "$count" -eq 1 ] || fail "Claude task settings appeared $count times"
        assert_present "$home/state/$id.claude-settings.json" "Claude task settings file missing"
        node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$home/state/$id.claude-settings.json" \
          || fail "Claude task settings are invalid JSON"
        ;;
      codex)
        count=$(printf '%s' "$text" | grep -oF 'notify=[' | wc -l | tr -d ' ')
        [ "$count" -eq 1 ] || fail "Codex notify safeguard appeared $count times"
        ;;
      opencode)
        count=$(printf '%s' "$text" | grep -oF 'opencode-turn-end.js' | wc -l | tr -d ' ')
        [ "$count" -eq 1 ] || fail "OpenCode task plugin appeared $count times"
        assert_present "$home/state/$id.opencode-turn-end.js" "OpenCode task plugin missing"
        assert_contains "$text" '%23%25%3F' "OpenCode task plugin file URL did not encode path metacharacters"
        node --check "$home/state/$id.opencode-turn-end.js" >/dev/null \
          || fail "OpenCode task plugin is invalid JavaScript"
        ;;
      pi)
        count=$(printf '%s' "$text" | grep -oF "$id.pi-ext.ts" | wc -l | tr -d ' ')
        [ "$count" -eq 1 ] || fail "Pi task extension appeared $count times"
        assert_present "$home/state/$id.pi-ext.ts" "Pi task extension missing"
        ;;
      grok)
        count=$(printf '%s' "$text" | grep -oF 'FM_GROK_TURNEND_TOKEN=' | wc -l | tr -d ' ')
        [ "$count" -eq 1 ] || fail "Grok task token appeared $count times"
        assert_absent "$host/.fm-grok-turnend" "Grok host launch wrote a task pointer into the host"
        ;;
      kimi)
        count=$(printf '%s' "$text" | grep -oF 'FM_KIMI_TURNEND_TOKEN=' | wc -l | tr -d ' ')
        [ "$count" -eq 1 ] || fail "Kimi task token appeared $count times"
        assert_present "$home/state/$id.kimi-turnend-token" "Kimi task token state is missing"
        assert_absent "$host/.fm-kimi-turnend" "Kimi host launch wrote a task pointer into the host"
        ;;
    esac
    rm -rf "/tmp/fm-$id"
  done

  id=adapter-raw
  (cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-brief.sh" "$id" "$(basename "$project")" >/dev/null 2>&1)
  out=$(cd "$host" && FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" 'claude --dangerously-skip-permissions' 2>&1) || status=$?
  expect_code 2 "$status" "host mode must reject a raw launch command without a verified task safeguard"
  assert_contains "$out" 'requires a named verified harness' "raw host launch refusal was not explicit"
  assert_absent "$home/state/$id.meta" "raw host launch mutated task state before refusal"

  after=$(git -C "$host" status --porcelain)
  [ "$before" = "$after" ] || fail "harness integration rewrote host configuration"
  pass "all six harnesses add one task safeguard without changing host hooks"
}

test_mutators_require_host_cwd() {
  local host="$TMP/mutator-host" other="$TMP/mutator-other" home="$TMP/mutator-home" out status=0
  make_host "$host"
  mkdir -p "$other" "$home/state"
  printf 'window=fake:fm-lane\nworktree=/tmp/target\nhost_root=%s\nproject=/tmp/project\nkind=ship\n' "$host" > "$home/state/lane.meta"
  printf 'window=fake:fm-scout\nworktree=/tmp/scout\nhost_root=%s\nproject=/tmp/project\nkind=scout\n' "$host" > "$home/state/scout.meta"
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-send.sh" lane hello 2>&1) || status=$?
  expect_code 2 "$status" "fm-send must reject a host cwd mismatch"
  assert_contains "$out" 'requires the recorded host root cwd' "fm-send host mismatch was not explicit"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-teardown.sh" lane 2>&1) || status=$?
  expect_code 2 "$status" "fm-teardown must reject a host cwd mismatch"
  assert_present "$home/state/lane.meta" "teardown mutated task state before host validation"
  printf 'mode=local-only\n' >> "$home/state/lane.meta"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-merge-local.sh" lane 2>&1) || status=$?
  expect_code 2 "$status" "fm-merge-local must reject a host cwd mismatch"
  assert_present "$home/state/lane.meta" "local merge mutated task state before host validation"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-pr-merge.sh" lane https://github.com/example/repo/pull/1 2>&1) || status=$?
  expect_code 2 "$status" "fm-pr-merge must reject a host cwd mismatch"
  assert_present "$home/state/lane.meta" "PR merge mutated task state before host validation"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-pr-check.sh" lane https://github.com/example/repo/pull/1 2>&1) || status=$?
  expect_code 2 "$status" "fm-pr-check must reject a host cwd mismatch"
  if grep -q '^pr=' "$home/state/lane.meta"; then
    fail "PR check mutated task metadata before host validation"
  fi
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-review-diff.sh" lane --stat 2>&1) || status=$?
  expect_code 2 "$status" "fm-review-diff must reject a host cwd mismatch"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-promote.sh" scout 2>&1) || status=$?
  expect_code 2 "$status" "fm-promote must reject a host cwd mismatch"
  grep -qx 'kind=scout' "$home/state/scout.meta" || fail "promote mutated task metadata before host validation"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-check-register.sh" lane 2>&1) || status=$?
  expect_code 2 "$status" "fm-check-register must reject a host cwd mismatch"
  assert_absent "$home/state/lane.check-trust" "check registration mutated trust state before host validation"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-decision-hold.sh" complete lane --none 2>&1) || status=$?
  expect_code 2 "$status" "fm-decision-hold must reject a host cwd mismatch"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-x-followup.sh" --check lane 2>&1) || status=$?
  expect_code 2 "$status" "fm-x-followup must reject a host cwd mismatch"
  status=0
  out=$(cd "$other" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-x-link.sh" lane request-1 2>&1) || status=$?
  expect_code 2 "$status" "fm-x-link must reject a host cwd mismatch"
  pass "task lifecycle actions reject host cwd mismatch before mutation"
}

test_secondmate_actions_keep_supervisor_host_authority() {
  local host="$TMP/secondmate-action-host" other="$TMP/secondmate-action-other" meta="$TMP/secondmate-action.meta" ordinary="$TMP/ordinary-action.meta" out status=0
  make_host "$host"
  mkdir -p "$other"
  printf 'window=fm-mate\nworktree=/tmp/mate\nkind=secondmate\n' > "$meta"
  printf 'window=fm-task\nworktree=/tmp/task\nkind=ship\n' > "$ordinary"

  (cd "$host" && FM_HOST_ROOT="$host" bash -c '. "$1"; fm_host_root_assert_task_cwd "$2" "$3"' _ "$LIB" "$ROOT" "$meta") \
    || status=$?
  expect_code 0 "$status" "secondmate action should use the primary supervisor host cwd without host_root metadata"

  status=0
  out=$(cd "$other" && FM_HOST_ROOT="$host" bash -c '. "$1"; fm_host_root_assert_task_cwd "$2" "$3"' _ "$LIB" "$ROOT" "$meta" 2>&1) \
    || status=$?
  expect_code 2 "$status" "secondmate action must still reject a supervisor host cwd mismatch"
  assert_contains "$out" 'requires the supervisor cwd' "secondmate cwd mismatch did not preserve primary host authority"

  status=0
  out=$(cd "$host" && FM_HOST_ROOT="$host" bash -c '. "$1"; fm_host_root_assert_task_cwd "$2" "$3"' _ "$LIB" "$ROOT" "$ordinary" 2>&1) \
    || status=$?
  expect_code 2 "$status" "ordinary task without host_root metadata must remain rejected"
  assert_contains "$out" 'has no recorded host_root' "secondmate exception weakened ordinary task ownership"
  pass "secondmate actions retain primary host cwd authority without inheriting host_root metadata"
}

test_spawn_rollback_is_transactional() {
  local host="$TMP/rollback-host" home="$TMP/rollback-home" project="$TMP/rollback-target" wt="$TMP/rollback-wt" stuck_wt="$TMP/rollback-stuck-wt" uncertain_wt="$TMP/rollback-uncertain-wt" fb log current tree_log out status=0
  make_host "$host"; mkdir -p "$home/data" "$home/state" "$home/config"; fm_git_init_commit "$project"
  git -C "$project" worktree add -q --detach "$wt"
  git -C "$project" worktree add -q --detach "$stuck_wt"
  git -C "$project" worktree add -q --detach "$uncertain_wt"
  for id in rollback-clean rollback-stuck rollback-uncertain; do
    (cd "$host" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
      "$ROOT/bin/fm-brief.sh" "$id" target >/dev/null 2>&1)
  done
  fb=$(make_fakebin "$TMP/fake-rollback")
  log="$TMP/rollback.log"; current="$TMP/rollback.current"; tree_log="$TMP/rollback-treehouse.log"
  printf '%s\n' "$project" > "$current"
  out=$(cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_FAIL_LAUNCH_SEND=1 FM_BACKEND_STOP_ATTEMPTS=1 FM_BACKEND_STOP_DELAY=0 FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$TMP/rollback.launch" \
    FM_CURRENT_PATH="$current" FM_TARGET_PATH="$wt" FM_HOST_PATH="$host" FM_TREEHOUSE_LOG="$tree_log" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" rollback-clean "$project" pi 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "injected launch failure unexpectedly succeeded"
  assert_grep 'return --force' "$tree_log" "successful rollback did not return the isolated copy"
  assert_absent "$home/state/rollback-clean.meta" "successful rollback left metadata"
  assert_absent "$home/state/rollback-clean.pi-ext.ts" "successful rollback left its pre-record Pi artifact"
  assert_absent "/tmp/fm-rollback-clean" "successful rollback left its task temp root"

  : > "$log"; : > "$tree_log"; printf '%s\n' "$project" > "$current"; status=0
  out=$(cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_FAIL_LAUNCH_SEND=1 FM_REFUSE_STOP=1 FM_BACKEND_STOP_ATTEMPTS=1 FM_BACKEND_STOP_DELAY=0 FM_TMUX_LOG="$log" \
    FM_LAUNCH_FILE="$TMP/rollback-stuck.launch" FM_CURRENT_PATH="$current" FM_TARGET_PATH="$stuck_wt" FM_HOST_PATH="$host" \
    FM_TREEHOUSE_LOG="$tree_log" TMUX=fake "$ROOT/bin/fm-spawn.sh" rollback-stuck "$project" pi 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "injected stop failure unexpectedly succeeded"
  assert_contains "$out" 'still exists after stop' "failed endpoint termination was not explicit (backend log: $(tr '\n' ';' < "$log"))"
  assert_no_grep 'return --force' "$tree_log" "rollback reused the isolated copy after unconfirmed termination"
  assert_present "$home/state/rollback-stuck.meta" "failed rollback lost recovery metadata"
  assert_present "$home/state/rollback-stuck.pi-ext.ts" "failed rollback discarded a recoverable pre-record artifact"
  assert_present "/tmp/fm-rollback-stuck" "failed rollback discarded its recoverable task temp root"
  rm -rf "/tmp/fm-rollback-stuck"
  rm -f "$home/state/rollback-stuck.meta" "$home/state/rollback-stuck.pi-ext.ts" "$current.endpoint"

  : > "$log"; : > "$tree_log"; printf '%s\n' "$project" > "$current"; status=0
  out=$(cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" \
    FM_FAIL_LAUNCH_ENTER=1 FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$TMP/rollback-uncertain.launch" \
    FM_CURRENT_PATH="$current" FM_TARGET_PATH="$uncertain_wt" FM_HOST_PATH="$host" FM_TREEHOUSE_LOG="$tree_log" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" rollback-uncertain "$project" pi 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "ambiguous Enter failure unexpectedly succeeded"
  assert_contains "$out" 'launch submission could not be confirmed' "ambiguous Enter failure did not explain the retained task"
  assert_no_grep 'kill-window' "$log" "ambiguous Enter failure killed a possibly running worker"
  assert_no_grep 'return --force' "$tree_log" "ambiguous Enter failure recycled a possibly active worktree"
  assert_present "$home/state/rollback-uncertain.meta" "ambiguous Enter failure lost task metadata"
  assert_present "$home/state/rollback-uncertain.pi-ext.ts" "ambiguous Enter failure lost its task safeguard"
  assert_present "/tmp/fm-rollback-uncertain" "ambiguous Enter failure removed its task temp root"
  rm -rf "/tmp/fm-rollback-uncertain"
  rm -f "$home/state/rollback-uncertain.meta" "$home/state/rollback-uncertain.pi-ext.ts" "$current.endpoint"
  pass "spawn rollback cleans pre-launch failures and preserves ambiguous launch submissions"
}

test_task_actions_use_recorded_host_root() {
  local host="$TMP/recorded-host" wrong="$TMP/wrong-host" home="$TMP/recorded-home" fb log current out status=0
  make_host "$host"; make_host "$wrong"; mkdir -p "$home/state" "$home/config"
  printf 'window=test-session:fm-lane\nworktree=/tmp/target\nhost_root=%s\nproject=/tmp/project\nkind=ship\n' "$host" > "$home/state/lane.meta"
  fb=$(make_fakebin "$TMP/fake-recorded-host")
  log="$TMP/recorded-host.log"; current="$TMP/recorded-host.current"
  : > "$log"; printf '%s\n' "$host" > "$current"; : > "$current.endpoint"
  out=$(cd "$wrong" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$wrong" \
    FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$TMP/unused.launch" FM_CURRENT_PATH="$current" FM_TARGET_PATH=/tmp/target FM_HOST_PATH="$host" \
    "$ROOT/bin/fm-send.sh" lane hello 2>&1) || status=$?
  expect_code 2 "$status" "send must reject an ambient host that differs from task ownership"
  assert_contains "$out" 'does not match task metadata host_root' "send did not identify recorded host ownership"
  assert_no_grep 'send-keys' "$log" "send touched the endpoint before recorded-host validation"
  status=0
  out=$(cd "$wrong" && PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$wrong" \
    FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$TMP/unused.launch" FM_CURRENT_PATH="$current" FM_TARGET_PATH=/tmp/target FM_HOST_PATH="$host" \
    "$ROOT/bin/fm-teardown.sh" lane --force 2>&1) || status=$?
  expect_code 2 "$status" "teardown must reject an ambient host that differs from task ownership"
  assert_present "$home/state/lane.meta" "teardown changed task data before recorded-host validation"
  pass "task actions bind to recorded physical host ownership before endpoint or task mutation"
}

test_spawn_rejects_old_brief_and_secondmate_clears_roots() {
  local host="$TMP/reject-host" home="$TMP/reject-home" project="$TMP/reject-target" subhome="$TMP/secondmate-home" fb log current launch meta out status=0
  make_host "$host"; mkdir -p "$home/data/old" "$home/state" "$home/config"; printf 'old brief\n' > "$home/data/old/brief.md"; fm_git_init_commit "$project"
  out=$(cd "$host" && FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_HOST_ROOT="$host" "$ROOT/bin/fm-spawn.sh" old "$project" codex 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "host spawn accepted a cwd-relative old brief"
  assert_contains "$out" 'requires a host-root brief' "old-brief rejection was not explicit"

  mkdir -p "$subhome/bin" "$subhome/data"
  printf '# Secondmate\n' > "$subhome/AGENTS.md"
  printf 'mate\n' > "$subhome/.fm-secondmate-home"
  printf 'charter\n' > "$subhome/data/charter.md"
  fb=$(make_fakebin "$TMP/fake-secondmate")
  log="$TMP/secondmate.log"; current="$TMP/secondmate.current"; launch="$TMP/secondmate.launch"
  printf '%s\n' "$subhome" > "$current"
  (cd "$host" && PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_HOST_ROOT="$host" FM_TARGET_WORKTREE=/should-not-leak FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$launch" \
    FM_CURRENT_PATH="$current" FM_TARGET_PATH="$subhome" FM_HOST_PATH="$host" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" mate "$subhome" codex --secondmate >/dev/null 2>&1)
  assert_contains "$(cat "$launch")" 'FM_HOST_ROOT= FM_TARGET_WORKTREE=' "secondmate launch did not clear both host variables"
  meta="$home/state/mate.meta"
  assert_no_grep '^host_root=' "$meta" "secondmate metadata inherited host_root"
  assert_grep "worktree=$subhome" "$meta" "secondmate lost its isolated-home worktree"

  : > "$launch"; printf '%s\n' "$subhome" > "$current"
  (cd "$host" && env -u FM_HOST_ROOT -u FM_TARGET_WORKTREE PATH="$fb:$PATH" FM_SPAWN_NO_GUARD=1 \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_TMUX_LOG="$log" FM_LAUNCH_FILE="$launch" \
    FM_CURRENT_PATH="$current" FM_TARGET_PATH="$subhome" FM_HOST_PATH="$host" TMUX=fake \
    "$ROOT/bin/fm-spawn.sh" mate-unset "$subhome" codex --secondmate >/dev/null 2>&1)
  assert_not_contains "$(cat "$launch")" 'FM_HOST_ROOT=' "unset-mode secondmate launch changed its historical environment prefix"
  assert_not_contains "$(cat "$launch")" 'FM_TARGET_WORKTREE=' "unset-mode secondmate launch set a new empty target variable"
  pass "host spawn rejects old briefs, clears inherited secondmate roots, and preserves unset launches"
}

test_resolution_and_validation
test_session_cwd_mismatch_precedes_mutation
test_host_command_rendering
test_brief_variants
test_spawn_separates_roots
test_duplicate_spawn_preserves_existing_task
test_spawn_rejects_host_as_target_and_cleans_failed_transition
test_orca_active_cwd_probe
test_all_harnesses_add_one_task_safeguard
test_mutators_require_host_cwd
test_secondmate_actions_keep_supervisor_host_authority
test_spawn_rollback_is_transactional
test_task_actions_use_recorded_host_root
test_spawn_rejects_old_brief_and_secondmate_clears_roots
