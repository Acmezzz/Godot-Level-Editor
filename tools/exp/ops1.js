// 组 1 四视角 + 组 2 游戏类型。apply 由 ctx 提供（草稿+revision 统一管理）。
function collect(data, ids) {
  for (const [k, v] of Object.entries(data.aliases || {})) ids[k] = v;
  return data;
}

async function shotMap(call, shot, code, name, draft) {
  const [, media] = await call("capture_editor", { target: "draft_map", draft, map: code, width: 520, height: 360 });
  shot(media, name);
}

async function groupProjection({ apply, call, shot, check, ids, draft }) {
  await apply([
    { op: "map.create", name: "小镇", width: 20, height: 14, as: "town" },
    { op: "map.create", name: "等距房", width: 14, height: 12, projection: "isometric", as: "iso" },
    { op: "map.create", name: "六边场", width: 12, height: 10, projection: "hexagonal", as: "hex" },
    { op: "map.create", name: "三角桥", width: 16, height: 10, topology: "triangles", as: "tri" },
    { op: "layer.put", map: "$town", as: "town_draw", data: { name: "绘制" } },
    { op: "layer.put", map: "$iso", as: "iso_draw", data: { name: "绘制" } },
    { op: "layer.put", map: "$hex", as: "hex_draw", data: { name: "绘制" } },
    { op: "layer.put", map: "$tri", as: "tri_draw", data: { name: "绘制" } },
  ]);
  const { town, iso, hex, tri } = ids;
  const td = ids.town_draw, id_ = ids.iso_draw, hd = ids.hex_draw, td2 = ids.tri_draw;
  check("四图创建", Boolean(town && iso && hex && tri && td && id_ && hd && td2), ids);
  await apply([
    { op: "tiles.set", map: town, layer: td, cells: townCells().concat(townFloor()) },
    { op: "collision.set", map: town, cells: townBorder() },
    { op: "instance.put", map: town, as: "npc1", data: { asset: "npc", layer: td, x: 10, y: 6 } },
    { op: "instance.put", map: town, as: "hero1", data: { asset: "hero", layer: td, x: 5, y: 7 } },
    { op: "instance.put", map: iso, as: "block1", data: { asset: "block", layer: id_, x: 6, y: 5 } },
  ]);
  await apply([
    { op: "tiles.set", map: iso, layer: id_, cells: isoCells() },
    { op: "tiles.set", map: hex, layer: hd, cells: hexCells() },
    { op: "tiles.set", map: tri, layer: td2, cells: triCells() },
  ]);
  for (const [code, name] of [[town, "map-town"], [iso, "map-iso"], [hex, "map-hex"], [tri, "map-tri"]]) {
    await shotMap(call, shot, code, name, draft);
  }
  check("四视角建图与截图", true);
  return ids;
}

function townCells() {
  const c = [];
  for (let x = 1; x < 19; x++) { c.push({ x, y: 0, asset: "wall", atlas: [0, 0] }); c.push({ x, y: 13, asset: "wall", atlas: [0, 0] }); }
  for (let y = 1; y < 13; y++) { c.push({ x: 1, y, asset: "wall", atlas: [0, 0] }); c.push({ x: 18, y, asset: "wall", atlas: [0, 0] }); }
  return c;
}

function townFloor() {
  const c = [];
  for (let x = 2; x < 18; x++) for (let y = 1; y < 13; y++) c.push({ x, y, asset: "floor", atlas: [0, 0] });
  return c;
}

function townBorder() {
  const c = [];
  for (let x = 1; x < 19; x++) { c.push({ x, y: 0, type: "solid" }); c.push({ x, y: 13, type: "solid" }); }
  for (let y = 1; y < 13; y++) { c.push({ x: 1, y, type: "solid" }); c.push({ x: 18, y, type: "solid" }); }
  return c;
}

function isoCells() {
  const c = [];
  for (let x = 4; x < 10; x++) for (let y = 3; y < 9; y++) c.push({ x, y, asset: "floor", atlas: [0, 0] });
  return c;
}

function hexCells() {
  const c = [];
  for (let x = 1; x < 11; x++) c.push({ x, y: 2, asset: "floor", atlas: [0, 0] });
  for (let x = 1; x < 11; x += 2) c.push({ x, y: 3, asset: "wall", atlas: [0, 0] });
  return c;
}

function triCells() {
  const c = [];
  for (let x = 8; x < 24; x++) {
    c.push({ x, y: 5, asset: "floor", atlas: [0, 0] });
    c.push({ x, y: 6, asset: "wall", atlas: [0, 0] });
  }
  return c;
}

module.exports = { collect, shotMap, groupProjection };
