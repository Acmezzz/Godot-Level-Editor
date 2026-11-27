// 组 2 游戏类型（RPG 出口/单向平台/尖刺/AVG 对话）+ 组 3 UI。
const { collect, shotMap } = require("./ops1.js");

async function groupGameplay({ apply, call, shot, check, ids }) {
  const { town } = ids;
  await apply([
    { op: "map.patch", map: town, data: { meta: { mapOutputs: { north: {
      name: "去六边场", maps: true, map: ids.hex } } } } },
    { op: "collision.set", map: town, cells: [
      { x: 8, y: 9, type: "oneway" }, { x: 9, y: 9, type: "oneway" },
      { x: 14, y: 9, type: "oneway" }, { x: 15, y: 9, type: "oneway" },
      { x: 12, y: 12, type: "spike" }] },
    { op: "content.put", function: "dialog", as: "dlg1", data: {
      name: "村长对话", fields: { who: "村长", text: "欢迎来到小镇。\n多行对白。" },
      steps: [
        { step: "SAY0", at: 0.0, duration: 1.5, fields: { voice: "AUD0" } },
        { step: "SAY0", at: 1.5, duration: 1.5, fields: { voice: "AUD1" } }] } },
    { op: "content.put", function: "dialog", as: "dlg2", data: {
      name: "村民对话", fields: { who: "村民", text: "听说明天有集市。" } } },
    { op: "binding.put", map: town, instance: ids.npc1, function: "dialog", as: "bd1", data: { content: ids.dlg1 } },
  ]);
  check("RPG 出口/单向/尖刺/对话绑定", true);
  // 场景演出内容 + hero 绑定 + 机关内容（flow_target 指向六边场）+ 机关实体绑定
  await apply([
    { op: "content.put", function: "scene", as: "scn1", data: {
      name: "开场演出", fields: { cam: [6.0, 7.0] },
      steps: [
        { step: "CUE0", at: 0.0, duration: 2.0, fields: {} },
        { step: "CUE0", at: 2.0, duration: 1.0, fields: {} }] } },
    { op: "binding.put", map: town, instance: ids.hero1, function: "scene", as: "bd2", data: { content: "$scn1" } },
    { op: "content.put", function: "mechanism", as: "mec1", data: {
      name: "传送机关", fields: { target: { map: ids.hex } } } },
    { op: "instance.put", map: town, as: "block1", data: { asset: "block", layer: ids.town_draw, x: 12, y: 8 } },
    { op: "binding.put", map: town, instance: "$block1", function: "mechanism", as: "bd3", data: { content: "$mec1" } },
  ]);
  check("演出/机关/flow_target 绑定", true);
  return ids;
}

async function groupUi({ apply, call, shot, check, ids, draft }) {
  await apply([
    { op: "view.put", view: "title", data: { name: "标题屏", layout: { elements: [
      { id: "title", kind: "text", anchors: [0.15, 0.2, 0.85, 0.4], text: "小镇传说" },
      { id: "start", kind: "button", anchors: [0.3, 0.6, 0.7, 0.75], nav: { map: ids.town } }] } } },
    { op: "view.put", view: "menu", data: { name: "菜单屏", layout: { elements: [
      { id: "opt", kind: "text", anchors: [0.2, 0.3, 0.8, 0.5], text: "选项" },
      { id: "back", kind: "button", anchors: [0.4, 0.7, 0.6, 0.8], nav: { view: "title" } }] } } },
    { op: "startup.set", data: { target: { view: "title" } } },
  ]);
  check("两屏+导航+启动入口", true);
  const [, media] = await call("capture_editor", { panel: "screens", view: "title", width: 520, height: 360 });
  shot(media, "screens-panel");
  return ids;
}

module.exports = { groupGameplay, groupUi };
