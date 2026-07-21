import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const injectorPath = path.join(root, "scripts", "injector.mjs");
const temporary = await fs.mkdtemp("/tmp/codex-dream-skin-windows-anchor-");
let browserId = "Browser-A";
let targets = [];
let closeAnchorOnList = false;
let closeAnchorDuringPageOpen = false;
let closeAnchorAfterProbe = false;
let anchorClosedAfterProbe = false;
const requests = [];
const browserSockets = new Set();
const pageSockets = new Set();
const rendererCommands = [];
const postAnchorCommands = [];
const activeChildren = new Set();

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
      if (opcode === 0x8) { socket.destroy(); return; }
      const message = JSON.parse(body.toString("utf8"));
      rendererCommands.push(message.method);
      if (anchorClosedAfterProbe) postAnchorCommands.push(message.method);
      let result = {};
      if (message.method === "Page.addScriptToEvaluateOnNewDocument") {
        result = { identifier: "replacement-script" };
      } else if (message.method === "Page.captureScreenshot") {
        result = { data: Buffer.from("replacement").toString("base64") };
      } else if (message.method === "Runtime.evaluate") {
        const expression = message.params?.expression ?? "";
        let value = true;
        if (expression.includes("const markers")) {
          value = { markers: { shell: true, sidebar: true, composer: true, main: true }, codex: true };
        } else if (expression.includes("width: innerWidth")) {
          value = { width: 1200, height: 800 };
        } else if (expression.includes("const result =")) {
          value = { pass: true };
        }
        result = { result: { value } };
      }
      const response = websocketFrame(JSON.stringify({ id: message.id, result }));
      const isProbe = message.method === "Runtime.evaluate" &&
        String(message.params?.expression ?? "").includes("const markers");
      if (closeAnchorAfterProbe && isProbe) {
        closeAnchorAfterProbe = false;
        anchorClosedAfterProbe = true;
        for (const browserSocket of browserSockets) browserSocket.destroy();
        setTimeout(() => socket.write(response), 75);
      } else {
        socket.write(response);
      }
    }
  };
  socket.on("data", consume);
  if (head.length) consume(head);
}

const server = http.createServer((request, response) => {
  requests.push(request.url);
  response.setHeader("content-type", "application/json");
  if (request.url === "/json/version") {
    response.end(JSON.stringify({
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
  const acceptUpgrade = () => socket.write([
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Accept: ${accept}`,
    "",
    "",
  ].join("\r\n"));
  if (request.url?.startsWith("/devtools/browser/")) {
    acceptUpgrade();
    browserSockets.add(socket);
    socket.on("data", () => {});
    socket.once("close", () => browserSockets.delete(socket));
    return;
  }
  pageSockets.add(socket);
  socket.once("close", () => pageSockets.delete(socket));
  if (closeAnchorDuringPageOpen) {
    closeAnchorDuringPageOpen = false;
    for (const browserSocket of browserSockets) browserSocket.destroy();
    setTimeout(() => { acceptUpgrade(); attachCdpSocket(socket, head); }, 100);
  } else {
    acceptUpgrade();
    attachCdpSocket(socket, head);
  }
});

await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(0, "127.0.0.1", resolve);
});
const port = server.address().port;

function launch(args) {
  const child = spawn(process.execPath, [injectorPath, ...args], { stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  const completed = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code, signal) => resolve({ code, signal, stdout, stderr }));
  });
  const handle = { child, completed };
  activeChildren.add(handle);
  completed.finally(() => activeChildren.delete(handle));
  return handle;
}

async function withDeadline(promise, message, timeoutMs = 6000) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(message)), timeoutMs); }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}

async function cleanupChild(handle) {
  if (handle.child.exitCode === null && handle.child.signalCode === null) handle.child.kill("SIGKILL");
  await withDeadline(handle.completed, "injector child did not terminate during cleanup", 2000);
}

async function run(args) {
  const handle = launch(args);
  try {
    return await withDeadline(handle.completed, "injector child exceeded its deadline");
  } finally {
    await cleanupChild(handle);
  }
}

try {
  let result = await run(["--verify", "--port", String(port), "--timeout-ms", "250"]);
  assert.notEqual(result.code, 0);
  assert.match(result.stderr, /--browser-id is required/);

  browserId = "Browser-A";
  targets = [{
    type: "page",
    id: "Replacement-Page",
    title: "Replacement Codex",
    url: "app://codex/",
    webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/Replacement-Page`,
  }];
  const oneShotCases = [
    ["verify", ["--verify"]],
    ["once", ["--once"]],
    ["remove", ["--remove"]],
    ["reload/capture", ["--once", "--reload", "--screenshot", path.join(temporary, "replacement.png")]],
  ];
  for (const [label, modeArgs] of oneShotCases) {
    rendererCommands.length = 0;
    postAnchorCommands.length = 0;
    anchorClosedAfterProbe = false;
    closeAnchorAfterProbe = true;
    result = await run([
      ...modeArgs, "--port", String(port), "--browser-id", "Browser-A", "--timeout-ms", "750",
    ]);
    assert.deepEqual(postAnchorCommands, [], `${label} sent its command sequence after the original Browser anchor closed`);
    assert.notEqual(result.code, 0, `${label} accepted a replacement browser`);
  }

  rendererCommands.length = 0;
  closeAnchorDuringPageOpen = true;
  const watcher = launch([
    "--watch", "--port", String(port), "--browser-id", "Browser-A", "--theme-dir", path.join(root, "assets"),
  ]);
  try {
    result = await withDeadline(watcher.completed, "watcher did not stop after Browser anchor replacement", 4000);
    assert.deepEqual(rendererCommands, [], "watch sent renderer commands after the original Browser anchor closed");
    assert.notEqual(result.code, 0, "watch accepted a replacement browser");
  } finally {
    await cleanupChild(watcher);
  }

  console.log("PASS: Windows injector guards every renderer command with the original Browser anchor.");
} finally {
  const cleanup = await Promise.allSettled([...activeChildren].map(cleanupChild));
  for (const socket of browserSockets) socket.destroy();
  for (const socket of pageSockets) socket.destroy();
  await new Promise((resolve) => server.close(resolve));
  await fs.rm(temporary, { recursive: true, force: true });
  const failure = cleanup.find((entry) => entry.status === "rejected");
  if (failure) throw failure.reason;
}
