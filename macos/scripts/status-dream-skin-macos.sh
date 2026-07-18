#!/bin/bash

# Fast status for SwiftBar. No codesign / CDP probes by default.

set +e
set -u

SHORT="false"
JSON="false"
STUDIO_JSON="false"
DEEP="false"
OPERATION="status"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --short) SHORT="true"; shift ;;
    --json) JSON="true"; shift ;;
    --studio-json) STUDIO_JSON="true"; shift ;;
    --deep) DEEP="true"; shift ;;
    --operation) OPERATION="${2:-}"; shift 2 ;;
    *) printf 'Unknown status argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done

case "$OPERATION" in
  preflight|install|apply|status|pause|resume|restore|verify|uninstall) ;;
  *) printf 'Invalid Studio operation: %s\n' "$OPERATION" >&2; exit 2 ;;
esac

STATE_ROOT="${HOME}/Library/Application Support/CodexDreamSkinStudio"
STATE_PATH="${STATE_ROOT}/state.json"
THEME_DIR="${STATE_ROOT}/theme"
THEME_BACKUP_PATH="${STATE_ROOT}/theme-backup.json"
INSTALL_ROOT="${HOME}/.codex/codex-dream-skin-studio"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

PORT="9341"
SESSION="off"
INJECTOR_ALIVE="false"
CDP_OK="false"
THEME_NAME=""
CODEX_RUNNING="false"

read_json_field() {
  # Parse machine-written JSON (one key per line) without python3, which macOS
  # 12.3+ no longer preinstalls. Handles "key": "string" and "key": number.
  [ -f "$1" ] || return 0
  /usr/bin/sed -n \
    -e 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    -e 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    "$1" 2>/dev/null | /usr/bin/head -n1
}

# Keep this check deliberately shell/ps-only: SwiftBar invokes status every
# few seconds and must not perform codesign, CDP, or Node startup.  A live PID
# alone is not enough because a stale state file can outlive the watcher and
# its PID may later be reused by an unrelated process.
injector_identity_matches() {
  local pid="$1"
  local expected_start="$2"
  local expected_node="$3"
  local expected_injector="$4"
  local expected_port="$5"
  local command_line command_lower node_lower injector_lower actual_start

  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" != "0" ] || return 1
  [ -n "$expected_start" ] && [ -n "$expected_node" ] && [ -n "$expected_injector" ] || return 1
  case "$expected_port" in ''|*[!0-9]*) return 1 ;; esac
  /bin/kill -0 "$pid" 2>/dev/null || return 1
  command_line="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
  [ -n "$command_line" ] || return 1
  command_lower="$(printf '%s' "$command_line" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  node_lower="$(printf '%s' "$expected_node" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  injector_lower="$(printf '%s' "$expected_injector" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  case "$command_lower" in "$node_lower "*) ;; *) return 1 ;; esac
  case "$command_lower" in *"$injector_lower"*--watch*) ;; *) return 1 ;; esac
  # The watcher launch shape puts --theme-dir immediately after the port.
  # Requiring that following token prevents 93410 from matching saved port
  # 9341 via a loose prefix pattern.
  case "$command_lower" in *"--port $expected_port --theme-dir "*) ;; *) return 1 ;; esac
  actual_start="$(/bin/ps -p "$pid" -o lstart= 2>/dev/null | /usr/bin/awk '{$1=$1; print}')"
  [ -n "$actual_start" ] && [ "$actual_start" = "$expected_start" ]
}

# Codex process: cheap name match only.  26.707 renamed Codex.app to
# ChatGPT.app, while older installs still expose the former process name.
if /usr/bin/pgrep -x ChatGPT >/dev/null 2>&1 || /usr/bin/pgrep -x Codex >/dev/null 2>&1; then
  CODEX_RUNNING="true"
fi

if [ -f "$STATE_PATH" ]; then
  saved_port="$(read_json_field "$STATE_PATH" port)"
  [ -n "${saved_port:-}" ] && PORT="$saved_port"
  SESSION="$(read_json_field "$STATE_PATH" session)"
  pid="$(read_json_field "$STATE_PATH" injectorPid)"
  saved_start="$(read_json_field "$STATE_PATH" injectorStartedAt)"
  saved_node="$(read_json_field "$STATE_PATH" nodePath)"
  saved_injector="$(read_json_field "$STATE_PATH" injectorPath)"
  if injector_identity_matches "${pid:-}" "$saved_start" "$saved_node" "$saved_injector" "$PORT"; then
    INJECTOR_ALIVE="true"
    SESSION="active"
  elif [ "${SESSION:-}" = "paused" ] && [ "${pid:-}" = "0" ]; then
    SESSION="paused"
  elif [ -n "${pid:-}" ] && [ "$pid" != "0" ]; then
    SESSION="stale"
  elif [ -z "${SESSION:-}" ]; then
    SESSION="unknown"
  fi
fi

if [ -f "$THEME_DIR/theme.json" ]; then
  THEME_NAME="$(read_json_field "$THEME_DIR/theme.json" name)"
  [ -n "$THEME_NAME" ] || THEME_NAME="$(read_json_field "$THEME_DIR/theme.json" id)"
fi

if [ "$DEEP" = "true" ]; then
  if /usr/bin/curl --noproxy '*' --silent --fail --max-time 1 "http://127.0.0.1:${PORT}/json/version" >/dev/null 2>&1; then
    CDP_OK="true"
  fi
fi

official_codex_bundle_exists() {
  local candidate identifier executable_name
  for candidate in "${CODEX_APP_BUNDLE:-}" \
    "/Applications/ChatGPT.app" "$HOME/Applications/ChatGPT.app" \
    "/Applications/Codex.app" "$HOME/Applications/Codex.app"; do
    [ -n "$candidate" ] || continue
    [ -f "$candidate/Contents/Info.plist" ] || continue
    identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$candidate/Contents/Info.plist" 2>/dev/null || true)"
    [ "$identifier" = "com.openai.codex" ] || continue
    executable_name="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$candidate/Contents/Info.plist" 2>/dev/null || true)"
    OFFICIAL_CODEX_EXE="$candidate/Contents/MacOS/$executable_name"
    [ -x "$OFFICIAL_CODEX_EXE" ] && return 0
  done
  candidate="$(/usr/bin/mdfind 'kMDItemCFBundleIdentifier == "com.openai.codex"' | /usr/bin/head -n 1)"
  if [ -n "$candidate" ] && [ -f "$candidate/Contents/Info.plist" ]; then
    identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$candidate/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$identifier" = "com.openai.codex" ]; then
      executable_name="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$candidate/Contents/Info.plist" 2>/dev/null || true)"
      OFFICIAL_CODEX_EXE="$candidate/Contents/MacOS/$executable_name"
      [ -x "$OFFICIAL_CODEX_EXE" ] && return 0
    fi
  fi
  return 1
}

studio_strict_verify() {
  local port="$1"
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  (
    . "$PROJECT_ROOT/scripts/common-macos.sh"
    fail() { exit 1; }
    discover_codex_app
    require_macos_runtime
    verified_cdp_endpoint "$port" || exit 1
    "$NODE" "$INJECTOR" --verify --port "$port" --theme-dir "$THEME_DIR" --timeout-ms 5000 >/dev/null 2>&1
  )
}

native_restore_helper_is_safe() {
  local root="$1"
  local helper="$root/bin/dream-skin-config-restore"
  local root_real=""
  local bin_real=""
  [ -d "$root" ] && [ -d "$root/bin" ] && [ ! -L "$root/bin" ] || return 1
  [ -f "$helper" ] && [ ! -L "$helper" ] && [ -x "$helper" ] || return 1
  root_real="$(cd "$root" && pwd -P)" || return 1
  bin_real="$(cd "$root/bin" && pwd -P)" || return 1
  [ "$bin_real" = "$root_real/bin" ]
}

if [ "$STUDIO_JSON" = "true" ]; then
  # Studio status must inspect only; lifecycle scripts own all writes and PID changes.
  json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
  INSTALL="not-installed"
  CODEX="not-installed"
  STUDIO_SESSION="official"
  VERIFIED="null"
  REQUIRES_RESTART="false"
  ACTIONS='["install"]'
  OK="true"
  ERROR="null"
  EXIT_CODE=0

  if native_restore_helper_is_safe "$INSTALL_ROOT" \
    && [ -f "$INSTALL_ROOT/VERSION" ] && /usr/bin/cmp -s "$INSTALL_ROOT/VERSION" "$PROJECT_ROOT/VERSION" \
    && [ -x "$INSTALL_ROOT/scripts/studio-adapter-macos.sh" ] \
    && [ -x "$INSTALL_ROOT/scripts/start-dream-skin-macos.sh" ] \
    && [ -x "$INSTALL_ROOT/scripts/restore-dream-skin-macos.sh" ] \
    && [ -f "$THEME_BACKUP_PATH" ] && [ -f "$THEME_DIR/theme.json" ]; then
    INSTALL="ready"
  fi

  if official_codex_bundle_exists; then
    if [ -f "$HOME/.codex/config.toml" ]; then
      [ "$CODEX_RUNNING" = "true" ] && CODEX="running" || CODEX="stopped"
    else
      CODEX="needs-first-run"
    fi
  fi

  case "$SESSION" in active|paused|stale) STUDIO_SESSION="$SESSION" ;; esac
  CDP_OK="false"
  if [ "$DEEP" = "true" ] && studio_strict_verify "$PORT"; then
    CDP_OK="true"
  fi
  [ "$CDP_OK" = "true" ] && VERIFIED="true"
  if [ "$CODEX" = "running" ] && [ "$VERIFIED" != "true" ]; then
    REQUIRES_RESTART="true"
  fi

  if [ "$INSTALL" = "ready" ]; then
    case "$STUDIO_SESSION" in
      active) ACTIONS='["pause","resume","restore","verify","uninstall"]' ;;
      paused) ACTIONS='["apply","resume","restore","verify","uninstall"]' ;;
      stale) ACTIONS='["apply","restore","verify","uninstall"]' ;;
      *)
        if [ "$CODEX" = "running" ]; then
          ACTIONS='["apply","restore","verify","uninstall"]'
        else
          ACTIONS='["apply","restore","uninstall"]'
        fi
        ;;
    esac
  fi

  case "$CODEX" in
    not-installed)
      OK="false"
      EXIT_CODE=1
      ERROR='{"code":"CODEX_NOT_INSTALLED","message":"Codex is not installed.","recoveryActions":["cancel"]}'
      ;;
    needs-first-run)
      OK="false"
      EXIT_CODE=1
      ERROR='{"code":"CODEX_FIRST_RUN_REQUIRED","message":"Open Codex and complete first-run setup.","recoveryActions":["open-codex","retry","cancel"]}'
      ;;
  esac
  if [ "$STUDIO_SESSION" = "stale" ]; then
    OK="false"
    EXIT_CODE=1
    ERROR='{"code":"STATE_UNSAFE","message":"Theme state needs recovery before it can be used.","recoveryActions":["restore","diagnostics","cancel"]}'
  fi

  printf '{"schemaVersion":1,"ok":%s,"operation":"%s","state":{"install":"%s","codex":"%s","session":"%s","operation":"idle","themeName":%s,"requiresRestart":%s,"availableActions":%s,"verified":%s},"error":%s}\n' \
    "$OK" "$(json_escape "$OPERATION")" "$INSTALL" "$CODEX" "$STUDIO_SESSION" \
    "$(if [ -n "$THEME_NAME" ]; then printf '\"%s\"' "$(json_escape "$THEME_NAME")"; else printf 'null'; fi)" \
    "$REQUIRES_RESTART" "$ACTIONS" "$VERIFIED" "$ERROR"
  exit "$EXIT_CODE"
fi

label="Skin"
case "$SESSION" in
  active) label="Skin ON" ;;
  paused) label="Skin 暂停" ;;
  stale|unknown) label="Skin ?" ;;
  *) label="Skin 关" ;;
esac

if [ "$SHORT" = "true" ]; then
  printf '%s\n' "$label"
  exit 0
fi

if [ "$JSON" = "true" ]; then
  # Emit JSON without python3; escape strings for a valid JSON string context.
  json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
  bool() { [ "$1" = "true" ] && printf 'true' || printf 'false'; }
  case "$PORT" in ''|*[!0-9]*) port_json="\"$(json_escape "$PORT")\"" ;; *) port_json="$PORT" ;; esac
  printf '{"session":"%s","port":%s,"injectorAlive":%s,"cdpOk":%s,"codexRunning":%s,"themeName":"%s"}\n' \
    "$(json_escape "$SESSION")" "$port_json" "$(bool "$INJECTOR_ALIVE")" \
    "$(bool "$CDP_OK")" "$(bool "$CODEX_RUNNING")" "$(json_escape "$THEME_NAME")"
  exit 0
fi

printf 'session=%s\n' "$SESSION"
printf 'port=%s\n' "$PORT"
printf 'injector=%s\n' "$INJECTOR_ALIVE"
printf 'cdp=%s\n' "$CDP_OK"
printf 'codex=%s\n' "$CODEX_RUNNING"
printf 'theme=%s\n' "${THEME_NAME:-}"
