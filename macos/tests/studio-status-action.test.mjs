import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const source = (name) => fs.readFileSync(path.join(root, "studio/Sources/CodexDreamSkinStudio", name), "utf8");

const content = source("ContentView.swift");
const app = source("CodexDreamSkinStudioApp.swift");
const menu = source("StatusItemController.swift");
const status = fs.readFileSync(path.join(root, "scripts/status-dream-skin-macos.sh"), "utf8");
const adapter = fs.readFileSync(path.join(root, "scripts/studio-adapter-macos.sh"), "utf8");
assert.match(content, /Button\(action: controller\.refreshStatus\)/);
assert.match(content, /disabled\(!model\.menuState\.statusEnabled\)/);
assert.match(app, /onStatus: \{ \[weak self\] in self\?\.refreshStatus\(\) \}/);
assert.match(menu, /item\("Check Status", #selector\(status\), enabled: menuState\.statusEnabled\)/);
assert.match(status, /renderer_rollback_evidence_is_valid/);
assert.match(adapter, /status_has_action "\$OPERATION"/);

console.log("PASS: macOS Studio exposes one fixed, modeled Status action in window and menu.");
