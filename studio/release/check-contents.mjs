import fs from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import path from "node:path";

const FILE_OPEN_FLAGS = fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0);
const DIRECTORY_OPEN_FLAGS = FILE_OPEN_FLAGS | (fsConstants.O_DIRECTORY ?? 0);
const CAN_OPEN_DIRECTORY_HANDLE = typeof fsConstants.O_DIRECTORY === "number";

class ReleaseContentError extends Error {
  constructor(reason) {
    super(reason);
    this.reason = reason;
  }
}

function reject(reason) {
  throw new ReleaseContentError(reason);
}

async function readFilesystem(operation) {
  try {
    return await operation();
  } catch {
    reject("filesystem error");
  }
}

function sameIdentity(left, right) {
  return left.dev === right.dev && left.ino === right.ino;
}

function sameStableStat(left, right) {
  return sameIdentity(left, right)
    && left.size === right.size
    && left.mtimeMs === right.mtimeMs
    && left.ctimeMs === right.ctimeMs;
}

async function readStableFile(filePath, pathStat) {
  let handle;
  try {
    handle = await readFilesystem(() => fs.open(filePath, FILE_OPEN_FLAGS));
    const openedStat = await readFilesystem(() => handle.stat());
    if (!pathStat.isFile() || !openedStat.isFile() || !sameStableStat(pathStat, openedStat)) {
      reject("filesystem changed");
    }
    const bytes = await readFilesystem(() => handle.readFile());
    const descriptorAfter = await readFilesystem(() => handle.stat());
    const pathAfter = await readFilesystem(() => fs.lstat(filePath));
    if (
      pathAfter.isSymbolicLink()
      || !pathAfter.isFile()
      || !sameStableStat(openedStat, descriptorAfter)
      || !sameStableStat(openedStat, pathAfter)
    ) reject("filesystem changed");
    return bytes;
  } finally {
    if (handle) await readFilesystem(() => handle.close());
  }
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
    const stat = await fs.lstat(file);
    if (stat.isSymbolicLink() || !stat.isFile()) reject("invalid allowlist");
    entries = JSON.parse((await readStableFile(file, stat)).toString("utf8"));
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
    || (lower.startsWith("screen shot ") && lower.endsWith(".png"))
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

function containsUserPathText(text) {
  const withoutRuntimeTemplate = text.replace(/"\/Users\/\$CURRENT_USER"/g, "");
  return /\/Users\/[^/\0\r\n]+\//.test(withoutRuntimeTemplate)
    || /C:\\Users\\[^\\\0\r\n]+\\/i.test(text);
}

function containsUserPath(bytes) {
  return containsUserPathText(bytes.toString("latin1"))
    || containsUserPathText(bytes.toString("utf16le"));
}

async function scan(root, allowedExecutables) {
  let rootStat;
  try {
    rootStat = await fs.lstat(root);
  } catch {
    reject("invalid root");
  }
  if (rootStat.isSymbolicLink() || !rootStat.isDirectory()) reject("invalid root");
  const foundExecutables = new Set();

  async function visit(directory, directoryStat, relativeDirectory = "") {
    let directoryHandle;
    let identityHandle;
    try {
      let openedStat = directoryStat;
      if (CAN_OPEN_DIRECTORY_HANDLE) {
        identityHandle = await readFilesystem(() => fs.open(directory, DIRECTORY_OPEN_FLAGS));
        openedStat = await readFilesystem(() => identityHandle.stat());
        if (!openedStat.isDirectory() || !sameStableStat(directoryStat, openedStat)) {
          reject("filesystem changed");
        }
      }
      directoryHandle = await readFilesystem(() => fs.opendir(directory));
      const pathAfterOpen = await readFilesystem(() => fs.lstat(directory));
      if (
        pathAfterOpen.isSymbolicLink()
        || !pathAfterOpen.isDirectory()
        || !sameStableStat(directoryStat, pathAfterOpen)
      ) reject("filesystem changed");

      const names = [];
      let entry;
      while ((entry = await readFilesystem(() => directoryHandle.read())) !== null) {
        names.push(entry.name);
      }
      names.sort((left, right) => Buffer.compare(Buffer.from(left), Buffer.from(right)));
      for (const name of names) {
        if (forbiddenName(name)) reject("forbidden name");
        const relative = relativeDirectory ? `${relativeDirectory}/${name}` : name;
        const absolute = path.join(directory, name);
        const stat = await readFilesystem(() => fs.lstat(absolute));
        if (stat.isSymbolicLink()) reject("symbolic link");
        if (stat.isDirectory()) {
          await visit(absolute, stat, relative);
          continue;
        }
        if (!stat.isFile()) reject("unsupported filesystem entry");
        const bytes = await readStableFile(absolute, stat);
        if (containsUserPath(bytes)) reject("absolute user path");
        if (isNativeExecutable(bytes)) {
          if (!allowedExecutables.has(relative)) reject("undeclared native executable");
          foundExecutables.add(relative);
        }
      }

      const pathAfter = await readFilesystem(() => fs.lstat(directory));
      if (
        pathAfter.isSymbolicLink()
        || !pathAfter.isDirectory()
        || !sameStableStat(directoryStat, pathAfter)
      ) reject("filesystem changed");
      if (identityHandle) {
        const descriptorAfter = await readFilesystem(() => identityHandle.stat());
        if (!descriptorAfter.isDirectory() || !sameStableStat(openedStat, descriptorAfter)) {
          reject("filesystem changed");
        }
      }
    } finally {
      if (directoryHandle) await readFilesystem(() => directoryHandle.close());
      if (identityHandle) await readFilesystem(() => identityHandle.close());
    }
  }

  await visit(root, rootStat);
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
  const reason = error instanceof ReleaseContentError ? error.reason : "filesystem error";
  console.error(`FAIL: release contents rejected: ${reason}.`);
  process.exitCode = 1;
}
