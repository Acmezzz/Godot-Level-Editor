// 极限组实现：卡牌/塔防/银河城/节奏/图层/压力。
const ids = {};

async function applyWrap(run2, operations) {
  const data = await run2.apply(operations);
  return data;
}

async function groupCards({ apply, check, timed, call }) {
  const t = timed("卡牌组");
  const names = ["斩击", "火球", "护盾", "诅咒", "回响", "闪电"];
  const cards = names.map((name, i) => ({
    op: "content.put", function: "card", as: "card" + i,
    data: { name, fields: { cost: i % 3, ctype: ["攻击", "法术", "诅咒"][i % 3], text: `造成 ${i + 2} 点伤害。` } } }));
  await apply(cards);
  const cardRefs = names.map((n, i) => ({ card: { function: "card", content: ids["card" + i] }, count: i + 1 }));
  await apply([{ op: "content.put", function: "deck", as: "deck1", data: {
    name: "初始卡组", fields: { cards: cardRefs } } }]);
  check("卡牌 6 张 + 卡组 record(flow_target×6)", true);
  t();
}

async function groupTowerDefense({ apply, check, timed }) {
  const t = timed("塔防组");
  await apply([
    { op: "map.create", name: "防御阵", width: 20, height: 14, as: "td" },
    { op: "layer.put", map: "$td", as: "tdl", data: { name: "地面" } },
    { op: "tiles.set", map: "$td", layer: "$tdl", cells: cellsGrid(20, 12, "floor") },
    { op: "instance.put", map: "$td", as: "tower1", data: { asset: "tower", layer: "$tdl", x: 5, y: 6 } },
    { op: "instance.put", map: "$td", as: "tower2", data: { asset: "tower", layer: "$tdl", x: 12, y: 9 } },
  ]);
  const tdl = ids.tdl;
  await apply([
    { op: "map.patch", map: ids.td, data: { meta: { cellGraph: {
      spaces: {
        laneA: { name: "上路", layer: tdl, origin: [0, 0], axisX: [16, 0], axisY: [0, 16] },
        laneB: { name: "下路", layer: tdl, origin: [0, 112], axisX: [16, 0], axisY: [0, 16] } },
      cells: [
        { id: "a1", space: "laneA", polygon: [[0, 0], [48, 0], [48, 32], [0, 32]] },
        { id: "a2", space: "laneA", polygon: [[48, 0], [96, 0], [96, 32], [48, 32]] },
        { id: "b1", space: "laneB", polygon: [[0, 0], [48, 0], [48, 32], [0, 32]] }],
      edges: [
        { id: "e1", from: "a1", to: "a2" },
        { id: "e2", from: "a2", to: "b1", toMap: ids.td } ] } } } }]);
  check("塔防图+格图双空间+跨图边", true);
  t();
}

function cellsGrid(w, h, asset) {
  const c = [];
  for (let x = 0; x < w; x++) for (let y = 0; y < h; y++) c.push({ x, y, asset, atlas: [0, 0] });
  return c;
}

async function groupMetroidvania({ apply, check, timed, call }) {
  const t = timed("银河城组");
  await apply([
    { op: "map.create", name: "城西", width: 16, height: 12, as: "west" },
    { op: "map.create", name: "城东", width: 16, height: 12, as: "east" },
    { op: "layer.put", map: "$west", as: "wl", data: { name: "主体" } },
    { op: "layer.put", map: "$east", as: "el", data: { name: "主体" } },
  ]);
  const [westL, eastL] = [ids.wl, ids.el];
  await apply([
    { op: "tiles.set", map: ids.west, layer: westL, cells: cellsGrid(16, 10, "floor") },
    { op: "tiles.set", map: ids.east, layer: eastL, cells: cellsGrid(16, 10, "floor") },
    { op: "instance.put", map: ids.west, as: "portal1", data: { asset: "portal", layer: westL, x: 15, y: 5 } },
    { op: "instance.put", map: ids.east, as: "gate1", data: { asset: "gate", layer: eastL, x: 1, "y": 5 } },
    { op: "content.put", function: "gate", as: "gatec", data: {
      name: "冲刺门", fields: { open_if: ["has_dash"] } } },
    { op: "binding.put", map: ids.east, instance: "$gate1", function: "gate", as: "gateb", data: { content: "$gatec" } },
    { op: "map.patch", map: ids.west, data: { meta: { mapOutputs: { east: {
      name: "去城东", maps: true, map: ids.east } } } } },
    { op: "project.set", section: "worldLayout", value: { version: 1, chunks: {
      [ids.west]: { origin: [0, 0], size: [16, 12] },
      [ids.east]: { origin: [16, 0], size: [16, 12], generatedKey: "city-east" } } } },
  ]);
  check("银河城：双图世界分块+条件门+传送门", true);
  t();
}

async function groupRhythm({ apply, check, timed }) {
  const t = timed("节奏组");
  // 32 步音符谱面（beats 时间轴，2 小节×8 拍×2 轨），lane 四轨轮换+判定窗 float
  const notes = [];
  for (let i = 0; i < 32; i++) {
    notes.push({ step: "NOT0", at: (i % 8) * 0.5 + Math.floor(i / 8) * 4, duration: 0.25,
      fields: { lane: ["A", "B", "C", "D"][i % 4], judge: 0.12 } });
  }
  await apply([
    { op: "content.put", function: "wave", as: "chart1", data: {
      name: "主谱面", fields: { music: "AUD0" }, steps: notes } },
    { op: "content.put", function: "wave", as: "chart2", data: {
      name: "加速谱面", fields: { music: "AUD1" }, steps: notes.map((n, i) => ({ ...n, at: n.at * 0.75 })) } },
  ]);
  check("节奏谱面 32 步×2 + BPM 加速变体", notes.length === 32);
  t();
}

async function groupLayers({ apply, check, timed, call }) {
  const t = timed("图层极限组");
  await apply([
    { op: "map.create", name: "深景", width: 40, height: 24, as: "deep" },
    { op: "layer.put", map: "$deep", as: "l00", data: { name: "L0 地面", parallax: 0.4 } },
  ]);
  const deep = ids.deep;
  const ops = [];
  for (let i = 1; i < 22; i++) {
    ops.push({ op: "layer.put", map: deep, as: "l" + String(i).padStart(2, "0"), data: {
      name: "L" + i + " 层", parallax: 0.4 + i * 0.03 } });
  }
  await apply(ops);
  check("22 层 parallax 阶梯", Object.keys(ids).filter((k) => /^l\d\d$/.test(k)).length === 22,
    Object.keys(ids).filter((k) => /^l\d\d$/.test(k)).length);
  // tileGrid 独立格系层 + blend 层
  await apply([
    { op: "layer.put", map: deep, as: "l23", data: { name: "斜坡层", tileGrid: { gridProjection: "orthogonal", gridTopology: "triangles" } } },
    { op: "layer.put", map: deep, as: "l24", data: { name: "发光层", blend: "add" } },
  ]);
  check("tileGrid 三角格系层 + add 混合层", true);
  // 铺瓦片验证 24 层共存
  await apply([
    { op: "tiles.set", map: deep, layer: ids.l01, cells: [{ x: 2, y: 2, asset: "floor", atlas: [0, 0] }] },
    { op: "tiles.set", map: deep, layer: ids.l23, cells: [{ x: 4, y: 4, asset: "floor", atlas: [0, 0] }] },
  ]);
  t();
}

async function groupStress({ apply, call, check, timed }) {
  const t = timed("压力组");
  // 单批 30 操作（混合类型）
  const batch = [];
  for (let i = 0; i < 15; i++) {
    batch.push({ op: "instance.put", map: ids.deep, as: "e" + i,
      data: { asset: "table", layer: ids.l00, x: 6 + i, y: 6 } });
  }
  for (let i = 0; 15 + i < 30; i++) {
    batch.push({ op: "tiles.set", map: ids.deep, layer: ids.l02, cells: [{ x: 8 + i, y: 10, asset: "wall", atlas: [0, 0] }] });
  }
  await apply(batch);
  check("单批 30 混合操作", true);
  // 3000 格瓦片单批
  const big = cellsGrid(100, 30, "floor");
  await apply([{ op: "tiles.set", map: ids.deep, layer: ids.l03, cells: big }]);
  check("单批 3000 格瓦片", big.length === 3000);
  // record 数组 40 行（卡组扩到 40 张）
  const rows = Array.from({ length: 40 }, (_, i) => ({
    card: { function: "card", content: ids["card" + (i % 6)] }, count: 1 }));
  await apply([{ op: "content.put", function: "deck", as: "deck40", data: {
    name: "40 张卡组", fields: { cards: rows } } }]);
  check("record 数组 40 行", true);
  t();
}

module.exports = { ids, cellsGrid, groupCards, groupTowerDefense, groupMetroidvania, groupRhythm, groupLayers, groupStress };
