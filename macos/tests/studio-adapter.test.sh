#!/bin/bash

set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
NODE="${NODE:-/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node}"
[ -x "$NODE" ] || { printf 'Codex bundled Node.js was not found: %s\n' "$NODE" >&2; exit 1; }

"$NODE" -e '
  const source = require("node:fs").readFileSync(process.argv[1], "utf8");
  if (!/mdfind '\''kMDItemCFBundleIdentifier == "com\.openai\.codex"'\''/.test(source)) {
    throw new Error("Studio status is missing the official Codex Spotlight fallback.");
  }
' "$SOURCE_ROOT/scripts/status-dream-skin-macos.sh"

TMP="$(/usr/bin/mktemp -d /tmp/codex-dream-skin-studio-adapter.XXXXXX)"
ROOT="$TMP/bundled-engine"
TEST_HOME="$TMP/home"
/bin/mkdir -p "$TEST_HOME" "$ROOT/bin"
/bin/cp -R "$SOURCE_ROOT/scripts" "$ROOT/scripts"
/bin/cp "$SOURCE_ROOT/VERSION" "$ROOT/VERSION"
/usr/bin/swift build --package-path "$SOURCE_ROOT/studio" --product dream-skin-config-restore >/dev/null
BUILT_NATIVE_HELPER="$(/usr/bin/swift build --package-path "$SOURCE_ROOT/studio" --show-bin-path)/dream-skin-config-restore"
/bin/cp "$BUILT_NATIVE_HELPER" "$ROOT/bin/dream-skin-config-restore"
/bin/chmod 755 "$ROOT/bin/dream-skin-config-restore"
RESPONDER_PID=""
cleanup() {
  [ -z "$RESPONDER_PID" ] || /bin/kill -TERM "$RESPONDER_PID" 2>/dev/null || true
  [ -z "$RESPONDER_PID" ] || wait "$RESPONDER_PID" 2>/dev/null || true
  /bin/rm -rf "$TMP"
}
trap cleanup EXIT

WATCHER_FIXTURE="$TMP/watcher-guard"
WATCHER_HOME="$WATCHER_FIXTURE/home"
WATCHER_MARKER="$WATCHER_FIXTURE/commands"
/bin/mkdir -p "$WATCHER_HOME/Library/Application Support/CodexDreamSkinStudio"
/bin/cp "$SOURCE_ROOT/VERSION" "$TMP/VERSION"
/usr/bin/sed \
  -e "s|/usr/bin/nohup|$WATCHER_FIXTURE/nohup|g" \
  -e "s|/bin/launchctl|$WATCHER_FIXTURE/launchctl|g" \
  -e "s|/bin/kill|$WATCHER_FIXTURE/kill|g" \
  -e "s|/bin/sleep|$WATCHER_FIXTURE/sleep|g" \
  "$SOURCE_ROOT/scripts/common-macos.sh" > "$WATCHER_FIXTURE/common-macos.sh"
/usr/bin/sed "s|__MARKER__|$WATCHER_MARKER|g" > "$WATCHER_FIXTURE/nohup" <<'STUB'
#!/bin/bash
printf 'nohup %s\n' "$*" >> "__MARKER__"
exit 1
STUB
/usr/bin/sed "s|__MARKER__|$WATCHER_MARKER|g" > "$WATCHER_FIXTURE/launchctl" <<'STUB'
#!/bin/bash
printf 'launchctl %s\n' "$*" >> "__MARKER__"
[ "${1:-}" = "print" ] && printf '  pid = 4242\n'
STUB
/usr/bin/sed > "$WATCHER_FIXTURE/kill" <<'STUB'
#!/bin/bash
[ "${1:-}" = "-0" ] && [ "${2:-}" = "4242" ]
STUB
/usr/bin/sed > "$WATCHER_FIXTURE/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB
/bin/chmod 755 "$WATCHER_FIXTURE/nohup" "$WATCHER_FIXTURE/launchctl" \
  "$WATCHER_FIXTURE/kill" "$WATCHER_FIXTURE/sleep"

run_watcher_fixture() (
  source "$WATCHER_FIXTURE/common-macos.sh"
  NODE=/usr/bin/false
  launch_injector_daemon 9341
)

: > "$WATCHER_MARKER"
set +e
HOME="$WATCHER_HOME" DREAM_SKIN_STUDIO_ADAPTER=true \
  run_watcher_fixture > "$WATCHER_FIXTURE/studio.out" 2>/dev/null
WATCHER_EXIT="$?"
set -e
[ "$WATCHER_EXIT" -ne 0 ] || { printf 'Studio watcher failure fell back to launchctl submit.\n' >&2; exit 1; }
/usr/bin/grep -q '^nohup ' "$WATCHER_MARKER"
! /usr/bin/grep -q '^launchctl submit ' "$WATCHER_MARKER"

: > "$WATCHER_MARKER"
WATCHER_PID="$(HOME="$WATCHER_HOME" run_watcher_fixture)"
[ "$WATCHER_PID" = "4242" ] || { printf 'Legacy watcher fallback did not return its launchctl PID.\n' >&2; exit 1; }
/usr/bin/grep -q '^launchctl submit ' "$WATCHER_MARKER"

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

assert_recovery() {
  "$NODE" -e '
    const actions = JSON.parse(process.argv[1]).error?.recoveryActions || [];
    if (!actions.includes(process.argv[2]) || (process.argv[3] && actions.includes(process.argv[3]))) process.exit(1);
  ' "$ADAPTER_JSON" "$1" "${2:-}"
}

VALID_NATIVE_HELPER="$TMP/valid-dream-skin-config-restore"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$VALID_NATIVE_HELPER"
for invalid_helper in missing symlink directory; do
  /bin/rm -rf "$ROOT/bin/dream-skin-config-restore"
  case "$invalid_helper" in
    missing) ;;
    symlink) /bin/ln -s "$VALID_NATIVE_HELPER" "$ROOT/bin/dream-skin-config-restore" ;;
    directory) /bin/mkdir "$ROOT/bin/dream-skin-config-restore" ;;
  esac
  for guarded_operation in preflight install; do
    BEFORE="$(snapshot)"
    run_adapter "$guarded_operation"
    assert_error RUNTIME_INVALID
    [ "$BEFORE" = "$(snapshot)" ] || {
      printf '%s with a %s native helper changed HOME.\n' "$guarded_operation" "$invalid_helper" >&2
      exit 1
    }
  done
done
/bin/rm -rf "$ROOT/bin/dream-skin-config-restore"
/bin/cp "$VALID_NATIVE_HELPER" "$ROOT/bin/dream-skin-config-restore"
/bin/chmod 755 "$ROOT/bin/dream-skin-config-restore"

INSTALLED_LAYOUT="$TMP/installed-layout"
/bin/mkdir -p "$INSTALLED_LAYOUT"
/usr/bin/rsync -a "$ROOT/" "$INSTALLED_LAYOUT/"
[ -f "$INSTALLED_LAYOUT/bin/dream-skin-config-restore" ]
[ ! -L "$INSTALLED_LAYOUT/bin/dream-skin-config-restore" ]
[ -x "$INSTALLED_LAYOUT/bin/dream-skin-config-restore" ]
/usr/bin/cmp -s "$ROOT/bin/dream-skin-config-restore" "$INSTALLED_LAYOUT/bin/dream-skin-config-restore"

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
/bin/mkdir -p "$INSTALL_ROOT/bin" "$INSTALL_ROOT/scripts" "$STATE_ROOT/theme"
/bin/cp "$ROOT/VERSION" "$INSTALL_ROOT/VERSION"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$INSTALL_ROOT/bin/"
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
/bin/mkdir -p "$FIXTURE_HOME" "$BUNDLED/bin" "$BUNDLED/scripts" "$INSTALLED/bin" "$INSTALLED/scripts"
/bin/cp "$ROOT/scripts/studio-adapter-macos.sh" "$BUNDLED/scripts/"
/bin/cp "$ROOT/VERSION" "$BUNDLED/VERSION"
/bin/cp "$ROOT/VERSION" "$INSTALLED/VERSION"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$BUNDLED/bin/"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$INSTALLED/bin/"

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

make_failure_stub() {
  local path="$1"
  local message="$2"
  /usr/bin/sed "s|__MESSAGE__|$message|g" > "$path" <<'STUB'
#!/bin/bash
printf '%s\n' '__MESSAGE__' >&2
exit 1
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

# Authorization flags are accepted request metadata, but pause and verify
# must never receive force-stop authority they cannot use.
write_status ready running active false true
: > "$MARKER"
run_fixture_adapter pause --restart-authorized --force-authorized
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'authorized pause failed.\n' >&2; exit 1; }
/usr/bin/grep -Fx 'pause-dream-skin-macos.sh ' "$MARKER" >/dev/null
! /usr/bin/grep -q -- '--force-stop-authorized' "$MARKER"

: > "$MARKER"
run_fixture_adapter verify --restart-authorized --force-authorized
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'authorized verify failed.\n' >&2; exit 1; }
/usr/bin/grep -Fx 'verify-dream-skin-macos.sh --reload' "$MARKER" >/dev/null
! /usr/bin/grep -q -- '--force-stop-authorized' "$MARKER"

# A process appearing after the read-only status snapshot must map the exact
# lifecycle message to normal authorization before force is ever offered.
write_status ready stopped official false null
make_failure_stub "$BUNDLED/scripts/install-dream-skin-macos.sh" \
  'Close Codex before installation so config.toml cannot be rewritten while the app is saving it.'
run_fixture_adapter install
assert_error CODEX_CLOSE_REQUIRED
assert_recovery authorize-restart authorize-force-stop
make_stub "$BUNDLED/scripts/install-dream-skin-macos.sh"

make_failure_stub "$INSTALLED/scripts/start-dream-skin-macos.sh" \
  'Codex is already running without the verified skin CDP endpoint. Close it first or pass --restart-existing.'
run_fixture_adapter apply
assert_error RESTART_REQUIRED
assert_recovery authorize-restart authorize-force-stop
make_stub "$INSTALLED/scripts/start-dream-skin-macos.sh"

make_failure_stub "$INSTALLED/scripts/restore-dream-skin-macos.sh" \
  'Explicit restart authorization is required before Studio can close Codex.'
run_fixture_adapter restore
assert_error RESTART_REQUIRED
assert_recovery authorize-restart authorize-force-stop

make_failure_stub "$INSTALLED/scripts/restore-dream-skin-macos.sh" \
  'Codex did not close within 15 seconds; explicit restart authorization is required for a forced stop.'
run_fixture_adapter restore --restart-authorized
assert_error FORCE_STOP_REQUIRED
assert_recovery authorize-force-stop
make_stub "$INSTALLED/scripts/restore-dream-skin-macos.sh"

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
printf 'Codex did not close within 15 seconds; explicit restart authorization is required for a forced stop.\n' >&2
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
/usr/bin/grep -Fx 'restore-dream-skin-macos.sh --restore-base-theme --restart-codex --restart-authorized' "$MARKER" >/dev/null
! /usr/bin/grep -q -- '--force-stop-authorized' "$MARKER"

: > "$MARKER"
run_fixture_adapter restore --restart-authorized --force-authorized
[ "$ADAPTER_EXIT" -eq 0 ] || { printf 'force-authorized restore failed.\n' >&2; exit 1; }
/usr/bin/grep -Fx 'restore-dream-skin-macos.sh --restore-base-theme --restart-codex --restart-authorized --force-stop-authorized' "$MARKER" >/dev/null

# Restore rechecks authorization after the adapter status snapshot. A Codex
# process appearing after that snapshot must not be stopped or permit mutation.
RESTORE_REAL="$TMP/restore-real"
RESTORE_REAL_HOME="$RESTORE_REAL/home"
RESTORE_REAL_MARKER="$RESTORE_REAL/marker"
/bin/mkdir -p "$RESTORE_REAL/scripts" "$RESTORE_REAL_HOME/.codex" "$RESTORE_REAL_HOME/state/theme"
/bin/cp "$ROOT/scripts/restore-dream-skin-macos.sh" "$RESTORE_REAL/scripts/"
/usr/bin/printf 'config sentinel\n' > "$RESTORE_REAL_HOME/.codex/config.toml"
/usr/bin/printf 'state sentinel\n' > "$RESTORE_REAL_HOME/state/state.json"
/usr/bin/printf 'backup sentinel\n' > "$RESTORE_REAL_HOME/state/theme-backup.json"
/usr/bin/sed "s|__HOME__|$RESTORE_REAL_HOME|g; s|__SCRIPTS__|$RESTORE_REAL/scripts|g; s|__MARKER__|$RESTORE_REAL_MARKER|g" > "$RESTORE_REAL/scripts/common-macos.sh" <<'STUB'
SCRIPT_DIR="__SCRIPTS__"
STATE_ROOT="__HOME__/state"
STATE_PATH="$STATE_ROOT/state.json"
THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.json"
THEME_DIR="$STATE_ROOT/theme"
CONFIG_PATH="__HOME__/.codex/config.toml"
INJECTOR="__HOME__/injector.mjs"
NODE=/usr/bin/true
fail() { printf 'fixture: %s\n' "$*" >&2; exit 1; }
discover_codex_app() { :; }
require_macos_runtime() { :; }
try_discover_codex_app() { :; }
try_require_macos_runtime() { :; }
try_validate_codex_app_identity() { CODEX_APP_VALIDATED=true; }
try_require_macos_node_runtime() { NODE=/usr/bin/true; NODE_RUNTIME_VALIDATED=true; }
ensure_state_root() { printf 'ensure\n' >> "__MARKER__"; }
state_field() { printf '9341\n'; }
codex_is_running() { return 0; }
verified_cdp_endpoint() { return 1; }
stop_codex() { printf 'stop:%s\n' "$1" >> "__MARKER__"; }
stop_recorded_injector() { printf 'injector\n' >> "__MARKER__"; }
release_codex_launchd_job() { printf 'release\n' >> "__MARKER__"; }
launch_codex_normally() { printf 'launch\n' >> "__MARKER__"; }
STUB
: > "$RESTORE_REAL_MARKER"
set +e
/usr/bin/env HOME="$RESTORE_REAL_HOME" DREAM_SKIN_STUDIO_ADAPTER=true \
  "$RESTORE_REAL/scripts/restore-dream-skin-macos.sh" --restore-base-theme --restart-codex >/dev/null 2>&1
RESTORE_REAL_EXIT="$?"
set -e
[ "$RESTORE_REAL_EXIT" -ne 0 ] || { printf 'Studio restore crossed the restart-authorization race.\n' >&2; exit 1; }
[ ! -s "$RESTORE_REAL_MARKER" ] || { printf 'unauthorized raced restore stopped or mutated state.\n' >&2; exit 1; }
[ "$(/bin/cat "$RESTORE_REAL_HOME/.codex/config.toml")" = 'config sentinel' ]
[ "$(/bin/cat "$RESTORE_REAL_HOME/state/state.json")" = 'state sentinel' ]

: > "$RESTORE_REAL_MARKER"
/usr/bin/env HOME="$RESTORE_REAL_HOME" DREAM_SKIN_STUDIO_ADAPTER=true \
  "$RESTORE_REAL/scripts/restore-dream-skin-macos.sh" --restore-base-theme --restart-codex --restart-authorized >/dev/null
/usr/bin/grep -Fx 'stop:false' "$RESTORE_REAL_MARKER" >/dev/null

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
[ "$(/usr/bin/head -n 1 "$MARKER")" = 'restore-dream-skin-macos.sh --restore-base-theme --restart-codex --uninstall --restart-authorized' ]

# Recreate the installed fixture after uninstall, then prove explicit theme deletion is last.
/bin/mkdir -p "$INSTALLED/bin" "$INSTALLED/scripts"
/bin/cp "$ROOT/VERSION" "$INSTALLED/VERSION"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$INSTALLED/bin/"
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
/bin/mkdir -p "$INSTALLED/bin" "$INSTALLED/scripts" "$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio/themes"
/bin/cp "$ROOT/VERSION" "$INSTALLED/VERSION"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$INSTALLED/bin/"
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

# Cleanup failures stay in the operation log and return one stable JSON line.
/bin/mkdir -p "$INSTALLED/bin" "$INSTALLED/scripts"
/bin/cp "$ROOT/VERSION" "$INSTALLED/VERSION"
/bin/cp "$ROOT/bin/dream-skin-config-restore" "$INSTALLED/bin/"
for script in start-dream-skin-macos.sh pause-dream-skin-macos.sh restore-dream-skin-macos.sh verify-dream-skin-macos.sh status-dream-skin-macos.sh common-macos.sh theme-config.mjs injector.mjs; do
  make_stub "$INSTALLED/scripts/$script"
done
write_status ready stopped official false false
/bin/chmod 500 "$FIXTURE_HOME/.codex"
CLEANUP_JSON="$TMP/cleanup-failure.json"
CLEANUP_STDERR="$TMP/cleanup-failure.stderr"
set +e
/usr/bin/env HOME="$FIXTURE_HOME" "$BUNDLED/scripts/studio-adapter-macos.sh" uninstall --restart-authorized \
  >"$CLEANUP_JSON" 2>"$CLEANUP_STDERR"
CLEANUP_EXIT="$?"
set -e
/bin/chmod 700 "$FIXTURE_HOME/.codex"
[ "$CLEANUP_EXIT" -eq 1 ] || { printf 'cleanup failure did not return a domain error.\n' >&2; exit 1; }
CLEANUP_VALUE="$(/bin/cat "$CLEANUP_JSON")"
assert_json_line "$CLEANUP_VALUE"
"$NODE" -e 'if (JSON.parse(process.argv[1]).error?.code !== "OPERATION_FAILED") process.exit(1)' "$CLEANUP_VALUE"
! /usr/bin/grep -Eqi 'permission denied|operation not permitted|rm:' "$CLEANUP_STDERR"

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
  const stopCodex = install.indexOf("stop_codex");
  const stopInjector = install.indexOf("stop_recorded_injector");
  if (deployCall === -1 || stopCodex === -1 || stopCodex > deployCall) throw new Error("install deploys before stopping Codex");
  if (stopInjector === -1 || stopInjector > deployCall) throw new Error("install deploys before validating the injector");
  for (const required of ["--force-stop-authorized", "--studio-strict-verify"]) {
    if (!start.includes(required)) throw new Error(`start missing ${required}`);
  }
  if (!/STUDIO_STRICT_VERIFY[\s\S]*installed.*true/.test(start)) throw new Error("strict verify does not guard soft success");
  if (!pause.includes("verified_cdp_endpoint") || !/fail .*live skin/.test(pause)) throw new Error("pause removal is not verified");
  if (!restore.includes("--restart-authorized")) throw new Error("restore missing restart authorization");
  if (!restore.includes("--force-stop-authorized")) throw new Error("restore missing force authorization");
' "$ROOT/scripts/install-dream-skin-macos.sh" "$ROOT/scripts/start-dream-skin-macos.sh" \
  "$ROOT/scripts/pause-dream-skin-macos.sh" "$ROOT/scripts/restore-dream-skin-macos.sh"

printf 'PASS: macOS Studio adapter lifecycle is authorized, ordered, and protocol-safe.\n'
