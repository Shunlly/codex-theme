#!/bin/bash

set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd -P)/common-macos.sh"

RESTORED_THEME_BACKUP_PATH="${RESTORED_THEME_BACKUP_PATH:-$STATE_ROOT/theme-backup.restored.json}"

archive_restored_theme_backup() {
  [ -e "$THEME_BACKUP_PATH" ] || [ -L "$THEME_BACKUP_PATH" ] || return 0
  [ -f "$THEME_BACKUP_PATH" ] && [ ! -L "$THEME_BACKUP_PATH" ] \
    || fail "The restored theme backup is not a safe regular file; recovery data was preserved."
  if [ -e "$RESTORED_THEME_BACKUP_PATH" ] || [ -L "$RESTORED_THEME_BACKUP_PATH" ]; then
    [ -f "$RESTORED_THEME_BACKUP_PATH" ] && [ ! -L "$RESTORED_THEME_BACKUP_PATH" ] \
      || fail "The restored-backup archive path is unsafe; recovery data was preserved."
  fi
  /bin/mv -f "$THEME_BACKUP_PATH" "$RESTORED_THEME_BACKUP_PATH" \
    || fail "Could not archive the restored theme backup; recovery data was preserved."
  [ ! -e "$THEME_BACKUP_PATH" ] && [ ! -L "$THEME_BACKUP_PATH" ] \
    && [ -f "$RESTORED_THEME_BACKUP_PATH" ] && [ ! -L "$RESTORED_THEME_BACKUP_PATH" ] \
    || fail "The restored theme backup archive could not be verified."
}

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
NATIVE_CONFIG_RESTORE_ROOT=""
if [ "$RESTORE_BASE_THEME" = "true" ] && [ "$NODE_AVAILABLE" != "true" ]; then
  NATIVE_CONFIG_RESTORE_ROOT="$PROJECT_ROOT"
  NATIVE_CONFIG_RESTORE="$NATIVE_CONFIG_RESTORE_ROOT/bin/dream-skin-config-restore"
  NATIVE_CONFIG_RESTORE_IDENTITY="$(native_restore_helper_identity "$NATIVE_CONFIG_RESTORE_ROOT" "$NATIVE_CONFIG_RESTORE")" \
    || fail "Native config restore helper is unsafe or missing: $NATIVE_CONFIG_RESTORE"
fi
require_lifecycle_lock
trap release_lifecycle_lock EXIT
DAMAGED_STATE_RECOVERY="false"
if [ "$PORT_EXPLICIT" = "false" ] && [ -f "$STATE_PATH" ]; then
  SAVED_PORT="$(state_field port 2>/dev/null || true)"
  case "$SAVED_PORT" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$SAVED_PORT" -ge 1024 ] && [ "$SAVED_PORT" -le 65535 ]; then PORT="$SAVED_PORT"; fi
      ;;
  esac
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
BROWSER_ID=""
if [ "$CODEX_AVAILABLE" = "true" ]; then
  if BROWSER_ID="$(verified_cdp_browser_id "$PORT")"; then DEBUG_READY="true"; fi
fi
if [ "$DEBUG_READY" = "true" ] && [ -f "$STATE_PATH" ]; then
  SAVED_BROWSER_ID="$(state_field browserId 2>/dev/null || true)"
  browser_id_is_valid "$SAVED_BROWSER_ID" \
    || fail "The saved Dream Skin Browser ID is missing or invalid; restore state was preserved."
  [ "$SAVED_BROWSER_ID" = "$BROWSER_ID" ] \
    || fail "The active CDP browser does not match the saved Dream Skin session; restore state was preserved."
  BROWSER_ID="$SAVED_BROWSER_ID"
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
  if ! stop_recorded_injector; then
    recover_damaged_injector_state_without_live_candidate \
      || fail "Could not classify the recorded injector safely; restore state was preserved."
    DAMAGED_STATE_RECOVERY="true"
  fi
fi
# Always remove the themed Codex launchd babysitter so quitting Codex stays quit.
release_codex_launchd_job || true

if [ "$DEBUG_READY" = "true" ]; then
  [ "$NODE_AVAILABLE" = "true" ] \
    || fail "The validated Codex Node.js runtime is unavailable; pass --restart-codex for a full restore."
  "$NODE" "$INJECTOR" --remove --port "$PORT" --browser-id "$BROWSER_ID" --theme-dir "$THEME_DIR" --timeout-ms 8000 >/dev/null \
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
  if [ -f "$THEME_BACKUP_PATH" ]; then
    if [ "$NODE_AVAILABLE" = "true" ]; then
      "$NODE" "$SCRIPT_DIR/theme-config.mjs" restore "$CONFIG_PATH" "$THEME_BACKUP_PATH"
    else
      [ "$(native_restore_helper_identity "$NATIVE_CONFIG_RESTORE_ROOT" "$NATIVE_CONFIG_RESTORE")" = "$NATIVE_CONFIG_RESTORE_IDENTITY" ] \
        || fail "Native config restore helper changed before execution; restore stopped safely."
      "$NATIVE_CONFIG_RESTORE" "$CONFIG_PATH" "$THEME_BACKUP_PATH"
    fi
  elif restored_theme_backup_is_valid; then
    printf 'The base theme was already restored and its completion proof is valid.\n'
  elif [ -f "$STATE_PATH" ] || { [ -d "$INSTALL_ROOT" ] && [ ! -L "$INSTALL_ROOT" ]; }; then
    fail "No selective pre-install theme backup is available; restore state was preserved."
  else
    printf 'No installed Dream Skin engine or recovery backup remains.\n'
  fi
fi

if [ "$DAMAGED_STATE_RECOVERY" = "true" ]; then
  recover_damaged_injector_state_without_live_candidate \
    || fail "A live injector candidate appeared during recovery; restore state was preserved."
fi
/bin/rm -f "$STATE_PATH" \
  || fail "Could not remove lifecycle state; the restored theme backup was preserved for retry."
[ ! -e "$STATE_PATH" ] && [ ! -L "$STATE_PATH" ] \
  || fail "Lifecycle state still exists; the restored theme backup was preserved for retry."
if [ "$RESTORE_BASE_THEME" = "true" ]; then
  archive_restored_theme_backup
fi

if [ "$RESTART_CODEX" = "true" ]; then
  [ "$CODEX_RUNNING" = "true" ] && stop_codex "$FORCE_STOP_AUTHORIZED"
  if [ "$CODEX_APP_VALIDATED" = "true" ]; then
    launch_codex_normally \
      || printf 'Codex could not be reopened automatically. The restore is complete; open Codex normally.\n' >&2
  else
    printf 'Codex was not restarted because full app signature validation failed. Repair or reinstall the official Codex app, then open it again.\n'
  fi
fi

if [ "$UNINSTALL" = "true" ] && [ "${DREAM_SKIN_DEFER_UNINSTALL_DELETE:-false}" != "true" ]; then
  /bin/rm -f "$HOME/Desktop/Codex Dream Skin.command"
  /bin/rm -f "$HOME/Desktop/Codex Dream Skin - Customize.command"
  /bin/rm -f "$HOME/Desktop/Codex Dream Skin - Verify.command"
  /bin/rm -f "$HOME/Desktop/Codex Dream Skin - Restore.command"
fi

printf 'Codex Dream Skin Studio was removed and the requested macOS restore actions completed successfully.\n'
