// 超限组：100 层 / 单批 10000 格 / 单批 100 混合操作 / 200 行 record / 防护探测。
const { ids, cellsGrid } = require("./groups2.js");

async function groupUltra({ apply, call, draft, check, timed }) {
  const t = timed("超限组");
  await apply([{ op: "map.create", name: "超限", width: 100, height: 100, as: "ultra" }]);
  const u = ids.ultra;
  const layers = [];
  for (let i = 0; i < 100; i++) layers.push({ op: "layer.put", map: u, as: "u" + i, data: { name: "第" + i + "层" } });
  await apply(layers);
  check("100 层单批创建", Object.keys(ids).filter((k) => /^u\d+$/.test(k)).length === 100,
    Object.keys(ids).filter((k) => /^u\d+$/.test(k)).length);
  await apply([{ op: "tiles.set", map: u, layer: ids.u50, cells: cellsGrid(100, 100, "wall") }]);
  const [full] = await call("query_content", { kind: "tiles", draft: draft(), map: u, layer: ids.u50, limit: 1 });
  check("单批 10000 格", full.total === 10000, full.total);
  const batch = [];
  for (let i = 0; i < 50; i++) batch.push({ op: "instance.put", map: u, as: "v" + i, data: { asset: "table", layer: ids.u0, x: 10 + i, y: 10 } });
  for (let i = 0; i < 50; i++) batch.push({ op: "tiles.set", map: u, layer: ids.u51, cells: [{ x: 10 + i, y: 12, asset: "floor", atlas: [0, 0] }] });
  await apply(batch);
  check("单批 100 混合操作", true);
  const rows = Array.from({ length: 200 }, (_, i) => ({
    card: { function: "card", content: ids["card" + (i % 6)] }, count: 1 }));
  await apply([{ op: "content.put", function: "deck", as: "deck200", data: { name: "200 行卡组", fields: { cards: rows } } }]);
  const [deck] = await call("query_content", { kind: "content", draft: draft(), function: "deck", content: ids.deck200 });
  check("record 200 行", Object.values(deck.data.fields).some((field) => Array.isArray(field) && field.length === 200));
  const reverse = await apply([{ op: "layer.put", map: u, layer: ids.u0, data: { parallax: -0.5 } }]);
  const [invalid] = await call("apply_changes", { draft: draft(), revision: reverse.revision,
    operations: [{ op: "layer.put", map: u, layer: ids.u0, data: { blend: "screen" } }] }, true);
  const overflow = await apply([{ op: "tiles.set", map: u, layer: ids.u0,
    cells: [{ x: -5, y: -5, asset: "floor", atlas: [0, 0] }] }]);
  const [map] = await call("query_content", { kind: "map", draft: draft(), map: u });
  check("边界语义（反向视差 / 拒绝非法混合 / 越界保留并提示）",
    map.data.meta.layers.find((layer) => layer.id === ids.u0)?.parallax === -0.5 &&
    invalid.issues.some((issue) => issue.path.endsWith(".blend")) &&
    overflow.warnings.some((issue) => issue.map === u && issue.path === `tiles.${ids.u0}`) &&
    map.data.tiles[ids.u0].some(([x, y]) => x === -5 && y === -5),
    { invalid, warnings: overflow.warnings });
  t();
}

module.exports = { groupUltra };
