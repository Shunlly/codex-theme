import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const app = fs.readFileSync(
  path.join(root, "studio/Sources/CodexDreamSkinStudio/CodexDreamSkinStudioApp.swift"),
  "utf8",
);
const content = fs.readFileSync(
  path.join(root, "studio/Sources/CodexDreamSkinStudio/ContentView.swift"),
  "utf8",
);
const action = app.match(/func diagnostics\(\) \{[\s\S]*?\n    \}/)?.[0] ?? "";

assert.match(content, /Button\(action: controller\.diagnostics\)/);
assert.match(content, /accessibilityLabel\("Check diagnostics"\)/);
assert.match(action, /FileManager\.default\.homeDirectoryForCurrentUser/);
assert.match(action, /"Library\/Application Support\/CodexDreamSkinStudio"/);
assert.match(action, /NSWorkspace\.shared\.open/);
assert.match(action, /NSAlert\(\)/);
assert.doesNotMatch(action, /model\.refresh|Process|\/bin\/|path:/);

console.log("PASS: macOS Diagnostics opens only the fixed support directory and alerts visibly on failure.");
