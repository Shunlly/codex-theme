#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
NODE="${NODE:-/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node}"
[ -x "$NODE" ] || { printf 'Codex bundled Node.js was not found: %s\n' "$NODE" >&2; exit 1; }

TMP="$(/usr/bin/mktemp -d /tmp/codex-dream-skin-studio-adapter.XXXXXX)"
TEST_HOME="$TMP/home"
/bin/mkdir -p "$TEST_HOME"
cleanup() { /bin/rm -rf "$TMP"; }
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

BEFORE="$(snapshot)"
PREFLIGHT_JSON="$(/usr/bin/env HOME="$TEST_HOME" "$ROOT/scripts/studio-adapter-macos.sh" preflight)"
[ "$BEFORE" = "$(snapshot)" ] || {
  printf 'preflight changed HOME.\n' >&2
  exit 1
}
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.schemaVersion !== 1 || value.operation !== "preflight") process.exit(1);
  if (!value.state || !Array.isArray(value.state.availableActions)) process.exit(1);
' "$PREFLIGHT_JSON"

BEFORE="$(snapshot)"
STATUS_JSON="$(/usr/bin/env HOME="$TEST_HOME" "$ROOT/scripts/studio-adapter-macos.sh" status)"
[ "$BEFORE" = "$(snapshot)" ] || {
  printf 'status changed HOME.\n' >&2
  exit 1
}
"$NODE" -e '
  const value = JSON.parse(process.argv[1]);
  if (value.schemaVersion !== 1 || value.operation !== "status") process.exit(1);
  if (!value.state || !Array.isArray(value.state.availableActions)) process.exit(1);
  if (/(port|pid|cdp|powershell|\/Users\/)/i.test(JSON.stringify(value))) process.exit(1);
' "$STATUS_JSON"

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
