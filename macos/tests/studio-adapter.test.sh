#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
NODE="${NODE:-/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node}"
[ -x "$NODE" ] || { printf 'Codex bundled Node.js was not found: %s\n' "$NODE" >&2; exit 1; }

"$NODE" -e '
  const source = require("node:fs").readFileSync(process.argv[1], "utf8");
  if (!/mdfind '\''kMDItemCFBundleIdentifier == "com\.openai\.codex"'\''/.test(source)) {
    throw new Error("Studio status is missing the official Codex Spotlight fallback.");
  }
' "$ROOT/scripts/status-dream-skin-macos.sh"

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
  shift
  set +e
  ADAPTER_JSON="$(/usr/bin/env HOME="$TEST_HOME" "$ROOT/scripts/studio-adapter-macos.sh" "$operation" "$@")"
  ADAPTER_EXIT="$?"
  set -e
}

assert_json_line() {
  "$NODE" -e '
    const lines = process.argv[1].split("\n").filter(Boolean);
    if (lines.length !== 1) throw new Error(`expected one stdout line, got ${lines.length}`);
    JSON.parse(lines[0]);
  ' "$1"
}

assert_error() {
  local code="$1"
  [ "$ADAPTER_EXIT" -eq "${2:-1}" ] || { printf '%s exited %s.\n' "$code" "$ADAPTER_EXIT" >&2; exit 1; }
  assert_json_line "$ADAPTER_JSON"
  "$NODE" -e 'if (JSON.parse(process.argv[1]).error?.code !== process.argv[2]) process.exit(1)' "$ADAPTER_JSON" "$code"
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

FIXTURE="$TMP/lifecycle"
FIXTURE_HOME="$FIXTURE/home"
BUNDLED="$FIXTURE/bundled"
INSTALLED="$FIXTURE_HOME/.codex/codex-dream-skin-studio"
MARKER="$FIXTURE/marker"
STATUS_FIXTURE="$FIXTURE/status.json"
/bin/mkdir -p "$FIXTURE_HOME" "$BUNDLED/scripts" "$INSTALLED/scripts"
/bin/cp "$ROOT/scripts/studio-adapter-macos.sh" "$BUNDLED/scripts/"
/bin/cp "$ROOT/VERSION" "$BUNDLED/VERSION"
/bin/cp "$ROOT/VERSION" "$INSTALLED/VERSION"

write_status() {
  /usr/bin/printf '{"schemaVersion":1,"ok":true,"operation":"status","state":{"install":"%s","codex":"%s","session":"%s","operation":"idle","themeName":"Fixture","requiresRestart":%s,"availableActions":["apply","pause","resume","restore","verify","uninstall"],"verified":%s},"error":null}\n' \
    "$1" "$2" "$3" "$4" "$5" > "$STATUS_FIXTURE"
}

make_stub() {
  local path="$1"
  /usr/bin/sed "s|__MARKER__|$MARKER|g; s|__STATUS__|$STATUS_FIXTURE|g" > "$path" <<'STUB'
#!/bin/bash
set -euo pipefail
name="$(/usr/bin/basename "$0")"
if [ "$name" = "status-dream-skin-macos.sh" ]; then
  /bin/cat "__STATUS__"
else
  /usr/bin/printf '%s %s\n' "$name" "$*" >> "__MARKER__"
  if [ "$name" = "start-dream-skin-macos.sh" ]; then
    /usr/bin/sed \
      -e 's/"session":"official"/"session":"active"/' \
      -e 's/"session":"paused"/"session":"active"/' \
      -e 's/"requiresRestart":true/"requiresRestart":false/' \
      -e 's/"verified":null/"verified":true/' \
      -e 's/"verified":false/"verified":true/' \
      "__STATUS__" > "__STATUS__.next"
    /bin/mv "__STATUS__.next" "__STATUS__"
  fi
fi
STUB
  /bin/chmod 755 "$path"
}

for root in "$BUNDLED" "$INSTALLED"; do
  for script in install-dream-skin-macos.sh start-dream-skin-macos.sh pause-dream-skin-macos.sh restore-dream-skin-macos.sh verify-dream-skin-macos.sh status-dream-skin-macos.sh common-macos.sh theme-config.mjs injector.mjs; do
    make_stub "$root/scripts/$script"
  done
done

run_fixture_adapter() {
  TEST_HOME="$FIXTURE_HOME"
  set +e
  ADAPTER_JSON="$(/usr/bin/env HOME="$TEST_HOME" "$BUNDLED/scripts/studio-adapter-macos.sh" "$@")"
  ADAPTER_EXIT="$?"
  set -e
}

write_status ready running official true null
: > "$MARKER"
run_fixture_adapter apply
assert_error RESTART_REQUIRED
[ ! -s "$MARKER" ] || { printf 'unauthorized apply invoked a script.\n' >&2; exit 1; }

: > "$MARKER"
run_fixture_adapter apply --restart-authorized
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'authorized apply failed.\n' >&2; exit 1; }
assert_json_line "$ADAPTER_JSON"
/usr/bin/grep -Fx 'start-dream-skin-macos.sh --studio-strict-verify --restart-existing' "$MARKER" >/dev/null
! /usr/bin/grep -q -- '--force-stop-authorized' "$MARKER"

: > "$MARKER"
write_status ready running official true null
run_fixture_adapter apply --restart-authorized --force-authorized
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'force-authorized apply failed.\n' >&2; exit 1; }
/usr/bin/grep -Fx 'start-dream-skin-macos.sh --studio-strict-verify --restart-existing --force-stop-authorized' "$MARKER" >/dev/null

: > "$MARKER"
run_fixture_adapter apply --force-authorized
assert_error INVALID_REQUEST 2
[ ! -s "$MARKER" ] || { printf 'invalid force authorization invoked a script.\n' >&2; exit 1; }

: > "$MARKER"
run_fixture_adapter pause --delete-user-themes
assert_error INVALID_REQUEST 2
[ ! -s "$MARKER" ] || { printf 'invalid theme deletion invoked a script.\n' >&2; exit 1; }

write_status ready running official true null
: > "$MARKER"
run_fixture_adapter install
assert_error CODEX_CLOSE_REQUIRED
[ ! -s "$MARKER" ] || { printf 'unauthorized install invoked a script.\n' >&2; exit 1; }

: > "$MARKER"
run_fixture_adapter install --restart-authorized
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'authorized install failed.\n' >&2; exit 1; }
/usr/bin/grep -Fx 'install-dream-skin-macos.sh --no-launchers --no-launch --close-running' "$MARKER" >/dev/null

# A stale managed-process identity must fail without replacing the installed engine.
ENGINE_BEFORE="$(/usr/bin/shasum -a 256 "$INSTALLED/VERSION" | /usr/bin/awk '{print $1}')"
/usr/bin/sed "s|__MARKER__|$MARKER|g" > "$BUNDLED/scripts/install-dream-skin-macos.sh" <<'STUB'
#!/bin/bash
/usr/bin/printf 'Recorded injector identity does not match.\n' >&2
exit 1
STUB
/bin/chmod 755 "$BUNDLED/scripts/install-dream-skin-macos.sh"
: > "$MARKER"
run_fixture_adapter install --restart-authorized
assert_error STATE_UNSAFE
[ "$ENGINE_BEFORE" = "$(/usr/bin/shasum -a 256 "$INSTALLED/VERSION" | /usr/bin/awk '{print $1}')" ] \
  || { printf 'unsafe install changed the installed engine.\n' >&2; exit 1; }
make_stub "$BUNDLED/scripts/install-dream-skin-macos.sh"

# Normal-quit timeout must surface force authorization before protected state changes.
/bin/mkdir -p "$FIXTURE_HOME/.codex" "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio"
/usr/bin/printf 'config sentinel\n' > "$FIXTURE_HOME/.codex/config.toml"
/usr/bin/printf 'state sentinel\n' > "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/state.json"
/usr/bin/printf 'backup sentinel\n' > "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/theme-backup.json"
PROTECTED_BEFORE="$(/usr/bin/shasum -a 256 \
  "$FIXTURE_HOME/.codex/config.toml" \
  "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/state.json" \
  "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/theme-backup.json")"
/usr/bin/sed > "$INSTALLED/scripts/restore-dream-skin-macos.sh" <<'STUB'
#!/bin/bash
printf 'Codex did not close; explicit restart authorization is required for a forced stop.\n' >&2
exit 1
STUB
/bin/chmod 755 "$INSTALLED/scripts/restore-dream-skin-macos.sh"
: > "$MARKER"
run_fixture_adapter restore --restart-authorized
assert_error FORCE_STOP_REQUIRED
[ "$PROTECTED_BEFORE" = "$(/usr/bin/shasum -a 256 \
  "$FIXTURE_HOME/.codex/config.toml" \
  "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/state.json" \
  "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/theme-backup.json")" ] \
  || { printf 'normal-quit timeout changed protected state.\n' >&2; exit 1; }
make_stub "$INSTALLED/scripts/restore-dream-skin-macos.sh"

: > "$MARKER"
run_fixture_adapter restore --restart-authorized
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'authorized restore failed.\n' >&2; exit 1; }
/usr/bin/grep -Fx 'restore-dream-skin-macos.sh --restore-base-theme --restart-codex' "$MARKER" >/dev/null
! /usr/bin/grep -q -- '--force-stop-authorized' "$MARKER"

: > "$MARKER"
run_fixture_adapter restore --restart-authorized --force-authorized
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'force-authorized restore failed.\n' >&2; exit 1; }
/usr/bin/grep -Fx 'restore-dream-skin-macos.sh --restore-base-theme --restart-codex --force-stop-authorized' "$MARKER" >/dev/null

write_status ready stopped paused false false
: > "$MARKER"
run_fixture_adapter resume
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'resume failed.\n' >&2; exit 1; }
/usr/bin/grep -Fx 'start-dream-skin-macos.sh --studio-strict-verify' "$MARKER" >/dev/null
[ "$(/usr/bin/head -n 1 "$MARKER")" = 'start-dream-skin-macos.sh --studio-strict-verify' ] \
  || { printf 'resume did not use the installed engine.\n' >&2; exit 1; }

/bin/mkdir -p "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/themes" \
  "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/images" \
  "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/theme"
: > "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/themes/saved"
: > "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/images/saved"
: > "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/theme/active"
write_status ready stopped official false false
: > "$MARKER"
run_fixture_adapter uninstall --restart-authorized
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'default uninstall failed.\n' >&2; exit 1; }
[ -e "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/themes/saved" ]
[ -e "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/images/saved" ]
[ -e "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/theme/active" ]
[ "$(/usr/bin/head -n 1 "$MARKER")" = 'restore-dream-skin-macos.sh --restore-base-theme --restart-codex --uninstall' ]

# Recreate the installed fixture after uninstall, then prove explicit theme deletion is last.
/bin/mkdir -p "$INSTALLED/scripts"
/bin/cp "$ROOT/VERSION" "$INSTALLED/VERSION"
for script in start-dream-skin-macos.sh pause-dream-skin-macos.sh restore-dream-skin-macos.sh verify-dream-skin-macos.sh status-dream-skin-macos.sh common-macos.sh theme-config.mjs injector.mjs; do
  make_stub "$INSTALLED/scripts/$script"
done
: > "$MARKER"
run_fixture_adapter uninstall --restart-authorized --delete-user-themes
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'theme-deleting uninstall failed.\n' >&2; exit 1; }
[ ! -e "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/themes" ]
[ ! -e "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/images" ]
[ ! -e "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/theme" ]

# A failed restore must leave both the installed engine and saved themes untouched.
/bin/mkdir -p "$INSTALLED/scripts" "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/themes"
/bin/cp "$ROOT/VERSION" "$INSTALLED/VERSION"
for script in start-dream-skin-macos.sh pause-dream-skin-macos.sh verify-dream-skin-macos.sh status-dream-skin-macos.sh common-macos.sh theme-config.mjs injector.mjs; do
  make_stub "$INSTALLED/scripts/$script"
done
/usr/bin/sed "s|__MARKER__|$MARKER|g" > "$INSTALLED/scripts/restore-dream-skin-macos.sh" <<'STUB'
#!/bin/bash
/usr/bin/printf 'restore-dream-skin-macos.sh %s\n' "$*" >> "__MARKER__"
exit 1
STUB
/bin/chmod 755 "$INSTALLED/scripts/restore-dream-skin-macos.sh"
: > "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/themes/saved"
: > "$MARKER"
run_fixture_adapter uninstall --restart-authorized --delete-user-themes
assert_error OPERATION_FAILED
[ -d "$INSTALLED" ] || { printf 'failed restore deleted the engine.\n' >&2; exit 1; }
[ -e "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/themes/saved" ] \
  || { printf 'failed restore deleted saved themes.\n' >&2; exit 1; }

# Lifecycle scripts must expose the explicit flags and keep mutations behind safe stops.
"$NODE" -e '
  const fs = require("node:fs");
  const install = fs.readFileSync(process.argv[1], "utf8");
  const start = fs.readFileSync(process.argv[2], "utf8");
  const pause = fs.readFileSync(process.argv[3], "utf8");
  const restore = fs.readFileSync(process.argv[4], "utf8");
  for (const required of ["--close-running", "--force-stop-authorized"]) {
    if (!install.includes(required)) throw new Error(`install missing ${required}`);
  }
  const deployCall = install.indexOf("\n  deploy_project\n");
  if (install.indexOf("stop_codex") > deployCall) throw new Error("install deploys before stopping Codex");
  if (install.indexOf("stop_recorded_injector") > deployCall) throw new Error("install deploys before validating the injector");
  for (const required of ["--force-stop-authorized", "--studio-strict-verify"]) {
    if (!start.includes(required)) throw new Error(`start missing ${required}`);
  }
  if (!/STUDIO_STRICT_VERIFY[\s\S]*installed.*true/.test(start)) throw new Error("strict verify does not guard soft success");
  if (!pause.includes("verified_cdp_endpoint") || !/fail .*live skin/.test(pause)) throw new Error("pause removal is not verified");
  if (!restore.includes("--force-stop-authorized")) throw new Error("restore missing force authorization");
' "$ROOT/scripts/install-dream-skin-macos.sh" "$ROOT/scripts/start-dream-skin-macos.sh" \
  "$ROOT/scripts/pause-dream-skin-macos.sh" "$ROOT/scripts/restore-dream-skin-macos.sh"

printf 'PASS: macOS Studio adapter lifecycle is authorized, ordered, and protocol-safe.\n'
