// 极限体验主框架：四类型+极限图层/数据，六组操作（计时+截图+validate）。
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { buildFixture2 } = require("./fixture2.js");
const groups = require("./groups2.js");
const { groupUltra } = require("./ops-ultra.js");

const GODOT = "D:/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe";
const ROOT = path.resolve(__dirname, "..", "..");

let rpcId = 0;
const PASS = [];
const FAIL = [];
const TIMES = [];

function check(name, cond, detail) {
  (cond ? PASS : FAIL).push(cond ? name : `${name} | ${JSON.stringify(detail).slice(0, 400)}`);
  console.log((cond ? "PASS " : "FAIL ") + name + (cond ? "" : " | " + JSON.stringify(detail).slice(0, 400)));
}

function timed(name) {
  const t0 = Date.now();
  return () => TIMES.push([name, Date.now() - t0]);
}

let PORT = 0;
let draft = "";
let revision = 0;

async function rpc(method, params, response = true) {
  rpcId += 1;
  const message = { jsonrpc: "2.0", method, ...(params ? { params } : {}) };
  if (response) message.id = rpcId;
  const res = await fetch(`http://127.0.0.1:${PORT}/mcp`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
      "Authorization": "Bearer exp2-secret" },
    body: JSON.stringify(message),
  });
  if (!response) return null;
  const obj = await res.json();
  if (obj.error) throw new Error(JSON.stringify(obj.error));
  return obj.result;
}

async function call(name, args = {}) {
  const result = await rpc("tools/call", { name, arguments: args });
  if (result.isError) throw new Error(`${name}: ${JSON.stringify(result.structuredContent).slice(0, 300)}`);
  return [result.structuredContent, (result.content || []).filter((r) => ["image", "audio"].includes(r.type))];
}

async function apply(operations) {
  const [data] = await call("apply_changes", { draft, revision, operations });
  revision = data.revision;
  for (const [k, v] of Object.entries(data.aliases || {})) groups.ids[k.slice(1)] = v;
  return data;
}

function ctx(logs, check) {
  return { apply, call, ids: groups.ids, draft: () => draft, logs, check, timed };
}

async function main() {
  const logsArg = process.argv.indexOf("--logs");
  const logs = path.resolve(process.argv[logsArg + 1] || "logs-exp2");
  fs.mkdirSync(logs, { recursive: true });
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "exp2-"));
  const game = path.join(root, "experience");
  buildFixture2(game, GODOT);
  const port = await new Promise((resolve) => {
    const s = require("net").createServer();
    s.listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => resolve(p)); });
  });
  PORT = port;
  const proc = spawn(GODOT, ["--path", ROOT, "--rendering-method", "gl_compatibility", "--audio-driver", "Dummy",
    "--resolution", "1280x800", "--", `--bird-mcp=${port}`, `--bird-project=${game.split(path.sep).join("/")}`],
    { env: { ...process.env, APPDATA: path.join(root, "profile"), BIRD_MCP_TOKEN: "exp2-secret" }, stdio: "ignore" });
  try {
    for (let i = 0; i < 150; i++) {
      if (proc.exitCode !== null) throw new Error("editor exited");
      try { await rpc("initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "exp2", version: "1" } }); break; }
      catch { await new Promise((r) => setTimeout(r, 200)); }
    }
    await rpc("notifications/initialized", null, false);
    let info = {};
    for (let i = 0; i < 50; i++) {
      info = (await call("describe_project", {}))[0].manifest || {};
      if (info.projectName) break;
      await new Promise((r) => setTimeout(r, 200));
    }
    check("工程打开", Boolean(info.projectName), info);
    const [d] = await call("manage_draft", { action: "create", name: "极限草稿" });
    draft = d.id;
    const c = ctx(logs, check);
    const shot = (media, name) => {
      if (!media || !media[0]) throw new Error(`no media for ${name}`);
      fs.writeFileSync(path.join(logs, `${name}.png`), Buffer.from(media[0].data, "base64"));
    };
    const cap = async (args, name) => {
      const t0 = Date.now();
      const [, media] = await call("capture_editor", args);
      shot(media, name);
      TIMES.push([`截图:${name}`, Date.now() - t0]);
    };
    await groups.groupCards(c);
    await groups.groupTowerDefense(c);
    await groups.groupMetroidvania(c);
    await groups.groupRhythm(c);
    await groups.groupLayers(c);
    await groups.groupStress(c);
    await groupUltra(c);
    await cap({ target: "draft_map", draft, map: groups.ids.deep, width: 640, height: 400 }, "deep-layers");
    await cap({ target: "draft_map", draft, map: groups.ids.td, width: 640, height: 400 }, "td-graph");
    await cap({ width: 640, height: 400 }, "editor-window");
    await cap({ panel: "screens", view: "title", width: 520, height: 360 }, "screens-panel");
    const [v] = await call("validate");
    check("全工程 validate", v.valid === true, v.issues);
    console.log("TIMES:", JSON.stringify(TIMES));
    console.log(`\n===== PASS ${PASS.length}  FAIL ${FAIL.length} =====`);
    if (FAIL.length) process.exitCode = 1;
  } finally {
    proc.kill();
  }
}

if (require.main === module) main().catch((e) => { console.error("ERROR", e.message); process.exit(1); });
