import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const fixtures = JSON.parse(fs.readFileSync(path.join(here, "fixtures-v1.json"), "utf8"));
const operations = new Set(["preflight", "install", "apply", "status", "pause", "resume", "restore", "verify", "uninstall"]);
const installs = new Set(["not-installed", "ready"]);
const codexStates = new Set(["not-installed", "needs-first-run", "stopped", "running"]);
const sessions = new Set(["official", "active", "paused", "stale"]);
const operationStates = new Set(["idle", "busy"]);
const availableActions = new Set(["install", "apply", "pause", "resume", "restore", "verify", "uninstall"]);
const recoveryActions = new Set([
  "open-codex", "authorize-restart", "authorize-force-stop", "retry", "restore", "diagnostics", "cancel",
]);
const errorCodes = new Set([
  "INVALID_REQUEST", "OPERATION_BUSY", "CODEX_NOT_INSTALLED", "CODEX_FIRST_RUN_REQUIRED",
  "CODEX_IDENTITY_INVALID", "RUNTIME_INVALID", "CODEX_CLOSE_REQUIRED", "RESTART_REQUIRED",
  "FORCE_STOP_REQUIRED", "STATE_UNSAFE", "PORT_UNAVAILABLE", "CONFIG_UNSAFE", "CONFIG_CHANGED",
  "CONFIG_BACKUP_MISSING", "THEME_INVALID", "INJECTOR_FAILED", "VERIFY_FAILED",
  "LIVE_REMOVE_FAILED", "OPERATION_FAILED", "INTERNAL_ERROR",
]);
const topKeys = ["error", "ok", "operation", "schemaVersion", "state"];
const stateKeys = ["availableActions", "codex", "install", "operation", "requiresRestart", "session", "themeName", "verified"];
const fixtureNames = [
  "not-installed", "needs-first-run", "installed-official", "active-verified", "paused", "stale-state",
  "restart-required", "force-stop-required", "verify-failed", "restored-official",
  "uninstalled-themes-preserved", "uninstalled-themes-deleted",
];

assert(Array.isArray(fixtures));
assert.deepEqual(fixtures.map((fixture) => fixture.name).sort(), fixtureNames.sort());
for (const fixture of fixtures) {
  assert.deepEqual(Object.keys(fixture.response).sort(), topKeys);
  assert.deepEqual(Object.keys(fixture.response.state).sort(), stateKeys);
  assert.equal(fixture.response.schemaVersion, 1);
  assert(operations.has(fixture.response.operation));
  assert(installs.has(fixture.response.state.install));
  assert(codexStates.has(fixture.response.state.codex));
  assert(sessions.has(fixture.response.state.session));
  assert(operationStates.has(fixture.response.state.operation));
  assert([true, false, null].includes(fixture.response.state.verified));
  assert(Array.isArray(fixture.response.state.availableActions));
  assert.equal(new Set(fixture.response.state.availableActions).size, fixture.response.state.availableActions.length);
  assert(fixture.response.state.availableActions.every((action) => availableActions.has(action)));
  if (fixture.response.state.session === "active") {
    assert.equal(fixture.response.state.install, "ready");
    assert.equal(fixture.response.state.codex, "running");
  }
  if (fixture.response.ok && ["apply", "resume", "verify"].includes(fixture.response.operation)) {
    assert.equal(fixture.response.state.verified, true);
  }
  if (fixture.response.ok) {
    assert.equal(fixture.response.error, null);
  } else {
    assert.deepEqual(Object.keys(fixture.response.error).sort(), ["code", "message", "recoveryActions"]);
    assert(errorCodes.has(fixture.response.error.code));
    assert(Array.isArray(fixture.response.error.recoveryActions));
    assert(fixture.response.error.recoveryActions.every((action) => recoveryActions.has(action)));
  }
  const serialized = JSON.stringify(fixture.response);
  assert(!/(?:port|pid|cdp|powershell|\/Users\/|[A-Z]:\\Users\\)/i.test(serialized));
}
console.log("PASS: Studio protocol fixtures v1.");
