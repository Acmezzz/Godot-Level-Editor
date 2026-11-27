// 极限体验工程：四类型（卡牌/塔防/银河城/节奏）+ 极限图层/数据，完整独立声明。
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

function png(p, w, h, [r, g, b]) {
  const chunk = (kind, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length, 0);
    const crcBuf = Buffer.concat([Buffer.from(kind), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(zlib.crc32(crcBuf) >>> 0, 0);
    return Buffer.concat([len, Buffer.from(kind), data, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 2;
  const row = Buffer.alloc(w * 3);
  for (let x = 0; x < w; x++) { row[x * 3] = r; row[x * 3 + 1] = g; row[x * 3 + 2] = b; }
  const raw = Buffer.concat(Array.from({ length: h }, () => Buffer.concat([Buffer.from([0]), row])));
  fs.writeFileSync(p, Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr), chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0)),
  ]));
}

function wav(p, frames) {
  const n = frames.length;
  const head = Buffer.alloc(44);
  head.write("RIFF", 0); head.writeUInt32LE(36 + n * 2, 4); head.write("WAVE", 8);
  head.write("fmt ", 12); head.writeUInt32LE(16, 16); head.writeUInt16LE(1, 20);
  head.writeUInt16LE(1, 22); head.writeUInt32LE(8000, 24); head.writeUInt32LE(16000, 28);
  head.writeUInt16LE(2, 32); head.writeUInt16LE(16, 34);
  head.write("data", 36); head.writeUInt32LE(n * 2, 40);
  const body = Buffer.alloc(n * 2);
  frames.forEach((v, i) => body.writeInt16LE(v, i * 2));
  fs.writeFileSync(p, Buffer.concat([head, body]));
}

function buildFixture2(game, godot) {
  const manifest = {
    projectName: "极限体验工程",
    startup: { maps: true, screens: true },
    mapOutputs: { next: { name: "出口", maps: true } },
    tileSize: 16,
    collisionTypes: { solid: { name: "实心", shape: "rect", color: "#cc4444" } },
    assets: [
      { id: "floor", kind: "scene", shape: "tile", atlas: "tile.png", cell: 16 },
      { id: "wall", kind: "scene", shape: "tile", atlas: "tile.png", cell: 16 },
      { id: "portal", kind: "entity", code: "PRT0", thumb: "entity.png", visual: {},
        ports: [{ id: "exit", x: 8, y: 8 }] },
      { id: "tower", kind: "entity", code: "TWR0", thumb: "entity.png", visual: {},
        ports: [{ id: "muzzle", x: 8, y: 2 }],
        fields: [{ id: "muzzle", kind: "input", type: "port_ref", sourcePort: "muzzle" }] },
      { id: "table", kind: "entity", code: "TBL0", thumb: "entity.png", visual: {} },
      { id: "gate", kind: "entity", code: "GAT0", thumb: "entity.png", visual: {} },
    ],
    functions: {
      card: { name: "卡牌", code: "CRD0", fields: [
        { id: "cost", kind: "input", type: "int", default: 1 },
        { id: "ctype", kind: "choice", options: ["攻击", "法术", "诅咒"] },
        { id: "text", kind: "input", type: "string", multiline: true },
        { id: "dmg", kind: "input", type: "curve", default: [
          { time: 0, value: 6 }, { time: 30, value: 12, mode: "smooth" }] }] },
      wave: { name: "波次", code: "WAV0", timebase: { unit: "beats", audioField: "music" }, steps: true, fields: [
        { id: "music", kind: "input", type: "string" }] },
      gate: { name: "门禁", code: "GAT0", fields: [
        { id: "open_if", kind: "input", type: "array", of: "condition",
          allowedConditions: ["has_dash", "has_gem"] }] },
      deck: { name: "卡组", code: "DEK0", fields: [
        { id: "cards", kind: "input", type: "array", of: "record", fields: [
          { id: "card", kind: "input", type: "flow_target", contentTypes: ["card"] },
          { id: "count", kind: "input", type: "int", default: 2 }] }] },
    },
    conditions: { has_dash: { name: "冲刺能力", code: "CND0" }, has_gem: { name: "宝石", code: "CND1" } },
    steps: {
      cue: { name: "演出", code: "CUE0", fields: [] },
      note: { name: "音符", code: "NOT0", fields: [
        { id: "lane", kind: "choice", options: ["A", "B", "C", "D"] },
        { id: "judge", kind: "input", type: "float" }] },
    },
    audio: [
      { id: "battle", name: "战斗曲", code: "AUD0", path: "theme.wav" },
      { id: "sfx", name: "音效", code: "AUD1", path: "sfx.wav" }],
    screenModules: { "deck-ui": { name: "卡组面板", fields: [
      { id: "volume", kind: "input", type: "range", min: 0, max: 100, default: 80 },
      { id: "muted", kind: "input", type: "bool", default: false }],
      outputs: { accepted: { name: "确认出牌", maps: false, screens: true } } } },
    mapGenerators: { room: { fields: [
      { id: "width", kind: "input", type: "int", min: 8, max: 30, default: 12 }] } },
    preview: { version: 1, executable: godot, capabilities: [
      "generateMap", "mapFrame", "worldFrame", "screenLayout", "timelineFrame", "playtestFrame"],
      args: ["--headless", "--path", game.split(path.sep).join("/"), "--"] },
    playtest: { executable: godot, args: ["--path", game.split(path.sep).join("/"), "--rendering-method", "gl_compatibility",
      "--audio-driver", "Dummy", "--resolution", "300x200", "--"],
      projectEntry: true, mapEntry: true, viewEntry: true, viewDraft: true,
      entryFunctions: ["card", "gate"], report: true, captureFrames: true },
  };
  fs.mkdirSync(game, { recursive: true });
  fs.mkdirSync(path.dirname(path.join(game, "editor/editor_manifest.json")), { recursive: true });
  fs.writeFileSync(path.join(game, "editor/editor_manifest.json"), JSON.stringify(manifest, null, "\t"), "utf8");
  fs.copyFileSync(path.resolve(__dirname, "..", "..", "tests", "mcp_fixture_game.gd.txt"), path.join(game, "game.gd"));
  png(path.join(game, "tile.png"), 16, 16, [86, 170, 51]);
  png(path.join(game, "entity.png"), 16, 16, [51, 86, 170]);
  wav(path.join(game, "theme.wav"), Array.from({ length: 8000 }, (_, i) => (i % 2 ? -1000 : 1000)));
  wav(path.join(game, "sfx.wav"), Array.from({ length: 4000 }, (_, i) => (i % 2 ? -3000 : 3000)));
}

module.exports = { buildFixture2 };
