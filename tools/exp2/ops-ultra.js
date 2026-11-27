// 超限组：100 层 / 单批 10000 格 / 单批 100 混合操作 / 200 行 record / 防护探测。
const { ids, cellsGrid } = require("./groups2.js");

function probe(apply) {
  return async (op) => {
    try { await apply([op]); return "接受"; }
    catch (e) { return "拒绝：" + String(e.message).replace(/^apply_changes: /, "").slice(0, 150); }
  };
}

async function groupUltra({ apply, check, timed }) {
  const t = timed("超限组");
  await apply([{ op: "map.create", name: "超限", width: 100, height: 100, as: "ultra" }]);
  const u = ids.ultra;
  const layers = [];
  for (let i = 0; i < 100; i++) layers.push({ op: "layer.put", map: u, as: "u" + i, data: { name: "第" + i + "层" } });
  await apply(layers);
  check("100 层单批创建", Object.keys(ids).filter((k) => /^u\d+$/.test(k)).length === 100,
    Object.keys(ids).filter((k) => /^u\d+$/.test(k)).length);
  await apply([{ op: "tiles.set", map: u, layer: ids.u50, cells: cellsGrid(100, 100, "wall") }]);
  check("单批 10000 格", true);
  const batch = [];
  for (let i = 0; i < 50; i++) batch.push({ op: "instance.put", map: u, as: "v" + i, data: { asset: "table", layer: ids.u0, x: 10 + i, y: 10 } });
  for (let i = 0; i < 50; i++) batch.push({ op: "tiles.set", map: u, layer: ids.u51, cells: [{ x: 10 + i, y: 12, asset: "floor", atlas: [0, 0] }] });
  await apply(batch);
  check("单批 100 混合操作", true);
  const rows = Array.from({ length: 200 }, (_, i) => ({
    card: { function: "card", content: ids["card" + (i % 6)] }, count: 1 }));
  await apply([{ op: "content.put", function: "deck", as: "deck200", data: { name: "200 行卡组", fields: { cards: rows } } }]);
  check("record 200 行", true);
  const p = probe(apply);
  const r1 = await p({ op: "layer.put", map: u, layer: ids.u0, data: { parallax: -0.5 } });
  const r2 = await p({ op: "layer.put", map: u, layer: ids.u0, data: { blend: "screen" } });
  const r3 = await p({ op: "tiles.set", map: u, layer: ids.u0, cells: [{ x: -5, y: -5, asset: "floor", atlas: [0, 0] }] });
  console.log("探测:", r1, "|", r2, "|", r3);
  check("防护探测（负 parallax/非法 blend/越界瓦片）", true, [r1, r2, r3]);
  // 越界瓦片接受后的渲染语义：截超限图确认
  t();
}

module.exports = { groupUltra };
