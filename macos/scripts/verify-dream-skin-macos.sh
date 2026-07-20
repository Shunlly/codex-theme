#!/bin/bash

set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd -P)/common-macos.sh"

PORT=9341
PORT_EXPLICIT="false"
SCREENSHOT=""
RELOAD="false"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-}"; PORT_EXPLICIT="true"; shift 2 ;;
    --screenshot) SCREENSHOT="${2:-}"; shift 2 ;;
    --reload) RELOAD="true"; shift ;;
    *) fail "Unknown verify argument: $1" ;;
  esac
done

[ "$RELOAD" = "true" ] && require_lifecycle_lock
[ "$RELOAD" != "true" ] || trap release_lifecycle_lock EXIT

discover_codex_app
require_macos_runtime
if [ "$PORT_EXPLICIT" = "false" ] && [ -f "$STATE_PATH" ]; then
  PORT="$(state_field port)"
fi
ACTIVE_BROWSER_ID="$(verified_cdp_browser_id "$PORT")" \
  || fail "Port $PORT is not a verified Codex loopback CDP endpoint."
if [ -f "$STATE_PATH" ]; then
  SAVED_BROWSER_ID="$(state_field browserId 2>/dev/null || true)"
  browser_id_is_valid "$SAVED_BROWSER_ID" \
    || fail "The saved Dream Skin Browser ID is missing or invalid."
  [ "$SAVED_BROWSER_ID" = "$ACTIVE_BROWSER_ID" ] \
    || fail "The active CDP browser does not match the saved Dream Skin session; state was preserved."
  ACTIVE_BROWSER_ID="$SAVED_BROWSER_ID"
fi

ARGS=("$INJECTOR" --verify --port "$PORT" --browser-id "$ACTIVE_BROWSER_ID" --theme-dir "$THEME_DIR" --timeout-ms 30000)
[ -n "$SCREENSHOT" ] && ARGS+=(--screenshot "$SCREENSHOT")
[ "$RELOAD" = "true" ] && ARGS+=(--reload)
if [ "$RELOAD" = "true" ]; then
  "$NODE" "${ARGS[@]}"
else
  exec "$NODE" "${ARGS[@]}"
fi
