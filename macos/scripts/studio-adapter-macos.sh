#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
OPERATION="${1:-status}"
shift || true

emit_invalid_request() {
  printf '%s\n' '{"schemaVersion":1,"ok":false,"operation":"status","state":{"install":"not-installed","codex":"not-installed","session":"official","operation":"idle","themeName":null,"requiresRestart":false,"availableActions":[],"verified":null},"error":{"code":"INVALID_REQUEST","message":"The Studio operation is invalid.","recoveryActions":["cancel"]}}'
  exit 2
}

case "$OPERATION" in
  preflight|status)
    [ "$#" -eq 0 ] || emit_invalid_request
    exec "$SCRIPT_DIR/status-dream-skin-macos.sh" --studio-json --deep --operation "$OPERATION"
    ;;
  install|apply|pause|resume|restore|verify|uninstall)
    emit_invalid_request
    ;;
  *) emit_invalid_request ;;
esac
