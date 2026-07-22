#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
NODE="${NODE:-/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node}"
CASE="${1:-all}"
TMP="$(/usr/bin/mktemp -d)"
FIXTURE_HOME="$TMP/home"
BUNDLED="$TMP/bundled"
INSTALLED="$FIXTURE_HOME/.codex/codex-dream-skin-studio"
STATE_ROOT="$FIXTURE_HOME/Library/Application Support/CodexDreamSkinStudio"
CODEX_BUNDLE="$FIXTURE_HOME/Applications/ChatGPT.bundle"
CODEX_EXE="$CODEX_BUNDLE/Contents/MacOS/ChatGPT"
STRICT_MARKER="$TMP/strict-verify"
LIFECYCLE_MARKER="$TMP/lifecycle.log"
PREFLIGHT_MARKER="$TMP/preflight.log"
CODEX_PID=""
WATCHER_PID=""

cleanup() {
  if [ -n "$WATCHER_PID" ]; then
    /bin/kill "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi
  if [ -n "$CODEX_PID" ]; then
    /bin/kill "$CODEX_PID" 2>/dev/null || true
    wait "$CODEX_PID" 2>/dev/null || true
  fi
  /bin/rm -rf "$TMP"
}
trap cleanup EXIT

case "$CASE" in
  all|resume|upgrade|preflight) ;;
  *) printf 'Unknown status-v4 case: %s\n' "$CASE" >&2; exit 2 ;;
esac

[ -x "$NODE" ] || { printf 'Node.js runtime was not found: %s\n' "$NODE" >&2; exit 1; }
/bin/mkdir -p "$BUNDLED/bin" "$BUNDLED/scripts" "$INSTALLED/bin" \
  "$INSTALLED/scripts" "$STATE_ROOT/theme" "$FIXTURE_HOME/.codex" \
  "$CODEX_BUNDLE/Contents/MacOS"
/bin/cp "$ROOT/VERSION" "$BUNDLED/VERSION"
/bin/cp "$ROOT/scripts/status-dream-skin-macos.sh" \
  "$ROOT/scripts/studio-adapter-macos.sh" "$BUNDLED/scripts/"
/usr/bin/sed > "$BUNDLED/bin/dream-skin-config-restore" <<'STUB'
#!/bin/bash
exit 0
STUB

/usr/bin/sed > "$TMP/status-node" <<STUB
#!/bin/bash
[ -e "$STRICT_MARKER" ]
STUB
/bin/chmod 755 "$TMP/status-node"

/usr/bin/sed \
  -e "s|__STATUS_NODE__|$TMP/status-node|g" \
  -e "s|__PREFLIGHT_MARKER__|$PREFLIGHT_MARKER|g" \
  > "$BUNDLED/scripts/common-macos.sh" <<'STUB'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
INSTALL_ROOT="$HOME/.codex/codex-dream-skin-studio"
STATE_ROOT="$HOME/Library/Application Support/CodexDreamSkinStudio"
STATE_PATH="$STATE_ROOT/state.json"
ROLLBACK_STATE_PATH="$STATE_ROOT/rollback.json"
THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.json"
RESTORED_THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.restored.json"
THEME_DIR="$STATE_ROOT/theme"
INJECTOR="$SCRIPT_DIR/injector.mjs"
EXPECTED_CODEX_TEAM_ID=2DC432GLL2
CODEX_APP_VALIDATED=false
CODEX_APP_CONTROL_VALIDATED=false
NODE_RUNTIME_VALIDATED=false

fail() { printf 'fixture: %s\n' "$*" >&2; return 1; }
lifecycle_lock_is_busy() { return 1; }
acquire_lifecycle_lock() { LIFECYCLE_LOCK_BORROWED=true; return 0; }
release_lifecycle_lock() { return 0; }
renderer_rollback_evidence_is_valid() { return 0; }
renderer_rollback_field() {
  /usr/bin/plutil -extract "$1" raw -o - "$ROLLBACK_STATE_PATH"
}
theme_backup_is_valid() { [ -f "$1" ] && [ ! -L "$1" ] && /usr/bin/grep -Fxq valid "$1"; }
live_theme_backup_is_valid() { theme_backup_is_valid "$THEME_BACKUP_PATH"; }
restored_theme_backup_is_valid() { theme_backup_is_valid "$RESTORED_THEME_BACKUP_PATH"; }

try_discover_codex_app() {
  printf 'discover:%s\n' "${PREFLIGHT_MODE:-valid}" >> "__PREFLIGHT_MARKER__"
  CODEX_BUNDLE="$CODEX_APP_BUNDLE"
  CODEX_EXE="$CODEX_BUNDLE/Contents/MacOS/ChatGPT"
  CODEX_VERSION=fixture
  [ "${PREFLIGHT_MODE:-valid}" != "missing-executable" ]
}

try_validate_codex_app_identity() {
  printf 'identity:%s\n' "${PREFLIGHT_MODE:-valid}" >> "__PREFLIGHT_MARKER__"
  case "${PREFLIGHT_MODE:-valid}" in
    bundle-signature|executable-signature|signer-team) return 1 ;;
  esac
  CODEX_APP_VALIDATED=true
  CODEX_TEAM_ID="$EXPECTED_CODEX_TEAM_ID"
}

try_validate_codex_app_control_identity() {
  [ "${PREFLIGHT_MODE:-valid}" = "valid" ] || return 1
  CODEX_APP_CONTROL_VALIDATED=true
}

try_require_macos_node_runtime() {
  printf 'runtime:%s\n' "${PREFLIGHT_MODE:-valid}" >> "__PREFLIGHT_MARKER__"
  [ "${PREFLIGHT_MODE:-valid}" != "runtime" ] || return 1
  NODE="__STATUS_NODE__"
  NODE_RUNTIME_VALIDATED=true
}

discover_codex_app() { try_discover_codex_app; }
require_macos_runtime() {
  try_validate_codex_app_identity \
    && try_require_macos_node_runtime
}
browser_id_is_valid() {
  [ -n "$1" ] && [ "${#1}" -le 200 ] || return 1
  case "$1" in *[!A-Za-z0-9._-]*) return 1 ;; esac
}
verified_cdp_browser_id() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "${ACTIVE_BROWSER_ID:-}" ] || return 1
  printf '%s\n' "$ACTIVE_BROWSER_ID"
}
STUB
/bin/chmod 755 "$BUNDLED/scripts/"*.sh "$BUNDLED/bin/dream-skin-config-restore"

/usr/bin/sed > "$TMP/ChatGPT.c" <<'STUB'
#include <signal.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;
static void stop_process(int value) { (void)value; running = 0; }
int main(void) {
  signal(SIGTERM, stop_process);
  signal(SIGINT, stop_process);
  while (running) pause();
  return 0;
}
STUB
/usr/bin/clang -Os "$TMP/ChatGPT.c" -o "$CODEX_EXE"
/usr/bin/plutil -create xml1 "$CODEX_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.openai.codex \
  "$CODEX_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string ChatGPT \
  "$CODEX_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string fixture \
  "$CODEX_BUNDLE/Contents/Info.plist"
/usr/bin/printf '[desktop]\n' > "$FIXTURE_HOME/.codex/config.toml"
"$CODEX_EXE" &
CODEX_PID="$!"
/bin/sleep 0.1
/bin/kill -0 "$CODEX_PID"

make_installed_engine() {
  /bin/mkdir -p "$INSTALLED/bin" "$INSTALLED/scripts"
  /bin/cp "$BUNDLED/bin/dream-skin-config-restore" "$INSTALLED/bin/"
  /bin/cp "$BUNDLED/scripts/status-dream-skin-macos.sh" \
    "$BUNDLED/scripts/common-macos.sh" "$INSTALLED/scripts/"
  /bin/cp "$ROOT/VERSION" "$INSTALLED/VERSION"
  for script in studio-adapter-macos.sh pause-dream-skin-macos.sh \
    restore-dream-skin-macos.sh verify-dream-skin-macos.sh; do
    : > "$INSTALLED/scripts/$script"
    /bin/chmod 755 "$INSTALLED/scripts/$script"
  done
  /usr/bin/sed \
    -e "s|__STRICT_MARKER__|$STRICT_MARKER|g" \
    -e "s|__LIFECYCLE_MARKER__|$LIFECYCLE_MARKER|g" \
    > "$INSTALLED/scripts/start-dream-skin-macos.sh" <<'STUB'
#!/bin/bash
printf 'start:%s\n' "$*" >> "__LIFECYCLE_MARKER__"
: > "__STRICT_MARKER__"
STUB
  : > "$INSTALLED/scripts/injector.mjs"
  : > "$INSTALLED/scripts/theme-config.mjs"
  /bin/chmod 755 "$INSTALLED/scripts/"*.sh \
    "$INSTALLED/bin/dream-skin-config-restore"
}

/usr/bin/sed "s|__LIFECYCLE_MARKER__|$LIFECYCLE_MARKER|g" \
  > "$BUNDLED/scripts/install-dream-skin-macos.sh" <<'STUB'
#!/bin/bash
printf 'install:%s\n' "$*" >> "__LIFECYCLE_MARKER__"
exit 0
STUB
/bin/chmod 755 "$BUNDLED/scripts/install-dream-skin-macos.sh"
: > "$BUNDLED/scripts/injector.mjs"
: > "$BUNDLED/scripts/theme-config.mjs"

make_installed_engine

reset_ready_state() {
  /bin/rm -f "$STRICT_MARKER" "$LIFECYCLE_MARKER" \
    "$STATE_ROOT/state.json" "$STATE_ROOT/rollback.json" \
    "$STATE_ROOT/theme-backup.restored.json"
  /usr/bin/printf 'valid\n' > "$STATE_ROOT/theme-backup.json"
  /usr/bin/printf '{"name":"Fixture"}\n' > "$STATE_ROOT/theme/theme.json"
  /bin/cp "$ROOT/VERSION" "$INSTALLED/VERSION"
  [ -x "$INSTALLED/scripts/verify-dream-skin-macos.sh" ] \
    || { : > "$INSTALLED/scripts/verify-dream-skin-macos.sh"; /bin/chmod 755 "$INSTALLED/scripts/verify-dream-skin-macos.sh"; }
}

run_status() {
  local operation="$1"
  local mode="${2:-valid}"
  local browser_id="${3:-}"
  set +e
  STATUS_JSON="$(/usr/bin/env HOME="$FIXTURE_HOME" CODEX_APP_BUNDLE="$CODEX_BUNDLE" \
    PREFLIGHT_MODE="$mode" ACTIVE_BROWSER_ID="$browser_id" \
    "$BUNDLED/scripts/status-dream-skin-macos.sh" \
    --studio-json --deep --operation "$operation" 2>"$TMP/status.stderr")"
  STATUS_EXIT="$?"
  set -e
}

assert_status() {
  "$NODE" -e "$1" "$STATUS_JSON"
}

snapshot_home() {
  /usr/bin/find "$FIXTURE_HOME" -print0 | /usr/bin/sort -z | while IFS= read -r -d '' path; do
    if [ -f "$path" ]; then
      /usr/bin/printf 'f %s ' "$path"
      /usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}'
    elif [ -d "$path" ]; then
      /usr/bin/printf 'd %s\n' "$path"
    else
      /usr/bin/printf 'o %s\n' "$path"
    fi
  done
}

test_resume() {
  reset_ready_state
  /usr/bin/printf '%s\n' \
    '{"port":19431,"session":"paused","injectorPid":0,"browserId":"Browser-A"}' \
    > "$STATE_ROOT/state.json"

  run_status status valid Browser-A
  [ "$STATUS_EXIT" -eq 0 ] || { printf 'matching paused status failed.\n' >&2; exit 1; }
  assert_status '
    const value = JSON.parse(process.argv[1]);
    if (value.state.session !== "paused" || value.state.requiresRestart !== false ||
        value.state.verified !== false) {
      throw new Error(`matching endpoint did not preserve the Resume hot path: ${process.argv[1]}`);
    }
  '

  run_status status valid Browser-B
  assert_status '
    const value = JSON.parse(process.argv[1]);
    if (value.state.requiresRestart !== true || value.state.verified !== null) {
      throw new Error(`mismatched endpoint did not require restart: ${process.argv[1]}`);
    }
  '
  run_status status valid ''
  assert_status '
    const value = JSON.parse(process.argv[1]);
    if (value.state.requiresRestart !== true || value.state.verified !== null) {
      throw new Error(`unavailable endpoint did not require restart: ${process.argv[1]}`);
    }
  '

  : > "$LIFECYCLE_MARKER"
  set +e
  ADAPTER_JSON="$(/usr/bin/env HOME="$FIXTURE_HOME" CODEX_APP_BUNDLE="$CODEX_BUNDLE" \
    PREFLIGHT_MODE=valid ACTIVE_BROWSER_ID=Browser-A \
    "$BUNDLED/scripts/studio-adapter-macos.sh" resume 2>"$TMP/resume.stderr")"
  ADAPTER_EXIT="$?"
  set -e
  [ "$ADAPTER_EXIT" -eq 0 ] || {
    printf 'unauthorized matching-endpoint Resume did not dispatch: %s\n' "$ADAPTER_JSON" >&2
    exit 1
  }
  /usr/bin/grep -Fxq 'start:--studio-strict-verify' "$LIFECYCLE_MARKER" || {
    printf 'Resume did not use the restart-free hot path.\n' >&2
    exit 1
  }

  "$NODE" -e '
    const fs = require("node:fs");
    fs.writeFileSync(process.argv[1], `${JSON.stringify({
      schemaVersion: 4,
      port: 19431,
      browserId: "Browser-A",
      injectorPid: 0,
      injectorStartedAt: "",
      nodePath: process.argv[2],
      injectorPath: process.argv[3],
      themeDir: process.argv[4],
      launcher: "managed-cdp",
      jobLabel: "com.openai.codex-dream-skin-studio.injector",
    })}\n`);
  ' "$STATE_ROOT/rollback.json" "$TMP/status-node" \
    "$INSTALLED/scripts/injector.mjs" "$STATE_ROOT/theme"
  run_status apply valid Browser-A
  [ "$STATUS_EXIT" -eq 1 ]
  assert_status '
    const value = JSON.parse(process.argv[1]);
    if (value.error?.code !== "STATE_UNSAFE" ||
        value.state.availableActions.join(",") !== "apply,resume,restore,uninstall" ||
        !value.error.recoveryActions.includes("authorize-force-stop")) {
      throw new Error(`managed-CDP recovery is not reachable in status: ${process.argv[1]}`);
    }
  '
  /bin/rm -f "$STATE_ROOT/rollback.json"
}

write_active_state() {
  local started_at="$1"
  local watcher_node="$2"
  "$NODE" -e '
    const fs = require("node:fs");
    const [path, pid, startedAt, node, injector, theme] = process.argv.slice(1);
    fs.writeFileSync(path, `${JSON.stringify({
      schemaVersion: 5,
      injectorProtocol: 3,
      port: 19432,
      session: "active",
      injectorPid: Number(pid),
      injectorStartedAt: startedAt,
      nodePath: node,
      injectorPath: injector,
      browserId: "Browser-A",
      themeDir: theme,
    })}\n`);
  ' "$STATE_ROOT/state.json" "$WATCHER_PID" "$started_at" "$watcher_node" \
    "$INSTALLED/scripts/injector.mjs" "$STATE_ROOT/theme"
}

test_upgrade() {
  reset_ready_state
  /usr/bin/printf '0.9.0\n' > "$INSTALLED/VERSION"
  /usr/bin/printf '%s\n' \
    '{"port":19431,"session":"paused","injectorPid":0,"browserId":"Browser-A"}' \
    > "$STATE_ROOT/state.json"
  run_status status valid Browser-A
  [ "$STATUS_EXIT" -eq 0 ] || { printf 'safe older paused status failed.\n' >&2; exit 1; }
  assert_status '
    const value = JSON.parse(process.argv[1]);
    if (value.state.install !== "not-installed" || value.state.session !== "paused" ||
        !value.state.availableActions.includes("install") ||
        value.state.availableActions.includes("resume")) {
      throw new Error(`safe older paused engine did not expose only upgrade/recovery: ${process.argv[1]}`);
    }
  '

  /bin/rm -f "$INSTALLED/scripts/verify-dream-skin-macos.sh"
  run_status status valid Browser-A
  assert_status '
    const value = JSON.parse(process.argv[1]);
    if (value.state.availableActions.includes("install") ||
        value.state.availableActions.join(",") !== "restore,uninstall") {
      throw new Error(`partial paused engine exposed Install: ${process.argv[1]}`);
    }
  '
  : > "$INSTALLED/scripts/verify-dream-skin-macos.sh"
  /bin/chmod 755 "$INSTALLED/scripts/verify-dream-skin-macos.sh"

  /usr/bin/printf 'setInterval(() => {}, 1000);\n' > "$INSTALLED/scripts/injector.mjs"
  "$NODE" "$INSTALLED/scripts/injector.mjs" --watch --port 19432 \
    --browser-id Browser-A --theme-dir "$STATE_ROOT/theme" &
  WATCHER_PID="$!"
  /bin/sleep 0.1
  /bin/kill -0 "$WATCHER_PID"
  watcher_node="$(/bin/ps -p "$WATCHER_PID" -o command= | /usr/bin/awk '{print $1}')"
  watcher_started="$(LC_ALL=C TZ=UTC /bin/ps -p "$WATCHER_PID" -o lstart= | /usr/bin/awk '{$1=$1; print}')"
  write_active_state "$watcher_started" "$watcher_node"
  run_status status valid Browser-A
  [ "$STATUS_EXIT" -eq 0 ] || { printf 'safe older active status failed.\n' >&2; exit 1; }
  assert_status '
    const value = JSON.parse(process.argv[1]);
    if (value.state.session !== "active" || !value.state.availableActions.includes("install")) {
      throw new Error(`safe older active engine was treated as stale: ${process.argv[1]}`);
    }
  '

  write_active_state 'forged start identity' "$watcher_node"
  run_status status valid Browser-A
  [ "$STATUS_EXIT" -eq 1 ] || { printf 'foreign watcher status did not fail closed.\n' >&2; exit 1; }
  assert_status '
    const value = JSON.parse(process.argv[1]);
    if (value.state.session !== "stale" || value.error?.code !== "STATE_UNSAFE" ||
        value.state.availableActions.includes("install")) {
      throw new Error(`foreign watcher bypassed the upgrade gate: ${process.argv[1]}`);
    }
  '
  : > "$LIFECYCLE_MARKER"
  set +e
  /usr/bin/env HOME="$FIXTURE_HOME" CODEX_APP_BUNDLE="$CODEX_BUNDLE" \
    PREFLIGHT_MODE=valid ACTIVE_BROWSER_ID=Browser-A \
    "$BUNDLED/scripts/studio-adapter-macos.sh" install --restart-authorized \
    > "$TMP/stale-install.json" 2> "$TMP/stale-install.stderr"
  stale_install_exit="$?"
  set -e
  [ "$stale_install_exit" -eq 1 ] || { printf 'foreign watcher Install did not fail.\n' >&2; exit 1; }
  [ ! -s "$LIFECYCLE_MARKER" ] || {
    printf 'foreign watcher Install dispatched the installer.\n' >&2
    exit 1
  }

  /bin/kill "$WATCHER_PID"
  wait "$WATCHER_PID" 2>/dev/null || true
  WATCHER_PID=""
  /bin/rm -f "$STATE_ROOT/state.json" "$STATE_ROOT/theme-backup.json"
  /usr/bin/printf 'valid\n' > "$STATE_ROOT/theme-backup.restored.json"
  run_status status valid ''
  assert_status '
    const value = JSON.parse(process.argv[1]);
    if (value.state.session !== "official" || !value.state.availableActions.includes("install")) {
      throw new Error(`safe older recovered engine hid Install: ${process.argv[1]}`);
    }
  '

  /bin/rm -f "$INSTALLED/scripts/verify-dream-skin-macos.sh"
  run_status status valid ''
  assert_status '
    const value = JSON.parse(process.argv[1]);
    if (value.state.availableActions.includes("install") ||
        value.state.availableActions.join(",") !== "restore,uninstall") {
      throw new Error(`partial recovered engine exposed Install: ${process.argv[1]}`);
    }
  '

}

test_preflight() {
  /bin/rm -rf "$INSTALLED"
  /bin/rm -f "$STATE_ROOT/state.json" "$STATE_ROOT/theme-backup.json" \
    "$STATE_ROOT/theme-backup.restored.json" "$STRICT_MARKER"
  run_status preflight valid ''
  [ "$STATUS_EXIT" -eq 0 ] || { printf 'valid deep preflight failed.\n' >&2; exit 1; }

  for mode in missing-executable bundle-signature executable-signature signer-team; do
    : > "$PREFLIGHT_MARKER"
    before="$(snapshot_home)"
    run_status preflight "$mode" ''
    [ "$STATUS_EXIT" -eq 1 ] || { printf '%s preflight did not fail.\n' "$mode" >&2; exit 1; }
    assert_status '
      const value = JSON.parse(process.argv[1]);
      if (value.error?.code !== "CODEX_IDENTITY_INVALID" || value.state.availableActions.length !== 0) {
        throw new Error(`identity failure was misclassified: ${process.argv[1]}`);
      }
    '
    [ "$before" = "$(snapshot_home)" ] || {
      printf '%s preflight changed HOME.\n' "$mode" >&2
      exit 1
    }
    /usr/bin/grep -Fq "discover:$mode" "$PREFLIGHT_MARKER"
    if [ "$mode" = "missing-executable" ]; then
      ! /usr/bin/grep -q '^identity:' "$PREFLIGHT_MARKER"
    else
      /usr/bin/grep -Fq "identity:$mode" "$PREFLIGHT_MARKER"
    fi
    ! /usr/bin/grep -q '^runtime:' "$PREFLIGHT_MARKER"
  done

  : > "$PREFLIGHT_MARKER"
  before="$(snapshot_home)"
  run_status preflight runtime ''
  [ "$STATUS_EXIT" -eq 1 ] || { printf 'invalid-runtime preflight did not fail.\n' >&2; exit 1; }
  assert_status '
    const value = JSON.parse(process.argv[1]);
    if (value.error?.code !== "RUNTIME_INVALID" || value.state.availableActions.length !== 0) {
      throw new Error(`runtime failure was misclassified: ${process.argv[1]}`);
    }
  '
  [ "$before" = "$(snapshot_home)" ] || { printf 'runtime preflight changed HOME.\n' >&2; exit 1; }
  /usr/bin/grep -Fq 'discover:runtime' "$PREFLIGHT_MARKER"
  /usr/bin/grep -Fq 'identity:runtime' "$PREFLIGHT_MARKER"
  /usr/bin/grep -Fq 'runtime:runtime' "$PREFLIGHT_MARKER"
}

case "$CASE" in
  resume) test_resume ;;
  upgrade) test_upgrade ;;
  preflight) test_preflight ;;
  all)
    test_resume
    test_upgrade
    test_preflight
    ;;
esac

printf 'PASS: macOS status separates endpoint, engine-version, and preflight readiness.\n'
