import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (relative) => fs.readFileSync(path.join(root, relative), "utf8");
const common = read("scripts/common-macos.sh");
const adapter = read("scripts/studio-adapter-macos.sh");
const restore = read("scripts/restore-dream-skin-macos.sh");
const start = read("scripts/start-dream-skin-macos.sh");
const install = read("scripts/install-dream-skin-macos.sh");

const tests = {
  "important-1"() {
    const helperStart = common.indexOf("managed_macos_launcher_is_owned() {");
    assert.ok(helperStart >= 0, "owned macOS launcher cleanup is not centralized");
    const helperEnd = common.indexOf("\n}\n", common.indexOf("remove_managed_macos_launchers() {"));
    const helper = common.slice(helperStart, helperEnd + 2);
    for (const contract of [
      "Codex Dream Skin.command",
      "Codex Dream Skin - Customize.command",
      "Codex Dream Skin - Verify.command",
      "Codex Dream Skin - Restore.command",
      "# CodexDreamSkinStudio launcher",
      "[ -f \"$launcher_path\" ]",
      "[ ! -L \"$launcher_path\" ]",
    ]) assert.ok(helper.includes(contract), `launcher helper is missing: ${contract}`);
    assert.match(helper, /launcher_is_owned[\s\S]*\/bin\/rm -f/, "launcher deletion is not ownership-gated");
    assert.ok(adapter.includes("remove_managed_macos_launchers"), "Studio uninstall bypasses owned launcher cleanup");
    assert.ok(restore.includes("remove_managed_macos_launchers"), "direct uninstall bypasses owned launcher cleanup");
    assert.doesNotMatch(adapter, /\/bin\/rm -f \"\$HOME\/Desktop\/Codex Dream Skin/);
    assert.doesNotMatch(restore, /\/bin\/rm -f \"\$HOME\/Desktop\/Codex Dream Skin/);
  },

  "important-2"() {
    assert.ok(common.includes("saved_managed_listener_is_absent() {"), "listener-absence proof is not shared");
    const gate = restore.indexOf('saved_managed_listener_is_absent "$PORT"');
    const stage = restore.indexOf("\n  stage_live_theme_backup", gate);
    const watcher = restore.indexOf("stop_recorded_injector", gate);
    assert.ok(gate >= 0, "ordinary saved state has no listener-absence gate");
    assert.ok(gate < stage, "restore stages recovery data before listener absence is proven");
    assert.ok(gate < watcher, "restore mutates the watcher before listener absence is proven");
    assert.match(restore, /\[ -f \"\$STATE_PATH\" \][\s\S]*saved_managed_listener_is_absent/, "ordinary state is not covered by the shared listener gate");
  },

  "important-3"() {
    assert.ok(common.includes("write_managed_cdp_recovery_evidence() {"), "early managed CDP failures have no durable evidence writer");
    const evidence = start.indexOf('write_managed_cdp_recovery_evidence "$PORT"');
    const launch = start.indexOf('launch_codex_with_cdp "$PORT"');
    assert.ok(evidence >= 0 && evidence < launch, "managed CDP recovery evidence is not published before launch");
    const verifyFailure = start.indexOf('if [ "$verify_code" -ne 0 ]; then');
    const verifyBody = start.slice(verifyFailure);
    const close = verifyBody.indexOf('stop_codex "$FORCE_STOP_AUTHORIZED"');
    const listener = verifyBody.indexOf('saved_managed_listener_is_absent "$PORT"');
    const stateDelete = verifyBody.indexOf('/bin/rm -f "$STATE_PATH"');
    assert.ok(close >= 0 && listener > close && stateDelete > listener,
      "strict verification discards lifecycle authority before close and listener proof");
    assert.match(start, /rollback_new_managed_cdp_session[\s\S]*write_managed_cdp_recovery_evidence[\s\S]*stop_codex/,
      "early rollback does not retain recovery evidence through close");
  },

  "important-5"() {
    const close = restore.indexOf('stop_codex "$FORCE_STOP_AUTHORIZED"');
    const rollbackWatcher = restore.indexOf("stop_renderer_rollback_watcher");
    assert.ok(close >= 0 && rollbackWatcher > close,
      "rollback watcher is stopped before the authorized Codex close commits");
  },

  "important-6"() {
    assert.doesNotMatch(install, /exec \"\$INSTALL_ROOT\/scripts\/install-dream-skin-macos\.sh\"/,
      "upgrade still replaces the transaction owner with one-way exec");
    for (const contract of [
      "rollback_deployed_project()",
      "snapshot_upgrade_recovery_evidence()",
      "restore_upgrade_recovery_evidence()",
      "DEPLOYED_PREVIOUS_ROOT",
    ]) assert.ok(install.includes(contract), `upgrade transaction is missing: ${contract}`);
    const child = install.indexOf('"$INSTALL_ROOT/scripts/install-dream-skin-macos.sh" "${install_args[@]}"');
    const commit = install.indexOf("\n  commit_deployed_project", child);
    const commitStart = install.indexOf("commit_deployed_project() {");
    const commitBody = install.slice(commitStart, install.indexOf("\n}", commitStart) + 2);
    assert.ok(child >= 0 && commit > child &&
      commitBody.includes("consume_upgrade_snapshot previous-engine") &&
      commitBody.includes('"$DEPLOYED_PREVIOUS_IDENTITY"') &&
      commitBody.includes('"$DEPLOYED_PREVIOUS_DIGEST"'),
    "the exact previous engine is not consumed after in-place initialization succeeds");
  },
};

const selected = process.argv[2];
if (selected) {
  assert.ok(tests[selected], `unknown lifecycle V4 finding: ${selected}`);
  tests[selected]();
  console.log(`PASS: macOS lifecycle V4 ${selected} contract verified.`);
} else {
  for (const test of Object.values(tests)) test();
  console.log("PASS: macOS lifecycle V4 contracts verified.");
}
