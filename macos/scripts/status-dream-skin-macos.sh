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
ROLLBACK_STATE_PATH="${STATE_ROOT}/rollback.json"
THEME_DIR="${STATE_ROOT}/theme"
THEME_BACKUP_PATH="${STATE_ROOT}/theme-backup.json"
RESTORED_THEME_BACKUP_PATH="${STATE_ROOT}/theme-backup.restored.json"
INSTALL_ROOT="${HOME}/.codex/codex-dream-skin-studio"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

studio_operation_is_busy() (
  . "$PROJECT_ROOT/scripts/common-macos.sh" >/dev/null 2>&1 || exit 1
  lifecycle_lock_is_busy
)

status_renderer_rollback_is_valid() (
  . "$PROJECT_ROOT/scripts/common-macos.sh" >/dev/null 2>&1 || exit 1
  renderer_rollback_evidence_is_valid
)

status_renderer_rollback_field() (
  . "$PROJECT_ROOT/scripts/common-macos.sh" >/dev/null 2>&1 || exit 1
  renderer_rollback_evidence_is_valid || exit 1
  renderer_rollback_field "$1"
)

if [ "$STUDIO_JSON" = "true" ] && studio_operation_is_busy; then
  printf '{"schemaVersion":1,"ok":false,"operation":"%s","state":{"install":"not-installed","codex":"not-installed","session":"official","operation":"busy","themeName":null,"requiresRestart":false,"availableActions":[],"verified":null},"error":{"code":"OPERATION_BUSY","message":"Another Studio operation is already running.","recoveryActions":["retry","cancel"]}}\n' \
    "$OPERATION"
  exit 1
fi

PORT="9341"
SESSION="off"
INJECTOR_ALIVE="false"
CDP_OK="false"
THEME_NAME=""
CODEX_RUNNING="false"
SAVED_BROWSER_ID=""
ROLLBACK_EVIDENCE_UNSAFE="false"
ROLLBACK_LAUNCHER=""

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
  local expected_browser_id="$6"
  local expected_theme_dir="$7"
  local expected_activation_gate="${8:-}"
  local command_line command_lower node_lower injector_lower actual_start

  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" != "0" ] || return 1
  [ -n "$expected_start" ] && [ -n "$expected_node" ] && [ -n "$expected_injector" ] \
    && [ "$expected_theme_dir" = "$THEME_DIR" ] || return 1
  case "$expected_port" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$expected_browser_id" ] && [ "${#expected_browser_id}" -le 200 ] || return 1
  case "$expected_browser_id" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  if [ -n "$expected_activation_gate" ]; then
    [ "${expected_activation_gate%/*}" = "$STATE_ROOT" ] || return 1
    case "${expected_activation_gate##*/}" in .watcher-activation.??????) ;; *) return 1 ;; esac
    case "${expected_activation_gate##*.watcher-activation.}" in *[!A-Za-z0-9]*) return 1 ;; esac
  fi
  [ "$(/bin/ps -p "$pid" -o uid= 2>/dev/null | /usr/bin/awk '{$1=$1; print}')" = "$(/usr/bin/id -u)" ] \
    || return 1
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
  case "$command_lower" in *"--port $expected_port --browser-id "*) ;; *) return 1 ;; esac
  case "$command_line" in
    *" --browser-id $expected_browser_id --theme-dir $expected_theme_dir --activation-gate $expected_activation_gate")
      [ -n "$expected_activation_gate" ] || return 1
      ;;
    *" --browser-id $expected_browser_id --theme-dir $expected_theme_dir")
      [ -z "$expected_activation_gate" ] || return 1
      ;;
    *) return 1 ;;
  esac
  actual_start="$(LC_ALL=C TZ=UTC /bin/ps -p "$pid" -o lstart= 2>/dev/null | /usr/bin/awk '{$1=$1; print}')"
  [ -n "$actual_start" ] && [ "$actual_start" = "$expected_start" ] && return 0
  # Compatibility for schema-v5 state written before start times were UTC/C.
  actual_start="$(/bin/ps -p "$pid" -o lstart= 2>/dev/null | /usr/bin/awk '{$1=$1; print}')"
  [ -n "$actual_start" ] && [ "$actual_start" = "$expected_start" ]
}

# Codex process: cheap name match only.  26.707 renamed Codex.app to
# ChatGPT.app, while older installs still expose the former process name.
if /usr/bin/pgrep -U "$(/usr/bin/id -u)" -x ChatGPT >/dev/null 2>&1 \
  || /usr/bin/pgrep -U "$(/usr/bin/id -u)" -x Codex >/dev/null 2>&1; then
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
  SAVED_BROWSER_ID="$(read_json_field "$STATE_PATH" browserId)"
  saved_theme_dir="$(read_json_field "$STATE_PATH" themeDir)"
  injector_protocol="$(read_json_field "$STATE_PATH" injectorProtocol)"
  saved_activation_gate=""
  if [ "$injector_protocol" = "4" ]; then
    saved_activation_gate="$(read_json_field "$STATE_PATH" activationGate)"
  fi
  if injector_identity_matches \
    "${pid:-}" "$saved_start" "$saved_node" "$saved_injector" "$PORT" \
    "$SAVED_BROWSER_ID" "$saved_theme_dir" "$saved_activation_gate"; then
    INJECTOR_ALIVE="true"
    SESSION="active"
  elif [ "${SESSION:-}" = "paused" ] && [ "${pid:-}" = "0" ]; then
    SESSION="paused"
  elif [ -n "${pid:-}" ] && [ "$pid" != "0" ]; then
    SESSION="stale"
  elif [ "${SESSION:-}" = "active" ]; then
    SESSION="stale"
  elif [ -z "${SESSION:-}" ]; then
    SESSION="unknown"
  fi
fi
if [ -e "$ROLLBACK_STATE_PATH" ] || [ -L "$ROLLBACK_STATE_PATH" ]; then
  SESSION="stale"
  if status_renderer_rollback_is_valid; then
    ROLLBACK_LAUNCHER="$(status_renderer_rollback_field launcher 2>/dev/null || true)"
  else
    ROLLBACK_EVIDENCE_UNSAFE="true"
  fi
fi

safe_theme_display_name() {
  local value="$1"
  [ -n "$value" ] || return 1
  case "$value" in
    *'/'*|*\\*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  if printf '%s' "$value" | LC_ALL=C /usr/bin/grep -q $'[\x01-\x1f\x7f]\|\xc2[\x80-\x9f]\|\xe2\x80[\xa8\xa9]'; then
    return 1
  fi
  printf '%s' "$value"
}

if [ -f "$THEME_DIR/theme.json" ] && [ ! -L "$THEME_DIR/theme.json" ]; then
  THEME_NAME="$(/usr/bin/plutil -extract name raw -o - "$THEME_DIR/theme.json" 2>/dev/null)"
  [ -n "$THEME_NAME" ] \
    || THEME_NAME="$(/usr/bin/plutil -extract id raw -o - "$THEME_DIR/theme.json" 2>/dev/null)"
  THEME_NAME="$(safe_theme_display_name "$THEME_NAME" 2>/dev/null)" || THEME_NAME=""
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
  local browser_id=""
  local active_browser_id=""
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  browser_id="$(read_json_field "$STATE_PATH" browserId)"
  [ -n "$browser_id" ] || return 1
  (
    . "$PROJECT_ROOT/scripts/common-macos.sh"
    fail() { exit 1; }
    discover_codex_app
    require_macos_runtime
    browser_id_is_valid "$browser_id" || exit 1
    active_browser_id="$(verified_cdp_browser_id "$port")" || exit 1
    [ "$active_browser_id" = "$browser_id" ] || exit 1
    "$NODE" "$INJECTOR" --verify --port "$port" --browser-id "$browser_id" --theme-dir "$THEME_DIR" --timeout-ms 5000 >/dev/null 2>&1
  )
}

studio_managed_cdp_is_ready() {
  local port="$1"
  local browser_id=""
  local active_browser_id=""
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  browser_id="$(read_json_field "$STATE_PATH" browserId)"
  [ -n "$browser_id" ] || return 1
  (
    . "$PROJECT_ROOT/scripts/common-macos.sh" >/dev/null 2>&1 || exit 1
    try_discover_codex_app >/dev/null 2>&1 || exit 1
    try_validate_codex_app_control_identity >/dev/null 2>&1 || exit 1
    browser_id_is_valid "$browser_id" || exit 1
    active_browser_id="$(verified_cdp_browser_id "$port")" || exit 1
    [ "$active_browser_id" = "$browser_id" ]
  )
}

studio_deep_preflight_result() {
  local configured="${CODEX_APP_BUNDLE:-}"
  local candidate=""
  (
    . "$PROJECT_ROOT/scripts/common-macos.sh" >/dev/null 2>&1 || exit 3
    if ! try_discover_codex_app >/dev/null 2>&1; then
      [ -n "${CODEX_BUNDLE:-}" ] && exit 2
      for candidate in "$configured" \
        "/Applications/ChatGPT.app" "$HOME/Applications/ChatGPT.app" \
        "/Applications/Codex.app" "$HOME/Applications/Codex.app"; do
        [ -n "$candidate" ] || continue
        { [ -e "$candidate" ] || [ -L "$candidate" ]; } && exit 2
      done
      exit 1
    fi
    try_validate_codex_app_identity >/dev/null 2>&1 || exit 2
    try_require_macos_node_runtime >/dev/null 2>&1 || exit 3
  )
}

if [ "$DEEP" = "true" ] && [ "$STUDIO_JSON" != "true" ] && studio_strict_verify "$PORT"; then
  CDP_OK="true"
fi

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

status_theme_backup_is_valid() (
  . "$PROJECT_ROOT/scripts/common-macos.sh" >/dev/null 2>&1
  theme_backup_is_valid "$1"
)

installed_engine_is_present() {
  [ -d "$INSTALL_ROOT" ] && [ ! -L "$INSTALL_ROOT" ]
}

installed_engine_is_complete() {
  native_restore_helper_is_safe "$INSTALL_ROOT" \
    && [ -f "$INSTALL_ROOT/VERSION" ] \
    && [ -x "$INSTALL_ROOT/scripts/studio-adapter-macos.sh" ] \
    && [ -x "$INSTALL_ROOT/scripts/start-dream-skin-macos.sh" ] \
    && [ -x "$INSTALL_ROOT/scripts/pause-dream-skin-macos.sh" ] \
    && [ -x "$INSTALL_ROOT/scripts/restore-dream-skin-macos.sh" ] \
    && [ -x "$INSTALL_ROOT/scripts/verify-dream-skin-macos.sh" ] \
    && [ -f "$INSTALL_ROOT/scripts/common-macos.sh" ] \
    && [ -f "$INSTALL_ROOT/scripts/injector.mjs" ] \
    && [ -f "$INSTALL_ROOT/scripts/theme-config.mjs" ]
}

installed_engine_matches_bundle() {
  installed_engine_is_complete \
    && /usr/bin/cmp -s "$INSTALL_ROOT/VERSION" "$PROJECT_ROOT/VERSION"
}

installed_engine_is_older() {
  local installed=""
  local bundled=""
  installed_engine_is_complete || return 1
  installed="$(/bin/cat "$INSTALL_ROOT/VERSION" 2>/dev/null)" || return 1
  bundled="$(/bin/cat "$PROJECT_ROOT/VERSION" 2>/dev/null)" || return 1
  /usr/bin/awk -v installed="$installed" -v bundled="$bundled" 'BEGIN {
    installedCount = split(installed, installedParts, ".")
    bundledCount = split(bundled, bundledParts, ".")
    if (installedCount != 3 || bundledCount != 3) exit 1
    for (part = 1; part <= 3; part++) {
      if (installedParts[part] !~ /^[0-9]+$/ || bundledParts[part] !~ /^[0-9]+$/) exit 1
      if ((installedParts[part] + 0) < (bundledParts[part] + 0)) exit 0
      if ((installedParts[part] + 0) > (bundledParts[part] + 0)) exit 1
    }
    exit 1
  }'
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
  ENGINE_COMPLETE="false"
  ENGINE_CURRENT="false"
  ENGINE_OUTDATED="false"
  ENGINE_PRESENT="false"
  ENGINE_SESSION_READY="false"
  RESTORE_PROOF_VALID="false"
  LIVE_BACKUP_VALID="false"
  PREFLIGHT_RESULT=0

  if installed_engine_is_complete; then ENGINE_COMPLETE="true"; fi
  if installed_engine_matches_bundle; then ENGINE_CURRENT="true"; fi
  if installed_engine_is_older; then ENGINE_OUTDATED="true"; fi
  if installed_engine_is_present; then ENGINE_PRESENT="true"; fi
  if status_theme_backup_is_valid "$RESTORED_THEME_BACKUP_PATH"; then RESTORE_PROOF_VALID="true"; fi
  if status_theme_backup_is_valid "$THEME_BACKUP_PATH"; then LIVE_BACKUP_VALID="true"; fi
  if [ "$ENGINE_COMPLETE" = "true" ] \
    && [ "$LIVE_BACKUP_VALID" = "true" ] \
    && [ -f "$THEME_DIR/theme.json" ] && [ ! -L "$THEME_DIR/theme.json" ]; then
    ENGINE_SESSION_READY="true"
    [ "$ENGINE_CURRENT" = "true" ] && INSTALL="ready"
  fi

  if [ "$DEEP" = "true" ] && [ "$OPERATION" = "preflight" ]; then
    studio_deep_preflight_result
    PREFLIGHT_RESULT="$?"
  fi

  if { [ "$PREFLIGHT_RESULT" -ge 2 ] 2>/dev/null || official_codex_bundle_exists; }; then
    if [ -f "$HOME/.codex/config.toml" ]; then
      [ "$CODEX_RUNNING" = "true" ] && CODEX="running" || CODEX="stopped"
    else
      CODEX="needs-first-run"
    fi
  fi

  case "$SESSION" in
    active|paused|stale) STUDIO_SESSION="$SESSION" ;;
    unknown) STUDIO_SESSION="stale" ;;
  esac
  if [ "$STUDIO_SESSION" = "active" ] \
    && { [ "$ENGINE_SESSION_READY" != "true" ] || [ "$CODEX" != "running" ]; }; then
    STUDIO_SESSION="stale"
  fi
  CDP_OK="false"
  MANAGED_CDP_READY="false"
  if [ "$DEEP" = "true" ]; then
    if studio_managed_cdp_is_ready "$PORT"; then
      MANAGED_CDP_READY="true"
      VERIFIED="false"
    fi
    if studio_strict_verify "$PORT"; then
      CDP_OK="true"
      MANAGED_CDP_READY="true"
      VERIFIED="true"
    fi
  fi
  if [ "$CODEX_RUNNING" = "true" ] && [ "$CODEX" != "not-installed" ] \
    && [ "$MANAGED_CDP_READY" != "true" ]; then
    REQUIRES_RESTART="true"
  fi

  if [ "$ROLLBACK_LAUNCHER" = "managed-cdp" ] \
    && [ "$ENGINE_CURRENT" = "true" ] \
    && [ "$ENGINE_SESSION_READY" = "true" ]; then
    ACTIONS='["apply","resume","restore","uninstall"]'
  elif [ "$INSTALL" = "ready" ]; then
    case "$STUDIO_SESSION" in
      active) ACTIONS='["pause","resume","restore","verify","uninstall"]' ;;
      paused) ACTIONS='["apply","resume","restore","verify","uninstall"]' ;;
      stale) ACTIONS='["restore","uninstall"]' ;;
      *)
        if [ "$CODEX" = "running" ]; then
          ACTIONS='["apply","restore","verify","uninstall"]'
        else
          ACTIONS='["apply","restore","uninstall"]'
        fi
        ;;
      esac
  elif [ "$ENGINE_OUTDATED" = "true" ] \
    && [ "$ENGINE_SESSION_READY" = "true" ] \
    && [ "$STUDIO_SESSION" != "stale" ]; then
    ACTIONS='["install","restore","uninstall"]'
  elif [ "$LIVE_BACKUP_VALID" = "true" ]; then
    ACTIONS='["restore","uninstall"]'
  elif [ "$ENGINE_PRESENT" = "true" ] && [ "$STUDIO_SESSION" = "stale" ] \
    && [ "$RESTORE_PROOF_VALID" = "true" ]; then
    ACTIONS='["restore","uninstall"]'
  elif [ "$ENGINE_PRESENT" = "true" ] && [ "$STUDIO_SESSION" = "official" ] \
    && [ ! -e "$STATE_PATH" ] && [ ! -L "$STATE_PATH" ] \
    && [ ! -e "$THEME_BACKUP_PATH" ] && [ ! -L "$THEME_BACKUP_PATH" ]; then
    if [ "$RESTORE_PROOF_VALID" = "true" ]; then
      if [ "$ENGINE_CURRENT" = "true" ] || [ "$ENGINE_OUTDATED" = "true" ]; then
        ACTIONS='["install","restore","uninstall"]'
      else
        ACTIONS='["restore","uninstall"]'
      fi
    else
      STUDIO_SESSION="stale"
      ACTIONS='[]'
    fi
  fi
  if [ "$ROLLBACK_EVIDENCE_UNSAFE" = "true" ]; then
    ACTIONS='[]'
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
    if [ "$ROLLBACK_EVIDENCE_UNSAFE" = "true" ]; then
      ERROR='{"code":"STATE_UNSAFE","message":"Renderer rollback evidence is unsafe or damaged.","recoveryActions":["diagnostics","cancel"]}'
    elif [ "$ROLLBACK_LAUNCHER" = "managed-cdp" ]; then
      ERROR='{"code":"STATE_UNSAFE","message":"The managed session needs authorized cleanup before retry.","recoveryActions":["authorize-force-stop","restore","diagnostics","cancel"]}'
    else
      ERROR='{"code":"STATE_UNSAFE","message":"Theme state needs recovery before it can be used.","recoveryActions":["restore","diagnostics","cancel"]}'
    fi
  fi
  case "$PREFLIGHT_RESULT" in
    2)
      OK="false"
      EXIT_CODE=1
      ACTIONS='[]'
      ERROR='{"code":"CODEX_IDENTITY_INVALID","message":"The Codex app identity is invalid.","recoveryActions":["diagnostics","cancel"]}'
      ;;
    3)
      OK="false"
      EXIT_CODE=1
      ACTIONS='[]'
      ERROR='{"code":"RUNTIME_INVALID","message":"The Codex bundled runtime is unavailable.","recoveryActions":["diagnostics","cancel"]}'
      ;;
  esac

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
