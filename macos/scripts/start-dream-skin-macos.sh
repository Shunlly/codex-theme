#!/bin/bash

set -Eeuo pipefail
. "$(cd "$(dirname "$0")" && pwd -P)/common-macos.sh"

record_start_error() {
  local code="$1"
  local line="$2"
  ensure_state_root
  printf '%s exit=%s line=%s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$code" "$line" >> "$START_ERROR_LOG"
  printf 'Codex Dream Skin Studio: start failed at line %s (exit %s). See %s\n' "$line" "$code" "$START_ERROR_LOG" >&2
}
trap 'code=$?; record_start_error "$code" "$LINENO"' ERR

PORT=9341
PORT_EXPLICIT="false"
RESTART_EXISTING="false"
PROMPT_RESTART="false"
FOREGROUND_INJECTOR="false"
FORCE_STOP_AUTHORIZED="false"
STUDIO_STRICT_VERIFY="false"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-}"; PORT_EXPLICIT="true"; shift 2 ;;
    --restart-existing) RESTART_EXISTING="true"; shift ;;
    --prompt-restart) PROMPT_RESTART="true"; shift ;;
    --foreground-injector) FOREGROUND_INJECTOR="true"; shift ;;
    --force-stop-authorized) FORCE_STOP_AUTHORIZED="true"; shift ;;
    --studio-strict-verify) STUDIO_STRICT_VERIFY="true"; shift ;;
    *) fail "Unknown start argument: $1" ;;
  esac
done
case "$PORT" in ''|*[!0-9]*) fail "Invalid port: $PORT" ;; esac
[ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || fail "Port must be between 1024 and 65535."
require_lifecycle_lock
trap release_lifecycle_lock EXIT

discover_codex_app
require_macos_runtime
ensure_state_root
[ ! -e "$ROLLBACK_STATE_PATH" ] && [ ! -L "$ROLLBACK_STATE_PATH" ] \
  || fail "A previous renderer rollback is unresolved; run Complete Restore before applying again."

if [ "$PORT_EXPLICIT" = "false" ] && [ -f "$STATE_PATH" ]; then
  saved_port="$(state_field port)" || fail "Could not read the existing state port."
  [ -n "$saved_port" ] && PORT="$saved_port"
fi

DEBUG_READY="false"
BROWSER_ID=""
OPENED_MANAGED_CDP_SESSION="false"
rollback_new_managed_cdp_session() {
  [ "$STUDIO_STRICT_VERIFY" = "true" ] && [ "$OPENED_MANAGED_CDP_SESSION" = "true" ] || return 0
  stop_codex "$FORCE_STOP_AUTHORIZED"
  launch_codex_normally
}
if BROWSER_ID="$(verified_cdp_browser_id "$PORT")"; then DEBUG_READY="true"; fi

if codex_is_running && [ "$DEBUG_READY" = "false" ]; then
  if [ "$PROMPT_RESTART" = "true" ] && [ "$RESTART_EXISTING" = "false" ]; then
    /usr/bin/osascript -e 'display dialog "Codex 需要重启一次才能启用 Dream Skin。" buttons {"取消", "重启并应用"} default button "重启并应用" with title "Codex Dream Skin Studio"' >/dev/null \
      || fail "Theme launch was cancelled."
    RESTART_EXISTING="true"
  fi
  [ "$RESTART_EXISTING" = "true" ] || fail "Codex is already running without the verified skin CDP endpoint. Close it first or pass --restart-existing."
  if [ "$STUDIO_STRICT_VERIFY" = "true" ]; then
    stop_codex "$FORCE_STOP_AUTHORIZED"
  else
    stop_codex true
  fi
fi

if [ -f "$STATE_PATH" ]; then
  stop_recorded_injector
  /bin/rm -f "$STATE_PATH"
fi

INJECTOR_PID=""
if [ "$DEBUG_READY" = "false" ]; then
  PORT="$(select_available_port "$PORT")"
  printf 'Launching Codex with skin debug port %s…\n' "$PORT" >&2
  launch_codex_with_cdp "$PORT"
  OPENED_MANAGED_CDP_SESSION="true"
  # Some builds open the window slowly; also try activating the app once.
  /usr/bin/open -na "$CODEX_BUNDLE" --args --remote-debugging-address=127.0.0.1 --remote-debugging-port="$PORT" >/dev/null 2>&1 || true
  if ! wait_for_cdp "$PORT"; then
    rollback_new_managed_cdp_session
    fail "Codex did not expose a verified loopback CDP endpoint on port $PORT within 45 seconds. See $APP_LOG and $APP_ERROR_LOG"
  fi
  if ! BROWSER_ID="$(verified_cdp_browser_id "$PORT")"; then
    rollback_new_managed_cdp_session
    fail "Codex exposed CDP without a stable numeric-loopback Browser ID."
  fi
fi

if [ "$FOREGROUND_INJECTOR" = "true" ]; then
  release_lifecycle_lock || fail "Could not release the lifecycle lock before starting the foreground watcher."
  [ ! -e "$LIFECYCLE_LOCK_PATH" ] && [ ! -L "$LIFECYCLE_LOCK_PATH" ] \
    || fail "The lifecycle lock was reacquired before the foreground watcher could start."
  trap - EXIT
  exec "$NODE" "$INJECTOR" --watch --port "$PORT" --browser-id "$BROWSER_ID" --theme-dir "$THEME_DIR"
fi

CODEX_PID="$(codex_main_pids | /usr/bin/head -n 1)"
if ! start_watcher "$PORT" "$BROWSER_ID" "$CODEX_PID"; then
  rollback_new_managed_cdp_session
  fail "The injector could not be started and recorded safely."
fi
INJECTOR_PID="$STARTED_WATCHER_PID"
INJECTOR_STARTED_AT="$STARTED_WATCHER_AT"

# Soft verify: keep the injector even if secondary selectors differ by Codex version.
VERIFY_OUTPUT="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/dream-skin-verify.XXXXXX")"
/bin/chmod 600 "$VERIFY_OUTPUT"
cleanup_verify_output() { /bin/rm -f "$VERIFY_OUTPUT"; }
trap 'cleanup_verify_output; release_lifecycle_lock' EXIT
if "$NODE" "$INJECTOR" --verify --port "$PORT" --browser-id "$BROWSER_ID" --theme-dir "$THEME_DIR" --timeout-ms 20000 >"$VERIFY_OUTPUT" 2>/dev/null; then
  verify_code=0
else
  verify_code=$?
fi
if [ "$verify_code" -ne 0 ]; then
  # One more force inject before giving up
  "$NODE" "$INJECTOR" --once --port "$PORT" --browser-id "$BROWSER_ID" --theme-dir "$THEME_DIR" --timeout-ms 15000 >/dev/null 2>&1 || true
  if "$NODE" "$INJECTOR" --verify --port "$PORT" --browser-id "$BROWSER_ID" --theme-dir "$THEME_DIR" --timeout-ms 12000 >"$VERIFY_OUTPUT" 2>/dev/null; then
    verify_code=0
  else
    verify_code=$?
  fi
fi
if [ "$verify_code" -ne 0 ]; then
  # If CSS markers are present, treat as soft success (do not kill injector).
  if [ "$STUDIO_STRICT_VERIFY" != "true" ] \
    && /usr/bin/grep -q '"installed": true' "$VERIFY_OUTPUT" 2>/dev/null; then
    printf 'Codex Dream Skin Studio %s is active (soft verify) on port %s.\n' "$SKIN_VERSION" "$PORT"
    cleanup_verify_output
    exit 0
  fi
  # The watcher is normally launched directly (launchctl is only a fallback),
  # so a successful `launchctl remove` does not prove that the recorded PID
  # stopped.  Verify the PID/path/start-time tuple before deleting state; if
  # it cannot be stopped safely, preserve the state as evidence and fail
  # closed instead of leaving an orphan watcher that can reinject later.
  if ! stop_recorded_injector; then
    cleanup_verify_output
    fail "Injection verification failed and the recorded injector could not be stopped safely; state was preserved. See $INJECTOR_ERROR_LOG"
  fi
  if [ "$STUDIO_STRICT_VERIFY" = "true" ]; then
    verified_cdp_endpoint "$PORT" \
      || fail "Injection verification failed and the live skin endpoint could not be verified; state was preserved."
    "$NODE" "$INJECTOR" --remove --port "$PORT" --browser-id "$BROWSER_ID" --theme-dir "$THEME_DIR" --timeout-ms 8000 >/dev/null 2>&1 \
      || fail "Injection verification failed and the live skin could not be removed safely; state was preserved."
  fi
  /bin/rm -f "$STATE_PATH"
  if [ "$STUDIO_STRICT_VERIFY" = "true" ]; then
    stop_codex "$FORCE_STOP_AUTHORIZED"
    launch_codex_normally
  fi
  cleanup_verify_output
  fail "Injection verification failed. The injector was stopped; see $INJECTOR_ERROR_LOG"
fi
cleanup_verify_output

printf 'Codex Dream Skin Studio %s is active on loopback port %s.\n' "$SKIN_VERSION" "$PORT"
