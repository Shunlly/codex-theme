import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const source = (name) => fs.readFileSync(path.join(root, "studio/Sources/CodexDreamSkinStudio", name), "utf8");

const content = source("ContentView.swift");
const app = source("CodexDreamSkinStudioApp.swift");
const menu = source("StatusItemController.swift");
assert.match(content, /Button\(action: controller\.refreshStatus\)/);
assert.match(content, /disabled\(!model\.menuState\.statusEnabled\)/);
assert.match(app, /onStatus: \{ \[weak self\] in self\?\.refreshStatus\(\) \}/);
assert.match(menu, /item\("Check Status", #selector\(status\), enabled: menuState\.statusEnabled\)/);

console.log("PASS: macOS Studio exposes one fixed, modeled Status action in window and menu.");
