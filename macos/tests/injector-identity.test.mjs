import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const injector = path.join(root, "scripts", "injector.mjs");
const temporary = await fs.mkdtemp("/tmp/codex-dream-skin-browser-id-");
const themeDir = path.join(temporary, "theme");
await fs.cp(path.join(root, "presets", "preset-midnight-aurora"), themeDir, { recursive: true });

let browserId = "Browser-A";
let versionPayload = null;
let targets = [];
let closeAnchorOnList = false;
const requests = [];
const browserSockets = new Set();
const pageSockets = new Set();
const mutationCommands = [];

function websocketFrame(payload) {
  const body = Buffer.from(payload);
  if (body.length < 126) return Buffer.concat([Buffer.from([0x81, body.length]), body]);
  const header = Buffer.alloc(4);
  header[0] = 0x81;
  header[1] = 126;
  header.writeUInt16BE(body.length, 2);
  return Buffer.concat([header, body]);
}

function attachCdpSocket(socket, head) {
  let buffered = Buffer.alloc(0);
  const consume = (chunk) => {
    buffered = Buffer.concat([buffered, chunk]);
    while (buffered.length >= 6) {
      const opcode = buffered[0] & 0x0f;
      let offset = 2;
      let length = buffered[1] & 0x7f;
      if (length === 126) {
        if (buffered.length < 8) return;
        length = buffered.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (buffered.length < 14) return;
        length = Number(buffered.readBigUInt64BE(2));
        offset = 10;
      }
      if (buffered.length < offset + 4 + length) return;
      const mask = buffered.subarray(offset, offset + 4);
      const body = Buffer.from(buffered.subarray(offset + 4, offset + 4 + length));
      buffered = buffered.subarray(offset + 4 + length);
      for (let index = 0; index < body.length; index += 1) body[index] ^= mask[index % 4];
      if (opcode === 0x8) {
        socket.destroy();
        return;
      }
      const message = JSON.parse(body.toString("utf8"));
      if ([
        "Runtime.enable",
        "Page.enable",
        "Page.addScriptToEvaluateOnNewDocument",
        "Page.removeScriptToEvaluateOnNewDocument",
        "Runtime.evaluate",
      ].includes(message.method)) mutationCommands.push(message.method);
      const result = message.method === "Page.addScriptToEvaluateOnNewDocument"
        ? { identifier: "replacement-script" }
        : message.method === "Runtime.evaluate"
          ? { result: { value: { codex: true } } }
          : {};
      socket.write(websocketFrame(JSON.stringify({ id: message.id, result })));
    }
  };
  socket.on("data", consume);
  if (head.length) consume(head);
}

const server = http.createServer((request, response) => {
  requests.push(request.url);
  response.setHeader("content-type", "application/json");
  if (request.url === "/json/version") {
    response.end(JSON.stringify(versionPayload ?? {
      webSocketDebuggerUrl: `ws://127.0.0.1:${server.address().port}/devtools/browser/${browserId}`,
    }));
  } else if (request.url === "/json/list") {
    if (closeAnchorOnList) {
      closeAnchorOnList = false;
      for (const socket of browserSockets) socket.destroy();
      setTimeout(() => response.end(JSON.stringify(targets)), 75);
    } else {
      response.end(JSON.stringify(targets));
    }
  } else {
    response.statusCode = 404;
    response.end("{}");
  }
});

server.on("upgrade", (request, socket, head) => {
  const key = request.headers["sec-websocket-key"];
  const accept = createHash("sha1")
    .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest("base64");
  socket.write([
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Accept: ${accept}`,
    "",
    "",
  ].join("\r\n"));
  if (request.url?.startsWith("/devtools/browser/")) {
    browserSockets.add(socket);
    socket.on("data", () => socket.destroy());
    socket.once("close", () => browserSockets.delete(socket));
  } else {
    pageSockets.add(socket);
    socket.once("close", () => pageSockets.delete(socket));
    attachCdpSocket(socket, head);
  }
});

await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(0, "127.0.0.1", resolve);
});
const port = server.address().port;

function launch(args) {
  const child = spawn(process.execPath, [injector, ...args], { stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const completed = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code, signal) => resolve({ code, signal, get stdout() { return stdout; }, get stderr() { return stderr; } }));
  });
  return { child, completed, output: () => ({ stdout, stderr }) };
}

async function run(args) {
  return launch(args).completed;
}

async function waitFor(predicate, message, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(message);
}

async function withDeadline(promise, message, timeoutMs = 5000) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(message)), timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

try {
  let result = await run(["--verify", "--port", String(port), "--timeout-ms", "250"]);
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /--browser-id is required/);

  for (const mode of ["--verify", "--once", "--remove"]) {
    requests.length = 0;
    result = await run([
      mode, "--port", String(port), "--browser-id", "Browser-B", "--timeout-ms", "250",
    ]);
    assert.notEqual(result.code, 0);
    assert.equal(requests[0], "/json/version", `${mode} must validate Browser ID first`);
    assert.equal(requests.includes("/json/list"), false, `${mode} enumerated targets after Browser ID mismatch`);
    assert.match(result.stderr, /identity changed from Browser-B to Browser-A/);
  }

  const invalidVersions = [
    {},
    { webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/Browser-A` },
    { webSocketDebuggerUrl: `ws://0.0.0.0:${port}/devtools/browser/Browser-A` },
    { webSocketDebuggerUrl: `ws://localhost:${port}/devtools/browser/Browser-A` },
    { webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/browser/bad%20id` },
    { webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/browser/Browser-A?query=1` },
  ];
  for (const payload of invalidVersions) {
    versionPayload = payload;
    requests.length = 0;
    result = await run([
      "--verify", "--port", String(port), "--browser-id", "Browser-A", "--timeout-ms", "250",
    ]);
    assert.notEqual(result.code, 0);
    assert.equal(requests[0], "/json/version");
    assert.equal(requests.includes("/json/list"), false);
  }
  versionPayload = null;

  requests.length = 0;
  mutationCommands.length = 0;
  targets = [{
    type: "page",
    id: "Original-Page",
    title: "Original Codex",
    url: "app://codex/",
    webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/Original-Page`,
  }];
  const validWatcher = launch([
    "--watch", "--port", String(port), "--browser-id", "Browser-A", "--theme-dir", themeDir,
  ]);
  await waitFor(
    () => validWatcher.output().stdout.includes("injected verified Codex target Original-Page"),
    "valid watcher did not inject its anchored target",
  );
  const themePath = path.join(themeDir, "theme.json");
  const theme = JSON.parse(await fs.readFile(themePath, "utf8"));
  theme.tagline = "Browser anchored hot reload";
  await fs.writeFile(themePath, `${JSON.stringify(theme, null, 2)}\n`);
  await waitFor(
    () => validWatcher.output().stdout.includes("refreshed theme"),
    "same-browser watcher did not hot reload",
  );
  const removalsBeforeShutdown = mutationCommands
    .filter((command) => command === "Page.removeScriptToEvaluateOnNewDocument").length;
  validWatcher.child.kill("SIGTERM");
  result = await validWatcher.completed;
  assert.equal(result.code, 0, result.stderr);
  assert.equal(
    mutationCommands.filter((command) => command === "Page.removeScriptToEvaluateOnNewDocument").length,
    removalsBeforeShutdown + 1,
    "normal watcher shutdown did not remove its registered early script",
  );

  requests.length = 0;
  targets = [];
  const replacedWatcher = launch([
    "--watch", "--port", String(port), "--browser-id", "Browser-A", "--theme-dir", themeDir,
  ]);
  await waitFor(() => requests.includes("/json/list"), "replacement fixture watcher did not start");
  const listsBeforeReplacement = requests.filter((item) => item === "/json/list").length;
  browserId = "Browser-B";
  result = await replacedWatcher.completed;
  assert.notEqual(result.code, 0, "watcher accepted a replacement browser");
  assert.equal(requests.filter((item) => item === "/json/list").length, listsBeforeReplacement);
  assert.match(result.stderr, /identity changed from Browser-A to Browser-B/);

  browserId = "Browser-A";
  requests.length = 0;
  mutationCommands.length = 0;
  targets = [];
  const reusedIdWatcher = launch([
    "--watch", "--port", String(port), "--browser-id", "Browser-A", "--theme-dir", themeDir,
  ]);
  try {
    await waitFor(
      () => browserSockets.size > 0 && requests.includes("/json/list"),
      "reuse fixture watcher did not anchor and enumerate the original browser",
    );
    targets = [{
      type: "page",
      id: "Replacement-Page",
      title: "Replacement Codex",
      url: "app://codex/",
      webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/Replacement-Page`,
    }];
    closeAnchorOnList = true;
    result = await withDeadline(
      reusedIdWatcher.completed,
      "watcher did not stop after its original browser identity closed",
    );
    assert.notEqual(result.code, 0, "watcher adopted a new browser reusing the old Browser ID");
    assert.match(result.stderr, /browser identity.*closed/i);
    assert.deepEqual(mutationCommands, [], "replacement browser received CDP mutation commands");
  } finally {
    if (reusedIdWatcher.child.exitCode === null && reusedIdWatcher.child.signalCode === null) {
      reusedIdWatcher.child.kill("SIGKILL");
    }
    await withDeadline(
      reusedIdWatcher.completed,
      "reuse fixture watcher did not terminate during cleanup",
      2000,
    ).catch(() => {});
  }

  console.log("PASS: macOS injector anchors Browser ID before discovery and across hot reloads.");
} finally {
  for (const socket of browserSockets) socket.destroy();
  for (const socket of pageSockets) socket.destroy();
  await new Promise((resolve) => server.close(resolve));
  await fs.rm(temporary, { recursive: true, force: true });
}
