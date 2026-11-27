// 真实环境体验测试主框架：启动编辑器（Godot 跑本仓库编辑器工程）+ MCP HTTP，跑六组操作。
// 用法: node tools/exp/run.js --logs <dir>
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { buildFixture } = require("./fixture.js");
const groups = require("./groups.js");

const ROOT = path.resolve(__dirname, "..", "..");
const GODOT = "D:/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe";

let rpcId = 0;
const PASS = [];
const FAIL = [];

function check(name, cond, detail) {
  (cond ? PASS : FAIL).push(cond ? name : `${name} | ${JSON.stringify(detail)}`);
  console.log((cond ? "PASS " : "FAIL ") + name + (cond ? "" : " | " + JSON.stringify(detail)));
}

let PORT = 0;
let TOKEN = "experience-secret";

async function rpc(method, params, response = true) {
  rpcId += 1;
  const message = { jsonrpc: "2.0", method, ...(params ? { params } : {}) };
  if (response) message.id = rpcId;
  const res = await fetch(`http://127.0.0.1:${PORT}/mcp`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json, text/event-stream",
      "Authorization": `Bearer ${TOKEN}`,
    },
    body: JSON.stringify(message),
  });
  if (!response) return null;
  const obj = await res.json();
  if (obj.error) throw new Error(JSON.stringify(obj.error));
  return obj.result;
}

function makeCalls(logs) {
  const call = async (name, args = {}, expectError = false) => {
    const result = await rpc("tools/call", { name, arguments: args });
    if (result.isError !== expectError) throw new Error(`${name}: ${JSON.stringify(result.structuredContent)}`);
    const media = (result.content || []).filter((r) => ["image", "audio"].includes(r.type));
    return [result.structuredContent, media];
  };
  const shot = (media, name) => {
    if (!media || !media[0]) throw new Error(`no media for ${name}`);
    fs.writeFileSync(path.join(logs, `${name}.png`), Buffer.from(media[0].data, "base64"));
  };
  return { call, shot };
}

async function main() {
  const logsArg = process.argv.indexOf("--logs");
  const logs = path.resolve(process.argv[logsArg + 1] || "logs-experience");
  fs.mkdirSync(logs, { recursive: true });
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "exp-"));
  const game = path.join(root, "experience");
  buildFixture(game, GODOT);
  const server = await new Promise((resolve) => {
    const s = require("net").createServer();
    s.listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => resolve(p)); });
  });
  PORT = server;
  const args = [GODOT, "--path", ROOT, "--rendering-method", "gl_compatibility", "--audio-driver", "Dummy",
    "--resolution", "1280x800", "--", `--bird-mcp=${PORT}`, `--bird-project=${game.split(path.sep).join("/")}`];
  const proc = spawn(args[0], args.slice(1), {
    env: { ...process.env, APPDATA: path.join(root, "profile"), BIRD_MCP_TOKEN: TOKEN },
    stdio: "ignore",
  });
  try {
    for (let i = 0; i < 150; i++) {
      if (proc.exitCode !== null) throw new Error("editor exited at startup");
      try { await rpc("initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "exp", version: "1" } }); break; }
      catch { await new Promise((r) => setTimeout(r, 200)); }
    }
    await rpc("notifications/initialized", null, false);
    const { call, shot } = makeCalls(logs);
    console.log("editor up:", game);
    await groups.runAll(call, shot, logs, check);
    console.log(`\n===== PASS ${PASS.length}  FAIL ${FAIL.length} =====`);
    if (FAIL.length) { FAIL.forEach((f) => console.log("FAIL:", f)); process.exitCode = 1; }
  } finally {
    proc.kill();
  }
}

if (require.main === module) main().catch((e) => { console.error("ERROR", e.message); process.exit(1); });
