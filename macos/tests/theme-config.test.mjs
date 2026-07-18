import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const macosRoot = path.resolve(here, "..");
const themeConfig = path.join(macosRoot, "scripts", "theme-config.mjs");
const tempRoot = await fs.mkdtemp(path.join("/tmp", "codex-dream-skin-config-"));

function runRestore(config, backup) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [themeConfig, "restore", config, backup], {
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
    const result = await runRestore(fixture.config, fixture.backup);
    assert.equal(result.code, 0, `${assignment}\n${result.stderr}`);
    assert.equal(
      await fs.readFile(fixture.config, "utf8"),
      `[desktop]\nkeepMe = true\n${assignment}\n`,
    );
    await assert.rejects(fs.access(fixture.backup), { code: "ENOENT" });
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
    const result = await runRestore(fixture.config, fixture.backup);
    assert.equal(result.code, 0, `${label}\n${result.stderr}`);
    assert.equal(await fs.readFile(fixture.config, "utf8"), expected);
  }

  const bom = Buffer.from([0xef, 0xbb, 0xbf]);
  const bomFixture = await writeFixture(
    "bom-first-desktop",
    `appearanceTheme = "system"`,
    Buffer.concat([bom, Buffer.from(`[desktop]\nappearanceTheme = "dark"\n`)]),
  );
  const bomResult = await runRestore(bomFixture.config, bomFixture.backup);
  assert.equal(bomResult.code, 0, bomResult.stderr);
  assert.deepEqual(
    await fs.readFile(bomFixture.config),
    Buffer.concat([bom, Buffer.from(`[desktop]\nappearanceTheme = "system"\n`)]),
  );

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
  for (const [index, config] of ambiguousLayouts.entries()) {
    const fixture = await writeFixture(
      `ambiguous-layout-${index}`,
      `appearanceTheme = "system"`,
      config,
    );
    const original = await fs.readFile(fixture.config);
    const result = await runRestore(fixture.config, fixture.backup);
    assert.notEqual(result.code, 0, `unexpectedly accepted: ${JSON.stringify(config)}`);
    assert.deepEqual(await fs.readFile(fixture.config), original);
    await fs.access(fixture.backup);
  }

  for (const [index, assignment] of invalidAssignments.entries()) {
    const fixture = await writeFixture(`invalid-${index}`, assignment);
    const original = await fs.readFile(fixture.config);
    const result = await runRestore(fixture.config, fixture.backup);
    assert.notEqual(result.code, 0, `unexpectedly accepted: ${JSON.stringify(assignment)}`);
    assert.deepEqual(await fs.readFile(fixture.config), original);
    await fs.access(fixture.backup);
    await assert.rejects(fs.access(`${fixture.config}.dream-skin.lock`), { code: "ENOENT" });
  }

  console.log("PASS: theme backup restore accepts only complete single-line TOML string assignments.");
} finally {
  await fs.rm(tempRoot, { recursive: true, force: true });
}
