#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
INSTALL_ROOT="$HOME/.codex/codex-dream-skin-studio"
STATE_ROOT="$HOME/Library/Application Support/CodexDreamSkinStudio"
OPERATION="${1:-status}"
shift || true

RESTART_AUTHORIZED="false"
FORCE_AUTHORIZED="false"
DELETE_USER_THEMES="false"

emit_invalid_request() {
  printf '{"schemaVersion":1,"ok":false,"operation":"%s","state":{"install":"not-installed","codex":"not-installed","session":"official","operation":"idle","themeName":null,"requiresRestart":false,"availableActions":[],"verified":null},"error":{"code":"INVALID_REQUEST","message":"The Studio operation is invalid.","recoveryActions":["cancel"]}}\n' \
    "$OPERATION"
  exit 2
}

case "$OPERATION" in
  preflight|install|apply|status|pause|resume|restore|verify|uninstall) ;;
  *) OPERATION="status"; emit_invalid_request ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --restart-authorized) RESTART_AUTHORIZED="true" ;;
    --force-authorized) FORCE_AUTHORIZED="true" ;;
    --delete-user-themes) DELETE_USER_THEMES="true" ;;
    *) emit_invalid_request ;;
  esac
  shift
done

if [ "$FORCE_AUTHORIZED" = "true" ] && [ "$RESTART_AUTHORIZED" != "true" ]; then
  emit_invalid_request
fi
if [ "$DELETE_USER_THEMES" = "true" ] && [ "$OPERATION" != "uninstall" ]; then
  emit_invalid_request
fi

native_restore_helper_is_safe() {
  local root="$1"
  local helper="$root/bin/dream-skin-config-restore"
  local root_real=""
  local bin_real=""
  [ -d "$root" ] && [ -d "$root/bin" ] && [ ! -L "$root/bin" ] || return 1
  [ -f "$helper" ] && [ ! -L "$helper" ] && [ -x "$helper" ] || return 1
  root_real="$(cd "$root" && pwd -P)" || return 1
  bin_real="$(cd "$root/bin" && pwd -P)" || return 1
  [ "$bin_real" = "$root_real/bin" ]
}

emit_runtime_invalid() {
  printf '{"schemaVersion":1,"ok":false,"operation":"%s","state":{"install":"not-installed","codex":"not-installed","session":"official","operation":"idle","themeName":null,"requiresRestart":false,"availableActions":[],"verified":null},"error":{"code":"RUNTIME_INVALID","message":"The Studio runtime is unavailable.","recoveryActions":["diagnostics","cancel"]}}\n' "$OPERATION"
  exit 1
}

emit_lifecycle_error() {
  printf '{"schemaVersion":1,"ok":false,"operation":"%s","state":{"install":"not-installed","codex":"not-installed","session":"official","operation":"%s","themeName":null,"requiresRestart":false,"availableActions":[],"verified":null},"error":{"code":"%s","message":"%s","recoveryActions":%s}}\n' \
    "$OPERATION" "$1" "$2" "$3" "$4"
  exit 1
}

if { [ "$OPERATION" = "preflight" ] || [ "$OPERATION" = "install" ]; } \
  && ! native_restore_helper_is_safe "$PROJECT_ROOT"; then
  emit_runtime_invalid
fi
if [ "$OPERATION" = "preflight" ] || [ "$OPERATION" = "status" ]; then
  [ "$RESTART_AUTHORIZED" = "false" ] && [ "$DELETE_USER_THEMES" = "false" ] || emit_invalid_request
  exec "$SCRIPT_DIR/status-dream-skin-macos.sh" --studio-json --deep --operation "$OPERATION"
fi

. "$SCRIPT_DIR/common-macos.sh"
if ! acquire_lifecycle_lock; then
  if lifecycle_lock_is_busy; then
    emit_lifecycle_error busy OPERATION_BUSY \
      "Another Studio operation is already running." '["retry","cancel"]'
  fi
  emit_lifecycle_error idle INTERNAL_ERROR \
    "The Studio lifecycle lock is unavailable." '["retry","diagnostics","cancel"]'
fi
trap release_lifecycle_lock EXIT

engine_complete() {
  local root="$1"
  native_restore_helper_is_safe "$root" \
    && [ -f "$root/VERSION" ] \
    && [ -x "$root/scripts/status-dream-skin-macos.sh" ] \
    && [ -x "$root/scripts/start-dream-skin-macos.sh" ] \
    && [ -x "$root/scripts/pause-dream-skin-macos.sh" ] \
    && [ -x "$root/scripts/restore-dream-skin-macos.sh" ] \
    && [ -x "$root/scripts/verify-dream-skin-macos.sh" ] \
    && [ -f "$root/scripts/common-macos.sh" ] \
    && [ -f "$root/scripts/injector.mjs" ] \
    && [ -f "$root/scripts/theme-config.mjs" ]
}

installed_matches_bundle() {
  engine_complete "$INSTALL_ROOT" \
    && [ -f "$PROJECT_ROOT/VERSION" ] \
    && /usr/bin/cmp -s "$INSTALL_ROOT/VERSION" "$PROJECT_ROOT/VERSION"
}

emit_error() {
  local code="$1"
  local message="$2"
  local recovery_json="$3"
  local restart="${4:-false}"
  local state_json='{"install":"not-installed","codex":"not-installed","session":"official","operation":"idle","themeName":null,"requiresRestart":false,"availableActions":[],"verified":null}'
  if [ -n "${STATUS_JSON:-}" ]; then
    state_json="$(printf '%s' "$STATUS_JSON" | /usr/bin/plutil -extract state json -o - - 2>/dev/null || printf '%s' "$state_json")"
  fi
  if [ "$restart" = "true" ]; then
    state_json="$(printf '%s' "$state_json" \
      | /usr/bin/plutil -replace requiresRestart -bool YES -o - -- - 2>/dev/null \
      || printf '%s' '{"install":"not-installed","codex":"not-installed","session":"official","operation":"idle","themeName":null,"requiresRestart":true,"availableActions":[],"verified":null}')"
  fi
  printf '{"schemaVersion":1,"ok":false,"operation":"%s","state":%s,"error":{"code":"%s","message":"%s","recoveryActions":%s}}\n' \
    "$OPERATION" "$state_json" "$code" "$message" "$recovery_json"
  exit 1
}

json_field() {
  printf '%s' "$STATUS_JSON" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null
}

status_root="$PROJECT_ROOT"
case "$OPERATION" in
  apply|pause|resume|verify)
    installed_matches_bundle \
      || emit_error OPERATION_FAILED "The installed Studio engine is unavailable or out of date." '["retry","diagnostics","cancel"]'
    status_root="$INSTALL_ROOT"
    ;;
esac

set +e
STATUS_JSON="$("$status_root/scripts/status-dream-skin-macos.sh" --studio-json --deep --operation "$OPERATION" 2>/dev/null)"
status_exit="$?"
set -e
if ! printf '%s' "$STATUS_JSON" | /usr/bin/plutil -convert json -o - - >/dev/null 2>&1; then
  emit_error INTERNAL_ERROR "Studio status could not be read safely." '["retry","diagnostics","cancel"]'
fi

status_error="$(json_field error.code 2>/dev/null || true)"
status_install="$(json_field state.install 2>/dev/null || true)"
live_recovery_backup_is_safe() {
  live_theme_backup_is_valid
}
status_has_action() {
  local expected="$1"
  local count=""
  local index=0
  count="$(json_field state.availableActions 2>/dev/null)" || return 1
  case "$count" in ''|*[!0-9]*) return 1 ;; esac
  while [ "$index" -lt "$count" ]; do
    [ "$(json_field "state.availableActions.$index" 2>/dev/null || true)" != "$expected" ] || return 0
    index=$((index + 1))
  done
  return 1
}
recovery_artifact_is_available() {
  status_has_action "$OPERATION" \
    && { live_recovery_backup_is_safe \
    || { status_has_action uninstall && restored_theme_backup_is_valid; }
    }
}
if [ "$status_exit" -ne 0 ] && [ -n "$status_error" ]; then
  case "$OPERATION:$status_error:$status_install" in
    install:STATE_UNSAFE:not-installed) ;;
    restore:STATE_UNSAFE:*|restore:CODEX_NOT_INSTALLED:*|restore:CODEX_FIRST_RUN_REQUIRED:*)
      recovery_artifact_is_available || { printf '%s\n' "$STATUS_JSON"; exit 1; }
      ;;
    uninstall:STATE_UNSAFE:*|uninstall:CODEX_NOT_INSTALLED:*|uninstall:CODEX_FIRST_RUN_REQUIRED:*)
      recovery_artifact_is_available || { printf '%s\n' "$STATUS_JSON"; exit 1; }
      ;;
    *) printf '%s\n' "$STATUS_JSON"; exit 1 ;;
  esac
fi

codex_state="$(json_field state.codex)"
requires_restart="$(json_field state.requiresRestart)"
if [ "$OPERATION" = "install" ] && [ "$codex_state" = "running" ] && [ "$RESTART_AUTHORIZED" != "true" ]; then
  emit_error CODEX_CLOSE_REQUIRED "Codex must close before Studio can be installed." '["authorize-restart","cancel"]' true
fi
case "$OPERATION" in
  apply|resume|restore|uninstall)
    if { [ "$requires_restart" = "true" ] || { [ "$codex_state" = "running" ] && { [ "$OPERATION" = "restore" ] || [ "$OPERATION" = "uninstall" ]; }; }; } \
      && [ "$RESTART_AUTHORIZED" != "true" ]; then
      emit_error RESTART_REQUIRED "Codex must restart once to apply the theme." '["authorize-restart","cancel"]' true
    fi
    ;;
esac

case "$OPERATION" in
  install) progress="installing"; command_root="$PROJECT_ROOT"; args=(--no-launchers --no-launch) ;;
  apply|resume) progress="applying"; command_root="$INSTALL_ROOT"; args=(--studio-strict-verify) ;;
  pause) progress="pausing"; command_root="$INSTALL_ROOT"; args=() ;;
  restore)
    progress="restoring"; command_root="$status_root"; args=(--restore-base-theme)
    case "$codex_state:$requires_restart" in
      running:*|stopped:*|needs-first-run:true) args+=(--restart-codex) ;;
    esac
    ;;
  verify) progress="verifying"; command_root="$INSTALL_ROOT"; args=(--reload) ;;
  uninstall)
    progress="uninstalling"; command_root="$status_root"; args=(--restore-base-theme)
    case "$codex_state:$requires_restart" in
      running:*|stopped:*|needs-first-run:true) args+=(--restart-codex) ;;
    esac
    args+=(--uninstall)
    ;;
esac

if [ "$RESTART_AUTHORIZED" = "true" ]; then
  case "$OPERATION" in
    install) [ "$codex_state" != "running" ] || args+=(--close-running) ;;
    apply|resume) [ "$codex_state" != "running" ] || args+=(--restart-existing) ;;
    restore|uninstall) args+=(--restart-authorized) ;;
  esac
fi
if [ "$FORCE_AUTHORIZED" = "true" ]; then
  case "$OPERATION" in
    install|apply|resume|restore|uninstall) args+=(--force-stop-authorized) ;;
  esac
fi

case "$OPERATION" in
  install) command="$command_root/scripts/install-dream-skin-macos.sh" ;;
  apply|resume) command="$command_root/scripts/start-dream-skin-macos.sh" ;;
  pause) command="$command_root/scripts/pause-dream-skin-macos.sh" ;;
  restore|uninstall) command="$command_root/scripts/restore-dream-skin-macos.sh" ;;
  verify) command="$command_root/scripts/verify-dream-skin-macos.sh" ;;
esac

/bin/mkdir -p "$STATE_ROOT"
/bin/chmod 700 "$STATE_ROOT"
OPERATION_LOG="$STATE_ROOT/studio-operation.log"
: > "$OPERATION_LOG"
/bin/chmod 600 "$OPERATION_LOG"
printf 'DREAM_SKIN_PROGRESS=%s\n' "$progress" >&2

set +e
if [ "$OPERATION" = "uninstall" ]; then
  DREAM_SKIN_STUDIO_ADAPTER=true DREAM_SKIN_DEFER_UNINSTALL_DELETE=true \
    "$command" "${args[@]}" >>"$OPERATION_LOG" 2>&1
elif [ "$OPERATION" = "pause" ]; then
  DREAM_SKIN_STUDIO_ADAPTER=true "$command" >>"$OPERATION_LOG" 2>&1
else
  DREAM_SKIN_STUDIO_ADAPTER=true "$command" "${args[@]}" >>"$OPERATION_LOG" 2>&1
fi
command_exit="$?"
set -e
if [ "$command_exit" -ne 0 ]; then
  if /usr/bin/grep -Eqi 'identity does not match|state is damaged|identity is incomplete|state was preserved' "$OPERATION_LOG"; then
    emit_error STATE_UNSAFE "Theme state needs recovery before it can be used." '["restore","diagnostics","cancel"]'
  elif /usr/bin/grep -Fqi 'Codex did not close within 15 seconds; explicit restart authorization is required for a forced stop.' "$OPERATION_LOG"; then
    emit_error FORCE_STOP_REQUIRED "Codex must close before the theme can be applied." '["authorize-force-stop","cancel"]'
  elif /usr/bin/grep -Fqi 'Close Codex before installation so config.toml cannot be rewritten while the app is saving it.' "$OPERATION_LOG"; then
    emit_error CODEX_CLOSE_REQUIRED "Codex must close before Studio can be installed." '["authorize-restart","cancel"]' true
  elif /usr/bin/grep -Fqi 'Codex is already running without the verified skin CDP endpoint. Close it first or pass --restart-existing.' "$OPERATION_LOG"; then
    emit_error RESTART_REQUIRED "Codex must restart once to apply the theme." '["authorize-restart","cancel"]' true
  elif /usr/bin/grep -Fqi 'Explicit restart authorization is required before Studio can close Codex.' "$OPERATION_LOG"; then
    emit_error RESTART_REQUIRED "Codex must restart once to apply the theme." '["authorize-restart","cancel"]' true
  elif /usr/bin/grep -Eqi 'verification failed|verify failed' "$OPERATION_LOG"; then
    emit_error VERIFY_FAILED "Theme verification failed." '["retry","restore","diagnostics","cancel"]'
  elif /usr/bin/grep -Eqi 'Node.js runtime|bundled Node|runtime.*signature|signature validation failed' "$OPERATION_LOG"; then
    emit_error RUNTIME_INVALID "The Studio runtime is unavailable." '["diagnostics","cancel"]'
  elif /usr/bin/grep -Eqi 'remove the live skin|live skin could not be removed' "$OPERATION_LOG"; then
    emit_error LIVE_REMOVE_FAILED "The live theme could not be removed safely." '["restore","diagnostics","cancel"]'
  else
    emit_error OPERATION_FAILED "The Studio operation failed." '["retry","diagnostics","cancel"]'
  fi
fi

if [ "$OPERATION" = "uninstall" ]; then
  set +e
  STATUS_JSON="$("$command_root/scripts/status-dream-skin-macos.sh" --studio-json --deep --operation uninstall 2>>"$OPERATION_LOG")"
  status_exit="$?"
  set -e
  restored_without_config="false"
  if [ "$status_exit" -ne 0 ] \
    && { [ "$(json_field error.code 2>/dev/null || true)" = "CODEX_NOT_INSTALLED" ] \
      || [ "$(json_field error.code 2>/dev/null || true)" = "CODEX_FIRST_RUN_REQUIRED" ]; }; then
    restored_without_config="true"
  fi
  { [ "$status_exit" -eq 0 ] || [ "$restored_without_config" = "true" ]; } \
    && [ "$(json_field state.session)" = "official" ] \
    || emit_error OPERATION_FAILED "The Studio restore could not be verified." '["retry","restore","diagnostics","cancel"]'

  set +e
  (
    set -e
    /bin/rm -rf "$INSTALL_ROOT"
    /bin/rm -f "$HOME/Desktop/Codex Dream Skin.command"
    /bin/rm -f "$HOME/Desktop/Codex Dream Skin - Customize.command"
    /bin/rm -f "$HOME/Desktop/Codex Dream Skin - Verify.command"
    /bin/rm -f "$HOME/Desktop/Codex Dream Skin - Restore.command"
    if [ "$DELETE_USER_THEMES" = "true" ]; then
      /bin/rm -rf "$STATE_ROOT/themes" "$STATE_ROOT/images" "$STATE_ROOT/theme"
    fi
  ) >>"$OPERATION_LOG" 2>&1
  cleanup_exit="$?"
  set -e
  [ "$cleanup_exit" -eq 0 ] \
    || emit_error OPERATION_FAILED "The Studio uninstall cleanup failed." '["retry","diagnostics","cancel"]'
  command_root="$PROJECT_ROOT"
elif [ "$OPERATION" = "install" ] && engine_complete "$INSTALL_ROOT"; then
  command_root="$INSTALL_ROOT"
fi

set +e
STATUS_JSON="$("$command_root/scripts/status-dream-skin-macos.sh" --studio-json --deep --operation "$OPERATION" 2>>"$OPERATION_LOG")"
status_exit="$?"
set -e
if [ "$status_exit" -ne 0 ]; then
  status_error="$(json_field error.code 2>/dev/null || true)"
  if { [ "$status_error" = "CODEX_NOT_INSTALLED" ] || [ "$status_error" = "CODEX_FIRST_RUN_REQUIRED" ]; } \
    && [ "$(json_field state.session)" = "official" ] \
    && { [ "$OPERATION" = "restore" ] || [ "$OPERATION" = "uninstall" ]; }; then
    state_json="$(printf '%s' "$STATUS_JSON" | /usr/bin/plutil -extract state json -o - -)"
    printf '{"schemaVersion":1,"ok":true,"operation":"%s","state":%s,"error":null}\n' \
      "$OPERATION" "$state_json"
    exit 0
  fi
  [ -z "$status_error" ] || { printf '%s\n' "$STATUS_JSON"; exit 1; }
  emit_error INTERNAL_ERROR "Studio status could not be read safely." '["retry","diagnostics","cancel"]'
fi
case "$OPERATION" in
  apply|resume|verify)
    [ "$(json_field state.verified)" = "true" ] \
      || emit_error VERIFY_FAILED "Theme verification failed." '["retry","restore","diagnostics","cancel"]'
    ;;
esac
printf '%s\n' "$STATUS_JSON"
