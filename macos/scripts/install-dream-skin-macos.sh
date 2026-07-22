#!/bin/bash

set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd -P)/common-macos.sh"

PORT=9341
CREATE_LAUNCHERS="true"
LAUNCH_AFTER_INSTALL="true"
IN_PLACE="false"
CLOSE_RUNNING="false"
FORCE_STOP_AUTHORIZED="false"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    --no-launchers) CREATE_LAUNCHERS="false"; shift ;;
    --no-launch) LAUNCH_AFTER_INSTALL="false"; shift ;;
    --in-place) IN_PLACE="true"; shift ;;
    --close-running) CLOSE_RUNNING="true"; shift ;;
    --force-stop-authorized) FORCE_STOP_AUTHORIZED="true"; shift ;;
    *) fail "Unknown installer argument: $1" ;;
  esac
done
case "$PORT" in ''|*[!0-9]*) fail "Invalid port: $PORT" ;; esac
[ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] || fail "Port must be between 1024 and 65535."
require_lifecycle_lock

DEPLOYED_PREVIOUS_ROOT=""
UPGRADE_SNAPSHOT_ROOT="${DREAM_SKIN_UPGRADE_SNAPSHOT_ROOT:-}"
UPGRADE_SNAPSHOT_IDENTITY="${DREAM_SKIN_UPGRADE_SNAPSHOT_IDENTITY:-}"
UPGRADE_ORIGINAL_GROUP_IDENTITY="${DREAM_SKIN_UPGRADE_ORIGINAL_GROUP_IDENTITY:-}"
UPGRADE_ORIGINAL_RECEIPT_IDENTITY="${DREAM_SKIN_UPGRADE_ORIGINAL_RECEIPT_IDENTITY:-}"
UPGRADE_ORIGINAL_RECEIPT_DIGEST="${DREAM_SKIN_UPGRADE_ORIGINAL_RECEIPT_DIGEST:-}"
DEPLOYED_PREVIOUS_IDENTITY=""
DEPLOYED_PREVIOUS_DIGEST=""
DEPLOYED_NEW_IDENTITY=""
DEPLOYED_NEW_DIGEST=""
DEPLOY_TRANSACTION_PHASE="none"
PRESERVE_UPGRADE_SNAPSHOT="$([ -n "${DREAM_SKIN_UPGRADE_SNAPSHOT_ROOT:-}" ] && printf true || printf false)"

upgrade_path_identity() {
  [ -e "$1" ] && [ ! -L "$1" ] || return 1
  /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null
}

upgrade_path_digest() {
  local path="$1"
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    /usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}'
  elif [ -d "$path" ] && [ ! -L "$path" ]; then
    COPYFILE_DISABLE=1 /usr/bin/tar -cf - -C "$path" . 2>/dev/null \
      | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
  else
    return 1
  fi
}

capture_upgrade_path() {
  local source_path="$1"
  local snapshot_name="$2"
  local snapshot_group="$3"
  local snapshot_dir="$UPGRADE_SNAPSHOT_ROOT/$snapshot_group"
  local marker_path="$snapshot_dir/$snapshot_name.state"
  local source_identity=""
  local source_digest=""
  local group_identity=""
  /bin/mkdir -p "$snapshot_dir" || return 1
  group_identity="$(upgrade_path_identity "$snapshot_dir")" || return 1
  [ ! -e "$snapshot_dir/$snapshot_name" ] && [ ! -L "$snapshot_dir/$snapshot_name" ] \
    && [ ! -e "$marker_path" ] && [ ! -L "$marker_path" ] || return 1
  if [ -e "$source_path" ] || [ -L "$source_path" ]; then
    [ ! -L "$source_path" ] \
      && { [ -f "$source_path" ] || [ -d "$source_path" ]; } || return 1
    source_identity="$(upgrade_path_identity "$source_path")" || return 1
    source_digest="$(upgrade_path_digest "$source_path")" || return 1
    /bin/cp -pPR "$source_path" "$snapshot_dir/$snapshot_name" || return 1
    [ "$(upgrade_path_identity "$source_path" 2>/dev/null || true)" = "$source_identity" ] \
      && [ "$(upgrade_path_digest "$source_path" 2>/dev/null || true)" = "$source_digest" ] \
      && [ "$(upgrade_path_digest "$snapshot_dir/$snapshot_name" 2>/dev/null || true)" = "$source_digest" ] \
      || return 1
    /usr/bin/printf 'present\n%s\n%s\n' \
      "$source_identity" "$source_digest" \
      > "$marker_path" || return 1
  else
    /usr/bin/printf 'absent\n\n\n' > "$marker_path" || return 1
  fi
  /bin/chmod 600 "$marker_path" || return 1
  [ "$(upgrade_path_identity "$snapshot_dir" 2>/dev/null || true)" = "$group_identity" ]
}

snapshot_upgrade_recovery_evidence() {
  local receipt=""
  ensure_state_root
  UPGRADE_SNAPSHOT_ROOT="$(/usr/bin/mktemp -d "$STATE_ROOT/.upgrade-recovery.XXXXXX")" \
    || fail "Could not create the upgrade recovery snapshot."
  /bin/chmod 700 "$UPGRADE_SNAPSHOT_ROOT"
  UPGRADE_SNAPSHOT_IDENTITY="$(upgrade_path_identity "$UPGRADE_SNAPSHOT_ROOT")" \
    || fail "Could not bind the upgrade recovery snapshot identity."
  capture_upgrade_path "$CONFIG_PATH" config original || fail "Could not snapshot config state."
  capture_upgrade_path "$THEME_BACKUP_PATH" live-backup original || fail "Could not snapshot live backup state."
  capture_upgrade_path "$RESTORED_THEME_BACKUP_PATH" restored-backup original || fail "Could not snapshot restored proof state."
  capture_upgrade_path "$STATE_PATH" lifecycle-state original || fail "Could not snapshot lifecycle state."
  capture_upgrade_path "$THEME_DIR" active-theme original || fail "Could not snapshot active theme state."
  capture_upgrade_path "$STATE_ROOT/themes" theme-library original || fail "Could not snapshot theme library state."
  receipt="$("$NODE" "$SCRIPT_DIR/theme-config.mjs" upgrade-receipt-finalize \
    "$UPGRADE_SNAPSHOT_ROOT" "$UPGRADE_SNAPSHOT_IDENTITY" \
    "$UPGRADE_SNAPSHOT_ROOT/original" original \
    config.state "$CONFIG_PATH" \
    live-backup.state "$THEME_BACKUP_PATH" \
    restored-backup.state "$RESTORED_THEME_BACKUP_PATH" \
    lifecycle-state.state "$STATE_PATH" \
    active-theme.state "$THEME_DIR" \
    theme-library.state "$STATE_ROOT/themes")" \
    || fail "Could not publish the original upgrade recovery receipt."
  IFS='|' read -r UPGRADE_ORIGINAL_GROUP_IDENTITY UPGRADE_ORIGINAL_RECEIPT_IDENTITY \
    UPGRADE_ORIGINAL_RECEIPT_DIGEST _ <<< "$receipt"
  [ -n "$UPGRADE_ORIGINAL_GROUP_IDENTITY" ] \
    && [ -n "$UPGRADE_ORIGINAL_RECEIPT_IDENTITY" ] \
    && [ -n "$UPGRADE_ORIGINAL_RECEIPT_DIGEST" ] \
    || fail "The original upgrade recovery receipt is incomplete."
}

verify_upgrade_receipt_group() {
  local group="$1"
  local entry="${2:-}"
  local candidate="${3:-}"
  local match_mode="${4:-}"
  if [ "$group" = original ]; then
    "$NODE" "$SCRIPT_DIR/theme-config.mjs" upgrade-receipt-verify \
      "$UPGRADE_SNAPSHOT_ROOT" "$UPGRADE_SNAPSHOT_IDENTITY" \
      "$UPGRADE_SNAPSHOT_ROOT/original" \
      "$UPGRADE_ORIGINAL_GROUP_IDENTITY" "$UPGRADE_ORIGINAL_RECEIPT_IDENTITY" \
      "$UPGRADE_ORIGINAL_RECEIPT_DIGEST" "$entry" "$candidate" "$match_mode"
  else
    "$NODE" "$SCRIPT_DIR/theme-config.mjs" upgrade-receipt-verify \
      "$UPGRADE_SNAPSHOT_ROOT" "$UPGRADE_SNAPSHOT_IDENTITY" \
      "$UPGRADE_SNAPSHOT_ROOT/$group" auto "$entry" "$candidate" "$match_mode"
  fi
}

record_upgrade_transaction_path() {
  local source_path="$1"
  local snapshot_name="$2"
  local source_identity=""
  local source_state="absent"
  [ -n "$UPGRADE_SNAPSHOT_ROOT" ] && [ -d "$UPGRADE_SNAPSHOT_ROOT" ] \
    && [ ! -L "$UPGRADE_SNAPSHOT_ROOT" ] || return 0
  [ -z "$UPGRADE_SNAPSHOT_IDENTITY" ] \
    || [ "$(upgrade_path_identity "$UPGRADE_SNAPSHOT_ROOT" 2>/dev/null || true)" = "$UPGRADE_SNAPSHOT_IDENTITY" ] \
    || return 1
  if [ -e "$source_path" ] || [ -L "$source_path" ]; then
    source_state="present"
    source_identity="$(upgrade_path_identity "$source_path")" || return 1
  fi
  MATCHED_UPGRADE_EXPECTED_GROUP="$(
    "$NODE" "$SCRIPT_DIR/theme-config.mjs" upgrade-receipt-capture \
      "$UPGRADE_SNAPSHOT_ROOT" "$UPGRADE_SNAPSHOT_IDENTITY" \
      "$snapshot_name" "$source_path" "$source_state" "$source_identity"
  )" || return 1
  [ -n "$MATCHED_UPGRADE_EXPECTED_GROUP" ]
}

consume_upgrade_original_path() {
  local path="$1"
  local snapshot_name="$2"
  local quarantine="$UPGRADE_SNAPSHOT_ROOT/held-$snapshot_name"
  local original_state=""
  local original_receipt=""
  [ ! -e "$quarantine" ] && [ ! -L "$quarantine" ] || return 1
  original_receipt="$(verify_upgrade_receipt_group original "$snapshot_name.state")" || return 1
  IFS='|' read -r original_state _ _ _ _ <<< "$original_receipt"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    [ "$original_state" = absent ] || return 1
    record_upgrade_transaction_path "$path" "$snapshot_name"
    return
  fi
  "$NODE" "$SCRIPT_DIR/theme-config.mjs" upgrade-receipt-hold \
    "$UPGRADE_SNAPSHOT_ROOT" "$UPGRADE_SNAPSHOT_IDENTITY" \
    "$UPGRADE_SNAPSHOT_ROOT/original" \
    "$UPGRADE_ORIGINAL_GROUP_IDENTITY" "$UPGRADE_ORIGINAL_RECEIPT_IDENTITY" \
      "$UPGRADE_ORIGINAL_RECEIPT_DIGEST" "$snapshot_name.state" "$path" "$quarantine" \
    >/dev/null || return 1
  upgrade_path_matches_snapshot "$quarantine" "$snapshot_name" original
}

upgrade_path_matches_snapshot() {
  verify_upgrade_receipt_group "$3" "$2.state" "$1" identity >/dev/null
}

upgrade_path_matches_any_expected() {
  local path="$1"
  local snapshot_name="$2"
  local expected_dir=""
  MATCHED_UPGRADE_EXPECTED_GROUP=""
  for expected_dir in "$UPGRADE_SNAPSHOT_ROOT"/.expected.*; do
    [ -d "$expected_dir" ] && [ ! -L "$expected_dir" ] || continue
    verify_upgrade_receipt_group "${expected_dir##*/}" "$snapshot_name.state" >/dev/null || continue
    if upgrade_path_matches_snapshot "$path" "$snapshot_name" "${expected_dir##*/}"; then
      MATCHED_UPGRADE_EXPECTED_GROUP="${expected_dir##*/}"
      return 0
    fi
  done
  return 1
}

restore_upgrade_path() {
  local destination_path="$1"
  local snapshot_name="$2"
  local restore_mode="upgrade-receipt-restore"
  local held="$UPGRADE_SNAPSHOT_ROOT/held-$snapshot_name"
  local failed="$UPGRADE_SNAPSHOT_ROOT/failed-$snapshot_name"
  upgrade_path_matches_snapshot "$destination_path" "$snapshot_name" original && return 0
  upgrade_path_matches_any_expected "$destination_path" "$snapshot_name" || return 1
  local expected_group="$MATCHED_UPGRADE_EXPECTED_GROUP"
  [ "$snapshot_name" != config ] || restore_mode="upgrade-receipt-restore-config"
  "$NODE" "$SCRIPT_DIR/theme-config.mjs" "$restore_mode" \
    "$UPGRADE_SNAPSHOT_ROOT" "$UPGRADE_SNAPSHOT_IDENTITY" \
    "$UPGRADE_SNAPSHOT_ROOT/original" \
    "$UPGRADE_ORIGINAL_GROUP_IDENTITY" "$UPGRADE_ORIGINAL_RECEIPT_IDENTITY" \
    "$UPGRADE_ORIGINAL_RECEIPT_DIGEST" \
    "$UPGRADE_SNAPSHOT_ROOT/$expected_group" "$snapshot_name.state" \
    "$destination_path" "$held" "$failed" >/dev/null
}

restore_upgrade_recovery_evidence() {
  local restore_status=0
  [ -n "$UPGRADE_SNAPSHOT_ROOT" ] \
    && [ -d "$UPGRADE_SNAPSHOT_ROOT" ] && [ ! -L "$UPGRADE_SNAPSHOT_ROOT" ] \
    && [ "$(upgrade_path_identity "$UPGRADE_SNAPSHOT_ROOT" 2>/dev/null || true)" = "$UPGRADE_SNAPSHOT_IDENTITY" ] \
    || return 1
  restore_upgrade_path "$CONFIG_PATH" config || restore_status=1
  restore_upgrade_path "$THEME_BACKUP_PATH" live-backup || restore_status=1
  restore_upgrade_path "$RESTORED_THEME_BACKUP_PATH" restored-backup || restore_status=1
  restore_upgrade_path "$STATE_PATH" lifecycle-state || restore_status=1
  restore_upgrade_path "$THEME_DIR" active-theme || restore_status=1
  restore_upgrade_path "$STATE_ROOT/themes" theme-library || restore_status=1
  return "$restore_status"
}

quarantine_upgrade_tree() {
  local source="$1"
  local expected_identity="$2"
  local expected_digest="$3"
  local quarantine="$4"
  [ ! -e "$quarantine" ] && [ ! -L "$quarantine" ] \
    && [ "$(upgrade_path_identity "$source" 2>/dev/null || true)" = "$expected_identity" ] \
    && [ "$(upgrade_path_digest "$source" 2>/dev/null || true)" = "$expected_digest" ] \
    || return 1
  /bin/mv "$source" "$quarantine" || return 1
  [ ! -e "$source" ] && [ ! -L "$source" ] \
    && [ "$(upgrade_path_identity "$quarantine" 2>/dev/null || true)" = "$expected_identity" ] \
    && [ "$(upgrade_path_digest "$quarantine" 2>/dev/null || true)" = "$expected_digest" ]
}

consume_upgrade_snapshot() {
  local expected_entry="${1:-}"
  local expected_entry_identity="${2:-}"
  local expected_entry_digest="${3:-}"
  local snapshot_digest=""
  local cleanup_root=""
  local cleanup_identity=""
  local expected_dir=""
  verify_upgrade_receipt_group original >/dev/null || return 1
  for expected_dir in "$UPGRADE_SNAPSHOT_ROOT"/.expected.*; do
    [ -e "$expected_dir" ] || [ -L "$expected_dir" ] || continue
    verify_upgrade_receipt_group "${expected_dir##*/}" >/dev/null || return 1
  done
  snapshot_digest="$(upgrade_path_digest "$UPGRADE_SNAPSHOT_ROOT")" || return 1
  cleanup_root="$(/usr/bin/mktemp -d "$STATE_ROOT/.upgrade-cleanup.XXXXXX")" || return 1
  /bin/chmod 700 "$cleanup_root" || return 1
  cleanup_identity="$(upgrade_path_identity "$cleanup_root")" || return 1
  quarantine_upgrade_tree "$UPGRADE_SNAPSHOT_ROOT" "$UPGRADE_SNAPSHOT_IDENTITY" \
    "$snapshot_digest" "$cleanup_root/snapshot" || return 1
  [ "$(upgrade_path_identity "$cleanup_root" 2>/dev/null || true)" = "$cleanup_identity" ] \
    || return 1
  if [ -n "$expected_entry" ]; then
    [ "$(upgrade_path_identity "$cleanup_root/snapshot/$expected_entry" 2>/dev/null || true)" = \
      "$expected_entry_identity" ] \
      && [ "$(upgrade_path_digest "$cleanup_root/snapshot/$expected_entry" 2>/dev/null || true)" = \
        "$expected_entry_digest" ] || return 1
  fi
  "$NODE" "$SCRIPT_DIR/theme-config.mjs" upgrade-consume-tree \
    "$cleanup_root" "$cleanup_identity" >/dev/null || return 1
  [ ! -e "$cleanup_root" ] && [ ! -L "$cleanup_root" ]
}

rollback_deployed_project() {
  local failed_root="$UPGRADE_SNAPSHOT_ROOT/failed-engine"
  local failed_engine_captured="false"
  local rollback_status=0
  [ "$DEPLOY_TRANSACTION_PHASE" != "none" ] || return 0
  PRESERVE_UPGRADE_SNAPSHOT="true"
  [ "$(upgrade_path_identity "$UPGRADE_SNAPSHOT_ROOT" 2>/dev/null || true)" = "$UPGRADE_SNAPSHOT_IDENTITY" ] \
    || return 1
  [ ! -e "$failed_root" ] && [ ! -L "$failed_root" ] || return 1
  if [ -e "$INSTALL_ROOT" ] || [ -L "$INSTALL_ROOT" ]; then
    [ "$DEPLOY_TRANSACTION_PHASE" != "previous-held" ] || return 1
    [ -d "$INSTALL_ROOT" ] && [ ! -L "$INSTALL_ROOT" ] || return 1
    [ "$(upgrade_path_identity "$INSTALL_ROOT")" = "$DEPLOYED_NEW_IDENTITY" ] \
      && [ "$(upgrade_path_digest "$INSTALL_ROOT")" = "$DEPLOYED_NEW_DIGEST" ] \
      || return 1
    quarantine_upgrade_tree "$INSTALL_ROOT" "$DEPLOYED_NEW_IDENTITY" \
      "$DEPLOYED_NEW_DIGEST" "$failed_root" \
      || return 1
    failed_engine_captured="true"
  fi
  if [ -n "$DEPLOYED_PREVIOUS_ROOT" ] \
    && { [ -e "$DEPLOYED_PREVIOUS_ROOT" ] || [ -L "$DEPLOYED_PREVIOUS_ROOT" ]; }; then
    [ -d "$DEPLOYED_PREVIOUS_ROOT" ] && [ ! -L "$DEPLOYED_PREVIOUS_ROOT" ] \
      && [ "$(upgrade_path_identity "$DEPLOYED_PREVIOUS_ROOT")" = "$DEPLOYED_PREVIOUS_IDENTITY" ] \
      && [ "$(upgrade_path_digest "$DEPLOYED_PREVIOUS_ROOT")" = "$DEPLOYED_PREVIOUS_DIGEST" ] \
      && [ ! -e "$INSTALL_ROOT" ] && [ ! -L "$INSTALL_ROOT" ] \
      && /bin/mv -n "$DEPLOYED_PREVIOUS_ROOT" "$INSTALL_ROOT" \
      && [ ! -e "$DEPLOYED_PREVIOUS_ROOT" ] && [ ! -L "$DEPLOYED_PREVIOUS_ROOT" ] \
      && [ "$(upgrade_path_identity "$INSTALL_ROOT" 2>/dev/null || true)" = "$DEPLOYED_PREVIOUS_IDENTITY" ] \
      && [ "$(upgrade_path_digest "$INSTALL_ROOT" 2>/dev/null || true)" = "$DEPLOYED_PREVIOUS_DIGEST" ] \
      || return 1
  fi
  restore_upgrade_recovery_evidence || rollback_status=1
  if [ "$rollback_status" -eq 0 ]; then
    if [ "$failed_engine_captured" = "true" ]; then
      consume_upgrade_snapshot failed-engine "$DEPLOYED_NEW_IDENTITY" "$DEPLOYED_NEW_DIGEST" \
        || rollback_status=1
    else
      consume_upgrade_snapshot || rollback_status=1
    fi
  fi
  [ "$rollback_status" -eq 0 ] || PRESERVE_UPGRADE_SNAPSHOT="true"
  [ "$rollback_status" -ne 0 ] || PRESERVE_UPGRADE_SNAPSHOT="false"
  DEPLOY_TRANSACTION_PHASE="none"
  return "$rollback_status"
}

commit_deployed_project() {
  [ "$DEPLOY_TRANSACTION_PHASE" = "active" ] || return 1
  PRESERVE_UPGRADE_SNAPSHOT="true"
  [ "$(upgrade_path_identity "$INSTALL_ROOT" 2>/dev/null || true)" = "$DEPLOYED_NEW_IDENTITY" ] \
    && [ "$(upgrade_path_digest "$INSTALL_ROOT" 2>/dev/null || true)" = "$DEPLOYED_NEW_DIGEST" ] \
    || return 1
  if [ -n "$DEPLOYED_PREVIOUS_ROOT" ]; then
    consume_upgrade_snapshot previous-engine "$DEPLOYED_PREVIOUS_IDENTITY" \
      "$DEPLOYED_PREVIOUS_DIGEST" || return 1
  else
    consume_upgrade_snapshot || return 1
  fi
  PRESERVE_UPGRADE_SNAPSHOT="false"
  DEPLOY_TRANSACTION_PHASE="none"
}

cleanup_install_transaction() {
  local exit_code="$1"
  trap - EXIT
  if [ "$DEPLOY_TRANSACTION_PHASE" != "none" ] && ! rollback_deployed_project; then
    printf 'Codex Dream Skin Studio: upgrade rollback needs manual recovery; preserved snapshot: %s\n' \
      "$UPGRADE_SNAPSHOT_ROOT" >&2
    exit_code=1
  fi
  if [ "$PRESERVE_UPGRADE_SNAPSHOT" != "true" ] \
    && [ -n "$UPGRADE_SNAPSHOT_ROOT" ] \
    && [ -d "$UPGRADE_SNAPSHOT_ROOT" ] && [ ! -L "$UPGRADE_SNAPSHOT_ROOT" ] \
    && [ "$(upgrade_path_identity "$UPGRADE_SNAPSHOT_ROOT" 2>/dev/null || true)" = \
      "$UPGRADE_SNAPSHOT_IDENTITY" ]; then
    /bin/rm -rf "$UPGRADE_SNAPSHOT_ROOT" || exit_code=1
  fi
  release_lifecycle_lock || exit_code=1
  exit "$exit_code"
}
trap 'cleanup_install_transaction "$?"' EXIT

deploy_project() {
  local temporary="$INSTALL_ROOT.installing.$$"
  local previous="$UPGRADE_SNAPSHOT_ROOT/previous-engine"
  [ ! -e "$temporary" ] && [ ! -L "$temporary" ] \
    || fail "An upgrade transaction path already exists: $temporary"
  [ ! -e "$previous" ] && [ ! -L "$previous" ] \
    || fail "A previous upgrade transaction path already exists: $previous"
  /bin/mkdir -p "$temporary"
  /usr/bin/rsync -a \
    --exclude '.git/' \
    --exclude '.DS_Store' \
    --exclude 'release/' \
    --exclude 'runtime/' \
    "$PROJECT_ROOT/" "$temporary/"
  /bin/chmod 700 "$temporary"/*.command "$temporary"/scripts/*.sh 2>/dev/null || true
  DEPLOYED_NEW_IDENTITY="$(upgrade_path_identity "$temporary")" \
    || fail "Could not bind the staged engine identity."
  DEPLOYED_NEW_DIGEST="$(upgrade_path_digest "$temporary")" \
    || fail "Could not bind the staged engine bytes."
  if [ -e "$INSTALL_ROOT" ] || [ -L "$INSTALL_ROOT" ]; then
    [ -d "$INSTALL_ROOT" ] && [ ! -L "$INSTALL_ROOT" ] \
      || fail "The existing install root is not a safe directory: $INSTALL_ROOT"
    DEPLOYED_PREVIOUS_IDENTITY="$(upgrade_path_identity "$INSTALL_ROOT")" \
      || fail "Could not bind the previous engine identity."
    DEPLOYED_PREVIOUS_DIGEST="$(upgrade_path_digest "$INSTALL_ROOT")" \
      || fail "Could not bind the previous engine bytes."
    DEPLOYED_PREVIOUS_ROOT="$previous"
    DEPLOY_TRANSACTION_PHASE="previous-held"
    /bin/mv "$INSTALL_ROOT" "$previous"
    [ "$(upgrade_path_identity "$previous" 2>/dev/null || true)" = "$DEPLOYED_PREVIOUS_IDENTITY" ] \
      && [ "$(upgrade_path_digest "$previous" 2>/dev/null || true)" = "$DEPLOYED_PREVIOUS_DIGEST" ] \
      || { PRESERVE_UPGRADE_SNAPSHOT="true"; fail "The previous engine changed during the upgrade swap."; }
  fi
  if ! /bin/mv "$temporary" "$INSTALL_ROOT"; then
    PRESERVE_UPGRADE_SNAPSHOT="true"
    fail "Could not install the project at $INSTALL_ROOT"
  fi
  DEPLOY_TRANSACTION_PHASE="new-published"
  [ "$(upgrade_path_identity "$INSTALL_ROOT" 2>/dev/null || true)" = "$DEPLOYED_NEW_IDENTITY" ] \
    && [ "$(upgrade_path_digest "$INSTALL_ROOT" 2>/dev/null || true)" = "$DEPLOYED_NEW_DIGEST" ] \
    || { PRESERVE_UPGRADE_SNAPSHOT="true"; fail "The installed engine changed during the upgrade swap."; }
  /usr/bin/printf '%s\n%s\n%s\n%s\n' \
    "$DEPLOYED_PREVIOUS_IDENTITY" "$DEPLOYED_PREVIOUS_DIGEST" \
    "$DEPLOYED_NEW_IDENTITY" "$DEPLOYED_NEW_DIGEST" \
    > "$UPGRADE_SNAPSHOT_ROOT/engine.state" \
    || fail "Could not record the engine transaction identities."
  /bin/chmod 600 "$UPGRADE_SNAPSHOT_ROOT/engine.state"
  DEPLOY_TRANSACTION_PHASE="active"
}

discover_codex_app
require_macos_runtime
if [ "$IN_PLACE" = "false" ] && [ "$PROJECT_ROOT" != "$INSTALL_ROOT" ]; then
  /bin/mkdir -p "$(dirname "$INSTALL_ROOT")"
  snapshot_upgrade_recovery_evidence
  PRESERVE_UPGRADE_SNAPSHOT="true"
fi
if codex_is_running; then
  [ "$CLOSE_RUNNING" = "true" ] || fail "Close Codex before installation so config.toml cannot be rewritten while the app is saving it."
  stop_codex "$FORCE_STOP_AUTHORIZED"
fi
if [ -f "$STATE_PATH" ]; then
  stop_recorded_injector \
    || fail "Could not stop the recorded injector; the installed engine was preserved."
  if [ -n "$UPGRADE_SNAPSHOT_ROOT" ]; then
    if ! consume_upgrade_original_path "$STATE_PATH" lifecycle-state; then
      PRESERVE_UPGRADE_SNAPSHOT="true"
      fail "Lifecycle state changed during upgrade cleanup; recovery data was preserved."
    fi
  else
    /bin/rm -f "$STATE_PATH"
  fi
fi

if [ "$IN_PLACE" = "false" ] && [ "$PROJECT_ROOT" != "$INSTALL_ROOT" ]; then
  deploy_project
  install_args=(--in-place --port "$PORT")
  [ "$CREATE_LAUNCHERS" = "true" ] || install_args+=(--no-launchers)
  [ "$LAUNCH_AFTER_INSTALL" = "true" ] || install_args+=(--no-launch)
  [ "$CLOSE_RUNNING" != "true" ] || install_args+=(--close-running)
  [ "$FORCE_STOP_AUTHORIZED" != "true" ] || install_args+=(--force-stop-authorized)
  set +e
  DREAM_SKIN_UPGRADE_SNAPSHOT_ROOT="$UPGRADE_SNAPSHOT_ROOT" \
    DREAM_SKIN_UPGRADE_SNAPSHOT_IDENTITY="$UPGRADE_SNAPSHOT_IDENTITY" \
    DREAM_SKIN_UPGRADE_ORIGINAL_GROUP_IDENTITY="$UPGRADE_ORIGINAL_GROUP_IDENTITY" \
    DREAM_SKIN_UPGRADE_ORIGINAL_RECEIPT_IDENTITY="$UPGRADE_ORIGINAL_RECEIPT_IDENTITY" \
    DREAM_SKIN_UPGRADE_ORIGINAL_RECEIPT_DIGEST="$UPGRADE_ORIGINAL_RECEIPT_DIGEST" \
    "$INSTALL_ROOT/scripts/install-dream-skin-macos.sh" "${install_args[@]}"
  install_exit="$?"
  set -e
  if [ "$install_exit" -ne 0 ]; then
    rollback_deployed_project \
      || fail "The new engine failed to initialize and automatic upgrade rollback needs manual recovery."
    exit "$install_exit"
  fi
  commit_deployed_project \
    || fail "The new engine initialized, but the upgrade transaction could not commit safely."
  exit 0
fi

ensure_state_root
seed_bundled_presets
if [ ! -f "$THEME_DIR/theme.json" ]; then
  if [ -n "$UPGRADE_SNAPSHOT_ROOT" ]; then
    active_stage="$(/usr/bin/mktemp -d "$UPGRADE_SNAPSHOT_ROOT/staged-active-theme.XXXXXX")" \
      || fail "Could not stage the default active theme."
    "$NODE" "$SCRIPT_DIR/stage-theme.mjs" \
      "$STATE_ROOT/themes/preset-midnight-aurora" "$active_stage" >/dev/null \
      || fail "Could not stage the default active theme."
    "$NODE" "$INJECTOR" --check-payload --theme-dir "$active_stage" >/dev/null \
      || fail "The default active theme failed validation."
    record_upgrade_transaction_path "$active_stage" active-theme \
      && upgrade_path_matches_any_expected "$active_stage" active-theme \
      || fail "Could not record the active-theme initialization transaction state."
    "$NODE" "$SCRIPT_DIR/theme-config.mjs" upgrade-receipt-replace \
      "$UPGRADE_SNAPSHOT_ROOT" "$UPGRADE_SNAPSHOT_IDENTITY" \
      "$UPGRADE_SNAPSHOT_ROOT/original" \
      "$UPGRADE_ORIGINAL_GROUP_IDENTITY" "$UPGRADE_ORIGINAL_RECEIPT_IDENTITY" \
      "$UPGRADE_ORIGINAL_RECEIPT_DIGEST" \
      "$UPGRADE_SNAPSHOT_ROOT/$MATCHED_UPGRADE_EXPECTED_GROUP" \
      active-theme.state "$active_stage" "$THEME_DIR" \
      "$UPGRADE_SNAPSHOT_ROOT/held-active-theme" >/dev/null \
      || fail "Could not publish the default active theme transactionally."
  else
    "$SCRIPT_DIR/switch-theme-macos.sh" --id preset-midnight-aurora --no-apply >/dev/null
  fi
fi
[ -f "$CONFIG_PATH" ] || fail "Codex config not found: $CONFIG_PATH. Launch Codex once, close it, and rerun the installer."
"$NODE" "$INJECTOR" --check-payload --theme-dir "$THEME_DIR" >/dev/null
"$NODE" "$SCRIPT_DIR/theme-config.mjs" install "$CONFIG_PATH" "$THEME_BACKUP_PATH"
[ -f "$THEME_BACKUP_PATH" ] && [ ! -L "$THEME_BACKUP_PATH" ] \
  || fail "The live theme recovery backup is not a safe regular file."
if [ -e "$RESTORED_THEME_BACKUP_PATH" ] || [ -L "$RESTORED_THEME_BACKUP_PATH" ]; then
  [ -f "$RESTORED_THEME_BACKUP_PATH" ] && [ ! -L "$RESTORED_THEME_BACKUP_PATH" ] \
    || fail "The completed-restore proof path is unsafe; the new live backup was preserved."
  if [ -n "$UPGRADE_SNAPSHOT_ROOT" ]; then
    if ! consume_upgrade_original_path "$RESTORED_THEME_BACKUP_PATH" restored-backup; then
      PRESERVE_UPGRADE_SNAPSHOT="true"
      fail "Could not invalidate the previous completed-restore proof safely; the new live backup was preserved."
    fi
  else
    /bin/rm -f "$RESTORED_THEME_BACKUP_PATH" \
      || fail "Could not invalidate the previous completed-restore proof; the new live backup was preserved."
  fi
  [ ! -e "$RESTORED_THEME_BACKUP_PATH" ] && [ ! -L "$RESTORED_THEME_BACKUP_PATH" ] \
    || fail "The previous completed-restore proof still exists; the new live backup was preserved."
fi
shell_quote() {
  "$NODE" -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

write_launcher() {
  local target="$1"
  local command="$2"
  if [ -e "$target" ] && ! /usr/bin/grep -q '^# CodexDreamSkinStudio launcher$' "$target" 2>/dev/null; then
    fail "Refusing to overwrite an unrelated Desktop file: $target"
  fi
  /usr/bin/printf '%s\n' \
    '#!/bin/bash' \
    '# CodexDreamSkinStudio launcher' \
    'set -e' \
    "$command" > "$target"
  /bin/chmod 700 "$target"
}

if [ "$CREATE_LAUNCHERS" = "true" ]; then
  /bin/mkdir -p "$HOME/Desktop"
  start_script="$(shell_quote "$SCRIPT_DIR/start-dream-skin-macos.sh")"
  customize_script="$(shell_quote "$SCRIPT_DIR/customize-theme-macos.sh")"
  verify_script="$(shell_quote "$SCRIPT_DIR/verify-dream-skin-macos.sh")"
  restore_script="$(shell_quote "$SCRIPT_DIR/restore-dream-skin-macos.sh")"
  screenshot="$(shell_quote "$HOME/Desktop/Codex Dream Skin Verification.png")"
  write_launcher "$HOME/Desktop/Codex Dream Skin.command" "exec $start_script --port $PORT --prompt-restart"
  write_launcher "$HOME/Desktop/Codex Dream Skin - Customize.command" "exec $customize_script"
  write_launcher "$HOME/Desktop/Codex Dream Skin - Verify.command" "$verify_script --screenshot $screenshot && /usr/bin/open $screenshot"
  write_launcher "$HOME/Desktop/Codex Dream Skin - Restore.command" "exec $restore_script --restore-base-theme --restart-codex"
fi

printf 'Codex Dream Skin Studio %s installed at %s for Codex %s using its signed Node.js %s.\n' \
  "$SKIN_VERSION" "$PROJECT_ROOT" "$CODEX_VERSION" "$NODE_VERSION"
printf 'Use the Desktop launchers to customize, start, verify, or restore the official appearance.\n'
printf 'Bundled presets are ready in your theme library — pick one from the menu bar (已保存的主题) or switch-theme.\n'

if [ "$LAUNCH_AFTER_INSTALL" = "true" ]; then
  "$SCRIPT_DIR/start-dream-skin-macos.sh" --port "$PORT" --prompt-restart
fi
