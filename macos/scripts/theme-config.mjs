import fs from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";

const [mode, configPath, backupPath] = process.argv.slice(2);
// Backup these keys so Restore can put them back. Do NOT force dark —
// Dream Skin CSS auto-adapts to light/dark via data-dream-shell.
const settings = new Map([
  ["appearanceTheme", null],
  ["appearanceDarkCodeThemeId", null],
]);
const targetKeys = [
  "appearanceTheme",
  "appearanceLightCodeThemeId",
  "appearanceDarkCodeThemeId",
];

if (!["install", "restore"].includes(mode) || !configPath || !backupPath) {
  throw new Error("Usage: theme-config.mjs <install|restore> <config-path> <backup-path>");
}

function desktopSection(content) {
  const headers = [...content.matchAll(/^(?:\uFEFF)?[\t ]*\[[\t ]*desktop[\t ]*\][\t ]*(?:#[^\r\n]*)?(?:\r?\n|$)/gm)];
  if (headers.length > 1) throw new Error("Refusing to rewrite multiple [desktop] tables.");
  const header = headers[0];
  if (!header) return null;
  const bodyStart = header.index + header[0].length;
  const remainder = content.slice(bodyStart);
  const nextHeader = /^[\t ]*\[/m.exec(remainder);
  const bodyEnd = nextHeader ? bodyStart + nextHeader.index : content.length;
  return { bodyStart, bodyEnd, body: content.slice(bodyStart, bodyEnd) };
}

function assertNoAmbiguousDesktopTables(content) {
  const desktopAlias = escapedBasicKeyPattern("desktop");
  const patterns = [
    /^(?:\uFEFF)?[\t ]*\[[\t ]*["']desktop["'][\t ]*\][\t ]*(?:#[^\r\n]*)?(?:\r?\n|$)/gm,
    /^(?:\uFEFF)?[\t ]*\[[\t ]*"[^"\r\n]*\\[^"\r\n]*"[\t ]*\][\t ]*(?:#[^\r\n]*)?(?:\r?\n|$)/gm,
    /^(?:\uFEFF)?[\t ]*\[\[[\t ]*(?:desktop|["']desktop["'])(?:[\t ]*\.|[\t ]*\]\])/gm,
    /^(?:\uFEFF)?[\t ]*\[[\t ]*(?:desktop|["']desktop["'])[\t ]*\./gm,
    new RegExp(`^(?:\\uFEFF)?[\\t ]*\\[\\[?[\\t ]*"${desktopAlias}"`, "gm"),
  ];
  if (patterns.some((pattern) => pattern.test(content))) {
    throw new Error("Refusing to rewrite an aliased or nested [desktop] table.");
  }

  const firstHeader = /^(?:\uFEFF)?[\t ]*\[/m.exec(content);
  const root = content.slice(0, firstHeader?.index ?? content.length);
  const rootPatterns = [
    /^(?:\uFEFF)?[\t ]*(?:desktop|["']desktop["'])[\t ]*(?:=|\.)/m,
    new RegExp(`^(?:\\uFEFF)?[\\t ]*"${desktopAlias}"[\\t ]*(?:=|\\.)`, "m"),
  ];
  if (rootPatterns.some((pattern) => pattern.test(root))) {
    throw new Error("Refusing to rewrite a dotted or inline desktop alias.");
  }
}

function assertNoAmbiguousSettings(body) {
  const keys = targetKeys.join("|");
  const escapedKeys = targetKeys.map(escapedBasicKeyPattern).join("|");
  const patterns = [
    new RegExp(`^[\\t ]+(?:${keys})[\\t ]*=`, "m"),
    new RegExp(`^[\\t ]*[\"'](?:${keys})[\"'][\\t ]*(?:=|\\.)`, "m"),
    new RegExp(`^[\\t ]*(?:${keys})[\\t ]*\\.`, "m"),
    new RegExp(`^[\\t ]*"(?:${escapedKeys})"[\\t ]*(?:=|\\.)`, "m"),
  ];
  if (patterns.some((pattern) => pattern.test(body))) {
    throw new Error("Refusing to rewrite aliased, dotted, or indented appearance settings.");
  }
  for (const key of targetKeys) {
    for (const line of settingLines(body, key).matches) {
      if (!validBackupAssignment(line, key)) {
        throw new Error(`Refusing to rewrite a non-string ${key} setting.`);
      }
    }
  }
}

function escapedBasicKeyPattern(key) {
  const hexPattern = (value, width) => value.toString(16).padStart(width, "0")
    .replace(/[a-f]/g, (digit) => `[${digit}${digit.toUpperCase()}]`);
  return [...key].map((character) => {
    const literal = character.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const value = character.codePointAt(0);
    return `(?:${literal}|\\\\u${hexPattern(value, 4)}|\\\\U${hexPattern(value, 8)})`;
  }).join("");
}

function assertEditableToml(content) {
  assertSupportedTomlLayout(content);
  assertNoAmbiguousDesktopTables(content);
  const section = desktopSection(content);
  if (section) assertNoAmbiguousSettings(section.body);
}

function tomlStructureForLine(line) {
  let result = "";
  let quote = null;
  let escaped = false;
  for (const character of line) {
    if (quote === '"') {
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === quote) {
        quote = null;
      }
      continue;
    }
    if (quote === "'") {
      if (character === quote) quote = null;
      continue;
    }
    if (character === '"' || character === "'") {
      quote = character;
    } else if (character === "#") {
      break;
    } else {
      result += character;
    }
  }
  return result;
}

function assertSupportedTomlLayout(content) {
  for (const line of content.split(/\r?\n/)) {
    const structure = tomlStructureForLine(line);
    const assignment = structure.indexOf("=");
    if (assignment < 0) continue;
    let depth = 0;
    for (const character of structure.slice(assignment + 1)) {
      if (character === "[") depth += 1;
      if (character === "]") depth -= 1;
    }
    if (depth > 0) {
      throw new Error("Refusing to rewrite TOML containing multiline arrays.");
    }
  }
}

function settingLines(body, key) {
  const token = key.replace(/[.*+?^${}()|[\\]\\]/g, "\\$&");
  const matches = body.match(new RegExp(`^${token}[\\t ]*=.*$`, "gm")) ?? [];
  if (matches.length > 1) throw new Error(`Refusing to rewrite duplicate ${key} settings.`);
  return { matches, token };
}

function hexDigitValue(character) {
  const code = character?.charCodeAt(0);
  if (code >= 0x30 && code <= 0x39) return code - 0x30;
  if (code >= 0x41 && code <= 0x46) return code - 0x41 + 10;
  if (code >= 0x61 && code <= 0x66) return code - 0x61 + 10;
  return -1;
}

function tomlStringEnd(line, start) {
  const quote = line[start];
  if (quote !== `"` && quote !== `'`) return -1;
  let index = start + 1;
  while (index < line.length) {
    const character = line[index];
    if (character === quote) return index + 1;
    if (quote === `"` && character === "\\") {
      index += 1;
      if (index >= line.length) return -1;
      const escape = line[index];
      if ([`"`, "\\", "b", "t", "n", "f", "r"].includes(escape)) {
        index += 1;
        continue;
      }
      if (escape !== "u" && escape !== "U") return -1;
      const digits = escape === "u" ? 4 : 8;
      let scalar = 0;
      for (let offset = 1; offset <= digits; offset += 1) {
        const digit = hexDigitValue(line[index + offset]);
        if (digit < 0) return -1;
        scalar = (scalar * 16) + digit;
      }
      if (scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) return -1;
      index += digits + 1;
      continue;
    }
    const code = line.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const low = line.charCodeAt(index + 1);
      if (low < 0xdc00 || low > 0xdfff) return -1;
      index += 2;
      continue;
    }
    if (code >= 0xdc00 && code <= 0xdfff) return -1;
    index += 1;
  }
  return -1;
}

function validBackupAssignment(line, key) {
  if (
    typeof line !== "string"
    || /[\u0000-\u0008\u000a-\u001f\u007f-\u009f\u2028\u2029]/u.test(line)
    || !line.startsWith(key)
  ) {
    return false;
  }
  let index = key.length;
  while (line[index] === " " || line[index] === "\t") index += 1;
  if (line[index] !== "=") return false;
  index += 1;
  while (line[index] === " " || line[index] === "\t") index += 1;
  index = tomlStringEnd(line, index);
  if (index < 0) return false;
  while (line[index] === " " || line[index] === "\t") index += 1;
  return index === line.length || line[index] === "#";
}

function validateBackup(backup) {
  if (
    backup?.schemaVersion !== 1
    || backup.platform !== "darwin"
    || backup.configPath !== configPath
    || !backup.values
    || typeof backup.values !== "object"
    || Array.isArray(backup.values)
  ) {
    throw new Error("Theme backup identity or schema does not match this config; nothing was restored.");
  }
  const expectedKeys = [...settings.keys()];
  const actualKeys = Object.keys(backup.values);
  if (
    actualKeys.length !== expectedKeys.length
    || actualKeys.some((key) => !settings.has(key))
    || expectedKeys.some((key) => !Object.hasOwn(backup.values, key))
  ) {
    throw new Error("Theme backup contains unexpected or missing settings; nothing was restored.");
  }
  for (const key of expectedKeys) {
    const line = backup.values[key];
    if (line === null) continue;
    if (!validBackupAssignment(line, key)) {
      throw new Error(`Theme backup contains an invalid ${key} assignment; nothing was restored.`);
    }
  }
}

function replaceSetting(body, key, line, preferredNewline) {
  const { token } = settingLines(body, key);
  const pattern = new RegExp(`^${token}[\\t ]*=.*(?:\\r?\\n)?`, "m");
  const newline = body.includes("\r\n") ? "\r\n" : preferredNewline;
  if (line === null) return body.replace(pattern, "");
  if (pattern.test(body)) return body.replace(pattern, `${line}${newline}`);
  const separator = body.length && !body.endsWith("\n") ? newline : "";
  return `${body}${separator}${line}${newline}`;
}

async function atomicWrite(file, value, modeBits, expectedBytes = null, expectedStat = null) {
  const temporary = `${file}.${process.pid}.${randomUUID()}.tmp`;
  try {
    await fs.writeFile(temporary, value, { mode: modeBits, flag: "wx" });
    if (expectedBytes) await assertConfigUnchanged(expectedBytes, expectedStat);
    await fs.rename(temporary, file);
    await fs.chmod(file, modeBits);
  } finally {
    await fs.rm(temporary, { force: true }).catch(() => {});
  }
}

function decodeStrictUtf8(bytes, label) {
  const content = bytes.toString("utf8");
  if (!Buffer.from(content, "utf8").equals(bytes)) {
    throw new Error(`${label} is not valid UTF-8; nothing was changed.`);
  }
  if (content.includes("\0")) {
    throw new Error(`${label} contains NUL characters; nothing was changed.`);
  }
  return content;
}

async function readStableRegularFile(file, invalidMessage) {
  const handle = await fs.open(file, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const opened = await handle.stat({ bigint: true });
    const linked = await fs.lstat(file, { bigint: true });
    if (!opened.isFile() || !linked.isFile() || opened.dev !== linked.dev || opened.ino !== linked.ino) {
      throw new Error(invalidMessage);
    }
    const bytes = await handle.readFile();
    const after = await handle.stat({ bigint: true });
    const linkedAfter = await fs.lstat(file, { bigint: true });
    if (
      !linkedAfter.isFile()
      || opened.dev !== after.dev
      || opened.ino !== after.ino
      || opened.size !== after.size
      || opened.mtimeNs !== after.mtimeNs
      || opened.dev !== linkedAfter.dev
      || opened.ino !== linkedAfter.ino
    ) {
      throw new Error("Theme backup identity changed while it was being read; nothing was changed.");
    }
    return bytes;
  } finally {
    await handle.close();
  }
}

async function acquireConfigLock() {
  const lockPath = `${configPath}.dream-skin.lock`;
  const deadline = Date.now() + 5000;
  while (true) {
    let created = false;
    try {
      await fs.mkdir(lockPath, { mode: 0o700 });
      created = true;
      await fs.writeFile(
        path.join(lockPath, "owner.json"),
        `${JSON.stringify({ pid: process.pid, createdAt: new Date().toISOString() })}\n`,
        { mode: 0o600, flag: "wx" },
      );
      return async () => fs.rm(lockPath, { recursive: true, force: true });
    } catch (error) {
      if (created) {
        await fs.rm(lockPath, { recursive: true, force: true }).catch(() => {});
        throw error;
      }
      if (error.code !== "EEXIST") {
        throw error;
      }
      const lockStat = await fs.lstat(lockPath).catch(() => null);
      if (lockStat?.isSymbolicLink() || (lockStat && !lockStat.isDirectory())) {
        throw new Error(`Unsafe config lock path: ${lockPath}`);
      }
      if (lockStat && Date.now() - lockStat.mtimeMs > 30000) {
        let ownerAlive = false;
        try {
          const owner = JSON.parse(await fs.readFile(path.join(lockPath, "owner.json"), "utf8"));
          if (Number.isSafeInteger(owner.pid) && owner.pid > 0) {
            try {
              process.kill(owner.pid, 0);
              ownerAlive = true;
            } catch (probeError) {
              ownerAlive = probeError.code === "EPERM";
            }
          }
        } catch {}
        if (!ownerAlive) {
          await fs.rm(lockPath, { recursive: true, force: true });
          continue;
        }
      }
      if (Date.now() >= deadline) {
        throw new Error("Another Dream Skin config operation is still running; try again shortly.");
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }
}

async function assertConfigUnchanged(expectedBytes, expectedStat = null) {
  const currentStat = await fs.lstat(configPath);
  if (
    currentStat.isSymbolicLink()
    || !currentStat.isFile()
    || (expectedStat && (currentStat.dev !== expectedStat.dev || currentStat.ino !== expectedStat.ino))
  ) {
    throw new Error("Codex config file identity changed during this operation; nothing was overwritten.");
  }
  const currentBytes = await fs.readFile(configPath);
  if (!currentBytes.equals(expectedBytes)) {
    throw new Error("Codex config changed during this operation; nothing was overwritten.");
  }
}

async function main() {
  let originalBytes;
  let content;
  try {
    originalBytes = await fs.readFile(configPath);
    content = decodeStrictUtf8(originalBytes, "Codex config");
  } catch (error) {
    if (error.code === "ENOENT") throw new Error(`Codex config not found: ${configPath}`);
    throw error;
  }

  const originalStat = await fs.lstat(configPath);
  if (originalStat.isSymbolicLink() || !originalStat.isFile()) {
    throw new Error("Codex config must be a regular file, not a symbolic link.");
  }
  if (content.includes('"""') || content.includes("'''")) {
    throw new Error("Refusing to rewrite TOML containing multiline strings.");
  }
  assertEditableToml(content);
  let section = desktopSection(content);
  const preferredNewline = content.includes("\r\n") ? "\r\n" : "\n";

  if (mode === "install") {
    if (!section) {
      content = `${content.trimEnd()}${preferredNewline}${preferredNewline}[desktop]${preferredNewline}`;
      section = desktopSection(content);
    }
    let existingBackup = null;
    let backupExists = false;
    try {
      const backupBytes = await readStableRegularFile(
        backupPath,
        "Theme backup must be a regular file, not a symbolic link.",
      );
      existingBackup = JSON.parse(decodeStrictUtf8(backupBytes, "Theme backup"));
      backupExists = true;
    } catch (error) {
      if (error.code !== "ENOENT") throw new Error(`Could not read the theme backup: ${error.message}`);
    }
    if (backupExists) {
      validateBackup(existingBackup);
    } else {
      const values = {};
      for (const key of settings.keys()) {
        const { matches } = settingLines(section.body, key);
        values[key] = matches[0] ?? null;
      }
      const backup = {
        schemaVersion: 1,
        platform: "darwin",
        createdAt: new Date().toISOString(),
        configPath,
        values,
      };
      await fs.mkdir(path.dirname(backupPath), { recursive: true, mode: 0o700 });
      await assertConfigUnchanged(originalBytes, originalStat);
      await atomicWrite(backupPath, `${JSON.stringify(backup, null, 2)}\n`, 0o600);
    }

    // Only apply non-null settings. null means "backup only / leave user's appearance alone".
    let body = section.body;
    let changed = false;
    for (const [key, line] of settings) {
      if (line === null) continue;
      body = replaceSetting(body, key, line, preferredNewline);
      changed = true;
    }
    if (changed) {
      const updated = content.slice(0, section.bodyStart) + body + content.slice(section.bodyEnd);
      assertEditableToml(updated);
      await assertConfigUnchanged(originalBytes, originalStat);
      await atomicWrite(configPath, updated, originalStat.mode & 0o777, originalBytes, originalStat);
    }
    console.log("Saved base-theme backup; left Codex appearanceTheme unchanged (skin auto-adapts light/dark).");
    return;
  }

  let backup;
  try {
    const backupBytes = await readStableRegularFile(
      backupPath,
      "Theme backup must be a regular file, not a symbolic link.",
    );
    backup = JSON.parse(decodeStrictUtf8(backupBytes, "Theme backup"));
  } catch (error) {
    if (error.code === "ENOENT") throw new Error("No selective pre-install theme backup is available.");
    throw new Error(`Could not read the theme backup: ${error.message}`);
  }
  validateBackup(backup);
  if (!section) {
    const hasSavedSetting = [...settings.keys()].some((key) => backup.values[key]);
    if (!hasSavedSetting) {
      await assertConfigUnchanged(originalBytes, originalStat);
      console.log("Restored the saved base-theme keys.");
      return;
    }
    content = `${content.trimEnd()}${preferredNewline}${preferredNewline}[desktop]${preferredNewline}`;
    section = desktopSection(content);
  }
  let body = section.body;
  for (const key of settings.keys()) {
    body = replaceSetting(body, key, backup.values[key] ?? null, preferredNewline);
  }
  const restored = content.slice(0, section.bodyStart) + body + content.slice(section.bodyEnd);
  assertEditableToml(restored);
  await assertConfigUnchanged(originalBytes, originalStat);
  await atomicWrite(configPath, restored, originalStat.mode & 0o777, originalBytes, originalStat);
  console.log("Restored the saved base-theme keys.");
}

const releaseLock = await acquireConfigLock();
try {
  await main();
} finally {
  await releaseLock();
}
