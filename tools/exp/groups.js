// 协调器：六组体验操作，实现分散在 ops1/ops2/ops3。
const { groupProjection } = require("./ops1.js");
const { groupGameplay, groupUi } = require("./ops2.js");
const { groupTriggers, groupComplex, groupE2e } = require("./ops3.js");

const ids = {};

let draft = "";
let revision = 0;

async function apply(call, operations) {
  const [data] = await call("apply_changes", { draft, revision, operations });
  revision = data.revision;
  for (const [k, v] of Object.entries(data.aliases || {})) ids[k.slice(1)] = v;
  return data;
}

async function runAll(call, shot, logs, check) {
  let info = {};
  for (let i = 0; i < 50; i++) {
    const [r] = await call("describe_project");
    info = r.manifest || {};
    if (info.projectName === "体验测试工程") break;
    await new Promise((r2) => setTimeout(r2, 200));
  }
  check("工程已打开", info.projectName === "体验测试工程", info.projectName);
  const [d] = await call("manage_draft", { action: "create", name: "体验草稿" });
  draft = d.id;
  console.log("draft:", draft);
  const ctx = { call, shot, logs, check, ids, draft, apply: (ops) => apply(call, ops) };
  await groupProjection(ctx);
  await groupGameplay(ctx);
  await groupUi(ctx);
  await groupTriggers(ctx);
  await groupComplex(ctx);
  await groupE2e(ctx);
  const [plan] = await call("publish", { previewOnly: true, draft, revision });
  check("publish 预览计划", Array.isArray(plan.entries) && plan.entries.length === 10, plan.entries && plan.entries.length);
  const [done] = await call("publish", { draft, revision });
  check("publish 落盘", Array.isArray(done.files) && done.files.length > 0, done);
}

module.exports = { runAll, ids };
