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

CODEX_AVAILABLE="false"
NODE_AVAILABLE="false"
unset NODE RUNTIME_NODE NODE_VERSION NODE_TEAM_ID CODEX_TEAM_ID
CODEX_APP_VALIDATED="false"
CODEX_APP_CONTROL_VALIDATED="false"
NODE_RUNTIME_VALIDATED="false"
if try_discover_codex_app; then
  if try_validate_codex_app_identity; then
    CODEX_AVAILABLE="true"
    if try_require_macos_node_runtime; then
      NODE_AVAILABLE="true"
    else
      unset NODE RUNTIME_NODE NODE_VERSION NODE_TEAM_ID
    fi
  elif try_validate_codex_app_control_identity; then
    CODEX_AVAILABLE="true"
    unset NODE RUNTIME_NODE NODE_VERSION NODE_TEAM_ID
  elif [ "$RESTART_CODEX" = "true" ]; then
    fail "The official Codex app is required to complete the requested restart."
  fi
elif [ "$RESTART_CODEX" = "true" ]; then
  fail "The official Codex app is required to complete the requested restart."
fi
NATIVE_CONFIG_RESTORE=""
NATIVE_CONFIG_RESTORE_IDENTITY=""
if [ "$RESTORE_BASE_THEME" = "true" ] && [ "$NODE_AVAILABLE" != "true" ]; then
  NATIVE_CONFIG_RESTORE="$INSTALL_ROOT/bin/dream-skin-config-restore"
  NATIVE_CONFIG_RESTORE_IDENTITY="$(native_restore_helper_identity "$INSTALL_ROOT" "$NATIVE_CONFIG_RESTORE")" \
    || fail "Native config restore helper is unsafe or missing: $NATIVE_CONFIG_RESTORE"
fi
if [ "$PORT_EXPLICIT" = "false" ] && [ -f "$STATE_PATH" ]; then
  PORT="$(state_field port)" || fail "Could not read the saved CDP port; state was preserved."
fi

CODEX_RUNNING="false"
if [ "$CODEX_AVAILABLE" = "true" ]; then
  codex_is_running && CODEX_RUNNING="true"
fi
if [ "${DREAM_SKIN_STUDIO_ADAPTER:-false}" = "true" ] \
  && [ "$CODEX_RUNNING" = "true" ] \
  && [ "$RESTART_CODEX" = "true" ] \
  && [ "$RESTART_AUTHORIZED" != "true" ]; then
  fail "Explicit restart authorization is required before Studio can close Codex."
fi
ensure_state_root
DEBUG_READY="false"
if [ "$CODEX_AVAILABLE" = "true" ]; then
  verified_cdp_endpoint "$PORT" && DEBUG_READY="true"
fi

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
  [ "$NODE_AVAILABLE" = "true" ] \
    || fail "The validated Codex Node.js runtime is unavailable; pass --restart-codex for a full restore."
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
  if [ "$NODE_AVAILABLE" = "true" ]; then
    "$NODE" "$SCRIPT_DIR/theme-config.mjs" restore "$CONFIG_PATH" "$THEME_BACKUP_PATH"
  else
    [ "$(native_restore_helper_identity "$INSTALL_ROOT" "$NATIVE_CONFIG_RESTORE")" = "$NATIVE_CONFIG_RESTORE_IDENTITY" ] \
      || fail "Native config restore helper changed before execution; restore stopped safely."
    "$NATIVE_CONFIG_RESTORE" "$CONFIG_PATH" "$THEME_BACKUP_PATH"
  fi
fi

if [ "$RESTART_CODEX" = "true" ]; then
  [ "$CODEX_RUNNING" = "true" ] && stop_codex "$FORCE_STOP_AUTHORIZED"
  if [ "$CODEX_APP_VALIDATED" = "true" ]; then
    launch_codex_normally
  else
    printf 'Codex was not restarted because full app signature validation failed. Repair or reinstall the official Codex app, then open it again.\n'
  fi
fi

/bin/rm -f "$STATE_PATH"
if [ "$UNINSTALL" = "true" ] && [ "${DREAM_SKIN_DEFER_UNINSTALL_DELETE:-false}" != "true" ]; then
  /bin/rm -f "$HOME/Desktop/Codex Dream Skin.command"
  /bin/rm -f "$HOME/Desktop/Codex Dream Skin - Customize.command"
  /bin/rm -f "$HOME/Desktop/Codex Dream Skin - Verify.command"
  /bin/rm -f "$HOME/Desktop/Codex Dream Skin - Restore.command"
fi

printf 'Codex Dream Skin Studio was removed and the requested macOS restore actions completed successfully.\n'
