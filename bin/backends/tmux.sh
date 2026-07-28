#!/usr/bin/env bash
# bin/backends/tmux.sh - the tmux session-provider adapter.
#
# Reference backend (AGENTS.md section 8; data/fm-backend-design-d7). P1 moves
# the tmux command sequences that fm-send.sh, fm-peek.sh, fm-watch.sh,
# fm-spawn.sh, and fm-teardown.sh already ran inline into named functions
# here, running the EXACT same commands in the EXACT same order, so the
# default (tmux, `backend=` absent) path stays byte-identical. Sourced only
# through bin/fm-backend.sh's fm_backend_source, never directly.
#
# Worktree acquisition (running `treehouse get` inside the pane, and polling
# its cwd) is unchanged by this extraction: P1 scopes only the session
# provider, not the worktree provider, so fm-spawn.sh still drives that part
# inline with these same send/current-path primitives.
#
# The verified composer/busy-detection and verify-and-retry-submit primitives
# already live in bin/fm-tmux-lib.sh, shared with the away-mode daemon
# (bin/fm-supervise-daemon.sh); this adapter sources that file and re-exports
# its submit core under the backend's naming convention rather than
# duplicating it, so the two consumers cannot drift apart.
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-tmux-lib.sh"

# fm_backend_tmux_resolve_bare_selector: the live-window-listing fallback for a
# selector that is neither an explicit target nor a task selector routed
# through meta - an ad hoc window name with no recorded task. Mirrors the
# `tmux list-windows -a ... | grep` pipeline that used to live inline in
# fm-send.sh's and fm-peek.sh's own (until now duplicated) resolve().
fm_backend_tmux_resolve_bare_selector() {  # <name>
  local name=$1
  fm_tmux_cli list-windows -a -F '#{session_name}:#{window_name}' | grep -m1 ":$name\$" \
    || { echo "error: no window named $name" >&2; return 1; }
}

# fm_backend_tmux_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's and fm-watch.sh's `tmux capture-pane -p -t "$T" -S -"$N"`.
fm_backend_tmux_capture() {  # <target> <lines>
  fm_tmux_cli capture-pane -p -t "$1" -S -"$2"
}

# fm_backend_tmux_send_key: one named key. Mirrors fm-send.sh's --key path:
# `tmux display-message -p -t "$T" '#{pane_id}' >/dev/null`, then
# `tmux send-keys -t "$T" "$2"`.
fm_backend_tmux_send_key() {  # <target> <key>
  fm_tmux_cli display-message -p -t "$1" '#{pane_id}' >/dev/null
  fm_tmux_cli send-keys -t "$1" "$2"
}

# fm_backend_tmux_send_text_submit: type <text> into <target> once, then
# submit with Enter, retried (Enter only, never retyped) until the composer
# clears. Re-exports fm_tmux_submit_core (bin/fm-tmux-lib.sh) verbatim; see
# that file for the composer-verification contract and echoed verdicts.
fm_backend_tmux_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  fm_tmux_submit_core "$@"
}

# fm_backend_tmux_container_ensure: reuse the current tmux session when
# firstmate itself runs inside tmux, else ensure a dedicated detached
# "firstmate" session exists. Mirrors fm-spawn.sh's container-ensure block;
# prints the resolved session name.
fm_backend_tmux_container_ensure() {
  if [ -n "${TMUX:-}" ]; then
    fm_tmux_cli display-message -p '#S'
  else
    fm_tmux_cli has-session -t firstmate 2>/dev/null || fm_tmux_cli new-session -d -s firstmate
    printf 'firstmate'
  fi
}

fm_backend_tmux_task_marker() {
  local token
  token=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null \
    | base64 \
    | tr '+/' '-_' \
    | tr -d '=\r\n') || return 1
  [ "${#token}" -eq 22 ] || return 1
  case "$token" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  printf 'fm-%s' "$token"
}

fm_backend_tmux_use_socket() {
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  FM_BACKEND_TMUX_SOCKET=$1
}

fm_backend_tmux_socket_path() {
  local path
  path=$(fm_tmux_cli display-message -p '#{socket_path}' 2>/dev/null) || return 1
  fm_backend_tmux_use_socket "$path" || return 1
  printf '%s' "$path"
}

# fm_backend_tmux_create_task: create the task's window in <proj-abs>,
# refusing an existing <window-name> in <session>. Mirrors fm-spawn.sh's
# duplicate-check-then-new-window sequence, including the exact error text
# (session:window, matching how fm-spawn.sh composed its own $T). Prints the
# created window's stable window id on stdout for the caller to target.
#
# Robustness (fm-spawn tmux window handling under a non-default captain config):
#   - Capture a STABLE window id with -P -F '#{window_id}', and let tmux append
#     at the next free index by targeting the session with a trailing colon
#     ("$ses:"), so a non-default base-index (e.g. base-index 1) cannot collide.
#   - PIN the window name by disabling automatic-rename and allow-rename on the
#     new window: the captain's tmux may rename the window away from fm-<id> once
#     treehouse cd's into the worktree, which would break name-based targeting.
# The returned window id lets callers target the window even if its name is ever
# lost, so worktree discovery cannot fall back to the active client's window.
fm_backend_tmux_create_task() {  # <session> <window-name> <proj-abs> [task-marker] -> prints window id
  local ses=$1 wname=$2 proj_abs=$3 marker=${4:-} wid
  FM_BACKEND_CREATE_OCCURRED=0
  FM_BACKEND_CREATED_TARGET=
  if fm_tmux_cli list-windows -t "$ses" -F '#{window_name}' | grep -qx "$wname"; then
    echo "error: window $ses:$wname already exists" >&2
    return 1
  fi
  wid=$(fm_tmux_cli new-window -dP -F '#{window_id}' -t "$ses:" -n "$wname" -c "$proj_abs") || return 1
  FM_BACKEND_CREATE_OCCURRED=1
  FM_BACKEND_CREATED_TARGET=$wid
  if [ -n "$marker" ] && ! fm_tmux_cli set-window-option -t "$wid" @firstmate_task_marker "$marker" 2>/dev/null; then
    return 1
  fi
  fm_tmux_cli set-window-option -t "$wid" automatic-rename off 2>/dev/null || true
  fm_tmux_cli set-window-option -t "$wid" allow-rename off 2>/dev/null || true
  printf '%s\n' "$wid"
}

# fm_backend_tmux_current_path: the live pane's current working directory, or
# empty on any tmux error. Mirrors fm-spawn.sh's worktree-discovery poll:
# `tmux display-message -p -t "$T" '#{pane_current_path}'`.
fm_backend_tmux_current_path() {  # <target>
  fm_tmux_cli display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

# fm_backend_tmux_send_text_line: send one line of TEXT then Enter, with no
# composer verification - used for the fixed spawn-time commands
# (`treehouse get`, the GOTMPDIR export) that already ran this exact sequence
# inline in fm-spawn.sh. Mirrors `tmux send-keys -t "$T" "<text>" Enter`.
fm_backend_tmux_send_text_line() {  # <target> <text>
  fm_tmux_cli send-keys -t "$1" "$2" Enter
}

# fm_backend_tmux_send_literal: send TEXT as literal bytes with no
# submission - the caller sends Enter separately (fm-spawn.sh's launch-command
# send pauses between the literal send and Enter for the harness to settle).
# Mirrors `tmux send-keys -t "$T" -l "<text>"`.
fm_backend_tmux_send_literal() {  # <target> <text>
  fm_tmux_cli send-keys -t "$1" -l "$2"
}

# Resolve any exact tmux handle accepted for a recorded task window to its
# server-global window id. Inventory matching avoids display-message's dangerous
# fallback to the active window when a named target has disappeared.
fm_backend_tmux_canonical_window() {  # <target> [task-marker] -> @<window-id>
  local target=$1 expected_marker=${2:-} out status pane_id window_id named named_pane indexed_window indexed_pane marker matched= named_seen=0
  out=$(fm_tmux_cli list-panes -a -F '#{pane_id}|#{window_id}|#{session_name}:#{window_name}|#{session_name}:#{window_name}.#{pane_index}|#{session_name}:#{window_index}|#{session_name}:#{window_index}.#{pane_index}|#{@firstmate_task_marker}' 2>&1)
  status=$?
  if [ "$status" -ne 0 ]; then
    case "$out" in
      *'no server running'*|*'no sessions'*|*'No such file or directory'*|*'Connection refused'*) return 2 ;;
      *) return 1 ;;
    esac
  fi
  while IFS='|' read -r pane_id window_id named named_pane indexed_window indexed_pane marker; do
    case "$target" in
      "$pane_id"|"$window_id"|"$indexed_window"|"$indexed_pane")
        [ -z "$expected_marker" ] || [ "$marker" = "$expected_marker" ] || return 1
        printf '%s' "$window_id"
        return 0
        ;;
    esac
  done <<< "$out"
  while IFS='|' read -r pane_id window_id named named_pane indexed_window indexed_pane marker; do
    case "$target" in
      "$named"|"$named_pane")
        named_seen=1
        [ -z "$expected_marker" ] || [ "$marker" = "$expected_marker" ] || continue
        if [ -n "$matched" ] && [ "$matched" != "$window_id" ]; then
          return 1
        fi
        matched=$window_id
        ;;
    esac
  done <<< "$out"
  if [ -n "$matched" ]; then
    printf '%s' "$matched"
    return 0
  fi
  [ "$named_seen" -eq 0 ] || [ -z "$expected_marker" ] || return 1
  return 2
}

# Tri-state endpoint probe for destructive cleanup. Enumerate exact handles:
# `display-message -t` silently falls back to the active window when a named
# target disappeared, which would report a killed worker as still present.
# A readable inventory proves presence/absence; control-plane failures stay unknown.
fm_backend_tmux_target_state() {  # <target> [task-marker] -> present|absent|unknown
  local target=$1 expected_marker=${2:-} out status pane_id window_id named indexed_window indexed_pane marker
  out=$(fm_tmux_cli list-panes -a -F '#{pane_id}|#{window_id}|#{session_name}:#{window_name}|#{session_name}:#{window_index}|#{session_name}:#{window_index}.#{pane_index}|#{@firstmate_task_marker}' 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    while IFS='|' read -r pane_id window_id named indexed_window indexed_pane marker; do
      case "$target" in
        "$pane_id"|"$window_id"|"$named"|"$indexed_window"|"$indexed_pane")
          if [ -n "$expected_marker" ] && [ "$marker" != "$expected_marker" ]; then
            printf 'unknown'
          else
            printf 'present'
          fi
          return 0
          ;;
      esac
    done <<< "$out"
    printf 'absent'
  else
    case "$out" in
      *'no server running'*|*'no sessions'*|*'No such file or directory'*|*'Connection refused'*) printf 'absent' ;;
      *) printf 'unknown' ;;
    esac
  fi
}

# fm_backend_tmux_kill: remove one explicitly named task window, best-effort.
# Empty, omitted, and malformed targets return nonzero before invoking tmux so
# tmux can never interpret an empty target as the caller's current window.
fm_backend_tmux_kill() {  # <target>
  local target=${1:-} session window
  case "$target" in
    *:*)
      session=${target%%:*}
      window=${target#*:}
      ;;
    *) return 1 ;;
  esac
  case "$session:$window" in
    :*|*:|*:*:*) return 1 ;;
  esac
  fm_tmux_cli kill-window -t "=$session:=$window" 2>/dev/null || true
}

# fm_backend_tmux_current_command: <target>'s live foreground process name -
# tmux's own `#{pane_current_command}`, already resolved from the pty's
# foreground process group (verified empirically with real tmux 3.6a: a
# harness invoked interactively stays the reported command even while it
# shells out to subcommands that do not take over the pty - e.g. `bash -c
# "sleep 30"` alone reports "sleep" because bash execs directly into it, but
# a persisting parent script running `sleep` as a child reports the PARENT's
# own name throughout; the value reverts to the shell's own name only once
# the foreground command actually exits). Empty on any tmux error.
fm_backend_tmux_current_command() {  # <target>
  fm_tmux_cli display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
}

# fm_backend_tmux_agent_state: recovery-grade harness-agent state for one
# recorded target. See bin/fm-backend.sh's fm_backend_agent_state for the
# shared state vocabulary and docs/tmux-backend.md "Agent liveness probe" for
# the empirical basis. Tmux silently falls back to the active window when a
# named target is absent, so the exact recorded window must appear in a
# successful session inventory before its foreground command can be trusted.
# An omitted window or a definitive missing-session/server response is
# `missing`; any other inventory or pane read failure is `unreadable`, so a
# transient tmux problem never licenses a duplicate.
fm_backend_tmux_agent_state() {  # <target> [task-marker]
  local target=$1 expected_marker=${2:-} comm session window windows inventory_status found=0 marker=
  case "$target" in
    @*)
      if windows=$(LC_ALL=C fm_tmux_cli list-panes -a -F '#{window_id}|#{@firstmate_task_marker}' 2>&1); then
        inventory_status=0
      else
        inventory_status=$?
      fi
      ;;
    *:*:*|'':*|*:'') printf 'unreadable'; return 0 ;;
    *:*)
      session=${target%%:*}
      window=${target#*:}
      if windows=$(LC_ALL=C fm_tmux_cli list-windows -t "$session" -F '#{window_name}|#{@firstmate_task_marker}' 2>&1); then
        inventory_status=0
      else
        inventory_status=$?
      fi
      ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  if [ "$inventory_status" -ne 0 ]; then
    case "$windows" in
      *"can't find session:"*|*"no server running on "*|*"no sessions"*|*"error connecting to "*" (No such file or directory)"|*"error connecting to "*" (Connection refused)")
        printf 'missing'
        ;;
      *)
        printf 'unreadable'
        ;;
    esac
    return 0
  fi
  while IFS='|' read -r candidate marker; do
    case "$target" in
      @*) [ "$candidate" = "$target" ] || continue ;;
      *) [ "$candidate" = "$window" ] || continue ;;
    esac
    found=1
    break
  done <<< "$windows"
  if [ "$found" -eq 0 ]; then
    printf 'missing'
    return 0
  fi
  if [ -n "$expected_marker" ] && [ "$marker" != "$expected_marker" ]; then
    printf 'unreadable'
    return 0
  fi

  comm=$(fm_backend_tmux_current_command "$target") || {
    printf 'unreadable'
    return 0
  }
  comm=${comm#-}
  case "$comm" in
    *claude*|*codex*|*opencode*|*grok*|*kimi*|pi|pi-signed|pi-launcher|Pi) printf 'alive' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'dead' ;;
    '') printf 'unreadable' ;;
    *) printf 'ambiguous' ;;
  esac
}

# Backward-compatible three-state view for callers that only need a yes/no
# agent verdict. The detailed state contract is owned by fm_backend_agent_state.
fm_backend_tmux_agent_alive() {  # <target>
  case "$(fm_backend_tmux_agent_state "$@")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
