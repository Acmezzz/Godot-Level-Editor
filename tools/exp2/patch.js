// 一次性补丁：run2.js 主尾段插入编辑器窗口与 screens 面板截图。
const fs = require("fs");
const p = "tools/exp2/run2.js";
let s = fs.readFileSync(p, "utf8");
if (!s.includes(`"screens-panel"`)) {
  const a = `    await cap({ target: "draft_map", draft, map: groups.ids.td, width: 640, height: 400 }, "td-graph");\n    check(`;
  const b = `    await cap({ target: "draft_map", draft, map: groups.ids.td, width: 640, height: 400 }, "td-graph");\n` +
    `    await cap({ width: 640, height: 400 }, "editor-window");\n` +
    `    await cap({ panel: "screens", view: "title", width: 520, height: 360 }, "screens-panel");\n    const [v] = await call("validate");\n    check(`;
  s = s.replace(a, b);
}
fs.writeFileSync(p, s, "utf8");
console.log("patched:", s.includes(`"screens-panel"`));
