import fs from "node:fs/promises";
import path from "node:path";

function reject(reason) {
  throw new Error(reason);
}

function parseArguments(args) {
  if (args.length !== 4) reject("invalid arguments");
  const values = new Map();
  for (let index = 0; index < args.length; index += 2) {
    const option = args[index];
    const value = args[index + 1];
    if (!["--root", "--allowlist"].includes(option) || !value || values.has(option)) {
      reject("invalid arguments");
    }
    values.set(option, value);
  }
  if (values.size !== 2) reject("invalid arguments");
  return { root: values.get("--root"), allowlist: values.get("--allowlist") };
}

async function readAllowlist(file) {
  let entries;
  try {
    entries = JSON.parse(await fs.readFile(file, "utf8"));
  } catch {
    reject("invalid allowlist");
  }
  if (!Array.isArray(entries) || entries.length === 0) reject("invalid allowlist");
  const unique = new Set();
  for (const entry of entries) {
    if (
      typeof entry !== "string"
      || entry.length === 0
      || entry.includes("\\")
      || entry.includes("\0")
      || path.posix.isAbsolute(entry)
      || path.posix.normalize(entry) !== entry
      || entry.split("/").some((part) => part === "" || part === "." || part === "..")
      || unique.has(entry)
    ) reject("invalid allowlist");
    unique.add(entry);
  }
  return unique;
}

function forbiddenName(name) {
  const lower = name.toLowerCase();
  return lower === "state.json"
    || lower === "auth.json"
    || lower === "config.toml"
    || lower.endsWith(".log")
    || lower.startsWith("config.before-")
    || lower === "theme-backup.json"
    || lower === ".git"
    || lower === "screenshots"
    || lower.includes("screenshot")
    || lower === "codex dream skin verification.png";
}

function isNativeExecutable(bytes) {
  if (bytes.length >= 4) {
    const magic = bytes.subarray(0, 4).toString("hex");
    if ([
      "feedface", "cefaedfe", "feedfacf", "cffaedfe",
      "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    ].includes(magic)) return true;
  }
  if (bytes.length < 64 || bytes[0] !== 0x4d || bytes[1] !== 0x5a) return false;
  const peOffset = bytes.readUInt32LE(0x3c);
  return peOffset <= bytes.length - 4 && bytes.subarray(peOffset, peOffset + 4).equals(
    Buffer.from([0x50, 0x45, 0x00, 0x00]),
  );
}

function containsUserPath(bytes) {
  const text = bytes.toString("latin1");
  return /\/Users\/[^/\0\r\n"'$\\\s]+\//.test(text)
    || /C:\\Users\\[^\\\0\r\n"'$]+\\/i.test(text);
}

async function scan(root, allowedExecutables) {
  const rootStat = await fs.lstat(root).catch(() => reject("invalid root"));
  if (rootStat.isSymbolicLink() || !rootStat.isDirectory()) reject("invalid root");
  const foundExecutables = new Set();

  async function visit(directory, relativeDirectory = "") {
    const names = await fs.readdir(directory);
    names.sort((left, right) => left.localeCompare(right, "en"));
    for (const name of names) {
      if (forbiddenName(name)) reject("forbidden name");
      const relative = relativeDirectory ? `${relativeDirectory}/${name}` : name;
      const absolute = path.join(directory, name);
      const stat = await fs.lstat(absolute);
      if (stat.isSymbolicLink()) reject("symbolic link");
      if (stat.isDirectory()) {
        await visit(absolute, relative);
        continue;
      }
      if (!stat.isFile()) reject("unsupported filesystem entry");
      const bytes = await fs.readFile(absolute);
      if (containsUserPath(bytes)) reject("absolute user path");
      if (isNativeExecutable(bytes)) {
        if (!allowedExecutables.has(relative)) reject("undeclared native executable");
        foundExecutables.add(relative);
      }
    }
  }

  await visit(root);
  for (const entry of allowedExecutables) {
    if (!foundExecutables.has(entry)) reject("missing declared native executable");
  }
}

try {
  const options = parseArguments(process.argv.slice(2));
  const allowlist = await readAllowlist(options.allowlist);
  await scan(options.root, allowlist);
  console.log("PASS: release contents verified.");
} catch (error) {
  console.error(`FAIL: release contents rejected: ${error.message}.`);
  process.exitCode = 1;
}
