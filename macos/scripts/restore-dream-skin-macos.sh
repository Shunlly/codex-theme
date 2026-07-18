#!/bin/bash

set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd -P)/common-macos.sh"

PORT=9341
PORT_EXPLICIT="false"
RESTORE_BASE_THEME="false"
RESTART_CODEX="false"
UNINSTALL="false"
RESTART_AUTHORIZED="false"
FORCE_STOP_AUTHORIZED="false"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-}"; PORT_EXPLICIT="true"; shift 2 ;;
    --restore-base-theme) RESTORE_BASE_THEME="true"; shift ;;
    --restart-codex) RESTART_CODEX="true"; shift ;;
    --uninstall) UNINSTALL="true"; shift ;;
    --restart-authorized) RESTART_AUTHORIZED="true"; shift ;;
    --force-stop-authorized) FORCE_STOP_AUTHORIZED="true"; shift ;;
    *) fail "Unknown restore argument: $1" ;;
  esac
done

discover_codex_app
require_macos_runtime
if [ "$PORT_EXPLICIT" = "false" ] && [ -f "$STATE_PATH" ]; then
  PORT="$(state_field port)" || fail "Could not read the saved CDP port; state was preserved."
fi

CODEX_RUNNING="false"
codex_is_running && CODEX_RUNNING="true"
if [ "${DREAM_SKIN_STUDIO_ADAPTER:-false}" = "true" ] \
  && [ "$CODEX_RUNNING" = "true" ] \
  && [ "$RESTART_CODEX" = "true" ] \
  && [ "$RESTART_AUTHORIZED" != "true" ]; then
  fail "Explicit restart authorization is required before Studio can close Codex."
fi
ensure_state_root
DEBUG_READY="false"
verified_cdp_endpoint "$PORT" && DEBUG_READY="true"

# Close before touching the watcher, state, backup, or config. Studio calls
# pass only their explicit force authorization; legacy CLI behavior stays the
# same when it is not invoked through the adapter.
if [ "$CODEX_RUNNING" = "true" ] && [ "$RESTART_CODEX" = "true" ]; then
  if [ "${DREAM_SKIN_STUDIO_ADAPTER:-false}" = "true" ]; then
    stop_codex "$FORCE_STOP_AUTHORIZED"
  else
    stop_codex true
  fi
  CODEX_RUNNING="false"
  DEBUG_READY="false"
fi

if [ -f "$STATE_PATH" ]; then
  stop_recorded_injector \
    || fail "Could not stop the recorded injector; restore state was preserved."
fi
# Always remove the themed Codex launchd babysitter so quitting Codex stays quit.
release_codex_launchd_job || true

if [ "$DEBUG_READY" = "true" ]; then
  "$NODE" "$INJECTOR" --remove --port "$PORT" --theme-dir "$THEME_DIR" --timeout-ms 8000 >/dev/null \
    || fail "The live skin could not be removed and verified; restore stopped safely."
elif [ "$CODEX_RUNNING" = "true" ] && [ "$RESTART_CODEX" = "false" ]; then
  fail "Codex is still running but its saved CDP endpoint cannot be verified. Pass --restart-codex for a full restore."
fi

if [ "$RESTORE_BASE_THEME" = "true" ]; then
  if [ "$CODEX_RUNNING" = "true" ]; then
    [ "$RESTART_CODEX" = "true" ] \
      || fail "Close Codex or pass --restart-codex before restoring config.toml."
    stop_codex "$FORCE_STOP_AUTHORIZED"
    CODEX_RUNNING="false"
  fi
  "$NODE" "$SCRIPT_DIR/theme-config.mjs" restore "$CONFIG_PATH" "$THEME_BACKUP_PATH"
fi

if [ "$RESTART_CODEX" = "true" ]; then
  [ "$CODEX_RUNNING" = "true" ] && stop_codex "$FORCE_STOP_AUTHORIZED"
  launch_codex_normally
fi

/bin/rm -f "$STATE_PATH"
if [ "$UNINSTALL" = "true" ] && [ "${DREAM_SKIN_DEFER_UNINSTALL_DELETE:-false}" != "true" ]; then
  /bin/rm -f "$HOME/Desktop/Codex Dream Skin.command"
  /bin/rm -f "$HOME/Desktop/Codex Dream Skin - Customize.command"
  /bin/rm -f "$HOME/Desktop/Codex Dream Skin - Verify.command"
  /bin/rm -f "$HOME/Desktop/Codex Dream Skin - Restore.command"
fi

printf 'Codex Dream Skin Studio was removed and the requested macOS restore actions completed successfully.\n'
