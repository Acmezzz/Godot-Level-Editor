// 游戏侧工程生成：3 功能（对话/场景/机关）+ 条件/步骤/触发池 + 碰撞类型池 + 双音频。
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

function writeJson(p, v) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(v, null, "\t"), "utf8");
}

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
    chunk("IHDR", ihdr), chunk("IDAT", zlib.gzipSync ? zlib.deflateSync(raw) : raw), chunk("IEND", Buffer.alloc(0)),
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

function buildFixture(game, godot) {
  writeJson(path.join(game, "editor/editor_manifest.json"), {
    projectName: "体验测试工程",
    startup: { maps: true, screens: true },
    mapOutputs: { next: { name: "出口", maps: true } },
    tileSize: 16,
    collisionTypes: {
      solid: { name: "实心", shape: "rect", color: "#cc4444" },
      oneway: { name: "单向", shape: "rect", color: "#44cc88" },
      spike: { name: "尖刺", shape: "triangle_r", color: "#ccaa22" },
    },
    assets: [
      { id: "floor", kind: "scene", shape: "tile", atlas: "tile.png", cell: 16 },
      { id: "wall", kind: "scene", shape: "tile", atlas: "tile.png", cell: 16 },
      { id: "hero", kind: "entity", code: "HERO", thumb: "tile.png", visual: {}, props: [] },
      { id: "npc", kind: "entity", code: "NPC0", thumb: "tile.png", visual: {}, props: [] },
      { id: "block", kind: "entity", code: "BLK0", thumb: "entity.png", visual: {}, props: [] },
      { id: "gate", kind: "entity", code: "GATE0", thumb: "tile.png", visual: {}, props: [] },
    ],
    functions: {
      dialog: { name: "对话", code: "DLG0", timebase: { unit: "seconds", audioField: "voice" }, steps: true, repeatable: true, fields: [
        { id: "who", kind: "input", type: "string" },
        { id: "text", kind: "input", type: "string", multiline: true }] },
      scene: { name: "场景演出", code: "SCNE", timebase: "seconds", steps: true, fields: [
        { id: "cam", kind: "input", type: "vector2" }] },
      mechanism: { name: "机关", code: "MECH", fields: [
        { id: "target", kind: "input", type: "flow_target", maps: true }] },
    },
    conditions: { raining: { name: "下雨", code: "COND" } },
    steps: {
      cue: { name: "演出标记", code: "CUE0", fields: [] },
      say: { name: "台词", code: "SAY0", fields: [
        { id: "voice", kind: "input", type: "string" }] },
    },
    triggers: { round_end: { name: "回合结束", code: "TRG0", eventTargets: { contentTypes: ["dialog"] } } },
    audio: [
      { id: "theme", name: "主题曲", code: "AUD0", path: "theme.wav" },
      { id: "sfx", name: "音效", code: "AUD1", path: "sfx.wav" }],
    mapGenerators: { room: { fields: [
      { id: "width", kind: "input", type: "int", min: 8, max: 30, default: 12 }] } },
    preview: { version: 1, executable: godot, capabilities: [
      "generateMap", "mapFrame", "worldFrame", "screenLayout", "timelineFrame", "playtestFrame"],
      args: ["--headless", "--path", game.split(path.sep).join("/"), "--"] },
    playtest: { executable: godot, args: ["--path", game.split(path.sep).join("/"), "--rendering-method", "gl_compatibility",
      "--audio-driver", "Dummy", "--resolution", "300x200", "--"],
      projectEntry: true, mapEntry: true, viewEntry: true, viewDraft: true,
      entryFunctions: ["dialog", "scene"], report: true, captureFrames: true },
  });
  fs.mkdirSync(game, { recursive: true });
  fs.copyFileSync(path.resolve(__dirname, "..", "..", "tests", "mcp_fixture_game.gd.txt"), path.join(game, "game.gd"));
  png(path.join(game, "tile.png"), 16, 16, [86, 170, 51]);
  png(path.join(game, "entity.png"), 16, 16, [51, 86, 170]);
  wav(path.join(game, "theme.wav"), Array.from({ length: 8000 }, (_, i) => (i % 2 ? -1000 : 1000)));
  wav(path.join(game, "sfx.wav"), Array.from({ length: 4000 }, (_, i) => (i % 2 ? -3000 : 3000)));
}

module.exports = { buildFixture };
