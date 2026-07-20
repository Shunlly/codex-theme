#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
NODE="${NODE:-$(command -v node)}"
TMP="$(/usr/bin/mktemp -d /tmp/codex-dream-skin-browser-state.XXXXXX)"
SERVER_PID=""
WATCHER_PID=""
cleanup() {
  [ -z "${TRANSACTION_FAKE_LAUNCHCTL:-}" ] \
    || "$TRANSACTION_FAKE_LAUNCHCTL" remove test-job >/dev/null 2>&1 || true
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
/bin/kill -TERM "$WATCHER_PID" 2>/dev/null || true
wait "$WATCHER_PID" 2>/dev/null || true
WATCHER_PID=""

# A watcher launch is one transaction: identity lookup and atomic state
# publication failures must stop the exact new watcher before retry can start.
TRANSACTION_ROOT="$TMP/watcher-transaction"
TRANSACTION_HOME="$TRANSACTION_ROOT/home"
TRANSACTION_ENGINE="$TRANSACTION_ROOT/engine"
TRANSACTION_STATE="$TRANSACTION_HOME/Library/Application Support/CodexDreamSkinStudio"
TRANSACTION_FALLBACK_CONTROL="$TRANSACTION_ROOT/force-launchctl"
TRANSACTION_FALLBACK_ATTEMPTS="$TRANSACTION_ROOT/launch-attempts"
TRANSACTION_FALLBACK_PID="$TRANSACTION_ROOT/launchctl-watcher.pid"
TRANSACTION_FAKE_LAUNCHCTL="$TRANSACTION_ENGINE/scripts/fake-launchctl.sh"
TRANSACTION_FAKE_JOB_PID="$TRANSACTION_ROOT/fake-launchctl-job.pid"
/bin/mkdir -p "$TRANSACTION_ENGINE/scripts"
/bin/cp "$ROOT/VERSION" "$TRANSACTION_ENGINE/VERSION"
/bin/cp "$ROOT/scripts/start-dream-skin-macos.sh" "$ROOT/scripts/pause-dream-skin-macos.sh" \
  "$TRANSACTION_ENGINE/scripts/"
/usr/bin/sed "s|/bin/launchctl|\"$TRANSACTION_FAKE_LAUNCHCTL\"|g" \
  "$ROOT/scripts/common-macos.sh" > "$TRANSACTION_ENGINE/scripts/common-production-macos.sh"
/usr/bin/sed "s|__ENGINE__|$TRANSACTION_ENGINE|g" > "$TRANSACTION_ENGINE/scripts/common-macos.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
. "__ENGINE__/scripts/common-production-macos.sh"
INJECTOR="$SCRIPT_DIR/fake-injector.mjs"
discover_codex_app() { :; }
require_macos_runtime() { :; }
ensure_node_runtime() { :; }
require_lifecycle_lock() { :; }
release_lifecycle_lock() { :; }
release_codex_launchd_job() { :; }
codex_is_running() { return 1; }
codex_main_pids() { :; }
wait_for_cdp() { :; }
launch_codex_with_cdp() { : > "$DREAM_SKIN_CDP_OPENED"; }
stop_codex() { printf 'stop:%s\n' "$1" >> "$DREAM_SKIN_CDP_MARKER"; }
launch_codex_normally() { printf 'normal\n' >> "$DREAM_SKIN_CDP_MARKER"; }
verified_cdp_browser_id() {
  if [ "${DREAM_SKIN_OPEN_NEW_CDP:-false}" = "true" ] && [ ! -e "$DREAM_SKIN_CDP_OPENED" ]; then
    return 1
  fi
  printf 'Browser-A\n'
}
process_started_at() {
  [ "${DREAM_SKIN_STATE_FAULT:-}" != "start-time" ] || return 1
  /bin/ps -p "$1" -o lstart= 2>/dev/null | /usr/bin/awk '{$1=$1; print}'
}
case "${DREAM_SKIN_STATE_FAULT:-}" in
  temp-write) STATE_PATH="$STATE_ROOT/missing/state.json" ;;
esac
STUB
/usr/bin/sed "s|__JOB_PID__|$TRANSACTION_FAKE_JOB_PID|g" \
  > "$TRANSACTION_FAKE_LAUNCHCTL" <<'STUB'
#!/bin/bash
set -euo pipefail
job_pid_path="__JOB_PID__"
case "${1:-}" in
  remove)
    exit 1
    ;;
  submit)
    shift
    stdout_path=/dev/null
    stderr_path=/dev/null
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -l) shift 2 ;;
        -o) stdout_path="$2"; shift 2 ;;
        -e) stderr_path="$2"; shift 2 ;;
        --) shift; break ;;
        *) shift ;;
      esac
    done
    /usr/bin/nohup "$@" >>"$stdout_path" 2>>"$stderr_path" &
    printf '%s\n' "$!" > "$job_pid_path"
    ;;
  kickstart)
    ;;
  print)
    [ -s "$job_pid_path" ] || exit 113
    pid="$(/bin/cat "$job_pid_path")"
    /bin/kill -0 "$pid" 2>/dev/null || exit 113
    printf '\tpid = %s\n' "$pid"
    ;;
  *)
    exit 2
    ;;
esac
STUB
/usr/bin/sed \
  -e "s|__FALLBACK_CONTROL__|$TRANSACTION_FALLBACK_CONTROL|g" \
  -e "s|__FALLBACK_ATTEMPTS__|$TRANSACTION_FALLBACK_ATTEMPTS|g" \
  -e "s|__FALLBACK_PID__|$TRANSACTION_FALLBACK_PID|g" \
  > "$TRANSACTION_ENGINE/scripts/fake-injector.mjs" <<'STUB'
import fs from "node:fs";
if (process.argv.includes("--watch")) {
  let pidFile = process.env.DREAM_SKIN_WATCHER_PID_FILE;
  if (fs.existsSync("__FALLBACK_CONTROL__")) {
    let attempts = 0;
    try { attempts = Number(fs.readFileSync("__FALLBACK_ATTEMPTS__", "utf8")); } catch {}
    attempts += 1;
    fs.writeFileSync("__FALLBACK_ATTEMPTS__", String(attempts));
    if (attempts === 1) process.exit(0);
    pidFile = "__FALLBACK_PID__";
  }
  fs.writeFileSync(pidFile, String(process.pid));
  setInterval(() => {}, 30000);
}
STUB
/bin/chmod 755 "$TRANSACTION_ENGINE/scripts/"*.sh

wait_for_watcher_pid() {
  local file="$1"
  local deadline=$((SECONDS + 5))
  while [ ! -s "$file" ] && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.02; done
  [ -s "$file" ] || { printf 'Watcher fixture did not publish its PID.\n' >&2; exit 1; }
  /bin/cat "$file"
}

assert_watcher_stopped() {
  local pid="$1"
  local deadline=$((SECONDS + 5))
  while /bin/kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.02; done
  if /bin/kill -0 "$pid" 2>/dev/null; then
    WATCHER_PID="$pid"
    printf 'Failed watcher transaction left PID %s alive.\n' "$pid" >&2
    exit 1
  fi
}

run_watcher_transaction() {
  local path="$1"
  local fault="$2"
  local open_new_cdp="${3:-false}"
  local launcher="${4:-direct}"
  local pid_file="$TRANSACTION_ROOT/$path-$fault.pid"
  local cdp_opened="$TRANSACTION_ROOT/$path-$fault.cdp"
  local cdp_marker="$TRANSACTION_ROOT/$path-$fault.cdp.log"
  local output="$TRANSACTION_ROOT/$path-$fault.out"
  local error="$TRANSACTION_ROOT/$path-$fault.err"
  local command
  set --

  "$TRANSACTION_FAKE_LAUNCHCTL" remove test-job >/dev/null 2>&1 || true
  /bin/rm -rf "$TRANSACTION_HOME"
  /bin/mkdir -p "$TRANSACTION_STATE/theme" "$TRANSACTION_HOME/.codex"
  /bin/rm -f "$pid_file" "$cdp_opened" "$cdp_marker" \
    "$TRANSACTION_FALLBACK_CONTROL" "$TRANSACTION_FALLBACK_ATTEMPTS" \
    "$TRANSACTION_FALLBACK_PID" "$TRANSACTION_FAKE_JOB_PID"
  if [ "$launcher" = "launchctl" ]; then
    : > "$TRANSACTION_FALLBACK_CONTROL"
    pid_file="$TRANSACTION_FALLBACK_PID"
  fi
  if [ "$fault" = "rename" ]; then /bin/mkdir "$TRANSACTION_STATE/state.json"; fi
  case "$path" in
    full)
      command="$TRANSACTION_ENGINE/scripts/start-dream-skin-macos.sh"
      [ "$open_new_cdp" != "true" ] || set -- --studio-strict-verify
      ;;
    hot)
      command=/bin/bash
      set -- -c '. "$1/scripts/common-macos.sh"; hot_reapply_theme 19341 1000' _ "$TRANSACTION_ENGINE"
      ;;
  esac

  set +e
  /usr/bin/env HOME="$TRANSACTION_HOME" NODE="$NODE" NODE_RUNTIME_VALIDATED=true \
    DREAM_SKIN_STATE_FAULT="$fault" DREAM_SKIN_OPEN_NEW_CDP="$open_new_cdp" \
    DREAM_SKIN_WATCHER_PID_FILE="$pid_file" DREAM_SKIN_CDP_OPENED="$cdp_opened" \
    DREAM_SKIN_CDP_MARKER="$cdp_marker" \
    "$command" "$@" >"$output" 2>"$error"
  local failed_exit="$?"
  set -e
  [ "$failed_exit" -ne 0 ] || { printf '%s accepted %s failure.\n' "$path" "$fault" >&2; exit 1; }
  local failed_pid
  failed_pid="$(wait_for_watcher_pid "$pid_file")"
  assert_watcher_stopped "$failed_pid"
  if [ "$fault" = "rename" ]; then /bin/rmdir "$TRANSACTION_STATE/state.json"; fi
  [ ! -e "$TRANSACTION_STATE/state.json" ] && [ ! -L "$TRANSACTION_STATE/state.json" ] \
    || { printf '%s published state after %s failure.\n' "$path" "$fault" >&2; exit 1; }
  if /usr/bin/find "$TRANSACTION_STATE" -name 'state.json.*.tmp' -print -quit | /usr/bin/grep -q .; then
    printf '%s retained temporary state after %s failure.\n' "$path" "$fault" >&2
    exit 1
  fi
  if [ "$open_new_cdp" = "true" ]; then
    /usr/bin/grep -Fx 'stop:false' "$cdp_marker" >/dev/null
    /usr/bin/grep -Fx 'normal' "$cdp_marker" >/dev/null
  fi

  /bin/rm -f "$pid_file" "$TRANSACTION_FALLBACK_CONTROL" "$TRANSACTION_FALLBACK_ATTEMPTS"
  case "$path" in
    full)
      /usr/bin/env HOME="$TRANSACTION_HOME" NODE="$NODE" NODE_RUNTIME_VALIDATED=true \
        DREAM_SKIN_WATCHER_PID_FILE="$pid_file" DREAM_SKIN_CDP_OPENED="$cdp_opened" \
        DREAM_SKIN_CDP_MARKER="$cdp_marker" \
        "$TRANSACTION_ENGINE/scripts/start-dream-skin-macos.sh" >/dev/null
      ;;
    hot)
      /usr/bin/env HOME="$TRANSACTION_HOME" NODE="$NODE" NODE_RUNTIME_VALIDATED=true \
        DREAM_SKIN_WATCHER_PID_FILE="$pid_file" DREAM_SKIN_CDP_OPENED="$cdp_opened" \
        DREAM_SKIN_CDP_MARKER="$cdp_marker" \
        /bin/bash -c '. "$1/scripts/common-macos.sh"; hot_reapply_theme 19341 1000' \
        _ "$TRANSACTION_ENGINE"
      ;;
  esac
  local retry_pid
  retry_pid="$(wait_for_watcher_pid "$pid_file")"
  WATCHER_PID="$retry_pid"
  [ "$($NODE -e 'process.stdout.write(String(JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).injectorPid))' "$TRANSACTION_STATE/state.json")" = "$retry_pid" ]
  /usr/bin/env HOME="$TRANSACTION_HOME" NODE="$NODE" NODE_RUNTIME_VALIDATED=true \
    DREAM_SKIN_WATCHER_PID_FILE="$pid_file" DREAM_SKIN_CDP_OPENED="$cdp_opened" \
    DREAM_SKIN_CDP_MARKER="$cdp_marker" \
    "$TRANSACTION_ENGINE/scripts/pause-dream-skin-macos.sh" >/dev/null
  assert_watcher_stopped "$retry_pid"
  WATCHER_PID=""
  [ "$($NODE -e 'process.stdout.write(JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8")).session)' "$TRANSACTION_STATE/state.json")" = "paused" ]
}

run_watcher_transaction full start-time true
run_watcher_transaction full temp-write
run_watcher_transaction full rename
run_watcher_transaction hot start-time
run_watcher_transaction hot temp-write
run_watcher_transaction hot rename
run_watcher_transaction hot temp-write false launchctl

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
