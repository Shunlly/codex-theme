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
  printf '{"schemaVersion":1,"ok":false,"operation":"%s","state":{"install":"not-installed","codex":"not-installed","session":"official","operation":"idle","themeName":null,"requiresRestart":false,"availableActions":[],"verified":null},"error":{"code":"INVALID_REQUEST","message":"The Studio operation is invalid.","recoveryActions":["cancel"]}}\n' "$OPERATION"
  exit 2
}

case "$OPERATION" in
  preflight|install|apply|status|pause|resume|restore|verify|uninstall) ;;
  *) emit_invalid_request ;;
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
if [ "$OPERATION" = "preflight" ] || [ "$OPERATION" = "status" ]; then
  [ "$RESTART_AUTHORIZED" = "false" ] && [ "$DELETE_USER_THEMES" = "false" ] || emit_invalid_request
  exec "$SCRIPT_DIR/status-dream-skin-macos.sh" --studio-json --deep --operation "$OPERATION"
fi

NODE_BIN="${NODE:-}"
if [ ! -x "$NODE_BIN" ]; then
  for candidate in \
    "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node" \
    "/Applications/Codex.app/Contents/Resources/cua_node/bin/node" \
    "$HOME/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node" \
    "$HOME/Applications/Codex.app/Contents/Resources/cua_node/bin/node"
  do
    if [ -x "$candidate" ]; then NODE_BIN="$candidate"; break; fi
  done
fi
[ -x "$NODE_BIN" ] || {
  printf '{"schemaVersion":1,"ok":false,"operation":"%s","state":{"install":"not-installed","codex":"not-installed","session":"official","operation":"idle","themeName":null,"requiresRestart":false,"availableActions":[],"verified":null},"error":{"code":"RUNTIME_INVALID","message":"The Codex runtime is unavailable.","recoveryActions":["diagnostics","cancel"]}}\n' "$OPERATION"
  exit 1
}

engine_complete() {
  local root="$1"
  [ -f "$root/VERSION" ] \
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
  "$NODE_BIN" -e '
    let state = { install: "not-installed", codex: "not-installed", session: "official", operation: "idle", themeName: null, requiresRestart: false, availableActions: [], verified: null };
    try { state = JSON.parse(process.argv[1]).state || state; } catch {}
    state.operation = "idle";
    state.requiresRestart = process.argv[6] === "true";
    process.stdout.write(`${JSON.stringify({ schemaVersion: 1, ok: false, operation: process.argv[2], state, error: { code: process.argv[3], message: process.argv[4], recoveryActions: JSON.parse(process.argv[5]) } })}\n`);
  ' "${STATUS_JSON:-}" "$OPERATION" "$code" "$message" "$recovery_json" "$restart"
  exit 1
}

json_field() {
  "$NODE_BIN" -e '
    let value = JSON.parse(process.argv[1]);
    for (const key of process.argv[2].split(".")) value = value?.[key];
    if (value !== undefined && value !== null) process.stdout.write(String(value));
  ' "$STATUS_JSON" "$1"
}

status_root="$PROJECT_ROOT"
case "$OPERATION" in
  apply|pause|resume|verify)
    installed_matches_bundle \
      || emit_error OPERATION_FAILED "The installed Studio engine is unavailable or out of date." '["retry","diagnostics","cancel"]'
    status_root="$INSTALL_ROOT"
    ;;
  restore|uninstall)
    if engine_complete "$INSTALL_ROOT"; then status_root="$INSTALL_ROOT"; fi
    ;;
esac

set +e
STATUS_JSON="$("$status_root/scripts/status-dream-skin-macos.sh" --studio-json --deep --operation "$OPERATION" 2>/dev/null)"
status_exit="$?"
set -e
if ! "$NODE_BIN" -e 'JSON.parse(process.argv[1])' "$STATUS_JSON" >/dev/null 2>&1; then
  emit_error INTERNAL_ERROR "Studio status could not be read safely." '["retry","diagnostics","cancel"]'
fi

status_error="$(json_field error.code 2>/dev/null || true)"
if [ "$status_exit" -ne 0 ] && [ -n "$status_error" ]; then
  printf '%s\n' "$STATUS_JSON"
  exit 1
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
  restore) progress="restoring"; command_root="$status_root"; args=(--restore-base-theme --restart-codex) ;;
  verify) progress="verifying"; command_root="$INSTALL_ROOT"; args=(--reload) ;;
  uninstall) progress="uninstalling"; command_root="$status_root"; args=(--restore-base-theme --restart-codex --uninstall) ;;
esac

if [ "$codex_state" = "running" ] && [ "$RESTART_AUTHORIZED" = "true" ]; then
  case "$OPERATION" in
    install) args+=(--close-running) ;;
    apply|resume) args+=(--restart-existing) ;;
  esac
  [ "$FORCE_AUTHORIZED" != "true" ] || args+=(--force-stop-authorized)
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
printf 'DREAM_SKIN_PROGRESS %s\n' "$progress" >&2

set +e
if [ "$OPERATION" = "uninstall" ]; then
  DREAM_SKIN_STUDIO_ADAPTER=true DREAM_SKIN_DEFER_UNINSTALL_DELETE=true \
    "$command" "${args[@]}" >>"$OPERATION_LOG" 2>&1
else
  DREAM_SKIN_STUDIO_ADAPTER=true "$command" "${args[@]}" >>"$OPERATION_LOG" 2>&1
fi
command_exit="$?"
set -e
if [ "$command_exit" -ne 0 ]; then
  if /usr/bin/grep -Eqi 'identity does not match|state is damaged|identity is incomplete|state was preserved' "$OPERATION_LOG"; then
    emit_error STATE_UNSAFE "Theme state needs recovery before it can be used." '["restore","diagnostics","cancel"]'
  elif /usr/bin/grep -Eqi 'did not close|forced stop|force stop|explicit restart authorization' "$OPERATION_LOG"; then
    emit_error FORCE_STOP_REQUIRED "Codex must close before the theme can be applied." '["authorize-force-stop","cancel"]'
  elif /usr/bin/grep -Eqi 'verification failed|verify failed' "$OPERATION_LOG"; then
    emit_error VERIFY_FAILED "Theme verification failed." '["retry","restore","diagnostics","cancel"]'
  elif /usr/bin/grep -Eqi 'remove the live skin|live skin could not be removed' "$OPERATION_LOG"; then
    emit_error LIVE_REMOVE_FAILED "The live theme could not be removed safely." '["retry","restore","diagnostics","cancel"]'
  else
    emit_error OPERATION_FAILED "The Studio operation failed." '["retry","diagnostics","cancel"]'
  fi
fi

if [ "$OPERATION" = "uninstall" ]; then
  set +e
  STATUS_JSON="$("$command_root/scripts/status-dream-skin-macos.sh" --studio-json --deep --operation uninstall 2>>"$OPERATION_LOG")"
  status_exit="$?"
  set -e
  [ "$status_exit" -eq 0 ] && [ "$(json_field state.session)" = "official" ] \
    || emit_error OPERATION_FAILED "The Studio restore could not be verified." '["retry","restore","diagnostics","cancel"]'

  /bin/rm -rf "$INSTALL_ROOT"
  /bin/rm -f "$HOME/Desktop/Codex Dream Skin.command"
  /bin/rm -f "$HOME/Desktop/Codex Dream Skin - Customize.command"
  /bin/rm -f "$HOME/Desktop/Codex Dream Skin - Verify.command"
  /bin/rm -f "$HOME/Desktop/Codex Dream Skin - Restore.command"
  if [ "$DELETE_USER_THEMES" = "true" ]; then
    /bin/rm -rf "$STATE_ROOT/themes" "$STATE_ROOT/images" "$STATE_ROOT/theme"
  fi
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
  [ -z "$status_error" ] || { printf '%s\n' "$STATUS_JSON"; exit 1; }
  emit_error INTERNAL_ERROR "Studio status could not be read safely." '["retry","diagnostics","cancel"]'
fi
case "$OPERATION" in
  apply|resume|verify)
    [ "$(json_field state.verified)" = "true" ] \
      || emit_error VERIFY_FAILED "Theme verification failed." '["retry","restore","diagnostics","cancel"]'
    ;;
  uninstall)
    STATUS_JSON="$("$NODE_BIN" -e '
      const value = JSON.parse(process.argv[1]);
      value.ok = true;
      value.operation = "uninstall";
      value.state.install = "not-installed";
      value.state.session = "official";
      value.state.themeName = null;
      value.state.availableActions = ["install"];
      value.state.verified = null;
      value.error = null;
      process.stdout.write(JSON.stringify(value));
    ' "$STATUS_JSON")"
    ;;
esac
printf '%s\n' "$STATUS_JSON"
