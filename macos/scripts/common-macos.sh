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
ROLLBACK_STATE_PATH="$STATE_ROOT/rollback.json"
LIFECYCLE_LOCK_PATH="$STATE_ROOT/lifecycle.lock"
LIFECYCLE_LOCK_OWNER_PATH="$LIFECYCLE_LOCK_PATH/owner"
LIFECYCLE_LOCK_GATE_PATH="$STATE_ROOT/lifecycle.lock.gate"
THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.json"
RESTORED_THEME_BACKUP_PATH="$STATE_ROOT/theme-backup.restored.json"
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
SKIN_VERSION="$(/bin/cat "$PROJECT_ROOT/VERSION")"
CODEX_APP_VALIDATED="false"
CODEX_APP_CONTROL_VALIDATED="false"
NODE_RUNTIME_VALIDATED="false"
LIFECYCLE_LOCK_OWNED="false"
LIFECYCLE_LOCK_BORROWED="false"
LIFECYCLE_LOCK_OWNER_PID=""
LIFECYCLE_LOCK_OWNER_STARTED_AT=""
LIFECYCLE_LOCK_GATE_HELD="false"

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
  /bin/mkdir -p "$STATE_ROOT" || return 1
  [ -d "$STATE_ROOT" ] && [ ! -L "$STATE_ROOT" ] || return 1
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

theme_backup_assignment_is_valid() {
  local key="$1"
  local backup_path="$2"
  /usr/bin/plutil -extract "values.$key" raw -o - "$backup_path" 2>/dev/null \
    | LC_ALL=C /usr/bin/awk -v expected="$key" '
      function hex_value(character, position) {
        position = index("0123456789abcdef", tolower(character))
        return position ? position - 1 : -1
      }
      BEGIN {
        for (value = 1; value < 256; value += 1) ordinal[sprintf("%c", value)] = value
      }
      {
        if (NR != 1) invalid = 1
        line = $0
      }
      END {
        if (invalid || NR != 1) exit 1
        length_bytes = length(line)
        for (index_byte = 1; index_byte <= length_bytes; index_byte += 1) {
          byte = ordinal[substr(line, index_byte, 1)]
          if (byte <= 8 || (byte >= 10 && byte <= 31) || byte == 127) exit 1
          next_byte = ordinal[substr(line, index_byte + 1, 1)]
          third_byte = ordinal[substr(line, index_byte + 2, 1)]
          if (byte == 194 && next_byte >= 128 && next_byte <= 159) exit 1
          if (byte == 226 && next_byte == 128 && (third_byte == 168 || third_byte == 169)) exit 1
        }

        expected_length = length(expected)
        if (substr(line, 1, expected_length) != expected) exit 1
        cursor = expected_length + 1
        while (cursor <= length_bytes && (substr(line, cursor, 1) == " " || substr(line, cursor, 1) == "\t")) cursor += 1
        if (substr(line, cursor, 1) != "=") exit 1
        cursor += 1
        while (cursor <= length_bytes && (substr(line, cursor, 1) == " " || substr(line, cursor, 1) == "\t")) cursor += 1
        quote = substr(line, cursor, 1)
        if (quote != "\"" && quote != "\047") exit 1
        cursor += 1
        closed = 0
        while (cursor <= length_bytes) {
          character = substr(line, cursor, 1)
          if (character == quote) {
            cursor += 1
            closed = 1
            break
          }
          if (quote == "\"" && character == "\\") {
            cursor += 1
            if (cursor > length_bytes) exit 1
            escape = substr(line, cursor, 1)
            if (index("\"\\btnfr", escape)) {
              cursor += 1
              continue
            }
            if (escape != "u" && escape != "U") exit 1
            digits = escape == "u" ? 4 : 8
            if (cursor + digits > length_bytes) exit 1
            scalar = 0
            for (offset = 1; offset <= digits; offset += 1) {
              digit = hex_value(substr(line, cursor + offset, 1))
              if (digit < 0) exit 1
              scalar = (scalar * 16) + digit
            }
            if (scalar > 1114111 || (scalar >= 55296 && scalar <= 57343)) exit 1
            cursor += digits + 1
            continue
          }
          cursor += 1
        }
        if (!closed) exit 1
        while (cursor <= length_bytes && (substr(line, cursor, 1) == " " || substr(line, cursor, 1) == "\t")) cursor += 1
        if (cursor <= length_bytes && substr(line, cursor, 1) != "#") exit 1
      }
    '
}

theme_backup_is_valid() {
  local backup_path="$1"
  local expected_config_path="${2:-$CONFIG_PATH}"
  local keys=""
  local schema_type=""
  local schema_value=""
  local value_type=""
  [ -d "$STATE_ROOT" ] && [ ! -L "$STATE_ROOT" ] \
    && [ -f "$backup_path" ] && [ ! -L "$backup_path" ] \
    || return 1
  schema_type="$(/usr/bin/plutil -type schemaVersion "$backup_path" 2>/dev/null)" || return 1
  schema_value="$(/usr/bin/plutil -extract schemaVersion raw -o - "$backup_path" 2>/dev/null)" || return 1
  case "$schema_type:$schema_value" in integer:1|float:1.000000) ;; *) return 1 ;; esac
  [ "$(/usr/bin/plutil -type platform "$backup_path" 2>/dev/null)" = "string" ] \
    && [ "$(/usr/bin/plutil -extract platform raw -o - "$backup_path" 2>/dev/null)" = "darwin" ] \
    && [ "$(/usr/bin/plutil -type configPath "$backup_path" 2>/dev/null)" = "string" ] \
    && [ "$(/usr/bin/plutil -extract configPath raw -o - "$backup_path" 2>/dev/null)" = "$expected_config_path" ] \
    && [ "$(/usr/bin/plutil -type values "$backup_path" 2>/dev/null)" = "dictionary" ] \
    || return 1
  keys="$(/usr/bin/plutil -extract values raw -o - "$backup_path" 2>/dev/null \
    | LC_ALL=C /usr/bin/sort)" || return 1
  [ "$keys" = $'appearanceDarkCodeThemeId\nappearanceTheme' ] || return 1
  for key in appearanceTheme appearanceDarkCodeThemeId; do
    value_type="$(/usr/bin/plutil -type "values.$key" "$backup_path" 2>/dev/null)" \
      || return 1
    case "$value_type" in
      '(any)') ;;
      string) theme_backup_assignment_is_valid "$key" "$backup_path" || return 1 ;;
      *) return 1 ;;
    esac
  done
}

live_theme_backup_is_valid() {
  theme_backup_is_valid "$THEME_BACKUP_PATH"
}

restored_theme_backup_is_valid() {
  theme_backup_is_valid "$RESTORED_THEME_BACKUP_PATH"
}

renderer_rollback_evidence_is_valid() {
  local port=""
  local browser_id=""
  [ -d "$STATE_ROOT" ] && [ ! -L "$STATE_ROOT" ] \
    && [ -f "$ROLLBACK_STATE_PATH" ] && [ ! -L "$ROLLBACK_STATE_PATH" ] \
    || return 1
  [ "$(/usr/bin/plutil -extract schemaVersion raw -o - "$ROLLBACK_STATE_PATH" 2>/dev/null)" = "1" ] \
    && [ "$(/usr/bin/plutil -extract themeDir raw -o - "$ROLLBACK_STATE_PATH" 2>/dev/null)" = "$THEME_DIR" ] \
    || return 1
  port="$(/usr/bin/plutil -extract port raw -o - "$ROLLBACK_STATE_PATH" 2>/dev/null)" || return 1
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || return 1
  browser_id="$(/usr/bin/plutil -extract browserId raw -o - "$ROLLBACK_STATE_PATH" 2>/dev/null)" \
    || return 1
  browser_id_is_valid "$browser_id"
}

renderer_rollback_field() {
  /usr/bin/plutil -extract "$1" raw -o - "$ROLLBACK_STATE_PATH"
}

codex_main_pids() {
  local current_uid
  local uid
  local pid
  local command_line
  current_uid="$(/usr/bin/id -u)"
  while read -r uid pid command_line; do
    [ "$uid" = "$current_uid" ] || continue
    [ -n "$pid" ] || continue
    case "$command_line" in
      "$CODEX_EXE"*) printf '%s\n' "$pid" ;;
    esac
  done < <(/bin/ps -axo uid=,pid=,command=)
}

codex_is_running() {
  [ -n "$(codex_main_pids)" ]
}

process_started_at() {
  LC_ALL=C TZ=UTC /bin/ps -p "$1" -o lstart= 2>/dev/null | /usr/bin/awk '{$1=$1; print}'
}

lifecycle_process_started_at() {
  process_started_at "$1"
}

process_start_identity_matches() {
  local pid="$1"
  local expected="$2"
  local actual=""
  actual="$(process_started_at "$pid")"
  [ -n "$actual" ] && [ "$actual" = "$expected" ] && return 0
  # Compatibility for schema-v5 state written before start times were UTC/C.
  actual="$(/bin/ps -p "$pid" -o lstart= 2>/dev/null | /usr/bin/awk '{$1=$1; print}')"
  [ -n "$actual" ] && [ "$actual" = "$expected" ]
}

process_belongs_to_current_user() {
  local uid=""
  uid="$(/bin/ps -p "$1" -o uid= 2>/dev/null | /usr/bin/awk '{$1=$1; print}')"
  [ -n "$uid" ] && [ "$uid" = "$(/usr/bin/id -u)" ]
}

read_lifecycle_lock_owner() {
  [ -d "$LIFECYCLE_LOCK_PATH" ] && [ ! -L "$LIFECYCLE_LOCK_PATH" ] \
    && [ -f "$LIFECYCLE_LOCK_OWNER_PATH" ] && [ ! -L "$LIFECYCLE_LOCK_OWNER_PATH" ] || return 1
  local pid started_at extra
  pid="$(/usr/bin/sed -n '1p' "$LIFECYCLE_LOCK_OWNER_PATH" 2>/dev/null)"
  started_at="$(/usr/bin/sed -n '2p' "$LIFECYCLE_LOCK_OWNER_PATH" 2>/dev/null)"
  extra="$(/usr/bin/sed -n '3p' "$LIFECYCLE_LOCK_OWNER_PATH" 2>/dev/null)"
  case "$pid" in ''|*[!0-9]*|??????????*) return 1 ;; esac
  [ "$pid" -gt 1 ] 2>/dev/null && [ -n "$started_at" ] && [ -z "$extra" ] || return 1
  LIFECYCLE_RECORDED_OWNER_PID="$pid"
  LIFECYCLE_RECORDED_OWNER_STARTED_AT="$started_at"
}

lifecycle_lock_owner_matches() {
  local pid="$1"
  local started_at="$2"
  process_belongs_to_current_user "$pid" || return 1
  /bin/kill -0 "$pid" 2>/dev/null || return 1
  [ "$(lifecycle_process_started_at "$pid")" = "$started_at" ]
}

lifecycle_process_is_descendant() {
  local current="$1"
  local ancestor="$2"
  local parent=""
  local depth=0
  while [ "$depth" -lt 64 ]; do
    [ "$current" = "$ancestor" ] && return 0
    case "$current" in ''|*[!0-9]*|0|1) return 1 ;; esac
    process_belongs_to_current_user "$current" || return 1
    parent="$(/bin/ps -p "$current" -o ppid= 2>/dev/null | /usr/bin/awk '{$1=$1; print}')"
    [ -n "$parent" ] && [ "$parent" != "$current" ] || return 1
    current="$parent"
    depth=$((depth + 1))
  done
  return 1
}

lifecycle_lock_handoff_is_valid() {
  local owner_pid="${DREAM_SKIN_LIFECYCLE_LOCK_OWNER_PID:-}"
  local owner_started_at="${DREAM_SKIN_LIFECYCLE_LOCK_OWNER_STARTED_AT:-}"
  case "$owner_pid" in ''|*[!0-9]*|??????????*) return 1 ;; esac
  [ -n "$owner_started_at" ] || return 1
  read_lifecycle_lock_owner || return 1
  [ "$LIFECYCLE_RECORDED_OWNER_PID" = "$owner_pid" ] \
    && [ "$LIFECYCLE_RECORDED_OWNER_STARTED_AT" = "$owner_started_at" ] \
    && lifecycle_lock_owner_matches "$owner_pid" "$owner_started_at" \
    && lifecycle_process_is_descendant "$$" "$owner_pid"
}

lifecycle_lock_is_recent() {
  local modified now
  modified="$(/usr/bin/stat -f '%m' "$LIFECYCLE_LOCK_PATH" 2>/dev/null)" || return 1
  now="$(/bin/date '+%s')"
  case "$modified:$now" in *[!0-9:]*) return 1 ;; esac
  [ "$now" -lt "$modified" ] || [ $((now - modified)) -lt 10 ]
}

ensure_lifecycle_lock_gate() {
  if [ ! -e "$LIFECYCLE_LOCK_GATE_PATH" ] && [ ! -L "$LIFECYCLE_LOCK_GATE_PATH" ]; then
    (umask 077; set -o noclobber; : > "$LIFECYCLE_LOCK_GATE_PATH") 2>/dev/null || true
  fi
  [ -f "$LIFECYCLE_LOCK_GATE_PATH" ] && [ ! -L "$LIFECYCLE_LOCK_GATE_PATH" ] || return 1
  /bin/chmod 600 "$LIFECYCLE_LOCK_GATE_PATH"
}

lifecycle_lock_gate_acquire() {
  local timeout="${1:-0}"
  local gate_status=0
  LIFECYCLE_LOCK_GATE_HELD="false"
  [ -f "$LIFECYCLE_LOCK_GATE_PATH" ] && [ ! -L "$LIFECYCLE_LOCK_GATE_PATH" ] || return 1
  if ! exec 9<"$LIFECYCLE_LOCK_GATE_PATH"; then return 1; fi
  if /usr/bin/lockf -s -t "$timeout" 9; then
    LIFECYCLE_LOCK_GATE_HELD="true"
    return 0
  else
    gate_status="$?"
  fi
  exec 9>&-
  return "$gate_status"
}

lifecycle_lock_gate_release() {
  if [ "$LIFECYCLE_LOCK_GATE_HELD" = "true" ]; then exec 9>&-; fi
  LIFECYCLE_LOCK_GATE_HELD="false"
}

lifecycle_lock_record_is_busy() {
  [ -e "$LIFECYCLE_LOCK_PATH" ] || [ -L "$LIFECYCLE_LOCK_PATH" ] || return 1
  [ -d "$LIFECYCLE_LOCK_PATH" ] && [ ! -L "$LIFECYCLE_LOCK_PATH" ] || return 0
  if read_lifecycle_lock_owner; then
    lifecycle_lock_owner_matches \
      "$LIFECYCLE_RECORDED_OWNER_PID" "$LIFECYCLE_RECORDED_OWNER_STARTED_AT"
    return
  fi
  lifecycle_lock_is_recent
}

# Returns success only when another live/recent operation or lock transition owns the lock.
lifecycle_lock_is_busy() {
  local gate_status=0
  local record_status=0
  lifecycle_lock_handoff_is_valid && return 1
  if [ -e "$LIFECYCLE_LOCK_GATE_PATH" ] || [ -L "$LIFECYCLE_LOCK_GATE_PATH" ]; then
    if lifecycle_lock_gate_acquire; then gate_status=0; else gate_status="$?"; fi
    if [ "$gate_status" -eq 75 ]; then return 0; fi
    [ "$gate_status" -eq 0 ] || return 1
    if lifecycle_lock_record_is_busy; then record_status=0; else record_status="$?"; fi
    lifecycle_lock_gate_release
    return "$record_status"
  fi
  lifecycle_lock_record_is_busy
}

acquire_lifecycle_lock() {
  if lifecycle_lock_handoff_is_valid; then
    if [ "$$" = "$DREAM_SKIN_LIFECYCLE_LOCK_OWNER_PID" ]; then
      LIFECYCLE_LOCK_OWNED="true"
      LIFECYCLE_LOCK_BORROWED="false"
      LIFECYCLE_LOCK_OWNER_PID="$DREAM_SKIN_LIFECYCLE_LOCK_OWNER_PID"
      LIFECYCLE_LOCK_OWNER_STARTED_AT="$DREAM_SKIN_LIFECYCLE_LOCK_OWNER_STARTED_AT"
    else
      LIFECYCLE_LOCK_BORROWED="true"
    fi
    return 0
  fi

  LIFECYCLE_LOCK_OWNED="false"
  LIFECYCLE_LOCK_BORROWED="false"
  ensure_state_root || return 1
  ensure_lifecycle_lock_gate || return 1
  lifecycle_lock_gate_acquire || return 1
  local attempt=0
  local acquired="false"
  local owner_started_at=""
  local temporary_owner=""
  local stale_path=""
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    if /bin/mkdir "$LIFECYCLE_LOCK_PATH" 2>/dev/null; then
      if ! /bin/chmod 700 "$LIFECYCLE_LOCK_PATH"; then
        /bin/rmdir "$LIFECYCLE_LOCK_PATH" 2>/dev/null || true
        break
      fi
      owner_started_at="$(lifecycle_process_started_at "$$")"
      if [ -z "$owner_started_at" ]; then
        /bin/rmdir "$LIFECYCLE_LOCK_PATH" 2>/dev/null || true
        break
      fi
      temporary_owner="$LIFECYCLE_LOCK_PATH/.owner.$$"
      if ! (umask 077; printf '%s\n%s\n' "$$" "$owner_started_at" > "$temporary_owner") \
        || ! /bin/chmod 600 "$temporary_owner" \
        || ! /bin/mv "$temporary_owner" "$LIFECYCLE_LOCK_OWNER_PATH"; then
        /bin/rm -rf "$LIFECYCLE_LOCK_PATH"
        break
      fi
      LIFECYCLE_LOCK_OWNED="true"
      LIFECYCLE_LOCK_OWNER_PID="$$"
      LIFECYCLE_LOCK_OWNER_STARTED_AT="$owner_started_at"
      DREAM_SKIN_LIFECYCLE_LOCK_OWNER_PID="$$"
      DREAM_SKIN_LIFECYCLE_LOCK_OWNER_STARTED_AT="$owner_started_at"
      export DREAM_SKIN_LIFECYCLE_LOCK_OWNER_PID DREAM_SKIN_LIFECYCLE_LOCK_OWNER_STARTED_AT
      acquired="true"
      break
    fi
    lifecycle_lock_record_is_busy && break
    stale_path="$LIFECYCLE_LOCK_PATH.stale.$$.$attempt"
    if /bin/mv "$LIFECYCLE_LOCK_PATH" "$stale_path" 2>/dev/null; then
      /bin/rm -rf "$stale_path" || break
    fi
  done
  lifecycle_lock_gate_release
  [ "$acquired" = "true" ]
}

require_lifecycle_lock() {
  acquire_lifecycle_lock && return 0
  printf 'Codex Dream Skin Studio: Another lifecycle operation is already running.\n' >&2
  exit 1
}

release_lifecycle_lock() {
  local release_status=0
  if [ "$LIFECYCLE_LOCK_OWNED" = "true" ]; then
    ensure_lifecycle_lock_gate || return 1
    lifecycle_lock_gate_acquire 5 || return 1
    if read_lifecycle_lock_owner \
      && [ "$LIFECYCLE_RECORDED_OWNER_PID" = "$LIFECYCLE_LOCK_OWNER_PID" ] \
      && [ "$LIFECYCLE_RECORDED_OWNER_STARTED_AT" = "$LIFECYCLE_LOCK_OWNER_STARTED_AT" ]; then
      local released_path="$LIFECYCLE_LOCK_PATH.released.$$"
      if /bin/mv "$LIFECYCLE_LOCK_PATH" "$released_path" 2>/dev/null; then
        /bin/rm -rf "$released_path" || release_status=1
      else
        release_status=1
      fi
    else
      release_status=1
    fi
    lifecycle_lock_gate_release
    [ "$release_status" -eq 0 ] || return 1
  fi
  LIFECYCLE_LOCK_OWNED="false"
  LIFECYCLE_LOCK_BORROWED="false"
  LIFECYCLE_LOCK_OWNER_PID=""
  LIFECYCLE_LOCK_OWNER_STARTED_AT=""
  unset DREAM_SKIN_LIFECYCLE_LOCK_OWNER_PID DREAM_SKIN_LIFECYCLE_LOCK_OWNER_STARTED_AT
  return 0
}

recorded_injector_process_matches() {
  local pid="$1"
  local expected_start="${2:-}"
  local expected_node="${3:-}"
  local expected_injector="${4:-}"
  local expected_port="${5:-}"
  local expected_browser_id="${6:-}"
  local command_line=""
  local command_lower=""
  local node_lower=""
  local injector_lower=""
  local actual_start=""

  # A recorded PID is only safe to signal when the complete launch identity
  # was persisted.  Do not fall back to the current process paths: a stale or
  # hand-edited state file must fail closed instead of authorizing a reused PID.
  [ -n "$expected_start" ] || return 1
  launched_injector_process_matches \
    "$pid" "$expected_node" "$expected_injector" "$expected_port" "$expected_browser_id" \
    || return 1
  process_start_identity_matches "$pid" "$expected_start" || return 1
  return 0
}

launched_injector_process_matches() {
  local pid="$1"
  local expected_node="${2:-}"
  local expected_injector="${3:-}"
  local expected_port="${4:-}"
  local expected_browser_id="${5:-}"
  local command_line=""
  local command_lower=""
  local node_lower=""
  local injector_lower=""

  [ -n "$expected_node" ] && [ -n "$expected_injector" ] || return 1
  case "$expected_port" in
    ''|*[!0-9]*) return 1 ;;
  esac
  browser_id_is_valid "$expected_browser_id" || return 1
  process_belongs_to_current_user "$pid" || return 1
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
    *"$injector_lower --watch --port $expected_port --browser-id "*) ;;
    *) return 1 ;;
  esac
  case "$command_line" in
    *" --browser-id $expected_browser_id --theme-dir "*) ;;
    *) return 1 ;;
  esac
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

listener_records() {
  /usr/sbin/lsof -nP -iTCP:"$1" -sTCP:LISTEN -Fpn 2>/dev/null || true
}

listener_pids() {
  local port="$1"
  listener_records "$port" | /usr/bin/awk \
    -v ipv4="127.0.0.1:$port" -v ipv6="[::1]:$port" '
      function finish_pid() {
        if (pid != "" && !pid_has_endpoint) invalid = 1
      }
      /^p/ {
        finish_pid()
        pid = substr($0, 2)
        pid_has_endpoint = 0
        if (pid !~ /^[1-9][0-9]*$/) invalid = 1
        next
      }
      /^f/ {
        if (pid == "") invalid = 1
        next
      }
      /^n/ {
        endpoint = substr($0, 2)
        if (pid == "" || (endpoint != ipv4 && endpoint != ipv6)) invalid = 1
        pid_has_endpoint = 1
        found_endpoint = 1
        pids[pid] = 1
        next
      }
      { invalid = 1 }
      END {
        finish_pid()
        if (NR > 0 && !found_endpoint) invalid = 1
        if (invalid) exit 1
        for (value in pids) print value
      }
    ' | /usr/bin/sort -n -u
}

port_is_available() {
  local pids=""
  pids="$(listener_pids "$1")" || return 1
  [ -z "$pids" ]
}

pid_is_codex_descendant() {
  local current="$1"
  local command_line=""
  local parent=""
  local depth=0
  while [ "$current" -gt 1 ] 2>/dev/null && [ "$depth" -lt 32 ]; do
    process_belongs_to_current_user "$current" || return 1
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
  local pids=""
  local pid
  pids="$(listener_pids "$port")" || return 1
  [ -n "$pids" ] || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    pid_is_codex_descendant "$pid" || return 1
  done <<< "$pids"
}

browser_id_is_valid() {
  local value="$1"
  [ -n "$value" ] && [ "${#value}" -le 200 ] || return 1
  case "$value" in *[!A-Za-z0-9._-]*) return 1 ;; esac
}

cdp_version_json() {
  local port="$1"
  /usr/bin/curl --noproxy '*' --silent --fail --max-time 1 \
    "http://127.0.0.1:${port}/json/version"
}

cdp_browser_id() {
  local port="$1"
  local payload=""
  local websocket_url=""
  local browser_id=""
  payload="$(cdp_version_json "$port" 2>/dev/null)" || return 1
  websocket_url="$(printf '%s' "$payload" \
    | /usr/bin/plutil -extract webSocketDebuggerUrl raw -o - - 2>/dev/null)" || return 1
  case "$websocket_url" in
    "ws://127.0.0.1:$port/devtools/browser/"*)
      browser_id="${websocket_url#"ws://127.0.0.1:$port/devtools/browser/"}"
      ;;
    "ws://[::1]:$port/devtools/browser/"*)
      browser_id="${websocket_url#"ws://[::1]:$port/devtools/browser/"}"
      ;;
    *) return 1 ;;
  esac
  browser_id_is_valid "$browser_id" || return 1
  printf '%s\n' "$browser_id"
}

verified_cdp_browser_id() {
  local port="$1"
  local browser_id=""
  port_belongs_to_codex "$port" || return 1
  browser_id="$(cdp_browser_id "$port")" || return 1
  port_belongs_to_codex "$port" || return 1
  printf '%s\n' "$browser_id"
}

# Cheap enough for lifecycle polling, but still bound to an owned listener and
# a strictly shaped numeric-loopback browser identity.
cdp_http_ready() {
  cdp_browser_id "$1" >/dev/null 2>&1
}

verified_cdp_endpoint() {
  local port="$1"
  verified_cdp_browser_id "$port" >/dev/null
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
  local browser_id="$5"
  local node_ver="${NODE_VERSION:-unknown}"
  local bundle="${CODEX_BUNDLE:-}"
  local exe="${CODEX_EXE:-}"
  local app_ver="${CODEX_VERSION:-}"
  local team="${CODEX_TEAM_ID:-}"
  "$NODE" -e '
    const fs = require("node:fs");
    const [file, version, port, pid, startedAt, injector, node, nodeVersion, bundle, exe, appVersion, teamId, root, themeDir, codexPid, browserId, arch] = process.argv.slice(1);
    const state = {
      schemaVersion: 5,
      platform: `darwin-${arch}`,
      skinVersion: version,
      injectorProtocol: 3,
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
      browserId,
      projectRoot: root,
      themeDir,
      createdAt: new Date().toISOString()
    };
    const temporary = `${file}.${process.pid}.tmp`;
    try {
      fs.writeFileSync(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
      fs.renameSync(temporary, file);
    } finally {
      fs.rmSync(temporary, { force: true });
    }
  ' "$STATE_PATH" "$SKIN_VERSION" "$port" "$injector_pid" "$injector_started_at" "$INJECTOR" "$NODE" "$node_ver" "$bundle" "$exe" "$app_ver" "$team" "$PROJECT_ROOT" "$THEME_DIR" "$codex_pid" "$browser_id" "$(/usr/bin/uname -m)"
}

owned_injector_process_matches() {
  local pid="$1"
  local started_at="$2"
  local node="$3"
  local injector="$4"
  local port="$5"
  local browser_id="$6"
  if [ -n "$started_at" ]; then
    recorded_injector_process_matches "$pid" "$started_at" "$node" "$injector" "$port" "$browser_id"
  else
    launched_injector_process_matches "$pid" "$node" "$injector" "$port" "$browser_id"
  fi
}

injector_launchctl_job_pid() {
  local output=""
  local pid=""
  output="$(/bin/launchctl print "gui/$(/usr/bin/id -u)/$INJECTOR_JOB_LABEL" 2>/dev/null \
    || printf '__ABSENT__')"
  [ "$output" != "__ABSENT__" ] || { printf '__ABSENT__\n'; return 0; }
  pid="$(printf '%s\n' "$output" \
    | /usr/bin/awk '/^[[:space:]]*pid = [0-9]+/{print $3; exit}')"
  case "$pid" in ''|*[!0-9]*|0|1|??????????*) printf '__UNSAFE__\n'; return 0 ;; esac
  printf '%s\n' "$pid"
}

injector_launchctl_job_is_absent() {
  local pid=""
  pid="$(injector_launchctl_job_pid)"
  case "$pid" in
    __ABSENT__) return 0 ;;
    __UNSAFE__)
      printf 'Dream Skin launchctl job identity could not be classified; refusing to remove it.\n' >&2
      ;;
    *)
      printf 'Dream Skin launchctl job PID %s is live but has no authorized watcher identity; refusing to remove it.\n' "$pid" >&2
      ;;
  esac
  return 1
}

remove_owned_injector_launchctl_job() {
  local expected_pid="$1"
  local started_at="$2"
  local node="$3"
  local injector="$4"
  local port="$5"
  local browser_id="$6"
  local pid=""
  pid="$(injector_launchctl_job_pid)"
  [ "$pid" = "__ABSENT__" ] && return 0
  [ "$pid" != "__UNSAFE__" ] || {
    printf 'Dream Skin launchctl job identity could not be classified; refusing to remove it.\n' >&2
    return 1
  }
  [ "$pid" = "$expected_pid" ] \
    && owned_injector_process_matches "$pid" "$started_at" "$node" "$injector" "$port" "$browser_id" \
    || {
      printf 'Dream Skin launchctl job does not match the authorized watcher; refusing to remove it.\n' >&2
      return 1
    }
  [ "$(injector_launchctl_job_pid)" = "$expected_pid" ] \
    && owned_injector_process_matches "$expected_pid" "$started_at" "$node" "$injector" "$port" "$browser_id" \
    || {
      printf 'Dream Skin launchctl job changed before removal; refusing to remove it.\n' >&2
      return 1
    }
  /bin/launchctl remove "$INJECTOR_JOB_LABEL" >/dev/null 2>&1 || true
}

write_renderer_rollback_evidence() {
  local port="$1"
  local browser_id="$2"
  if [ -e "$ROLLBACK_STATE_PATH" ] || [ -L "$ROLLBACK_STATE_PATH" ]; then
    [ -f "$ROLLBACK_STATE_PATH" ] && [ ! -L "$ROLLBACK_STATE_PATH" ] || return 1
  fi
  "$NODE" -e '
    const fs = require("node:fs");
    const [file, port, browserId, themeDir] = process.argv.slice(1);
    const temporary = `${file}.${process.pid}.tmp`;
    try {
      fs.writeFileSync(temporary, `${JSON.stringify({
        schemaVersion: 1,
        port: Number(port),
        browserId,
        themeDir,
        createdAt: new Date().toISOString(),
      }, null, 2)}\n`, { mode: 0o600, flag: "wx" });
      fs.renameSync(temporary, file);
    } finally {
      fs.rmSync(temporary, { force: true });
    }
  ' "$ROLLBACK_STATE_PATH" "$port" "$browser_id" "$THEME_DIR"
}

clear_renderer_rollback_evidence() {
  [ -e "$ROLLBACK_STATE_PATH" ] || [ -L "$ROLLBACK_STATE_PATH" ] || return 0
  [ -f "$ROLLBACK_STATE_PATH" ] && [ ! -L "$ROLLBACK_STATE_PATH" ] || return 1
  /bin/rm -f "$ROLLBACK_STATE_PATH"
  [ ! -e "$ROLLBACK_STATE_PATH" ] && [ ! -L "$ROLLBACK_STATE_PATH" ]
}

rollback_unpublished_watcher() {
  local pid="$1"
  local started_at="$2"
  local port="$3"
  local browser_id="$4"
  local active_browser_id=""
  stop_injector_process "$pid" "$started_at" "$NODE" "$INJECTOR" "$port" "$browser_id" \
    || {
      write_renderer_rollback_evidence "$port" "$browser_id" || true
      return 1
    }
  active_browser_id="$(verified_cdp_browser_id "$port")" \
    && [ "$active_browser_id" = "$browser_id" ] \
    && "$NODE" "$INJECTOR" --remove --port "$port" --browser-id "$browser_id" \
      --theme-dir "$THEME_DIR" --timeout-ms 8000 >/dev/null 2>&1 \
    && clear_renderer_rollback_evidence \
    && return 0
  write_renderer_rollback_evidence "$port" "$browser_id" || true
  return 1
}

stop_injector_process() {
  local pid="$1"
  local started_at="$2"
  local node="$3"
  local injector="$4"
  local port="$5"
  local browser_id="$6"
  /bin/kill -0 "$pid" 2>/dev/null || {
    remove_owned_injector_launchctl_job "$pid" "$started_at" "$node" "$injector" "$port" "$browser_id" \
      || return 1
    wait "$pid" 2>/dev/null || true
    return 0
  }
  if ! owned_injector_process_matches "$pid" "$started_at" "$node" "$injector" "$port" "$browser_id"; then
    if ! /bin/kill -0 "$pid" 2>/dev/null || [ -z "$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)" ]; then
      remove_owned_injector_launchctl_job "$pid" "$started_at" "$node" "$injector" "$port" "$browser_id" \
        || return 1
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    printf 'Dream Skin injector PID %s is live but its identity does not match; refusing to signal it.\n' "$pid" >&2
    return 1
  fi
  remove_owned_injector_launchctl_job "$pid" "$started_at" "$node" "$injector" "$port" "$browser_id" \
    || return 1
  /bin/kill -TERM "$pid" 2>/dev/null || true
  local deadline=$((SECONDS + 6))
  while /bin/kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do /bin/sleep 0.2; done
  if owned_injector_process_matches "$pid" "$started_at" "$node" "$injector" "$port" "$browser_id"; then
    /bin/kill -KILL "$pid" 2>/dev/null || true
  fi
  deadline=$((SECONDS + 2))
  while owned_injector_process_matches "$pid" "$started_at" "$node" "$injector" "$port" "$browser_id" \
    && [ "$SECONDS" -lt "$deadline" ]; do
    /bin/sleep 0.1
  done
  wait "$pid" 2>/dev/null || true
  if owned_injector_process_matches "$pid" "$started_at" "$node" "$injector" "$port" "$browser_id"; then
    printf 'Could not stop the Dream Skin injector (PID %s).\n' "$pid" >&2
    return 1
  fi
}

stop_recorded_injector() {
  [ -f "$STATE_PATH" ] || return 0
  local pid
  local saved_port
  local saved_start
  local saved_node
  local saved_injector
  local saved_browser_id
  if ! pid="$(state_field injectorPid 2>/dev/null)" || [ -z "${pid:-}" ]; then
    printf 'Dream Skin state is damaged or missing its injector PID; state was preserved.\n' >&2
    return 1
  fi
  # Already paused / no daemon
  if [ "$pid" = "0" ]; then
    injector_launchctl_job_is_absent
    return
  fi
  case "$pid" in
    *[!0-9]*|??????????*)
      printf 'Recorded Dream Skin injector PID is invalid; state was preserved.\n' >&2
      return 1
      ;;
  esac
  while [ "${pid#0}" != "$pid" ]; do pid="${pid#0}"; done
  if [ -z "$pid" ]; then
    injector_launchctl_job_is_absent
    return
  fi

  # Load and validate every recorded identity field before probing or
  # signalling the PID.  Missing fields are not treated as a harmless legacy
  # state: preserving the evidence is safer than guessing which process is
  # allowed to receive TERM/KILL.
  saved_port="$(state_field port 2>/dev/null || true)"
  saved_start="$(state_field injectorStartedAt 2>/dev/null || true)"
  saved_node="$(state_field nodePath 2>/dev/null || true)"
  saved_injector="$(state_field injectorPath 2>/dev/null || true)"
  saved_browser_id="$(state_field browserId 2>/dev/null || true)"
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
  if [ -z "$saved_start" ] || [ -z "$saved_node" ] || [ -z "$saved_injector" ] \
    || ! browser_id_is_valid "$saved_browser_id"; then
    printf 'Recorded Dream Skin injector identity is incomplete; state was preserved.\n' >&2
    return 1
  fi
  stop_injector_process "$pid" "$saved_start" "$saved_node" "$saved_injector" "$saved_port" "$saved_browser_id"
}

state_has_complete_injector_identity() {
  [ -f "$STATE_PATH" ] && [ ! -L "$STATE_PATH" ] || return 1
  local pid=""
  local saved_port=""
  local saved_start=""
  local saved_node=""
  local saved_injector=""
  local saved_browser_id=""
  pid="$(state_field injectorPid 2>/dev/null)" || return 1
  case "$pid" in ''|*[!0-9]*|??????????*) return 1 ;; esac
  [ "$pid" != "0" ] || return 0
  saved_port="$(state_field port 2>/dev/null)" || return 1
  saved_start="$(state_field injectorStartedAt 2>/dev/null)" || return 1
  saved_node="$(state_field nodePath 2>/dev/null)" || return 1
  saved_injector="$(state_field injectorPath 2>/dev/null)" || return 1
  saved_browser_id="$(state_field browserId 2>/dev/null)" || return 1
  case "$saved_port" in ''|*[!0-9]*) return 1 ;; esac
  [ "$saved_port" -ge 1024 ] && [ "$saved_port" -le 65535 ] \
    && [ -n "$saved_start" ] && [ -n "$saved_node" ] && [ -n "$saved_injector" ] \
    && browser_id_is_valid "$saved_browser_id"
}

live_injector_candidate_pids() {
  local current_uid=""
  local uid=""
  local pid=""
  local command_line=""
  current_uid="$(/usr/bin/id -u)"
  while read -r uid pid command_line; do
    [ "$uid" = "$current_uid" ] || continue
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" != "$$" ] || continue
    case "$command_line" in
      *"/injector.mjs --watch --port "*" --theme-dir $THEME_DIR"*|\
      *"/injector.mjs --watch --port "*" --browser-id "*" --theme-dir $THEME_DIR"*)
        /bin/kill -0 "$pid" 2>/dev/null && printf '%s\n' "$pid"
        ;;
    esac
  done < <(/bin/ps -axo uid=,pid=,command=)
}

recover_damaged_injector_state_without_live_candidate() {
  [ -f "$STATE_PATH" ] && [ ! -L "$STATE_PATH" ] || return 1
  if state_has_complete_injector_identity; then
    printf 'Recorded injector identity is complete but could not be stopped; state was preserved.\n' >&2
    return 1
  fi
  injector_launchctl_job_is_absent || return 1
  local candidates=""
  candidates="$(live_injector_candidate_pids)" || return 1
  if [ -n "$candidates" ]; then
    printf 'Damaged state has a live injector candidate; state was preserved.\n' >&2
    return 1
  fi
}

record_launched_injector() {
  local pid="$1"
  local port="$2"
  local browser_id="$3"
  local started_at=""
  started_at="$(process_started_at "$pid" 2>/dev/null || true)"
  if [ -z "$started_at" ]; then
    rollback_unpublished_watcher "$pid" "" "$port" "$browser_id" \
      || printf 'Could not roll back the unrecorded Dream Skin injector (PID %s).\n' "$pid" >&2
    printf 'Could not record the injector process start time.\n' >&2
    return 1
  fi
  LAUNCHED_INJECTOR_PID="$pid"
  LAUNCHED_INJECTOR_STARTED_AT="$started_at"
}

launch_injector_daemon() {
  local port="$1"
  local browser_id="$2"
  local pid=""
  local deadline=$((SECONDS + 10))
  LAUNCHED_INJECTOR_PID=""
  LAUNCHED_INJECTOR_STARTED_AT=""
  browser_id_is_valid "$browser_id" || {
    printf 'The CDP Browser ID is missing or invalid.\n' >&2
    return 1
  }
  : > "$INJECTOR_LOG"
  : > "$INJECTOR_ERROR_LOG"
  injector_launchctl_job_is_absent || return 1

  # Prefer a direct background process — launchctl submit is unreliable on newer macOS.
  /usr/bin/nohup "$NODE" "$INJECTOR" --watch --port "$port" --browser-id "$browser_id" --theme-dir "$THEME_DIR" \
    >>"$INJECTOR_LOG" 2>>"$INJECTOR_ERROR_LOG" &
  pid="$!"
  /bin/sleep 0.08
  if [ -n "$pid" ] && /bin/kill -0 "$pid" 2>/dev/null; then
    record_launched_injector "$pid" "$port" "$browser_id"
    return
  fi
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  if [ "${DREAM_SKIN_STUDIO_ADAPTER:-false}" = "true" ]; then
    printf 'The injector did not start. See %s and %s\n' "$INJECTOR_ERROR_LOG" "$INJECTOR_LOG" >&2
    return 1
  fi

  # Fallback: launchctl submit
  /bin/launchctl submit -l "$INJECTOR_JOB_LABEL" -o "$INJECTOR_LOG" -e "$INJECTOR_ERROR_LOG" -- \
    "$NODE" "$INJECTOR" --watch --port "$port" --browser-id "$browser_id" --theme-dir "$THEME_DIR" >/dev/null 2>&1 || true
  /bin/launchctl kickstart -k "gui/$(/usr/bin/id -u)/$INJECTOR_JOB_LABEL" >/dev/null 2>&1 || true
  while [ "$SECONDS" -lt "$deadline" ]; do
    pid="$(/bin/launchctl print "gui/$(/usr/bin/id -u)/$INJECTOR_JOB_LABEL" 2>/dev/null \
      | /usr/bin/awk '/^[[:space:]]*pid = [0-9]+/{print $3; exit}')"
    if [ -n "$pid" ] && /bin/kill -0 "$pid" 2>/dev/null; then
      record_launched_injector "$pid" "$port" "$browser_id"
      return
    fi
    # Also detect the nohup node process by command line
    pid="$(/bin/ps -axo pid=,command= | /usr/bin/awk -v inj="$INJECTOR" -v port="$port" -v browser="$browser_id" '
      index($0, inj) && index($0, "--watch") && index($0, "--port " port " --browser-id " browser " --theme-dir ") { print $1; exit }
    ')"
    if [ -n "$pid" ] && /bin/kill -0 "$pid" 2>/dev/null; then
      record_launched_injector "$pid" "$port" "$browser_id"
      return
    fi
    /bin/sleep 0.2
  done
  printf 'The injector did not start. See %s and %s\n' "$INJECTOR_ERROR_LOG" "$INJECTOR_LOG" >&2
  return 1
}

start_watcher() {
  local port="$1"
  local browser_id="$2"
  local codex_pid="${3:-0}"
  local pid=""
  local started_at=""
  launch_injector_daemon "$port" "$browser_id" || return 1
  pid="$LAUNCHED_INJECTOR_PID"
  started_at="$LAUNCHED_INJECTOR_STARTED_AT"
  /bin/sleep 0.15
  if ! /bin/kill -0 "$pid" 2>/dev/null; then
    rollback_unpublished_watcher "$pid" "$started_at" "$port" "$browser_id" || true
    printf 'The injector exited during startup. See %s\n' "$INJECTOR_ERROR_LOG" >&2
    return 1
  fi
  if ! write_state "$port" "$pid" "$started_at" "$codex_pid" "$browser_id"; then
    rollback_unpublished_watcher "$pid" "$started_at" "$port" "$browser_id" \
      || printf 'Could not roll back the unpublished Dream Skin injector (PID %s).\n' "$pid" >&2
    return 1
  fi
  STARTED_WATCHER_PID="$pid"
  STARTED_WATCHER_AT="$started_at"
  LAUNCHED_INJECTOR_PID=""
  LAUNCHED_INJECTOR_STARTED_AT=""
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
  local browser_id=""
  local saved_browser_id=""

  [ ! -e "$ROLLBACK_STATE_PATH" ] && [ ! -L "$ROLLBACK_STATE_PATH" ] || return 1

  # A generic HTTP listener is not enough for a hot re-apply: only use the
  # endpoint already verified as belonging to the official Codex process.
  browser_id="$(verified_cdp_browser_id "$port")" || return 1
  ensure_node_runtime || return 1

  if [ -f "$STATE_PATH" ]; then
    saved_browser_id="$(state_field browserId 2>/dev/null || true)"
    browser_id_is_valid "$saved_browser_id" && [ "$saved_browser_id" = "$browser_id" ] || return 1
    browser_id="$saved_browser_id"
  fi

  injector_protocol="$(state_field injectorProtocol 2>/dev/null || true)"
  if [ "$injector_protocol" = "3" ]; then
    inj_pid="$(/bin/ps -axo pid=,command= | /usr/bin/awk -v inj="$INJECTOR" -v port="$port" -v browser="$browser_id" '
      index($0, inj) && index($0, "--watch") && index($0, "--port " port " --browser-id " browser " --theme-dir ") { print $1; exit }
    ')"
  fi
  if ! "$NODE" "$INJECTOR" --once --port "$port" --browser-id "$browser_id" --theme-dir "$THEME_DIR" \
    --timeout-ms "$timeout_ms" >/dev/null 2>&1; then
    return 1
  fi

  # A current watcher reloads theme files itself. Start one only when absent.
  if [ -n "$inj_pid" ] && /bin/kill -0 "$inj_pid" 2>/dev/null; then
    return 0
  fi
  stop_recorded_injector 2>/dev/null || return 1
  codex_pid="$(codex_main_pids 2>/dev/null | /usr/bin/head -n 1)"
  start_watcher "$port" "$browser_id" "${codex_pid:-0}" || return 1
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
