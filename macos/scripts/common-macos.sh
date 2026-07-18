#!/bin/bash

set -euo pipefail

if [ "$(/usr/bin/id -u)" -eq 0 ] || [ -n "${SUDO_USER:-}" ]; then
  printf 'Codex Dream Skin Studio: Do not run with sudo; run as your normal macOS user.\n' >&2
  exit 1
fi

if [ -z "${HOME:-}" ]; then
  CURRENT_USER="$(/usr/bin/id -un)"
  HOME="$(/usr/bin/dscl . -read "/Users/$CURRENT_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"
  [ -n "$HOME" ] || { printf 'Codex Dream Skin Studio: could not resolve the current macOS home directory.\n' >&2; exit 1; }
  export HOME
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
INJECTOR="$SCRIPT_DIR/injector.mjs"
INSTALL_ROOT="$HOME/.codex/codex-dream-skin-studio"
STATE_ROOT="$HOME/Library/Application Support/CodexDreamSkinStudio"
STATE_PATH="$STATE_ROOT/state.json"
THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.json"
THEME_DIR="$STATE_ROOT/theme"
CONFIG_PATH="$HOME/.codex/config.toml"
INJECTOR_LOG="$STATE_ROOT/injector.log"
INJECTOR_ERROR_LOG="$STATE_ROOT/injector-error.log"
APP_LOG="$STATE_ROOT/codex-launch.log"
APP_ERROR_LOG="$STATE_ROOT/codex-launch-error.log"
START_ERROR_LOG="$STATE_ROOT/start-error.log"
CODEX_APP_JOB_LABEL="com.openai.codex-dream-skin-studio.app"
INJECTOR_JOB_LABEL="com.openai.codex-dream-skin-studio.injector"
EXPECTED_CODEX_TEAM_ID="${CODEX_EXPECTED_TEAM_ID:-2DC432GLL2}"
SKIN_VERSION="1.2.0"
CODEX_APP_VALIDATED="false"
CODEX_APP_CONTROL_VALIDATED="false"
NODE_RUNTIME_VALIDATED="false"

fail() {
  local message="$*"
  if [ -n "${START_ERROR_LOG:-}" ] && [ -n "${STATE_ROOT:-}" ]; then
    /bin/mkdir -p "$STATE_ROOT" 2>/dev/null || true
    printf '%s %s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$message" >> "$START_ERROR_LOG" 2>/dev/null || true
  fi
  printf 'Codex Dream Skin Studio: %s\n' "$message" >&2
  exit 1
}

notify_user() {
  local message="$*"
  /usr/bin/osascript - "$message" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display notification (item 1 of argv) with title "Codex Dream Skin"
end run
APPLESCRIPT
}

alert_user() {
  local message="$*"
  /usr/bin/osascript - "$message" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display alert "Codex Dream Skin" message (item 1 of argv)
end run
APPLESCRIPT
}

ensure_state_root() {
  /bin/mkdir -p "$STATE_ROOT"
  /bin/chmod 700 "$STATE_ROOT"
}

# Seed bundled preset packs into the user's themes/ library so a fresh install
# ships with ready-to-use skins. Idempotent (each preset is refreshed in place)
# and scoped to preset-* ids, so user-made custom-* packs are never touched.
seed_bundled_presets() {
  local presets_root="$PROJECT_ROOT/presets"
  [ -d "$presets_root" ] || return 0
  local themes_root="$STATE_ROOT/themes"
  /bin/mkdir -p "$themes_root"
  local src id dest entry
  for src in "$presets_root"/preset-*/; do
    [ -d "$src" ] || continue
    [ -f "${src}theme.json" ] || continue
    id="$(/usr/bin/basename "$src")"
    dest="$themes_root/$id"
    /bin/rm -rf "$dest"
    /bin/mkdir -p "$dest"
    /bin/chmod 700 "$dest"
    for entry in "$src"*; do
      [ -f "$entry" ] || continue
      /bin/cp "$entry" "$dest/"
    done
    /bin/chmod 600 "$dest"/* 2>/dev/null || true
  done
}

runtime_discovery_error() {
  if [ "${RUNTIME_DISCOVERY_FATAL:-false}" = "true" ]; then
    fail "$*"
  fi
  printf 'Codex Dream Skin Studio: %s\n' "$*" >&2
  return 1
}

try_discover_codex_app() {
  local candidate=""
  local identifier=""
  local executable_name=""
  local configured="${CODEX_APP_BUNDLE:-}"

  unset CODEX_BUNDLE CODEX_EXE CODEX_VERSION CODEX_TEAM_ID
  unset NODE RUNTIME_NODE NODE_VERSION NODE_TEAM_ID
  CODEX_APP_VALIDATED="false"
  CODEX_APP_CONTROL_VALIDATED="false"
  NODE_RUNTIME_VALIDATED="false"

  for candidate in "$configured" \
    "/Applications/ChatGPT.app" "$HOME/Applications/ChatGPT.app" \
    "/Applications/Codex.app" "$HOME/Applications/Codex.app"; do
    [ -n "$candidate" ] || continue
    [ -f "$candidate/Contents/Info.plist" ] || continue
    identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$candidate/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$identifier" = "com.openai.codex" ]; then
      CODEX_BUNDLE="$candidate"
      break
    fi
  done

  if [ -z "${CODEX_BUNDLE:-}" ]; then
    candidate="$(/usr/bin/mdfind 'kMDItemCFBundleIdentifier == "com.openai.codex"' | /usr/bin/head -n 1)"
    if [ -n "$candidate" ] && [ -f "$candidate/Contents/Info.plist" ]; then
      identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$candidate/Contents/Info.plist" 2>/dev/null || true)"
      [ "$identifier" = "com.openai.codex" ] && CODEX_BUNDLE="$candidate"
    fi
  fi

  if [ -z "${CODEX_BUNDLE:-}" ]; then
    runtime_discovery_error "Could not find the official Codex app bundle (com.openai.codex)."
    return 1
  fi
  if ! executable_name="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$CODEX_BUNDLE/Contents/Info.plist" 2>/dev/null)"; then
    runtime_discovery_error "Could not read the official Codex app executable name."
    return 1
  fi
  CODEX_EXE="$CODEX_BUNDLE/Contents/MacOS/$executable_name"
  if ! CODEX_VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$CODEX_BUNDLE/Contents/Info.plist" 2>/dev/null)"; then
    runtime_discovery_error "Could not read the official Codex app version."
    return 1
  fi
  if [ ! -x "$CODEX_EXE" ]; then
    runtime_discovery_error "Codex executable is missing: $CODEX_EXE"
    return 1
  fi
  export CODEX_BUNDLE CODEX_EXE CODEX_VERSION
}

discover_codex_app() {
  local RUNTIME_DISCOVERY_FATAL="true"
  try_discover_codex_app
}

codesign_team_id() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 \
    | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}'
}

codesign_identifier() {
  /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 \
    | /usr/bin/awk -F= '/^Identifier=/{print $2; exit}'
}

try_validate_codex_app_identity() {
  local bundle_identifier=""
  local executable_identifier=""
  local executable_team_id=""
  CODEX_APP_VALIDATED="false"
  CODEX_APP_CONTROL_VALIDATED="false"
  NODE_RUNTIME_VALIDATED="false"
  if [ "$(/usr/bin/uname -s)" != "Darwin" ]; then
    runtime_discovery_error "This launcher requires macOS."
    return 1
  fi
  if [ -z "${CODEX_BUNDLE:-}" ]; then
    runtime_discovery_error "Discover the Codex app before validating its identity."
    return 1
  fi
  if [ -z "${CODEX_EXE:-}" ] || [ ! -f "$CODEX_EXE" ] || [ -L "$CODEX_EXE" ] || [ ! -x "$CODEX_EXE" ]; then
    runtime_discovery_error "The official Codex executable is not a trusted regular file: ${CODEX_EXE:-missing}"
    return 1
  fi
  bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$CODEX_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$bundle_identifier" != "com.openai.codex" ]; then
    runtime_discovery_error "Unexpected Codex bundle identifier: ${bundle_identifier:-missing}."
    return 1
  fi
  if ! /usr/bin/codesign --verify --deep --strict "$CODEX_BUNDLE" >/dev/null 2>&1; then
    runtime_discovery_error "The Codex app signature is not valid. Restore or reinstall the official app before continuing."
    return 1
  fi
  if [ "$(codesign_identifier "$CODEX_BUNDLE")" != "com.openai.codex" ]; then
    runtime_discovery_error "Unexpected Codex bundle signing identifier."
    return 1
  fi
  CODEX_TEAM_ID="$(codesign_team_id "$CODEX_BUNDLE")"
  if [ "$CODEX_TEAM_ID" != "$EXPECTED_CODEX_TEAM_ID" ]; then
    runtime_discovery_error "Unexpected Codex signing team: ${CODEX_TEAM_ID:-missing}."
    return 1
  fi
  if ! /usr/bin/codesign --verify --strict "$CODEX_EXE" >/dev/null 2>&1; then
    runtime_discovery_error "The Codex executable signature is not valid."
    return 1
  fi
  executable_identifier="$(codesign_identifier "$CODEX_EXE")"
  if [ "$executable_identifier" != "com.openai.codex" ]; then
    runtime_discovery_error "Unexpected Codex executable signing identifier: ${executable_identifier:-missing}."
    return 1
  fi
  executable_team_id="$(codesign_team_id "$CODEX_EXE")"
  if [ "$executable_team_id" != "$CODEX_TEAM_ID" ]; then
    runtime_discovery_error "The Codex executable signer does not match the app signer."
    return 1
  fi

  CODEX_APP_VALIDATED="true"
  export CODEX_APP_VALIDATED CODEX_TEAM_ID
}

try_validate_codex_app_control_identity() {
  local bundle_identifier=""
  local executable_identifier=""
  local executable_name=""
  local executable_team_id=""
  CODEX_APP_VALIDATED="false"
  CODEX_APP_CONTROL_VALIDATED="false"
  NODE_RUNTIME_VALIDATED="false"
  unset NODE RUNTIME_NODE NODE_VERSION NODE_TEAM_ID CODEX_TEAM_ID
  if [ "$(/usr/bin/uname -s)" != "Darwin" ]; then
    runtime_discovery_error "This launcher requires macOS."
    return 1
  fi
  if [ -z "${CODEX_BUNDLE:-}" ]; then
    runtime_discovery_error "Discover the Codex app before validating its control identity."
    return 1
  fi
  bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$CODEX_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  executable_name="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$CODEX_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$bundle_identifier" != "com.openai.codex" ]; then
    runtime_discovery_error "Unexpected Codex bundle identifier: ${bundle_identifier:-missing}."
    return 1
  fi
  if [ -z "$executable_name" ] || [ "${CODEX_EXE:-}" != "$CODEX_BUNDLE/Contents/MacOS/$executable_name" ]; then
    runtime_discovery_error "The Codex executable does not match the app bundle identity."
    return 1
  fi
  if [ ! -f "$CODEX_EXE" ] || [ -L "$CODEX_EXE" ] || [ ! -x "$CODEX_EXE" ]; then
    runtime_discovery_error "The official Codex executable is not a trusted regular file: $CODEX_EXE"
    return 1
  fi
  if ! /usr/bin/codesign --verify --strict "$CODEX_EXE" >/dev/null 2>&1; then
    runtime_discovery_error "The Codex executable signature is not valid."
    return 1
  fi
  executable_identifier="$(codesign_identifier "$CODEX_EXE")"
  if [ "$executable_identifier" != "com.openai.codex" ]; then
    runtime_discovery_error "Unexpected Codex executable signing identifier: ${executable_identifier:-missing}."
    return 1
  fi
  executable_team_id="$(codesign_team_id "$CODEX_EXE")"
  if [ "$executable_team_id" != "$EXPECTED_CODEX_TEAM_ID" ]; then
    runtime_discovery_error "Unexpected Codex executable signing team: ${executable_team_id:-missing}."
    return 1
  fi

  CODEX_APP_CONTROL_VALIDATED="true"
  export CODEX_APP_CONTROL_VALIDATED
}

try_require_macos_node_runtime() {
  unset NODE RUNTIME_NODE NODE_VERSION NODE_TEAM_ID
  NODE_RUNTIME_VALIDATED="false"
  if [ "${CODEX_APP_VALIDATED:-false}" != "true" ] || [ -z "${CODEX_TEAM_ID:-}" ]; then
    runtime_discovery_error "Validate the official Codex app before validating its Node.js runtime."
    return 1
  fi

  RUNTIME_NODE="$CODEX_BUNDLE/Contents/Resources/cua_node/bin/node"
  if [ ! -f "$RUNTIME_NODE" ] || [ -L "$RUNTIME_NODE" ] || [ ! -x "$RUNTIME_NODE" ]; then
    runtime_discovery_error "The signed Node.js runtime bundled with Codex was not found: $RUNTIME_NODE"
    return 1
  fi
  if ! /usr/bin/codesign --verify --strict "$RUNTIME_NODE" >/dev/null 2>&1; then
    runtime_discovery_error "The Node.js runtime bundled with Codex failed code-signature validation."
    return 1
  fi

  NODE_TEAM_ID="$(codesign_team_id "$RUNTIME_NODE")"
  if [ "$NODE_TEAM_ID" != "$CODEX_TEAM_ID" ]; then
    runtime_discovery_error "The bundled Node.js signer does not match the Codex app signer."
    return 1
  fi

  local machine_arch
  local node_major
  machine_arch="$(/usr/bin/uname -m)"
  if ! /usr/bin/file "$RUNTIME_NODE" | /usr/bin/grep -q "$machine_arch"; then
    runtime_discovery_error "The Codex Node.js runtime does not match this Mac architecture ($machine_arch)."
    return 1
  fi
  if ! NODE_VERSION="$($RUNTIME_NODE --version 2>/dev/null)"; then
    runtime_discovery_error "Could not execute the Codex bundled Node.js runtime."
    return 1
  fi
  node_major="${NODE_VERSION#v}"
  node_major="${node_major%%.*}"
  case "$node_major" in
    ''|*[!0-9]*)
      runtime_discovery_error "Could not parse bundled Node.js version: $NODE_VERSION"
      return 1
      ;;
  esac
  if [ "$node_major" -lt 20 ]; then
    runtime_discovery_error "Codex bundled Node.js $NODE_VERSION is too old; version 20 or newer is required."
    return 1
  fi

  NODE="$RUNTIME_NODE"
  NODE_RUNTIME_VALIDATED="true"
  export NODE RUNTIME_NODE NODE_VERSION CODEX_TEAM_ID NODE_TEAM_ID NODE_RUNTIME_VALIDATED
}

try_require_macos_runtime() {
  try_validate_codex_app_identity || return 1
  try_require_macos_node_runtime
}

require_macos_runtime() {
  local RUNTIME_DISCOVERY_FATAL="true"
  try_require_macos_runtime
}

native_restore_helper_identity() {
  local root="$1"
  local helper="$2"
  local root_real=""
  local bin_real=""
  [ "$helper" = "$root/bin/dream-skin-config-restore" ] || return 1
  [ -d "$root" ] && [ -d "$root/bin" ] && [ ! -L "$root/bin" ] || return 1
  [ -f "$helper" ] && [ ! -L "$helper" ] && [ -x "$helper" ] || return 1
  root_real="$(cd "$root" && pwd -P)" || return 1
  bin_real="$(cd "$root/bin" && pwd -P)" || return 1
  [ "$bin_real" = "$root_real/bin" ] || return 1
  /usr/bin/stat -f '%d:%i' "$helper"
}

codex_main_pids() {
  local pid
  local command_line
  while read -r pid command_line; do
    [ -n "$pid" ] || continue
    case "$command_line" in
      "$CODEX_EXE"*) printf '%s\n' "$pid" ;;
    esac
  done < <(/bin/ps -axo pid=,command=)
}

codex_is_running() {
  [ -n "$(codex_main_pids)" ]
}

process_started_at() {
  /bin/ps -p "$1" -o lstart= 2>/dev/null | /usr/bin/awk '{$1=$1; print}'
}

recorded_injector_process_matches() {
  local pid="$1"
  local expected_start="${2:-}"
  local expected_node="${3:-}"
  local expected_injector="${4:-}"
  local expected_port="${5:-}"
  local command_line=""
  local command_lower=""
  local node_lower=""
  local injector_lower=""
  local actual_start=""

  # A recorded PID is only safe to signal when the complete launch identity
  # was persisted.  Do not fall back to the current process paths: a stale or
  # hand-edited state file must fail closed instead of authorizing a reused PID.
  [ -n "$expected_start" ] && [ -n "$expected_node" ] && [ -n "$expected_injector" ] || return 1
  case "$expected_port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  /bin/kill -0 "$pid" 2>/dev/null || return 1
  command_line="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
  [ -n "$command_line" ] || return 1
  command_lower="$(printf '%s' "$command_line" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  injector_lower="$(printf '%s' "$expected_injector" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  node_lower="$(printf '%s' "$expected_node" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  case "$command_lower" in "$node_lower "*) ;; *) return 1 ;; esac
  # The watcher launch shape is deliberately matched as tokens.  In
  # particular, `--port 93410` must never satisfy a saved `9341` identity.
  case "$command_lower" in
    *"$injector_lower --watch --port $expected_port --theme-dir "*) ;;
    *) return 1 ;;
  esac
  actual_start="$(process_started_at "$pid")"
  [ -n "$actual_start" ] && [ "$actual_start" = "$expected_start" ] || return 1
  return 0
}

stop_codex() {
  local allow_force="${1:-false}"
  local deadline
  local pid

  release_codex_launchd_job
  codex_is_running || return 0
  /usr/bin/osascript -e 'tell application id "com.openai.codex" to quit' >/dev/null 2>&1 || true
  deadline=$((SECONDS + 15))
  while codex_is_running && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.25; done
  codex_is_running || return 0

  [ "$allow_force" = "true" ] || fail "Codex did not close within 15 seconds; explicit restart authorization is required for a forced stop."
  while IFS= read -r pid; do
    [ -n "$pid" ] && /bin/kill -TERM "$pid" 2>/dev/null || true
  done < <(codex_main_pids)
  deadline=$((SECONDS + 5))
  while codex_is_running && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.25; done
  if codex_is_running; then
    while IFS= read -r pid; do
      [ -n "$pid" ] && /bin/kill -KILL "$pid" 2>/dev/null || true
    done < <(codex_main_pids)
  fi
  /bin/sleep 0.5
  codex_is_running && fail "Codex could not be stopped safely."
  return 0
}

listener_pids() {
  /usr/sbin/lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | /usr/bin/sort -u || true
}

port_is_available() {
  [ -z "$(listener_pids "$1")" ]
}

pid_is_codex_descendant() {
  local current="$1"
  local command_line=""
  local parent=""
  local depth=0
  while [ "$current" -gt 1 ] 2>/dev/null && [ "$depth" -lt 32 ]; do
    command_line="$(/bin/ps -p "$current" -o command= 2>/dev/null || true)"
    case "$command_line" in "$CODEX_EXE"*) return 0 ;; esac
    parent="$(/bin/ps -p "$current" -o ppid= 2>/dev/null | /usr/bin/awk '{$1=$1; print}')"
    case "$parent" in ''|*[!0-9]*) return 1 ;; esac
    [ "$parent" -ne "$current" ] || return 1
    current="$parent"
    depth=$((depth + 1))
  done
  return 1
}

port_belongs_to_codex() {
  local port="$1"
  local found="false"
  local pid
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    found="true"
    pid_is_codex_descendant "$pid" || return 1
  done < <(listener_pids "$port")
  [ "$found" = "true" ]
}

# Cheap: can we talk to a loopback DevTools HTTP endpoint?
cdp_http_ready() {
  local port="$1"
  /usr/bin/curl --noproxy '*' --silent --fail --max-time 1 \
    "http://127.0.0.1:${port}/json/version" >/dev/null 2>&1
}

verified_cdp_endpoint() {
  local port="$1"
  port_belongs_to_codex "$port" || return 1
  cdp_http_ready "$port"
}

select_available_port() {
  local preferred="$1"
  local candidate="$preferred"
  local last=$((preferred + 100))
  [ "$last" -le 65535 ] || last=65535
  while [ "$candidate" -le "$last" ]; do
    if port_is_available "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    candidate=$((candidate + 1))
  done
  fail "No free loopback port was found between $preferred and $last."
}

wait_for_cdp() {
  local port="$1"
  local deadline=$((SECONDS + 45))
  local last_note=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    verified_cdp_endpoint "$port" && return 0
    if [ $((SECONDS - last_note)) -ge 8 ]; then
      last_note=$SECONDS
      printf 'Waiting for Codex debug port %s… (%ss)\n' "$port" "$SECONDS" >&2
    fi
    /bin/sleep 0.35
  done
  return 1
}

state_field() {
  local key="$1"
  if [ "${NODE_RUNTIME_VALIDATED:-false}" = "true" ] && [ -n "${NODE:-}" ] && [ -x "$NODE" ]; then
    "$NODE" -e '
      const fs = require("node:fs");
      const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))[process.argv[2]];
      if (value !== undefined && value !== null) process.stdout.write(String(value));
    ' "$STATE_PATH" "$key"
  else
    /usr/bin/plutil -extract "$key" raw -o - "$STATE_PATH"
  fi
}

restore_runtime_context_from_state() {
  [ -f "$STATE_PATH" ] || return 0
  local value=""

  value="$(state_field codexBundle 2>/dev/null || true)"
  # Only trust cached paths that still exist — Codex.app was renamed to
  # ChatGPT.app (26.707), so a stale bundle/exe must not hijack launch.
  if [ -n "$value" ] && [ -d "$value" ]; then CODEX_BUNDLE="$value"; fi
  value="$(state_field codexExe 2>/dev/null || true)"
  if [ -n "$value" ] && [ -x "$value" ]; then CODEX_EXE="$value"; fi
  value="$(state_field codexVersion 2>/dev/null || true)"
  [ -z "$value" ] || CODEX_VERSION="$value"
  value="$(state_field codexTeamId 2>/dev/null || true)"
  [ -z "$value" ] || CODEX_TEAM_ID="$value"

  export CODEX_BUNDLE CODEX_EXE CODEX_VERSION CODEX_TEAM_ID
}

write_state() {
  local port="$1"
  local injector_pid="$2"
  local injector_started_at="$3"
  local codex_pid="$4"
  local node_ver="${NODE_VERSION:-unknown}"
  local bundle="${CODEX_BUNDLE:-}"
  local exe="${CODEX_EXE:-}"
  local app_ver="${CODEX_VERSION:-}"
  local team="${CODEX_TEAM_ID:-}"
  "$NODE" -e '
    const fs = require("node:fs");
    const [file, version, port, pid, startedAt, injector, node, nodeVersion, bundle, exe, appVersion, teamId, root, themeDir, codexPid, arch] = process.argv.slice(1);
    const state = {
      schemaVersion: 4,
      platform: `darwin-${arch}`,
      skinVersion: version,
      injectorProtocol: 2,
      port: Number(port),
      injectorPid: Number(pid),
      injectorStartedAt: startedAt,
      injectorPath: injector,
      nodePath: node,
      nodeVersion,
      codexBundle: bundle,
      codexExe: exe,
      codexVersion: appVersion,
      codexTeamId: teamId,
      codexPid: Number(codexPid || 0),
      projectRoot: root,
      themeDir,
      createdAt: new Date().toISOString()
    };
    const temporary = `${file}.${process.pid}.tmp`;
    fs.writeFileSync(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
    fs.renameSync(temporary, file);
  ' "$STATE_PATH" "$SKIN_VERSION" "$port" "$injector_pid" "$injector_started_at" "$INJECTOR" "$NODE" "$node_ver" "$bundle" "$exe" "$app_ver" "$team" "$PROJECT_ROOT" "$THEME_DIR" "$codex_pid" "$(/usr/bin/uname -m)"
}

stop_recorded_injector() {
  [ -f "$STATE_PATH" ] || return 0
  local pid
  local saved_port
  local saved_start
  local saved_node
  local saved_injector
  if ! pid="$(state_field injectorPid 2>/dev/null)" || [ -z "${pid:-}" ]; then
    printf 'Dream Skin state is damaged or missing its injector PID; state was preserved.\n' >&2
    return 1
  fi
  # Already paused / no daemon
  if [ "$pid" = "0" ]; then
    /bin/launchctl remove "$INJECTOR_JOB_LABEL" >/dev/null 2>&1 || true
    return 0
  fi
  case "$pid" in
    *[!0-9]*|??????????*)
      printf 'Recorded Dream Skin injector PID is invalid; state was preserved.\n' >&2
      return 1
      ;;
  esac
  while [ "${pid#0}" != "$pid" ]; do pid="${pid#0}"; done
  if [ -z "$pid" ]; then
    /bin/launchctl remove "$INJECTOR_JOB_LABEL" >/dev/null 2>&1 || true
    return 0
  fi

  # Load and validate every recorded identity field before probing or
  # signalling the PID.  Missing fields are not treated as a harmless legacy
  # state: preserving the evidence is safer than guessing which process is
  # allowed to receive TERM/KILL.
  saved_port="$(state_field port 2>/dev/null || true)"
  saved_start="$(state_field injectorStartedAt 2>/dev/null || true)"
  saved_node="$(state_field nodePath 2>/dev/null || true)"
  saved_injector="$(state_field injectorPath 2>/dev/null || true)"
  case "$saved_port" in
    ''|*[!0-9]*)
      printf 'Recorded Dream Skin injector port is missing or invalid; state was preserved.\n' >&2
      return 1
      ;;
  esac
  [ "$saved_port" -ge 1024 ] && [ "$saved_port" -le 65535 ] || {
    printf 'Recorded Dream Skin injector port is out of range; state was preserved.\n' >&2
    return 1
  }
  if [ -z "$saved_start" ] || [ -z "$saved_node" ] || [ -z "$saved_injector" ]; then
    printf 'Recorded Dream Skin injector identity is incomplete; state was preserved.\n' >&2
    return 1
  fi
  /bin/kill -0 "$pid" 2>/dev/null || {
    /bin/launchctl remove "$INJECTOR_JOB_LABEL" >/dev/null 2>&1 || true
    return 0
  }
  if ! recorded_injector_process_matches "$pid" "$saved_start" "$saved_node" "$saved_injector" "$saved_port"; then
    # The process may have exited between the initial kill -0 probe and the
    # identity check. A dead (or already reaped) recorded PID is safe to
    # forget; a live PID with mismatched identity is never signalled.
    if ! /bin/kill -0 "$pid" 2>/dev/null || [ -z "$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)" ]; then
      /bin/launchctl remove "$INJECTOR_JOB_LABEL" >/dev/null 2>&1 || true
      return 0
    fi
    printf 'Recorded injector PID %s is live but its identity does not match; refusing to signal it.\n' "$pid" >&2
    return 1
  fi
  /bin/launchctl remove "$INJECTOR_JOB_LABEL" >/dev/null 2>&1 || true
  /bin/kill -TERM "$pid" 2>/dev/null || true
  local deadline=$((SECONDS + 6))
  while /bin/kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.2; done
  if recorded_injector_process_matches "$pid" "$saved_start" "$saved_node" "$saved_injector" "$saved_port"; then
    /bin/kill -KILL "$pid" 2>/dev/null || true
  fi
  deadline=$((SECONDS + 2))
  while recorded_injector_process_matches "$pid" "$saved_start" "$saved_node" "$saved_injector" "$saved_port" \
    && [ "$SECONDS" -lt "$deadline" ]; do
    /bin/sleep 0.1
  done
  if recorded_injector_process_matches "$pid" "$saved_start" "$saved_node" "$saved_injector" "$saved_port"; then
    printf 'Could not stop the recorded Dream Skin injector (PID %s).\n' "$pid" >&2
    return 1
  fi
  return 0
}

launch_injector_daemon() {
  local port="$1"
  local pid=""
  local deadline=$((SECONDS + 10))
  : > "$INJECTOR_LOG"
  : > "$INJECTOR_ERROR_LOG"
  /bin/launchctl remove "$INJECTOR_JOB_LABEL" >/dev/null 2>&1 || true

  # Prefer a direct background process — launchctl submit is unreliable on newer macOS.
  /usr/bin/nohup "$NODE" "$INJECTOR" --watch --port "$port" --theme-dir "$THEME_DIR" \
    >>"$INJECTOR_LOG" 2>>"$INJECTOR_ERROR_LOG" &
  pid="$!"
  /bin/sleep 0.08
  if [ -n "$pid" ] && /bin/kill -0 "$pid" 2>/dev/null; then
    printf '%s\n' "$pid"
    return 0
  fi
  if [ "${DREAM_SKIN_STUDIO_ADAPTER:-false}" = "true" ]; then
    fail "The injector did not start. See $INJECTOR_ERROR_LOG and $INJECTOR_LOG"
  fi

  # Fallback: launchctl submit
  /bin/launchctl submit -l "$INJECTOR_JOB_LABEL" -o "$INJECTOR_LOG" -e "$INJECTOR_ERROR_LOG" -- \
    "$NODE" "$INJECTOR" --watch --port "$port" --theme-dir "$THEME_DIR" >/dev/null 2>&1 || true
  /bin/launchctl kickstart -k "gui/$(/usr/bin/id -u)/$INJECTOR_JOB_LABEL" >/dev/null 2>&1 || true
  while [ "$SECONDS" -lt "$deadline" ]; do
    pid="$(/bin/launchctl print "gui/$(/usr/bin/id -u)/$INJECTOR_JOB_LABEL" 2>/dev/null \
      | /usr/bin/awk '/^[[:space:]]*pid = [0-9]+/{print $3; exit}')"
    if [ -n "$pid" ] && /bin/kill -0 "$pid" 2>/dev/null; then
      printf '%s\n' "$pid"
      return 0
    fi
    # Also detect the nohup node process by command line
    pid="$(/bin/ps -axo pid=,command= | /usr/bin/awk -v inj="$INJECTOR" -v port="$port" '
      index($0, inj) && index($0, "--watch") && index($0, "--port " port " --theme-dir ") { print $1; exit }
    ')"
    if [ -n "$pid" ] && /bin/kill -0 "$pid" 2>/dev/null; then
      printf '%s\n' "$pid"
      return 0
    fi
    /bin/sleep 0.2
  done
  fail "The injector did not start. See $INJECTOR_ERROR_LOG and $INJECTOR_LOG"
}

# Resolve Node quickly: prefer known Codex path, else full runtime check.
ensure_node_runtime() {
  if [ -n "${NODE:-}" ] && [ -x "${NODE:-}" ]; then
    if [ -z "${NODE_VERSION:-}" ]; then
      NODE_VERSION="$("$NODE" --version 2>/dev/null || echo unknown)"
      export NODE_VERSION
    fi
    # Fill CODEX_* if missing so write_state does not explode under set -u
    : "${CODEX_BUNDLE:=}"
    : "${CODEX_EXE:=}"
    : "${CODEX_VERSION:=}"
    : "${CODEX_TEAM_ID:=}"
    return 0
  fi
  local candidate cand_bundle
  for candidate in \
    "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node" \
    "/Applications/Codex.app/Contents/Resources/cua_node/bin/node" \
    "$HOME/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node" \
    "$HOME/Applications/Codex.app/Contents/Resources/cua_node/bin/node"
  do
    if [ -x "$candidate" ]; then
      NODE="$candidate"
      NODE_VERSION="$("$NODE" --version 2>/dev/null || echo unknown)"
      export NODE NODE_VERSION
      # Derive the bundle from the chosen node so CODEX_* matches the app that
      # actually exists on disk (Codex.app vs renamed ChatGPT.app).
      cand_bundle="${candidate%/Contents/Resources/cua_node/bin/node}"
      : "${CODEX_BUNDLE:=$cand_bundle}"
      : "${CODEX_EXE:=$cand_bundle/Contents/MacOS/ChatGPT}"
      : "${CODEX_VERSION:=}"
      : "${CODEX_TEAM_ID:=}"
      restore_runtime_context_from_state
      return 0
    fi
  done
  discover_codex_app
  require_macos_runtime
}

# Fast path when CDP is already open: restart injector + one-shot inject.
# Returns 0 on success, 1 if CDP is not ready (caller should full-start).
hot_reapply_theme() {
  local port="${1:-9341}"
  local timeout_ms="${2:-8000}"
  local inj_pid=""
  local injector_protocol=""
  local started_at=""
  local codex_pid=""

  # A generic HTTP listener is not enough for a hot re-apply: only use the
  # endpoint already verified as belonging to the official Codex process.
  verified_cdp_endpoint "$port" || return 1
  ensure_node_runtime || return 1

  injector_protocol="$(state_field injectorProtocol 2>/dev/null || true)"
  if [ "$injector_protocol" = "2" ]; then
    inj_pid="$(/bin/ps -axo pid=,command= | /usr/bin/awk -v inj="$INJECTOR" -v port="$port" '
      index($0, inj) && index($0, "--watch") && index($0, "--port " port " --theme-dir ") { print $1; exit }
    ')"
  fi
  if ! "$NODE" "$INJECTOR" --once --port "$port" --theme-dir "$THEME_DIR" \
    --timeout-ms "$timeout_ms" >/dev/null 2>&1; then
    return 1
  fi

  # A current watcher reloads theme files itself. Start one only when absent.
  if [ -n "$inj_pid" ] && /bin/kill -0 "$inj_pid" 2>/dev/null; then
    return 0
  fi
  stop_recorded_injector 2>/dev/null || return 1
  inj_pid="$(launch_injector_daemon "$port")"
  /bin/kill -0 "$inj_pid" 2>/dev/null || return 1
  started_at="$(process_started_at "$inj_pid")"
  codex_pid="$(codex_main_pids 2>/dev/null | /usr/bin/head -n 1)"
  [ -n "$started_at" ] || started_at="$(/bin/date)"
  write_state "$port" "$inj_pid" "$started_at" "${codex_pid:-0}"
  return 0
}

# Always tear down any leftover launchd babysitter for the themed Codex process.
# Older builds used `launchctl submit` which can relaunch Codex after the user quits
# or after SwiftBar exits — that is unexpected and unwanted.
release_codex_launchd_job() {
  /bin/launchctl remove "gui/$(/usr/bin/id -u)/$CODEX_APP_JOB_LABEL" >/dev/null 2>&1 || true
  /bin/launchctl remove "$CODEX_APP_JOB_LABEL" >/dev/null 2>&1 || true
}

launch_codex_with_cdp() {
  local port="$1"
  : > "$APP_LOG"
  : > "$APP_ERROR_LOG"
  release_codex_launchd_job
  # Start as a normal user process (NOT launchctl submit). submit keeps a job
  # that will restart Codex when the window is closed.
  /usr/bin/open -na "$CODEX_BUNDLE" --args \
    --remote-debugging-address=127.0.0.1 \
    --remote-debugging-port="$port" \
    >>"$APP_LOG" 2>>"$APP_ERROR_LOG" || true
  # Fallback if open failed to pass args on some builds
  if ! codex_is_running; then
    /usr/bin/nohup "$CODEX_EXE" \
      --remote-debugging-address=127.0.0.1 \
      --remote-debugging-port="$port" \
      >>"$APP_LOG" 2>>"$APP_ERROR_LOG" &
  fi
}

launch_codex_normally() {
  release_codex_launchd_job
  /usr/bin/open -na "$CODEX_BUNDLE"
}
