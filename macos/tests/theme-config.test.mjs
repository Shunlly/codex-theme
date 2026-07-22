import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const macosRoot = path.resolve(here, "..");
const themeConfig = path.join(macosRoot, "scripts", "theme-config.mjs");
const {
  atomicCreate,
  captureUpgradeExpected,
  consumeUpgradeTree,
  finalizeUpgradeReceipt,
  replaceUpgradeReceiptEntry,
} = await import(themeConfig);
const tempRoot = await fs.mkdtemp(path.join("/tmp", "codex-dream-skin-config-"));

function runThemeConfig(mode, config, backup) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [themeConfig, mode, config, backup], {
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", reject);
    child.once("close", (code) => resolve({ code, stdout, stderr }));
  });
}

async function writeFixture(label, assignment, configContents = "[desktop]\nkeepMe = true\n") {
  const directory = path.join(tempRoot, label);
  const config = path.join(directory, "config.toml");
  const backup = path.join(directory, "theme-backup.json");
  await fs.mkdir(directory);
  await fs.writeFile(config, configContents);
  await fs.writeFile(backup, `${JSON.stringify({
    schemaVersion: 1,
    platform: "darwin",
    configPath: config,
    values: {
      appearanceTheme: assignment,
      appearanceDarkCodeThemeId: null,
    },
  })}\n`);
  return { config, backup };
}

const validAssignments = [
  `appearanceTheme = ""`,
  `appearanceTheme = ''`,
  `appearanceTheme\t=\t"dark\\tmode\\u0021"\t# keep escaped content`,
  `appearanceTheme = "dark \\"quoted\\" \\\\ path" # keep comment`,
  `appearanceTheme = "emoji: \\U0001F600"`,
  `appearanceTheme = 'dark # literal \\q'`,
  `appearanceTheme = 'literal value'\t`,
];

const invalidAssignments = [
  `appearanceTheme =`,
  `appearanceTheme =   # no value`,
  `appearanceTheme = "unterminated`,
  `appearanceTheme = 'unterminated`,
  `appearanceTheme = 1`,
  `appearanceTheme = true`,
  `appearanceTheme = []`,
  `appearanceTheme = {}`,
  `appearanceTheme = """multiline"""`,
  `appearanceTheme = '' extra`,
  `appearanceTheme = "dark" extra`,
  `"appearanceTheme" = "dark"`,
  `appearanceDarkCodeThemeId = "dark"`,
  `appearanceThemeExtra = "dark"`,
  ` appearanceTheme = "dark"`,
  String.raw`appearanceTheme = "bad\q"`,
  String.raw`appearanceTheme = "\u123"`,
  String.raw`appearanceTheme = "\uD800"`,
  String.raw`appearanceTheme = "\U00110000"`,
  `appearanceTheme = 'can\'t'`,
  `appearanceTheme = "dark"\r`,
  `appearanceTheme = "dark"\nmodel = "unsafe"`,
  `appearanceTheme = "dark\nunsafe"`,
  `appearanceTheme = "dark${String.fromCodePoint(0x2028)}unsafe"`,
  `appearanceTheme = "dark${String.fromCodePoint(0x2029)}unsafe"`,
];

try {
  for (const [index, assignment] of validAssignments.entries()) {
    const fixture = await writeFixture(`valid-${index}`, assignment);
    const result = await runThemeConfig("restore", fixture.config, fixture.backup);
    assert.equal(result.code, 0, `${assignment}\n${result.stderr}`);
    assert.equal(
      await fs.readFile(fixture.config, "utf8"),
      `[desktop]\nkeepMe = true\n${assignment}\n`,
    );
    await fs.access(fixture.backup);
  }

  const layoutCases = [
    {
      label: "crlf-missing-desktop",
      config: "model = \"gpt-5\"\r\nkeepMe = true\r\n",
      expected: "model = \"gpt-5\"\r\nkeepMe = true\r\n\r\n[desktop]\r\nappearanceTheme = \"system\"\r\n",
    },
    {
      label: "crlf-empty-desktop",
      config: "model = \"gpt-5\"\r\n\r\n[desktop]\r\n",
      expected: "model = \"gpt-5\"\r\n\r\n[desktop]\r\nappearanceTheme = \"system\"\r\n",
    },
  ];
  for (const { label, config, expected } of layoutCases) {
    const fixture = await writeFixture(label, `appearanceTheme = "system"`, config);
    const result = await runThemeConfig("restore", fixture.config, fixture.backup);
    assert.equal(result.code, 0, `${label}\n${result.stderr}`);
    assert.equal(await fs.readFile(fixture.config, "utf8"), expected);
    await fs.access(fixture.backup);
  }

  const bom = Buffer.from([0xef, 0xbb, 0xbf]);
  const bomFixture = await writeFixture(
    "bom-first-desktop",
    `appearanceTheme = "system"`,
    Buffer.concat([bom, Buffer.from(`[desktop]\nappearanceTheme = "dark"\n`)]),
  );
  const bomResult = await runThemeConfig("restore", bomFixture.config, bomFixture.backup);
  assert.equal(bomResult.code, 0, bomResult.stderr);
  assert.deepEqual(
    await fs.readFile(bomFixture.config),
    Buffer.concat([bom, Buffer.from(`[desktop]\nappearanceTheme = "system"\n`)]),
  );
  await fs.access(bomFixture.backup);

  const unrelatedEscaped = await writeFixture(
    "unrelated-escaped-keys",
    `appearanceTheme = "system"`,
    String.raw`"\u006dodel" = "gpt-5"
[desktop]
"\u006bkeep" = "value"
`,
  );
  const unrelatedEscapedResult = await runThemeConfig("restore", unrelatedEscaped.config, unrelatedEscaped.backup);
  assert.equal(unrelatedEscapedResult.code, 0, unrelatedEscapedResult.stderr);
  assert.equal(
    await fs.readFile(unrelatedEscaped.config, "utf8"),
    String.raw`"\u006dodel" = "gpt-5"
[desktop]
"\u006bkeep" = "value"
appearanceTheme = "system"
`,
  );
  await fs.access(unrelatedEscaped.backup);

  const ambiguousLayouts = [
    `["desktop"]\nkeepMe = true\n`,
    `[desktop]\n  appearanceTheme = "dark"\n`,
    `[desktop]\n"appearanceTheme" = "dark"\n`,
    String.raw`["desk\u0074op"]
keepMe = true
`,
    String.raw`[desktop]
"\u0061ppearanceTheme" = "dark"
`,
  ];
  const targetKeys = [
    "appearanceTheme",
    "appearanceLightCodeThemeId",
    "appearanceDarkCodeThemeId",
  ];
  for (const key of targetKeys) {
    ambiguousLayouts.push(
      `[desktop]\n${key}.variant = "dark"\n`,
      `[desktop]\n"${key}".variant = "dark"\n`,
      `[desktop]\n${key} = { variant = "dark" }\n`,
      `desktop.${key} = "dark"\n`,
    );
  }
  ambiguousLayouts.push(
    `desktop = { appearanceTheme = "dark" }\n`,
    `"desktop".appearanceTheme = "dark"\n`,
    `"desktop" = { appearanceTheme = "dark" }\n`,
    `[[desktop]]\nappearanceTheme = "dark"\n`,
    `[desktop.appearanceTheme]\nvariant = "dark"\n`,
    `["desktop".appearanceTheme]\nvariant = "dark"\n`,
    String.raw`["desk\u0074op".appearanceTheme]
variant = "dark"
`,
    String.raw`"\u0064esktop".appearanceTheme = "dark"
`,
  );
  for (const [index, config] of ambiguousLayouts.entries()) {
    const fixture = await writeFixture(
      `ambiguous-layout-${index}`,
      `appearanceTheme = "system"`,
      config,
    );
    const original = await fs.readFile(fixture.config);
    const originalBackup = await fs.readFile(fixture.backup);
    const result = await runThemeConfig("restore", fixture.config, fixture.backup);
    assert.notEqual(result.code, 0, `unexpectedly accepted: ${JSON.stringify(config)}`);
    assert.deepEqual(await fs.readFile(fixture.config), original);
    assert.deepEqual(await fs.readFile(fixture.backup), originalBackup);

    const installResult = await runThemeConfig("install", fixture.config, fixture.backup);
    assert.notEqual(installResult.code, 0, `install unexpectedly accepted: ${JSON.stringify(config)}`);
    assert.deepEqual(await fs.readFile(fixture.config), original);
    assert.deepEqual(await fs.readFile(fixture.backup), originalBackup);
  }

  for (const [index, assignment] of invalidAssignments.entries()) {
    const fixture = await writeFixture(`invalid-${index}`, assignment);
    const original = await fs.readFile(fixture.config);
    const result = await runThemeConfig("restore", fixture.config, fixture.backup);
    assert.notEqual(result.code, 0, `unexpectedly accepted: ${JSON.stringify(assignment)}`);
    assert.deepEqual(await fs.readFile(fixture.config), original);
    await fs.access(fixture.backup);
    await assert.rejects(fs.access(`${fixture.config}.dream-skin.lock`), { code: "ENOENT" });
  }

  const invalidExistingBackup = await writeFixture(
    "invalid-existing-install-backup",
    `appearanceTheme = "system"`,
  );
  await fs.writeFile(invalidExistingBackup.backup, "{}\n");
  const invalidExistingConfigBytes = await fs.readFile(invalidExistingBackup.config);
  const invalidExistingBackupBytes = await fs.readFile(invalidExistingBackup.backup);
  const invalidExistingInstall = await runThemeConfig(
    "install",
    invalidExistingBackup.config,
    invalidExistingBackup.backup,
  );
  assert.notEqual(invalidExistingInstall.code, 0, "install accepted an invalid existing recovery backup");
  assert.deepEqual(await fs.readFile(invalidExistingBackup.config), invalidExistingConfigBytes);
  assert.deepEqual(await fs.readFile(invalidExistingBackup.backup), invalidExistingBackupBytes);

  const lateBackup = path.join(tempRoot, "late-backup.json");
  let lateIdentity;
  await assert.rejects(
    atomicCreate(lateBackup, "transaction backup\n", 0o600, async () => {
      await fs.writeFile(lateBackup, "foreign late creator\n", { flag: "wx", mode: 0o644 });
      const stat = await fs.lstat(lateBackup, { bigint: true });
      lateIdentity = `${stat.dev}:${stat.ino}`;
    }),
    { code: "EEXIST" },
  );
  const lateAfter = await fs.lstat(lateBackup, { bigint: true });
  assert.equal(`${lateAfter.dev}:${lateAfter.ino}`, lateIdentity);
  assert.equal(await fs.readFile(lateBackup, "utf8"), "foreign late creator\n");
  assert.equal(Number(lateAfter.mode & 0o777n), 0o644);

  const receiptRace = path.join(tempRoot, "receipt-selection-race");
  const receiptRoot = path.join(receiptRace, "snapshot");
  const receiptConfig = path.join(receiptRace, "config.toml");
  const receiptBackup = path.join(receiptRace, "backup.json");
  await fs.mkdir(receiptRoot, { recursive: true });
  await fs.writeFile(receiptConfig, "published config\n");
  await fs.writeFile(receiptBackup, "published backup\n");
  const receiptRootStat = await fs.lstat(receiptRoot, { bigint: true });
  const receiptConfigStat = await fs.lstat(receiptConfig, { bigint: true });
  const receiptBackupStat = await fs.lstat(receiptBackup, { bigint: true });
  await fs.copyFile(receiptConfig, `${receiptConfig}.replacement`);
  await fs.rename(`${receiptConfig}.replacement`, receiptConfig);
  await assert.rejects(captureUpgradeExpected(
    receiptRoot,
    `${receiptRootStat.dev}:${receiptRootStat.ino}`,
    [
      {
        name: "config",
        target: receiptConfig,
        expectedIdentity: `${receiptConfigStat.dev}:${receiptConfigStat.ino}`,
      },
      {
        name: "live-backup",
        target: receiptBackup,
        expectedIdentity: `${receiptBackupStat.dev}:${receiptBackupStat.ino}`,
      },
    ],
  ));
  assert.equal(await fs.readFile(receiptConfig, "utf8"), "published config\n");

  const directoryRace = path.join(tempRoot, "directory-publish-race");
  const directorySnapshot = path.join(directoryRace, "snapshot");
  const directoryOriginalGroup = path.join(directorySnapshot, "original");
  const directoryLive = path.join(directoryRace, "theme");
  const directoryStage = path.join(directorySnapshot, "staged");
  await fs.mkdir(directoryOriginalGroup, { recursive: true });
  await fs.mkdir(directoryLive, { recursive: true });
  await fs.mkdir(directoryStage);
  await fs.writeFile(path.join(directoryLive, "theme.json"), "original directory\n");
  await fs.writeFile(path.join(directoryStage, "theme.json"), "staged directory\n");
  const directoryRootStat = await fs.lstat(directorySnapshot, { bigint: true });
  const directoryLiveStat = await fs.lstat(directoryLive, { bigint: true });
  await fs.cp(directoryLive, path.join(directoryOriginalGroup, "active-theme"), { recursive: true });
  await fs.writeFile(
    path.join(directoryOriginalGroup, "active-theme.state"),
    `present\n${directoryLiveStat.dev}:${directoryLiveStat.ino}\nunused\n`,
  );
  const originalReceipt = await finalizeUpgradeReceipt(
    directorySnapshot,
    `${directoryRootStat.dev}:${directoryRootStat.ino}`,
    directoryOriginalGroup,
    "original",
    ["active-theme.state", directoryLive],
  );
  const stagedGroup = await fs.mkdtemp(path.join(directorySnapshot, ".expected."));
  const directoryStageStat = await fs.lstat(directoryStage, { bigint: true });
  await fs.cp(directoryStage, path.join(stagedGroup, "active-theme"), { recursive: true });
  await fs.writeFile(
    path.join(stagedGroup, "active-theme.state"),
    `present\n${directoryStageStat.dev}:${directoryStageStat.ino}\nunused\n`,
  );
  const stagedReceipt = await finalizeUpgradeReceipt(
    directorySnapshot,
    `${directoryRootStat.dev}:${directoryRootStat.ino}`,
    stagedGroup,
    "expected",
    ["active-theme.state", directoryStage],
  );
  const heldDirectory = path.join(directorySnapshot, "held-active-theme");
  const realMkdir = fs.mkdir;
  let lateDirectoryIdentity;
  fs.mkdir = async (target, options) => {
    if (target === directoryLive) {
      await realMkdir(directoryLive);
      await fs.writeFile(path.join(directoryLive, "foreign"), "foreign directory\n");
      const late = await fs.lstat(directoryLive, { bigint: true });
      lateDirectoryIdentity = `${late.dev}:${late.ino}`;
    }
    return realMkdir(target, options);
  };
  try {
    await assert.rejects(replaceUpgradeReceiptEntry({
      snapshotRoot: directorySnapshot,
      rootIdentity: `${directoryRootStat.dev}:${directoryRootStat.ino}`,
      originalGroup: directoryOriginalGroup,
      originalGroupIdentity: originalReceipt.groupIdentity,
      originalReceiptIdentity: originalReceipt.receiptIdentity,
      originalReceiptDigest: originalReceipt.receiptDigest,
      expectedGroup: stagedReceipt.finalGroup,
      entryName: "active-theme.state",
      livePath: directoryLive,
      stagedPath: directoryStage,
      heldPath: heldDirectory,
      quarantinePath: heldDirectory,
      direction: "publish",
    }), { code: "EEXIST" });
  } finally {
    fs.mkdir = realMkdir;
  }
  const lateDirectoryAfter = await fs.lstat(directoryLive, { bigint: true });
  assert.equal(`${lateDirectoryAfter.dev}:${lateDirectoryAfter.ino}`, lateDirectoryIdentity);
  assert.equal(await fs.readFile(path.join(directoryLive, "foreign"), "utf8"), "foreign directory\n");
  assert.equal(await fs.readFile(path.join(heldDirectory, "theme.json"), "utf8"), "original directory\n");

  const postStateRace = path.join(tempRoot, "publish-post-state-race");
  const postStateSnapshot = path.join(postStateRace, "snapshot");
  const postStateOriginalGroup = path.join(postStateSnapshot, "original");
  const postStateLive = path.join(postStateRace, "live");
  const postStateStage = path.join(postStateRace, "stage");
  const postStateHeld = path.join(postStateSnapshot, "held-entry");
  await fs.mkdir(postStateOriginalGroup, { recursive: true });
  await fs.writeFile(postStateLive, "original post-state\n");
  await fs.writeFile(postStateStage, "published post-state\n");
  const postStateRootStat = await fs.lstat(postStateSnapshot, { bigint: true });
  const postStateLiveStat = await fs.lstat(postStateLive, { bigint: true });
  await fs.copyFile(postStateLive, path.join(postStateOriginalGroup, "entry"));
  await fs.writeFile(
    path.join(postStateOriginalGroup, "entry.state"),
    `present\n${postStateLiveStat.dev}:${postStateLiveStat.ino}\nunused\n`,
  );
  const postStateOriginalReceipt = await finalizeUpgradeReceipt(
    postStateSnapshot,
    `${postStateRootStat.dev}:${postStateRootStat.ino}`,
    postStateOriginalGroup,
    "original",
    ["entry.state", postStateLive],
  );
  const postStateStageStat = await fs.lstat(postStateStage, { bigint: true });
  const postStateExpectedGroup = await fs.mkdtemp(path.join(postStateSnapshot, ".expected."));
  await fs.copyFile(postStateStage, path.join(postStateExpectedGroup, "entry"));
  await fs.writeFile(
    path.join(postStateExpectedGroup, "entry.state"),
    `present\n${postStateStageStat.dev}:${postStateStageStat.ino}\nunused\n`,
  );
  const postStateExpectedReceipt = await finalizeUpgradeReceipt(
    postStateSnapshot,
    `${postStateRootStat.dev}:${postStateRootStat.ino}`,
    postStateExpectedGroup,
    "expected",
    ["entry.state", postStateStage],
  );
  const realMkdtemp = fs.mkdtemp;
  let postStateForeignIdentity;
  fs.mkdtemp = async (prefix, options) => {
    if (prefix === path.join(postStateSnapshot, ".expected.") && !postStateForeignIdentity) {
      await fs.rename(postStateLive, `${postStateLive}.transaction-owned`);
      await fs.copyFile(`${postStateLive}.transaction-owned`, postStateLive);
      const foreign = await fs.lstat(postStateLive, { bigint: true });
      postStateForeignIdentity = `${foreign.dev}:${foreign.ino}`;
    }
    return realMkdtemp(prefix, options);
  };
  try {
    await assert.rejects(replaceUpgradeReceiptEntry({
      snapshotRoot: postStateSnapshot,
      rootIdentity: `${postStateRootStat.dev}:${postStateRootStat.ino}`,
      originalGroup: postStateOriginalGroup,
      originalGroupIdentity: postStateOriginalReceipt.groupIdentity,
      originalReceiptIdentity: postStateOriginalReceipt.receiptIdentity,
      originalReceiptDigest: postStateOriginalReceipt.receiptDigest,
      expectedGroup: postStateExpectedReceipt.finalGroup,
      entryName: "entry.state",
      livePath: postStateLive,
      stagedPath: postStateStage,
      heldPath: postStateHeld,
      quarantinePath: postStateHeld,
      direction: "publish",
    }));
  } finally {
    fs.mkdtemp = realMkdtemp;
  }
  const postStateForeign = await fs.lstat(postStateLive, { bigint: true });
  assert.equal(`${postStateForeign.dev}:${postStateForeign.ino}`, postStateForeignIdentity);
  assert.equal(await fs.readFile(postStateLive, "utf8"), "published post-state\n");
  assert.equal(await fs.readFile(postStateHeld, "utf8"), "original post-state\n");
  assert.equal(await fs.readFile(`${postStateLive}.transaction-owned`, "utf8"), "published post-state\n");

  async function makeRestoreRace(label, withHeld, originalPresent = true) {
    const root = path.join(tempRoot, label);
    const snapshot = path.join(root, "snapshot");
    const originalGroup = path.join(snapshot, "original");
    const live = path.join(root, "live");
    const held = path.join(snapshot, "held-entry");
    const originalSource = withHeld ? held : path.join(root, "original-source");
    await fs.mkdir(originalGroup, { recursive: true });
    const rootStat = await fs.lstat(snapshot, { bigint: true });
    if (originalPresent) {
      await fs.writeFile(originalSource, "original\n");
      await fs.copyFile(originalSource, path.join(originalGroup, "entry"));
      const originalStat = await fs.lstat(originalSource, { bigint: true });
      await fs.writeFile(
        path.join(originalGroup, "entry.state"),
        `present\n${originalStat.dev}:${originalStat.ino}\nunused\n`,
      );
    } else {
      await fs.writeFile(path.join(originalGroup, "entry.state"), "absent\n\nunused\n");
    }
    const originalReceipt = await finalizeUpgradeReceipt(
      snapshot,
      `${rootStat.dev}:${rootStat.ino}`,
      originalGroup,
      "original",
      ["entry.state", originalSource],
    );
    if (originalPresent && !withHeld) await fs.rm(originalSource);
    await fs.writeFile(live, "transaction\n");
    const liveStat = await fs.lstat(live, { bigint: true });
    const expectedGroup = await fs.mkdtemp(path.join(snapshot, ".expected."));
    await fs.copyFile(live, path.join(expectedGroup, "entry"));
    await fs.writeFile(
      path.join(expectedGroup, "entry.state"),
      `present\n${liveStat.dev}:${liveStat.ino}\nunused\n`,
    );
    const expectedReceipt = await finalizeUpgradeReceipt(
      snapshot,
      `${rootStat.dev}:${rootStat.ino}`,
      expectedGroup,
      "expected",
      ["entry.state", live],
    );
    return {
      snapshot,
      rootIdentity: `${rootStat.dev}:${rootStat.ino}`,
      originalGroup,
      originalReceipt,
      expectedGroup: expectedReceipt.finalGroup,
      live,
      held,
      failed: path.join(snapshot, "failed-entry"),
      temporary: path.join(snapshot, "restore-entry"),
    };
  }

  for (const withHeld of [true, false]) {
    const fixture = await makeRestoreRace(
      withHeld ? "held-restore-late-creator" : "copied-restore-late-creator",
      withHeld,
    );
    const realRename = fs.rename;
    const realLink = fs.link;
    let foreignIdentity;
    async function createForeign(destination) {
      await fs.writeFile(destination, "foreign late creator\n", { flag: "wx" });
      const foreign = await fs.lstat(destination, { bigint: true });
      foreignIdentity = `${foreign.dev}:${foreign.ino}`;
    }
    fs.rename = async (source, destination) => {
      const publicationSource = withHeld ? fixture.held : fixture.temporary;
      if (source === publicationSource && destination === fixture.live) {
        await createForeign(destination);
      }
      return realRename(source, destination);
    };
    fs.link = async (source, destination) => {
      if (destination === fixture.live) await createForeign(destination);
      return realLink(source, destination);
    };
    try {
      await assert.rejects(replaceUpgradeReceiptEntry({
        snapshotRoot: fixture.snapshot,
        rootIdentity: fixture.rootIdentity,
        originalGroup: fixture.originalGroup,
        originalGroupIdentity: fixture.originalReceipt.groupIdentity,
        originalReceiptIdentity: fixture.originalReceipt.receiptIdentity,
        originalReceiptDigest: fixture.originalReceipt.receiptDigest,
        expectedGroup: fixture.expectedGroup,
        entryName: "entry.state",
        livePath: fixture.live,
        heldPath: fixture.held,
        quarantinePath: fixture.failed,
        direction: "restore",
      }));
    } finally {
      fs.rename = realRename;
      fs.link = realLink;
    }
    const foreignAfter = await fs.lstat(fixture.live, { bigint: true });
    assert.equal(`${foreignAfter.dev}:${foreignAfter.ino}`, foreignIdentity);
    assert.equal(await fs.readFile(fixture.live, "utf8"), "foreign late creator\n");
    assert.equal(await fs.readFile(fixture.failed, "utf8"), "transaction\n");
    assert.equal(await fs.readFile(path.join(fixture.originalGroup, "entry"), "utf8"), "original\n");
    if (withHeld) assert.equal(await fs.readFile(fixture.held, "utf8"), "original\n");
  }

  const absentFixture = await makeRestoreRace("absent-restore-late-creator", false, false);
  const realAbsentRename = fs.rename;
  const realAbsentLstat = fs.lstat;
  let absentArmed = false;
  let absentForeignIdentity;
  fs.rename = async (source, destination) => {
    const result = await realAbsentRename(source, destination);
    if (source === absentFixture.live && destination === absentFixture.failed) absentArmed = true;
    return result;
  };
  fs.lstat = async (target, options) => {
    try {
      return await realAbsentLstat(target, options);
    } catch (error) {
      if (absentArmed && target === absentFixture.live && error.code === "ENOENT") {
        writeFileSync(absentFixture.live, "foreign absent creator\n", { flag: "wx" });
        const foreign = await realAbsentLstat(absentFixture.live, { bigint: true });
        absentForeignIdentity = `${foreign.dev}:${foreign.ino}`;
        absentArmed = false;
      }
      throw error;
    }
  };
  try {
    await assert.rejects(replaceUpgradeReceiptEntry({
      snapshotRoot: absentFixture.snapshot,
      rootIdentity: absentFixture.rootIdentity,
      originalGroup: absentFixture.originalGroup,
      originalGroupIdentity: absentFixture.originalReceipt.groupIdentity,
      originalReceiptIdentity: absentFixture.originalReceipt.receiptIdentity,
      originalReceiptDigest: absentFixture.originalReceipt.receiptDigest,
      expectedGroup: absentFixture.expectedGroup,
      entryName: "entry.state",
      livePath: absentFixture.live,
      heldPath: absentFixture.held,
      quarantinePath: absentFixture.failed,
      direction: "restore",
    }));
  } finally {
    fs.rename = realAbsentRename;
    fs.lstat = realAbsentLstat;
  }
  const absentForeign = await fs.lstat(absentFixture.live, { bigint: true });
  assert.equal(`${absentForeign.dev}:${absentForeign.ino}`, absentForeignIdentity);
  assert.equal(await fs.readFile(absentFixture.live, "utf8"), "foreign absent creator\n");
  assert.equal(await fs.readFile(absentFixture.failed, "utf8"), "transaction\n");

  assert.equal(typeof consumeUpgradeTree, "function", "upgrade cleanup helper is not exported");
  const cleanupTree = path.join(tempRoot, "cleanup-tree");
  await fs.mkdir(cleanupTree);
  await fs.writeFile(path.join(cleanupTree, "recovery"), "exact recovery bytes\n");
  const cleanupTreeStat = await fs.lstat(cleanupTree, { bigint: true });
  const cleanupTreeIdentity = `${cleanupTreeStat.dev}:${cleanupTreeStat.ino}`;
  let cleanupQuarantine;
  let cleanupForeignIdentity;
  await assert.rejects(consumeUpgradeTree(cleanupTree, cleanupTreeIdentity, async (quarantine) => {
    cleanupQuarantine = quarantine;
    await fs.rename(quarantine, `${quarantine}.transaction-owned`);
    await fs.cp(`${quarantine}.transaction-owned`, quarantine, { recursive: true, preserveTimestamps: true });
    const foreign = await fs.lstat(quarantine, { bigint: true });
    cleanupForeignIdentity = `${foreign.dev}:${foreign.ino}`;
  }), /changed.*preserved/i);
  const cleanupForeign = await fs.lstat(cleanupQuarantine, { bigint: true });
  assert.equal(`${cleanupForeign.dev}:${cleanupForeign.ino}`, cleanupForeignIdentity);
  assert.equal(await fs.readFile(path.join(cleanupQuarantine, "recovery"), "utf8"), "exact recovery bytes\n");
  const displacedCleanup = `${cleanupQuarantine}.transaction-owned`;
  const displacedCleanupStat = await fs.lstat(displacedCleanup, { bigint: true });
  assert.equal(`${displacedCleanupStat.dev}:${displacedCleanupStat.ino}`, cleanupTreeIdentity);
  assert.equal(await fs.readFile(path.join(displacedCleanup, "recovery"), "utf8"), "exact recovery bytes\n");

  console.log("PASS: theme config install/restore accepts only editable TOML and complete single-line string backups.");
} finally {
  await fs.rm(tempRoot, { recursive: true, force: true });
}
