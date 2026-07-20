#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
NODE="${NODE:-$(command -v node)}"
TMP="$(/usr/bin/mktemp -d /tmp/codex-dream-skin-browser-state.XXXXXX)"
SERVER_PID=""
WATCHER_PID=""
cleanup() {
  [ -z "$SERVER_PID" ] || /bin/kill -TERM "$SERVER_PID" 2>/dev/null || true
  [ -z "$SERVER_PID" ] || wait "$SERVER_PID" 2>/dev/null || true
  [ -z "$WATCHER_PID" ] || /bin/kill -TERM "$WATCHER_PID" 2>/dev/null || true
  [ -z "$WATCHER_PID" ] || wait "$WATCHER_PID" 2>/dev/null || true
  /bin/rm -rf "$TMP"
}
trap cleanup EXIT

HOME="$TMP/home"
STATE_ROOT="$HOME/Library/Application Support/CodexDreamSkinStudio"
/bin/mkdir -p "$STATE_ROOT/theme" "$HOME/.codex"

/usr/bin/sed "s|__PORT_FILE__|$TMP/port|g; s|__PAYLOAD_FILE__|$TMP/version.json|g" \
  > "$TMP/server.mjs" <<'STUB'
import fs from "node:fs";
import http from "node:http";
const server = http.createServer((request, response) => {
  response.setHeader("content-type", "application/json");
  if (request.url === "/json/version") response.end(fs.readFileSync("__PAYLOAD_FILE__"));
  else { response.statusCode = 404; response.end("{}"); }
});
server.listen(0, "127.0.0.1", () => fs.writeFileSync("__PORT_FILE__", String(server.address().port)));
STUB
/usr/bin/printf '{}\n' > "$TMP/version.json"
"$NODE" "$TMP/server.mjs" &
SERVER_PID="$!"
deadline=$((SECONDS + 5))
while [ ! -s "$TMP/port" ] && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.02; done
PORT="$(/bin/cat "$TMP/port")"

/usr/bin/env HOME="$HOME" NODE="$NODE" /bin/bash -c '
  set -euo pipefail
  . "$1/scripts/common-macos.sh"
  type cdp_browser_id >/dev/null
  printf "{\"webSocketDebuggerUrl\":\"ws://127.0.0.1:%s/devtools/browser/Browser-A\"}\n" "$2" > "$3"
  [ "$(cdp_browser_id "$2")" = "Browser-A" ]
  printf "{\"webSocketDebuggerUrl\":\"ws://[::1]:%s/devtools/browser/Browser-v6\"}\n" "$2" > "$3"
  [ "$(cdp_browser_id "$2")" = "Browser-v6" ]
  for value in \
    "ws://0.0.0.0:$2/devtools/browser/Browser-A" \
    "ws://localhost:$2/devtools/browser/Browser-A" \
    "ws://example.com:$2/devtools/browser/Browser-A" \
    "ws://127.0.0.1:9341/devtools/browser/Browser-A" \
    "ws://127.0.0.1:$2/devtools/page/Browser-A" \
    "ws://127.0.0.1:$2/devtools/browser/bad%20id" \
    "ws://127.0.0.1:$2/devtools/browser/Browser-A?query=1"; do
    printf "{\"webSocketDebuggerUrl\":\"%s\"}\n" "$value" > "$3"
    if cdp_browser_id "$2" >/dev/null 2>&1; then exit 1; fi
  done
  printf "{\n" > "$3"
  if cdp_browser_id "$2" >/dev/null 2>&1; then exit 1; fi
' _ "$ROOT" "$PORT" "$TMP/version.json"

/usr/bin/env HOME="$HOME" NODE="$NODE" NODE_RUNTIME_VALIDATED=true /bin/bash -c '
  set -euo pipefail
  . "$1/scripts/common-macos.sh"
  NODE="$2"
  NODE_VERSION=v24.0.0
  CODEX_BUNDLE=/fixture/Codex.app
  CODEX_EXE=/fixture/Codex
  CODEX_VERSION=fixture
  CODEX_TEAM_ID=TEAM
  write_state 9341 4242 "Mon Jan 1 00:00:00 2024" 3131 Browser-A
' _ "$ROOT" "$NODE"
"$NODE" -e '
  const state = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (state.schemaVersion !== 5 || state.injectorProtocol !== 3 || state.browserId !== "Browser-A") process.exit(1);
' "$STATE_ROOT/state.json"

PAUSE_ROOT="$TMP/pause-engine"
/bin/mkdir -p "$PAUSE_ROOT/scripts"
/bin/cp "$ROOT/scripts/pause-dream-skin-macos.sh" "$PAUSE_ROOT/scripts/"
/usr/bin/sed "s|__STATE_ROOT__|$STATE_ROOT|g; s|__PROJECT_ROOT__|$PAUSE_ROOT|g" \
  > "$PAUSE_ROOT/scripts/common-macos.sh" <<'STUB'
PROJECT_ROOT="__PROJECT_ROOT__"
STATE_ROOT="__STATE_ROOT__"
STATE_PATH="$STATE_ROOT/state.json"
THEME_DIR="$STATE_ROOT/theme"
INJECTOR="$PROJECT_ROOT/scripts/injector.mjs"
fail() { printf '%s\n' "$*" >&2; exit 1; }
require_lifecycle_lock() { :; }
release_lifecycle_lock() { :; }
discover_codex_app() { :; }
require_macos_runtime() { :; }
ensure_state_root() { /bin/mkdir -p "$STATE_ROOT"; }
state_field() { "$NODE" -e 'process.stdout.write(String(JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))[process.argv[2]] ?? ""))' "$STATE_PATH" "$1"; }
browser_id_is_valid() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,200}$ ]]; }
codex_is_running() { return 1; }
verified_cdp_browser_id() { return 1; }
release_codex_launchd_job() { :; }
stop_recorded_injector() { :; }
STUB
/usr/bin/env HOME="$HOME" NODE="$NODE" "$PAUSE_ROOT/scripts/pause-dream-skin-macos.sh" >/dev/null
"$NODE" -e '
  const state = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (state.schemaVersion !== 5) throw new Error(`pause changed schemaVersion to ${state.schemaVersion}`);
  if (state.injectorProtocol !== 3) throw new Error(`pause changed injectorProtocol to ${state.injectorProtocol}`);
  if (state.browserId !== "Browser-A") throw new Error(`pause changed browserId to ${state.browserId}`);
  if (state.session !== "paused") throw new Error(`pause left session as ${state.session}`);
' "$STATE_ROOT/state.json"

/usr/bin/printf 'setTimeout(() => {}, 30000);\n' > "$TMP/fake-injector.mjs"
"$NODE" "$TMP/fake-injector.mjs" --watch --port 19341 --browser-id Browser-A --theme-dir "$STATE_ROOT/theme" &
WATCHER_PID="$!"
/bin/sleep 0.1
WATCHER_START="$(/bin/ps -p "$WATCHER_PID" -o lstart= | /usr/bin/awk '{$1=$1; print}')"
/usr/bin/env HOME="$HOME" /bin/bash -c '
  set -euo pipefail
  . "$1/scripts/common-macos.sh"
  recorded_injector_process_matches "$2" "$3" "$4" "$5" 19341 Browser-A
  if recorded_injector_process_matches "$2" "$3" "$4" "$5" 19341 browser-a; then exit 1; fi
  if recorded_injector_process_matches "$2" wrong-start "$4" "$5" 19341 Browser-A; then exit 1; fi
' _ "$ROOT" "$WATCHER_PID" "$WATCHER_START" "$NODE" "$TMP/fake-injector.mjs"

"$NODE" - "$ROOT" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const scripts = [
  "common-macos.sh", "start-dream-skin-macos.sh", "pause-dream-skin-macos.sh",
  "restore-dream-skin-macos.sh", "verify-dream-skin-macos.sh",
  "status-dream-skin-macos.sh", "doctor-macos.sh",
].map((name) => [name, fs.readFileSync(path.join(process.argv[2], "scripts", name), "utf8")]);
for (const [name, source] of scripts) {
  for (const match of source.matchAll(/\$INJECTOR" --(watch|once|verify|remove)\b[^\n]*/g)) {
    if (!match[0].includes("--browser-id")) throw new Error(`${name} omits Browser ID: ${match[0]}`);
  }
}
NODE

printf 'PASS: macOS shell persists and propagates case-sensitive Browser ID identity.\n'
