import fs from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { createHash, randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

const [mode, configPath, backupPath, archiveIdentity, ...extraArgs] = process.argv.slice(2);
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

async function atomicWrite(
  file,
  value,
  modeBits,
  expectedBytes = null,
  expectedStat = null,
  expectedTarget = configPath,
) {
  const temporary = `${file}.${process.pid}.${randomUUID()}.tmp`;
  try {
    await fs.writeFile(temporary, value, { mode: modeBits, flag: "wx" });
    if (expectedBytes) await assertConfigUnchanged(expectedBytes, expectedStat, expectedTarget);
    await fs.chmod(temporary, modeBits);
    const temporaryStat = await fs.lstat(temporary, { bigint: true });
    await fs.rename(temporary, file);
    const published = await fs.lstat(file, { bigint: true });
    if (published.dev !== temporaryStat.dev || published.ino !== temporaryStat.ino) {
      throw new Error("Atomic write publication identity changed.");
    }
    return published;
  } finally {
    await fs.rm(temporary, { force: true }).catch(() => {});
  }
}

export async function atomicCreate(file, value, modeBits, beforePublish = async () => {}) {
  const temporary = `${file}.${process.pid}.${randomUUID()}.tmp`;
  try {
    await fs.writeFile(temporary, value, { mode: modeBits, flag: "wx" });
    const temporaryStat = await fs.lstat(temporary, { bigint: true });
    await beforePublish();
    await fs.link(temporary, file);
    const published = await fs.lstat(file, { bigint: true });
    if (published.dev !== temporaryStat.dev || published.ino !== temporaryStat.ino) {
      throw new Error("Atomic publication identity changed; recovery data was preserved.");
    }
    return published;
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

async function readHandle(handle) {
  const chunks = [];
  const buffer = Buffer.alloc(16_384);
  let position = 0;
  while (true) {
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, position);
    if (!bytesRead) return Buffer.concat(chunks);
    chunks.push(Buffer.from(buffer.subarray(0, bytesRead)));
    position += bytesRead;
  }
}

async function openStableRegularFile(file, invalidMessage, expectedIdentity = null) {
  const handle = await fs.open(file, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const opened = await handle.stat({ bigint: true });
    const linked = await fs.lstat(file, { bigint: true });
    const openedIdentity = `${opened.dev}:${opened.ino}`;
    if (
      !opened.isFile()
      || !linked.isFile()
      || opened.dev !== linked.dev
      || opened.ino !== linked.ino
      || (expectedIdentity && openedIdentity !== expectedIdentity)
    ) {
      throw new Error(invalidMessage);
    }
    const bytes = await readHandle(handle);
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
    return { bytes, handle, stat: after };
  } catch (error) {
    await handle.close();
    throw error;
  }
}

async function readStableRegularFile(file, invalidMessage, expectedIdentity = null) {
  const opened = await openStableRegularFile(file, invalidMessage, expectedIdentity);
  try {
    return opened.bytes;
  } finally {
    await opened.handle.close();
  }
}

function statIdentity(stat) {
  return `${stat.dev}:${stat.ino}`;
}

async function describeUpgradePath(target) {
  let linked;
  try {
    linked = await fs.lstat(target, { bigint: true });
  } catch (error) {
    if (error.code === "ENOENT") return { state: "absent" };
    throw error;
  }
  if (linked.isSymbolicLink() || (!linked.isFile() && !linked.isDirectory())) {
    throw new Error(`Unsafe upgrade transaction path: ${target}`);
  }
  const hash = createHash("sha256");
  async function add(current, relative) {
    const before = await fs.lstat(current, { bigint: true });
    if (before.isSymbolicLink() || (!before.isFile() && !before.isDirectory())) {
      throw new Error(`Unsafe upgrade transaction entry: ${current}`);
    }
    hash.update(before.isDirectory() ? "d\0" : "f\0");
    hash.update(relative);
    hash.update("\0");
    if (before.isFile()) {
      const opened = await openStableRegularFile(
        current,
        `Upgrade transaction entry changed while it was read: ${current}`,
        statIdentity(before),
      );
      try {
        hash.update(opened.bytes);
      } finally {
        await opened.handle.close();
      }
    } else {
      const names = await fs.readdir(current);
      names.sort();
      for (const name of names) await add(path.join(current, name), `${relative}/${name}`);
    }
    const after = await fs.lstat(current, { bigint: true });
    if (before.dev !== after.dev || before.ino !== after.ino
      || before.size !== after.size || before.mtimeNs !== after.mtimeNs) {
      throw new Error(`Upgrade transaction entry changed while it was read: ${current}`);
    }
  }
  await add(target, ".");
  const after = await fs.lstat(target, { bigint: true });
  if (linked.dev !== after.dev || linked.ino !== after.ino
    || linked.size !== after.size || linked.mtimeNs !== after.mtimeNs) {
    throw new Error(`Upgrade transaction path changed while it was read: ${target}`);
  }
  return { state: "present", identity: statIdentity(after), digest: hash.digest("hex") };
}

function sameUpgradeDescription(actual, expected) {
  return actual?.state === expected?.state
    && (actual.state === "absent"
      || (actual.identity === expected.identity && actual.digest === expected.digest));
}

export async function consumeUpgradeTree(
  rootPath,
  expectedIdentity,
  beforeRemoval = async () => {},
) {
  const expected = await describeUpgradePath(rootPath);
  if (expected.state !== "present" || expected.identity !== expectedIdentity) {
    throw new Error("Upgrade cleanup tree identity changed; recovery data was preserved.");
  }
  const quarantineRoot = await fs.mkdtemp(`${rootPath}.consume.`);
  const quarantineRootIdentity = statIdentity(await fs.lstat(quarantineRoot, { bigint: true }));
  const quarantinePath = path.join(quarantineRoot, "tree");
  await fs.rename(rootPath, quarantinePath);
  if ((await describeUpgradePath(rootPath)).state !== "absent"
    || !sameUpgradeDescription(await describeUpgradePath(quarantinePath), expected)
    || (await describeUpgradePath(quarantineRoot)).identity !== quarantineRootIdentity) {
    throw new Error("Upgrade cleanup tree changed during quarantine; recovery data was preserved.");
  }
  await beforeRemoval(quarantinePath);
  if (!sameUpgradeDescription(await describeUpgradePath(quarantinePath), expected)
    || (await describeUpgradePath(quarantineRoot)).identity !== quarantineRootIdentity) {
    throw new Error("Upgrade cleanup tree changed before removal; recovery data was preserved.");
  }
  await fs.rm(quarantinePath, { recursive: true });
  if ((await describeUpgradePath(quarantinePath)).state !== "absent") {
    throw new Error("Upgrade cleanup tree was not removed.");
  }
  await fs.rmdir(quarantineRoot);
}

function identityToken(identity) {
  return identity.replace(":", "_");
}

function expectedReceiptIdentity(groupPath) {
  const parts = path.basename(groupPath).split(".");
  if (parts.length !== 5 || parts[1] !== "expected") {
    throw new Error("Expected upgrade receipt path is invalid.");
  }
  return {
    groupIdentity: parts[2].replace("_", ":"),
    receiptIdentity: parts[3].replace("_", ":"),
    receiptDigest: parts[4],
  };
}

export async function finalizeUpgradeReceipt(
  snapshotRoot,
  rootIdentity,
  groupPath,
  kind,
  sourcePairs,
  emit = false,
) {
  const root = await describeUpgradePath(snapshotRoot);
  if (root.state !== "present" || root.identity !== rootIdentity) {
    throw new Error("Upgrade snapshot root identity changed; recovery data was preserved.");
  }
  const group = await describeUpgradePath(groupPath);
  if (group.state !== "present") throw new Error("Upgrade receipt group is unavailable.");
  const entries = {};
  const sourcePaths = new Map();
  for (let index = 0; index < sourcePairs.length; index += 2) {
    if (!sourcePairs[index] || sourcePairs[index + 1] === undefined) {
      throw new Error("Upgrade receipt source arguments are incomplete.");
    }
    sourcePaths.set(sourcePairs[index], sourcePairs[index + 1]);
  }
  for (const name of (await fs.readdir(groupPath)).filter((value) => value.endsWith(".state")).sort()) {
    const markerPath = path.join(groupPath, name);
    const markerBytes = await readStableRegularFile(markerPath, "Upgrade receipt marker is unsafe.");
    const lines = decodeStrictUtf8(markerBytes, "Upgrade receipt marker").split(/\r?\n/);
    if (!['present', 'absent'].includes(lines[0]) || lines.length < 3) {
      throw new Error("Upgrade receipt marker is invalid.");
    }
    const snapshot = lines[0] === "present"
      ? await describeUpgradePath(path.join(groupPath, name.slice(0, -6)))
      : { state: "absent" };
    const sourcePath = sourcePaths.get(name);
    if (sourcePath === undefined) throw new Error("Upgrade receipt source path is missing.");
    const source = await describeUpgradePath(sourcePath);
    if (snapshot.state !== lines[0] || source.state !== snapshot.state
      || (source.state === "present" && (source.identity !== lines[1] || source.digest !== snapshot.digest))) {
      throw new Error("Upgrade snapshot does not match its stable source.");
    }
    entries[name] = {
      source,
      marker: await describeUpgradePath(markerPath),
      snapshot,
    };
  }
  if (!Object.keys(entries).length) throw new Error("Upgrade receipt group is empty.");
  const receiptPath = path.join(groupPath, "COMPLETE.json");
  const receipt = { schemaVersion: 1, rootIdentity, groupIdentity: group.identity, entries };
  await atomicCreate(receiptPath, `${JSON.stringify(receipt)}\n`, 0o600);
  const published = await describeUpgradePath(receiptPath);
  const rootAfter = await describeUpgradePath(snapshotRoot);
  if (rootAfter.identity !== rootIdentity) {
    throw new Error("Upgrade snapshot root changed during receipt publication.");
  }
  let finalGroup = groupPath;
  if (kind === "expected") {
    finalGroup = path.join(
      snapshotRoot,
      `.expected.${identityToken(group.identity)}.${identityToken(published.identity)}.${published.digest}`,
    );
    await fs.rename(groupPath, finalGroup);
  } else if (kind !== "original") {
    throw new Error("Unknown upgrade receipt kind.");
  }
  const finalGroupDescription = await describeUpgradePath(finalGroup);
  const finalReceiptDescription = await describeUpgradePath(path.join(finalGroup, "COMPLETE.json"));
  if (finalGroupDescription.identity !== group.identity
    || !sameUpgradeDescription(finalReceiptDescription, published)) {
    throw new Error("Upgrade receipt changed during final publication.");
  }
  for (const [name, sourcePath] of sourcePaths) {
    if (!sameUpgradeDescription(await describeUpgradePath(sourcePath), entries[name].source)) {
      throw new Error("Upgrade receipt source changed during publication.");
    }
  }
  const finalRoot = await describeUpgradePath(snapshotRoot);
  if (finalRoot.identity !== rootIdentity) throw new Error("Upgrade snapshot root changed during publication.");
  if (emit) process.stdout.write(`${group.identity}|${published.identity}|${published.digest}|${path.basename(finalGroup)}\n`);
  return {
    groupIdentity: group.identity,
    receiptIdentity: published.identity,
    receiptDigest: published.digest,
    finalGroup,
  };
}

export async function captureUpgradeExpected(snapshotRoot, rootIdentity, entries) {
  const root = await describeUpgradePath(snapshotRoot);
  if (root.state !== "present" || root.identity !== rootIdentity) {
    throw new Error("Upgrade snapshot root identity changed; recovery data was preserved.");
  }
  const groupPath = await fs.mkdtemp(path.join(snapshotRoot, ".expected."));
  const pairs = [];
  for (const { name, target, expectedState, expectedIdentity } of entries) {
    const source = await describeUpgradePath(target);
    if ((expectedState && source.state !== expectedState)
      || (expectedIdentity && source.identity !== expectedIdentity)) {
      throw new Error(`Upgrade transaction source changed: ${target}`);
    }
    if (source.state === "present") {
      await fs.cp(target, path.join(groupPath, name), {
        recursive: (await fs.lstat(target)).isDirectory(),
        preserveTimestamps: true,
        errorOnExist: true,
        force: false,
      });
      if (!sameUpgradeDescription(await describeUpgradePath(target), source)
        || (await describeUpgradePath(path.join(groupPath, name))).digest !== source.digest) {
        throw new Error("Upgrade source changed during receipt capture.");
      }
    }
    await atomicCreate(
      path.join(groupPath, `${name}.state`),
      `${source.state}\n${source.identity ?? ""}\nunused\n`,
      0o600,
    );
    pairs.push(`${name}.state`, target);
  }
  return await finalizeUpgradeReceipt(snapshotRoot, rootIdentity, groupPath, "expected", pairs);
}

async function verifyUpgradeReceipt(
  snapshotRoot,
  rootIdentity,
  groupPath,
  expectedGroupIdentity,
  expectedReceiptIdentity,
  expectedReceiptDigest,
  requestedEntry = null,
  candidatePath = null,
  matchMode = null,
  emit = false,
) {
  const root = await describeUpgradePath(snapshotRoot);
  const group = await describeUpgradePath(groupPath);
  const receiptPath = path.join(groupPath, "COMPLETE.json");
  const published = await describeUpgradePath(receiptPath);
  if (root.state !== "present" || root.identity !== rootIdentity
    || group.state !== "present" || group.identity !== expectedGroupIdentity
    || published.state !== "present" || published.identity !== expectedReceiptIdentity
    || published.digest !== expectedReceiptDigest) {
    throw new Error("Upgrade receipt identity or bytes changed; recovery data was preserved.");
  }
  const bytes = await readStableRegularFile(receiptPath, "Upgrade receipt is unsafe.", published.identity);
  const receipt = JSON.parse(decodeStrictUtf8(bytes, "Upgrade receipt"));
  if (receipt?.schemaVersion !== 1 || receipt.rootIdentity !== rootIdentity
    || receipt.groupIdentity !== expectedGroupIdentity || !receipt.entries) {
    throw new Error("Upgrade receipt schema is invalid.");
  }
  for (const [name, expected] of Object.entries(receipt.entries)) {
    const marker = await describeUpgradePath(path.join(groupPath, name));
    const snapshot = expected.snapshot.state === "present"
      ? await describeUpgradePath(path.join(groupPath, name.slice(0, -6)))
      : { state: "absent" };
    if (!sameUpgradeDescription(marker, expected.marker)
      || !sameUpgradeDescription(snapshot, expected.snapshot)) {
      throw new Error("Upgrade receipt entry changed; recovery data was preserved.");
    }
  }
  const rootAfter = await describeUpgradePath(snapshotRoot);
  if (rootAfter.identity !== rootIdentity) throw new Error("Upgrade snapshot root changed during verification.");
  if (requestedEntry) {
    const entry = receipt.entries[requestedEntry];
    if (!entry) throw new Error("Upgrade receipt entry is missing.");
    if (candidatePath) {
      const candidate = await describeUpgradePath(candidatePath);
      const matches = matchMode === "identity"
        ? sameUpgradeDescription(candidate, entry.source)
        : matchMode === "bytes" && candidate.state === entry.source.state
          && (candidate.state === "absent" || candidate.digest === entry.source.digest);
      if (!matches) throw new Error("Upgrade candidate does not match its receipt.");
    }
    if (emit) process.stdout.write([
      entry.source.state,
      entry.source.identity ?? "",
      entry.source.digest ?? "",
      entry.snapshot.identity ?? "",
      entry.snapshot.digest ?? "",
    ].join("|") + "\n");
  }
  return receipt;
}

async function publishUpgradePath(sourcePath, sourceExpected, destinationPath, publishedExpected) {
  if (sourceExpected.state === "absent") {
    if (publishedExpected.state !== "absent"
      || !sameUpgradeDescription(await describeUpgradePath(destinationPath), publishedExpected)) {
      throw new Error("Upgrade publication receipt is inconsistent.");
    }
    return { state: "absent" };
  }
  const source = await describeUpgradePath(sourcePath);
  if (!sameUpgradeDescription(source, sourceExpected)) {
    throw new Error("Upgrade publication source changed; recovery data was preserved.");
  }
  const sourceStat = await fs.lstat(sourcePath, { bigint: true });
  if (sourceStat.isFile()) {
    const opened = await openStableRegularFile(
      sourcePath,
      "Upgrade publication source changed; recovery data was preserved.",
      sourceExpected.identity,
    );
    try {
      await atomicCreate(destinationPath, opened.bytes, Number(opened.stat.mode & 0o777n));
    } finally {
      await opened.handle.close();
    }
  } else {
    await fs.mkdir(destinationPath, { mode: Number(sourceStat.mode & 0o777n) });
    for (const name of (await fs.readdir(sourcePath)).sort()) {
      const child = path.join(sourcePath, name);
      await fs.cp(child, path.join(destinationPath, name), {
        recursive: (await fs.lstat(child)).isDirectory(),
        preserveTimestamps: true,
        errorOnExist: true,
        force: false,
      });
    }
  }
  const published = await describeUpgradePath(destinationPath);
  if (published.state !== publishedExpected.state || published.digest !== publishedExpected.digest
    || !sameUpgradeDescription(await describeUpgradePath(sourcePath), sourceExpected)) {
    throw new Error("Published upgrade entry does not match its receipt; recovery data was preserved.");
  }
  return published;
}

async function replaceUpgradeEntry({
  livePath,
  currentExpected,
  sourcePath,
  sourceExpected,
  publishedExpected,
  quarantinePath,
}) {
  if (!sameUpgradeDescription(await describeUpgradePath(livePath), currentExpected)) {
    throw new Error("Upgrade live path does not match its receipt.");
  }
  if (!sameUpgradeDescription(await describeUpgradePath(sourcePath), sourceExpected)) {
    throw new Error("Upgrade source path does not match its receipt.");
  }
  if ((await describeUpgradePath(quarantinePath)).state !== "absent") {
    throw new Error("Upgrade quarantine path is occupied.");
  }
  let quarantined = false;
  try {
    if (currentExpected.state === "present") {
      await fs.rename(livePath, quarantinePath);
      quarantined = true;
      if (!sameUpgradeDescription(await describeUpgradePath(quarantinePath), currentExpected)
        || (await describeUpgradePath(livePath)).state !== "absent") {
        throw new Error("Upgrade entry changed during quarantine.");
      }
    }
    return await publishUpgradePath(sourcePath, sourceExpected, livePath, publishedExpected);
  } catch (error) {
    if (quarantined && (await describeUpgradePath(livePath)).state === "absent") {
      await publishUpgradePath(quarantinePath, currentExpected, livePath, currentExpected);
    }
    throw error;
  }
}

export async function replaceUpgradeReceiptEntry({
  snapshotRoot,
  rootIdentity,
  originalGroup,
  originalGroupIdentity,
  originalReceiptIdentity,
  originalReceiptDigest,
  expectedGroup,
  entryName,
  livePath,
  stagedPath = null,
  heldPath,
  quarantinePath,
  direction,
}) {
  const expectedIdentity = expectedReceiptIdentity(expectedGroup);
  const original = await verifyUpgradeReceipt(
    snapshotRoot, rootIdentity, originalGroup, originalGroupIdentity,
    originalReceiptIdentity, originalReceiptDigest,
  );
  const expected = await verifyUpgradeReceipt(
    snapshotRoot, rootIdentity, expectedGroup, expectedIdentity.groupIdentity,
    expectedIdentity.receiptIdentity, expectedIdentity.receiptDigest,
  );
  const originalEntry = original.entries[entryName];
  const expectedEntry = expected.entries[entryName];
  if (!originalEntry || !expectedEntry) throw new Error("Upgrade receipt entry is missing.");
  let currentExpected = originalEntry.source;
  let sourcePath = stagedPath;
  let sourceExpected = expectedEntry.source;
  let publishedExpected = expectedEntry.source;
  if (direction === "restore") {
    currentExpected = expectedEntry.source;
    publishedExpected = originalEntry.source;
    if ((await describeUpgradePath(heldPath)).state === "present") {
      sourcePath = heldPath;
      sourceExpected = originalEntry.source;
    } else {
      sourcePath = path.join(originalGroup, entryName.slice(0, -6));
      sourceExpected = originalEntry.snapshot;
    }
  } else if (direction !== "publish") {
    throw new Error("Unknown upgrade replacement direction.");
  }
  const published = await replaceUpgradeEntry({
    livePath,
    currentExpected,
    sourcePath,
    sourceExpected,
    publishedExpected,
    quarantinePath,
  });
  if (direction === "publish") {
    await captureUpgradeExpected(snapshotRoot, rootIdentity, [{
      name: entryName.slice(0, -6),
      target: livePath,
      expectedState: published.state,
      expectedIdentity: published.identity,
    }]);
  }
  await verifyUpgradeReceipt(
    snapshotRoot, rootIdentity, originalGroup, originalGroupIdentity,
    originalReceiptIdentity, originalReceiptDigest,
  );
  await verifyUpgradeReceipt(
    snapshotRoot, rootIdentity, expectedGroup, expectedIdentity.groupIdentity,
    expectedIdentity.receiptIdentity, expectedIdentity.receiptDigest,
  );
}

async function holdUpgradeReceiptEntry(
  snapshotRoot,
  rootIdentity,
  groupPath,
  groupIdentity,
  receiptIdentity,
  receiptDigest,
  entryName,
  livePath,
  heldPath,
) {
  const receipt = await verifyUpgradeReceipt(
    snapshotRoot,
    rootIdentity,
    groupPath,
    groupIdentity,
    receiptIdentity,
    receiptDigest,
    entryName,
    livePath,
    "identity",
  );
  const expected = receipt.entries[entryName].source;
  if (expected.state !== "present") throw new Error("Only present receipt entries can be held.");
  if ((await describeUpgradePath(heldPath)).state !== "absent") {
    throw new Error("Upgrade held path is already occupied.");
  }
  await fs.rename(livePath, heldPath);
  try {
    if (!sameUpgradeDescription(await describeUpgradePath(heldPath), expected)
      || (await describeUpgradePath(livePath)).state !== "absent") {
      throw new Error("Upgrade entry changed while it was moved into held storage.");
    }
    await verifyUpgradeReceipt(
      snapshotRoot,
      rootIdentity,
      groupPath,
      groupIdentity,
      receiptIdentity,
      receiptDigest,
    );
    await captureUpgradeExpected(snapshotRoot, rootIdentity, [{
      name: entryName.slice(0, -6),
      target: livePath,
      expectedState: "absent",
    }]);
  } catch (error) {
    if ((await describeUpgradePath(livePath)).state === "absent"
      && sameUpgradeDescription(await describeUpgradePath(heldPath), expected)) {
      await fs.rename(heldPath, livePath);
    }
    throw error;
  }
}

async function assertHeldFile(opened, file, expectedBytes, linkedPath) {
  const linked = await fs.lstat(linkedPath, { bigint: true });
  const held = await file.stat({ bigint: true });
  const heldBytes = await readHandle(file);
  if (
    !linked.isFile()
    || linked.dev !== held.dev
    || linked.ino !== held.ino
    || opened.dev !== held.dev
    || opened.ino !== held.ino
    || opened.size !== held.size
    || opened.mtimeNs !== held.mtimeNs
    || held.nlink !== 1n
    || !heldBytes.equals(expectedBytes)
  ) {
    throw new Error("Staged theme backup identity changed before committed cleanup.");
  }
}

async function consumeHeldBackup(
  opened,
  backupPath,
  beforeQuarantine = async () => {},
  afterQuarantine = async () => {},
  beforeConsumption = async () => {},
) {
  const { bytes, handle, stat } = opened;
  await assertHeldFile(stat, handle, bytes, backupPath);
  await beforeQuarantine();

  const quarantineDirectory = await fs.mkdtemp(`${backupPath}.cleanup.`);
  const quarantinePath = path.join(quarantineDirectory, "staged");
  await fs.rename(backupPath, quarantinePath);
  try {
    await afterQuarantine();
    await assertHeldFile(stat, handle, bytes, quarantinePath);
    try {
      await fs.lstat(backupPath);
      throw new Error("An unexpected theme backup appeared during committed cleanup.");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    await beforeConsumption();
    await fs.unlink(quarantinePath);
    const unlinked = await handle.stat({ bigint: true });
    if (unlinked.nlink !== 0n) {
      throw new Error("The committed theme backup was not removed by exact identity.");
    }
    await fs.rmdir(quarantineDirectory);
  } catch (error) {
    try {
      await fs.link(quarantinePath, backupPath);
    } catch (restoreError) {
      if (restoreError.code !== "EEXIST") throw new AggregateError([error, restoreError]);
    }
    throw error;
  }
}

export async function archiveBackup(
  stagedPath,
  destinationPath,
  expectedIdentity,
  beforeCleanup = async () => {},
  beforeQuarantine = async () => {},
) {
  const staged = await openStableRegularFile(
    stagedPath,
    "Staged theme backup identity changed before archive commit.",
    expectedIdentity,
  );
  try {
    const { bytes } = staged;
    try {
      const destination = await fs.lstat(destinationPath);
      if (!destination.isFile() || destination.isSymbolicLink()) {
        throw new Error("The restored-backup archive path is unsafe; recovery data was preserved.");
      }
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    await atomicWrite(destinationPath, bytes, 0o600, null, null, destinationPath);
    const archived = await readStableRegularFile(
      destinationPath,
      "The restored theme backup archive could not be verified.",
    );
    if (!archived.equals(bytes)) {
      throw new Error("The restored theme backup archive could not be verified.");
    }
    await beforeCleanup();
    await consumeHeldBackup(staged, stagedPath, beforeQuarantine);
  } finally {
    await staged.handle.close();
  }
}

export async function retireBackup(
  livePath,
  archivePath,
  expectedIdentity,
  beforeQuarantine = async () => {},
  afterQuarantine = async () => {},
) {
  const live = await openStableRegularFile(
    livePath,
    "Live theme backup identity changed before retirement.",
    expectedIdentity,
  );
  try {
    const archived = await openStableRegularFile(
      archivePath,
      "The restored theme backup archive could not be verified.",
    );
    try {
      if (!archived.bytes.equals(live.bytes)) {
        throw new Error("The restored theme backup archive does not match the live recovery backup.");
      }
      await assertHeldFile(archived.stat, archived.handle, archived.bytes, archivePath);
      await consumeHeldBackup(
        live,
        livePath,
        beforeQuarantine,
        afterQuarantine,
        () => assertHeldFile(archived.stat, archived.handle, archived.bytes, archivePath),
      );
    } finally {
      await archived.handle.close();
    }
  } finally {
    await live.handle.close();
  }
}

async function acquireConfigLock(target = configPath) {
  const lockPath = `${target}.dream-skin.lock`;
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

async function assertConfigUnchanged(expectedBytes, expectedStat = null, target = configPath) {
  const currentStat = await fs.lstat(target);
  if (
    currentStat.isSymbolicLink()
    || !currentStat.isFile()
    || (expectedStat && (currentStat.dev !== expectedStat.dev || currentStat.ino !== expectedStat.ino))
  ) {
    throw new Error("Codex config file identity changed during this operation; nothing was overwritten.");
  }
  const currentBytes = await fs.readFile(target);
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
    let configExpectedIdentity = statIdentity(originalStat);
    let backupExpectedIdentity = null;
    if (!section) {
      content = `${content.trimEnd()}${preferredNewline}${preferredNewline}[desktop]${preferredNewline}`;
      section = desktopSection(content);
    }
    let existingBackup = null;
    let backupExists = false;
    try {
      const openedBackup = await openStableRegularFile(
        backupPath,
        "Theme backup must be a regular file, not a symbolic link.",
      );
      try {
        existingBackup = JSON.parse(decodeStrictUtf8(openedBackup.bytes, "Theme backup"));
        backupExpectedIdentity = statIdentity(openedBackup.stat);
        backupExists = true;
      } finally {
        await openedBackup.handle.close();
      }
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
      const publishedBackup = await atomicCreate(
        backupPath,
        `${JSON.stringify(backup, null, 2)}\n`,
        0o600,
        () => assertConfigUnchanged(originalBytes, originalStat),
      );
      backupExpectedIdentity = statIdentity(publishedBackup);
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
      const publishedConfig = await atomicWrite(
        configPath,
        updated,
        originalStat.mode & 0o777,
        originalBytes,
        originalStat,
      );
      configExpectedIdentity = statIdentity(publishedConfig);
    }
    const upgradeRoot = process.env.DREAM_SKIN_UPGRADE_SNAPSHOT_ROOT || null;
    const upgradeRootIdentity = process.env.DREAM_SKIN_UPGRADE_SNAPSHOT_IDENTITY || null;
    if (upgradeRoot || upgradeRootIdentity) {
      if (!upgradeRoot || !upgradeRootIdentity) {
        throw new Error("Upgrade receipt environment is incomplete.");
      }
      await captureUpgradeExpected(upgradeRoot, upgradeRootIdentity, [
        { name: "config", target: configPath, expectedState: "present", expectedIdentity: configExpectedIdentity },
        { name: "live-backup", target: backupPath, expectedState: "present", expectedIdentity: backupExpectedIdentity },
      ]);
    }
    console.log("Saved base-theme backup; left Codex appearanceTheme unchanged (skin auto-adapts light/dark).");
    return;
  }

  let backup;
  try {
    const backupBytes = await readStableRegularFile(
      backupPath,
      "Theme backup must be a regular file, not a symbolic link.",
      process.env.DREAM_SKIN_BACKUP_IDENTITY || null,
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

async function runCli() {
  if (!["install", "restore", "archive", "retire", "upgrade-consume-tree", "upgrade-receipt-capture", "upgrade-receipt-finalize", "upgrade-receipt-verify", "upgrade-receipt-hold", "upgrade-receipt-replace", "upgrade-receipt-restore", "upgrade-receipt-restore-config"].includes(mode) || !configPath || !backupPath
    || (["archive", "retire"].includes(mode) && !archiveIdentity)) {
    throw new Error("Usage: theme-config.mjs <install|restore> <config-path> <backup-path> | <archive|retire> <live-path> <archive-path> <expected-identity>");
  }
  if (mode === "upgrade-consume-tree") {
    await consumeUpgradeTree(configPath, backupPath);
  } else if (["upgrade-receipt-replace", "upgrade-receipt-restore", "upgrade-receipt-restore-config"].includes(mode)) {
    if (!archiveIdentity || extraArgs.length !== 8) throw new Error("Upgrade replacement arguments are incomplete.");
    const [
      originalGroupIdentity, originalReceiptIdentity, originalReceiptDigest,
      expectedGroup, entryName, firstPath, secondPath, quarantinePath,
    ] = extraArgs;
    const direction = mode === "upgrade-receipt-replace" ? "publish" : "restore";
    const livePath = direction === "publish" ? secondPath : firstPath;
    const candidatePath = direction === "publish" ? firstPath : secondPath;
    const operation = () => replaceUpgradeReceiptEntry({
      snapshotRoot: configPath,
      rootIdentity: backupPath,
      originalGroup: archiveIdentity,
      originalGroupIdentity,
      originalReceiptIdentity,
      originalReceiptDigest,
      expectedGroup,
      entryName,
      livePath,
      stagedPath: direction === "publish" ? candidatePath : null,
      heldPath: direction === "restore" ? candidatePath : quarantinePath,
      quarantinePath,
      direction,
    });
    if (mode === "upgrade-receipt-restore-config") {
      const releaseLock = await acquireConfigLock(livePath);
      try {
        await operation();
      } finally {
        await releaseLock();
      }
    } else {
      await operation();
    }
  } else if (mode === "upgrade-receipt-capture") {
    if (!archiveIdentity || !extraArgs[0] || !["present", "absent"].includes(extraArgs[1])
      || extraArgs.length > 3) {
      throw new Error("Upgrade receipt capture arguments are incomplete.");
    }
    const receipt = await captureUpgradeExpected(configPath, backupPath, [{
      name: archiveIdentity,
      target: extraArgs[0],
      expectedState: extraArgs[1],
      expectedIdentity: extraArgs[2] || null,
    }]);
    process.stdout.write(`${path.basename(receipt.finalGroup)}\n`);
  } else if (mode === "upgrade-receipt-hold") {
    if (!archiveIdentity || extraArgs.length !== 6) {
      throw new Error("Upgrade receipt hold arguments are incomplete.");
    }
    await holdUpgradeReceiptEntry(
      configPath,
      backupPath,
      archiveIdentity,
      ...extraArgs,
    );
  } else if (mode === "upgrade-receipt-finalize") {
    if (!archiveIdentity || !["original", "expected"].includes(extraArgs[0])) {
      throw new Error("Upgrade receipt finalize arguments are incomplete.");
    }
    await finalizeUpgradeReceipt(configPath, backupPath, archiveIdentity, extraArgs[0], extraArgs.slice(1), true);
  } else if (mode === "upgrade-receipt-verify") {
    if (!archiveIdentity) throw new Error("Upgrade receipt verify arguments are incomplete.");
    let [groupIdentity, receiptIdentity, receiptDigest] = extraArgs;
    let requestedEntry = extraArgs[3] || null;
    let candidatePath = extraArgs[4] || null;
    let matchMode = extraArgs[5] || null;
    if (groupIdentity === "auto") {
      requestedEntry = extraArgs[1] || null;
      candidatePath = extraArgs[2] || null;
      matchMode = extraArgs[3] || null;
      const expectedIdentity = expectedReceiptIdentity(archiveIdentity);
      groupIdentity = expectedIdentity.groupIdentity;
      receiptIdentity = expectedIdentity.receiptIdentity;
      receiptDigest = expectedIdentity.receiptDigest;
    }
    if (!groupIdentity || !receiptIdentity || !receiptDigest) {
      throw new Error("Upgrade receipt identity is incomplete.");
    }
    await verifyUpgradeReceipt(
      configPath,
      backupPath,
      archiveIdentity,
      groupIdentity,
      receiptIdentity,
      receiptDigest,
      requestedEntry,
      candidatePath,
      matchMode,
      true,
    );
  } else if (mode === "archive") {
    await archiveBackup(configPath, backupPath, archiveIdentity);
  } else if (mode === "retire") {
    await retireBackup(configPath, backupPath, archiveIdentity);
  } else {
    const releaseLock = await acquireConfigLock();
    try {
      await main();
    } finally {
      await releaseLock();
    }
  }
}

const cliPath = process.argv[1] ? await fs.realpath(process.argv[1]).catch(() => null) : null;
if (cliPath && cliPath === await fs.realpath(fileURLToPath(import.meta.url))) {
  await runCli();
}
