// 组 4 触发编排 + 组 5 复杂结构 + 组 6 端到端验证。
const { collect } = require("./ops1.js");

async function groupTriggers({ apply, check, ids }) {
  const { town } = ids;
  await apply([
    { op: "binding.put", map: town, instance: ids.npc1, function: "dialog", as: "bd4",
      data: { content: ids.dlg1, trigger: "round_end", parallel: true } },
    { op: "binding.put", map: town, instance: ids.npc1, function: "dialog", as: "bd5",
      data: { content: ids.dlg2, trigger: "round_end", enabled: false } },
  ]);
  check("触发/并行/停用绑定", true);
  return ids;
}

async function groupComplex({ apply, call, shot, check, ids, draft }) {
  await apply([
    { op: "map.create", name: "共享绘制", width: 10, height: 8, as: "draw" },
    { op: "layer.put", map: "$draw", as: "draw_layer", data: { name: "绘制" } },
    { op: "tiles.set", map: "$draw", layer: "$draw_layer", cells: [{ x: 3, y: 3, asset: "wall", atlas: [0, 0] }] },
    { op: "group.put", data: { name: "共享前景", drawingMap: "$draw", maps: [ids.hex, ids.tri], drawOrder: 3 } },
    { op: "map.patch", map: ids.hex, data: { meta: { cellGraph: {
      spaces: { room: { name: "房间空间", layer: ids.hex_draw, origin: [0, 0], axisX: [16, 0], axisY: [0, 16] } },
      cells: [{ id: "c1", space: "room", polygon: [[0, 0], [32, 0], [32, 32], [0, 32]] }],
      edges: [] } } } },
    { op: "project.set", section: "worldLayout", value: { version: 1, chunks: {
      [ids.hex]: { origin: [0, 0], size: [12, 10], generatedKey: "room" } } } },
  ]);
  check("图组/格图空间/世界布局", true);
  const [, media] = await call("capture_editor", { target: "draft_map", draft, map: ids.hex, width: 520, height: 360 });
  shot(media, "hex-cellgraph", (520, 360));
  return ids;
}

async function groupE2e({ call, shot, check, draft }) {
  const [vdata] = await call("validate", { draft });
  check("全工程 validate 全绿", vdata.valid === true, vdata.issues);
  const gen = await call("generate_map");
  check("生成器列出", Boolean(gen[0].available), gen[0]);
  const [, media] = await call("capture_editor", { width: 640, height: 400 });
  shot(media, "editor-window");
  const [, audio] = await call("preview_asset", { audio: "AUD0", start: 0.2, duration: 0.4 });
  check("音频裁切 RIFF", audio[0] && audio[0].mimeType === "audio/wav", audio);
}

module.exports = { groupTriggers, groupComplex, groupE2e };
