#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
NODE="${NODE:-/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node}"
[ -x "$NODE" ] || { printf 'Codex bundled Node.js was not found: %s\n' "$NODE" >&2; exit 1; }

TMP="$(/usr/bin/mktemp -d /tmp/codex-dream-skin-studio-adapter.XXXXXX)"
TEST_HOME="$TMP/home"
/bin/mkdir -p "$TEST_HOME"
RESPONDER_PID=""
cleanup() {
  [ -z "$RESPONDER_PID" ] || /bin/kill -TERM "$RESPONDER_PID" 2>/dev/null || true
  [ -z "$RESPONDER_PID" ] || wait "$RESPONDER_PID" 2>/dev/null || true
  /bin/rm -rf "$TMP"
}
trap cleanup EXIT

snapshot() {
  /usr/bin/find "$TEST_HOME" -print0 | /usr/bin/sort -z | while IFS= read -r -d '' path; do
    if [ -f "$path" ]; then
      printf 'file %s ' "$path"
      /usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}'
    elif [ -d "$path" ]; then
      printf 'dir %s\n' "$path"
    else
      printf 'other %s\n' "$path"
    fi
  done
}

run_adapter() {
  local operation="$1"
  set +e
  ADAPTER_JSON="$(/usr/bin/env HOME="$TEST_HOME" "$ROOT/scripts/studio-adapter-macos.sh" "$operation")"
  ADAPTER_EXIT="$?"
  set -e
}

BEFORE="$(snapshot)"
run_adapter preflight
[ "$ADAPTER_EXIT" -eq 1 ] || {
  printf 'missing-Codex preflight did not exit 1.\n' >&2
  exit 1
}
[ "$BEFORE" = "$(snapshot)" ] || {
  printf 'preflight changed HOME.\n' >&2
  exit 1
}
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.schemaVersion !== 1 || value.operation !== "preflight") process.exit(1);
  if (value.ok || !["CODEX_NOT_INSTALLED", "CODEX_FIRST_RUN_REQUIRED"].includes(value.error?.code)) process.exit(1);
  if (!value.state || !Array.isArray(value.state.availableActions)) process.exit(1);
' "$ADAPTER_JSON"

BEFORE="$(snapshot)"
run_adapter status
[ "$ADAPTER_EXIT" -eq 1 ] || {
  printf 'missing-Codex status did not exit 1.\n' >&2
  exit 1
}
[ "$BEFORE" = "$(snapshot)" ] || {
  printf 'status changed HOME.\n' >&2
  exit 1
}
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.schemaVersion !== 1 || value.operation !== "status") process.exit(1);
  if (value.ok || !["CODEX_NOT_INSTALLED", "CODEX_FIRST_RUN_REQUIRED"].includes(value.error?.code)) process.exit(1);
  if (!value.state || !Array.isArray(value.state.availableActions)) process.exit(1);
  if (/(port|pid|cdp|powershell|\/Users\/)/i.test(JSON.stringify(value))) process.exit(1);
' "$ADAPTER_JSON"

PORT=19431
"$NODE" -e '
  const http = require("node:http");
  http.createServer((_, response) => response.end("{}"))
    .listen(Number(process.argv[1]), "127.0.0.1");
' "$PORT" &
RESPONDER_PID="$!"
/bin/sleep 0.1

LEGACY_HOME="$TMP/legacy-home"
LEGACY_STATE="$LEGACY_HOME/Library/Application Support/CodexDreamSkinStudio"
/bin/mkdir -p "$LEGACY_STATE"
/usr/bin/printf '{"port":%s}\n' "$PORT" > "$LEGACY_STATE/state.json"
LEGACY_JSON="$(/usr/bin/env HOME="$LEGACY_HOME" "$ROOT/scripts/status-dream-skin-macos.sh" --json --deep)"
LEGACY_TEXT="$(/usr/bin/env HOME="$LEGACY_HOME" "$ROOT/scripts/status-dream-skin-macos.sh" --deep)"
"$NODE" -e 'if (JSON.parse(process.argv[1]).cdpOk !== true) process.exit(1)' "$LEGACY_JSON"
printf '%s\n' "$LEGACY_TEXT" | /usr/bin/grep -Fx 'cdp=true' >/dev/null

TEST_HOME="$TMP/success-home"
INSTALL_ROOT="$TEST_HOME/.codex/codex-dream-skin-studio"
STATE_ROOT="$TEST_HOME/Library/Application Support/CodexDreamSkinStudio"
/bin/mkdir -p "$INSTALL_ROOT/scripts" "$STATE_ROOT/theme"
/bin/cp "$ROOT/VERSION" "$INSTALL_ROOT/VERSION"
for script in studio-adapter-macos.sh start-dream-skin-macos.sh restore-dream-skin-macos.sh; do
  : > "$INSTALL_ROOT/scripts/$script"
  /bin/chmod 755 "$INSTALL_ROOT/scripts/$script"
done
: > "$TEST_HOME/.codex/config.toml"
: > "$STATE_ROOT/theme-backup.json"
/usr/bin/printf '%s\n' '{"name":"Fixture"}' > "$STATE_ROOT/theme/theme.json"
/usr/bin/printf '{"port":%s,"session":"paused","injectorPid":0}\n' "$PORT" > "$STATE_ROOT/state.json"
run_adapter status
[ "$ADAPTER_EXIT" -eq 0 ] || {
  printf 'ready Studio status did not succeed.\n' >&2
  exit 1
}
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (!value.ok || value.state.install !== "ready" || value.state.verified !== null) process.exit(1);
' "$ADAPTER_JSON"

INVALID_JSON="$TMP/invalid.json"
if /usr/bin/env HOME="$TEST_HOME" "$ROOT/scripts/studio-adapter-macos.sh" nope >"$INVALID_JSON"; then
  printf 'unknown operation unexpectedly succeeded.\n' >&2
  exit 1
else
  [ "$?" -eq 2 ] || { printf 'unknown operation did not exit 2.\n' >&2; exit 1; }
fi
"$NODE" -e '
  const value = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (value.error?.code !== "INVALID_REQUEST") process.exit(1);
' "$INVALID_JSON"

printf 'PASS: macOS Studio adapter is read-only and protocol-safe.\n'
