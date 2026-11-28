// Node 22+; runs the actual Godot editor and a separate runtime from an isolated profile.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { spawn, execFileSync } = require('node:child_process');
const { buildFixture } = require('../exp/fixture.js');
const { author, configure } = require('./scenarios.js');
const root = path.resolve(__dirname, '../..');
const godot = process.env.BIRD_GODOT || 'D:/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe';
const python = process.env.BIRD_PYTHON || 'D:/AI/Anaconda/envs/pytorch/python.exe';
const out = path.resolve(process.argv[2] || 'tools/shots/live-authoring-20261128');
const slash = (p) => p.split(path.sep).join('/');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const json = (p, obj) => fs.writeFileSync(p, JSON.stringify(obj, null, 2));
const read = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const display = ['--rendering-method', 'gl_compatibility'];

async function until(fn, label) {
  for (let i = 0; i < 100; i++) {
    const result = await fn();
    if (result) return result;
    await sleep(100);
  }
  throw Error(`timeout: ${label}`);
}

function fixture(dir) {
  buildFixture(dir, godot);
  const file = path.join(dir, 'editor/editor_manifest.json');
  json(file, configure(read(file), slash(dir), godot));
  fs.copyFileSync(path.join(__dirname, 'game.gd'), path.join(dir, 'game.gd'));
  fs.copyFileSync(path.join(root, 'tests/runtime_fixture/main.tscn'), path.join(dir, 'main.tscn'));
  fs.copyFileSync(path.join(root, 'tests/runtime_fixture/project.godot.template'), path.join(dir, 'project.godot'));
  fs.mkdirSync(path.join(dir, 'src/canvas'), { recursive: true });
  fs.copyFileSync(path.join(root, 'src/canvas/grid_space.gd'), path.join(dir, 'src/canvas/grid_space.gd'));
  fs.mkdirSync(path.join(dir, 'maps'), { recursive: true });
}

async function main() {
  fs.mkdirSync(out, { recursive: true });
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bird-live-'));
  const game = path.join(tmp, 'game');
  const fresh = path.join(tmp, 'first-use');
  fixture(game);
  fixture(fresh);
  const env = { ...process.env, APPDATA: path.join(tmp, 'profile'), BIRD_MCP_TOKEN: require('node:crypto').randomUUID() };
  execFileSync(godot, ['--headless', '--path', game, '--editor', '--import', '--log-file', path.join(out, 'runtime-import.log')], { env, stdio: 'ignore' });
  const port = await new Promise((resolve) => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => resolve(p)); });
  });
  const app = spawn(godot, ['--path', root, ...display, '--resolution', '1280x800', '--log-file', path.join(out, 'editor.log'),
    '--', `--bird-mcp=${port}`, `--bird-project=${slash(game)}`], { env, stdio: 'ignore' });
  json(path.join(out, 'workspace.json'), { game, fresh, profile: env.APPDATA, editorPid: app.pid });
  let id = 0;
  const rpc = async (method, params) => {
    const response = await fetch(`http://127.0.0.1:${port}/mcp`, { method: 'POST', signal: AbortSignal.timeout(20000),
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${env.BIRD_MCP_TOKEN}` },
      body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }) });
    const data = await response.json();
    if (data.error) throw Error(JSON.stringify(data.error));
    return data.result;
  };
  const call = async (name, args = {}, output = '') => {
    const result = await rpc('tools/call', { name, arguments: args });
    if (result.isError) throw Error(`${name} ${JSON.stringify(args).slice(0, 260)}: ${JSON.stringify(result.structuredContent)}`);
    if (output) {
      const media = result.content.find((m) => ['image', 'audio'].includes(m.type));
      if (!media) throw Error(`missing media: ${name}`);
      fs.writeFileSync(path.join(out, output), Buffer.from(media.data, 'base64'));
    }
    return result.structuredContent;
  };
  const issues = [];
  const probe = async (name, fn) => {
    try { return await fn(); }
    catch (err) { issues.push({ name, error: err.message }); console.log(`NOTE ${name}: ${err.message}`); }
  };
  const expect = (label, value, detail) => {
    if (!value) throw Error(`${label}: ${JSON.stringify(detail)}`);
    console.log(`PASS ${label}`);
  };
  let gamePid;
  try {
    await until(async () => {
      try { return await rpc('initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'live-experience', version: '1' } }); }
      catch { return false; }
    }, 'editor initialize');
    const ids = await author(call, expect, out);
    await probe('hidden-layer authoring', () => call('capture_editor', { panel: 'map', map: ids.side, width: 1100, height: 690 }, 'author-side.png'));
    await probe('timeline authoring', () => call('capture_editor', { panel: 'timeline', function: 'cue', content: ids.cue, time: 0.55, width: 1100, height: 690 }, 'author-timeline.png'));
    await probe('audio preview', () => call('preview_asset', { audio: 'AUD0', start: 0.15, duration: 0.4 }, 'audio-clip.wav'));
    const reports = {};
    const start = async (entry, target = {}) => {
      const launched = await call('playtest', { action: 'start', entry, target });
      gamePid = launched.pid;
      const ready = await until(async () => {
        const s = await call('playtest', { action: 'status' });
        if (['error', 'invalid'].includes(s.report?.status)) throw Error(JSON.stringify(s));
        return s.report?.status === 'ready' && s;
      }, `runtime ready ${entry} ${JSON.stringify(target)}`);
      gamePid ||= ready.pid;
      if (!gamePid) throw Error(`missing game pid ${JSON.stringify(ready)}`);
      return ready.report.result;
    };
    const state = () => {
      try { return read(path.join(game, 'editor/live-state.json')); } catch { return {}; }
    };
    const key = (k) => execFileSync(python, [path.join(__dirname, 'desktop.py'), 'key', String(gamePid), k]);
    const click = (x, y) => execFileSync(python, [path.join(__dirname, 'desktop.py'), 'click', String(gamePid), String(x), String(y)]);
    const shot = (name) => call('playtest', { action: 'capture', width: 800, height: 480 }, `${name}.png`);
    const wait = (predicate, label) => until(() => { const v = state(); return predicate(v) && v; }, label);
    const stop = () => call('playtest', { action: 'stop' });
    await probe('project → screen → side → isometric', async () => {
      reports.screen = await start('project');
      expect('project starts at authored screen', reports.screen.screen === ids.screen, reports.screen);
      await shot('play-01-menu');
      click(400, 264);
      reports.settings = await wait((s) => s.screen === ids.settings, 'mouse navigates to settings');
      click(400, 202);
      reports.volume = await wait((s) => s.volume === 0.25, 'mouse activates the authored settings button');
      await shot('play-02-settings');
      key('D');
      await wait((s) => s.screen === ids.screen, 'return from settings');
      key('S');
      reports.side = await wait((s) => s.map === ids.side, 'enter side via screen');
      expect('three shared drawings around base', JSON.stringify(reports.side.stack) === JSON.stringify([-2, 0, 2, 5]), reports.side);
      await shot('play-03-side');
      key('D');
      reports.blocked = await wait((s) => s.blocked === 1, 'map collision');
      key('W');
      key('D');
      reports.passage = await wait((s) => s.blocked === 1 && s.moves === 2, 'move through group-only collision');
      expect('HUD stays screen-bound while map camera moves', reports.passage.cameraX !== reports.side.cameraX &&
        JSON.stringify(reports.passage.hudAt) === JSON.stringify(reports.side.hudAt), reports.passage);
      key('E');
      reports.cue = await wait((s) => s.fired?.includes('say') && s.fired.includes('sound') &&
        s.layerDisplay?.[ids.reveal] && s.audioPlaying && s.subtitle, 'parallel text, audio and reveal');
      await shot('play-04-cue');
      reports.pulse = await wait((s) => Object.values(s.layerDisplay || {}).filter(Boolean).length >= 7, 'timeline lights up at least seven authored layers');
      await shot('play-04b-layer-pulse');
      reports.pulseEnd = await wait((s) => s.layerDisplay?.[ids.pulse23] && s.layerDisplay[ids.pulse0] === false,
        'last authored layer lights after first goes dark');
      reports.transition = await wait((s) => s.fade > 0.3 && s.map === ids.side, 'transition opacity');
      expect('all 24 pulse layers and the reveal are hidden before map change', Object.keys(reports.transition.layerDisplay).length === 25 &&
        Object.values(reports.transition.layerDisplay).every((v) => v === false), reports.transition);
      await shot('play-05-transition');
      reports.iso = await wait((s) => s.map === ids.iso, 'timeline continuation into isometric map');
      expect('group applicability follows map ID', JSON.stringify(reports.iso.stack) === JSON.stringify([-2, 0]), reports.iso);
      key('2');
      reports.isoBlocked = await wait((s) => s.notice === 'ROUTE LOCKED', 'gated shortcut');
      key('1');
      reports.isoStep = await wait((s) => s.cell === 'switch' && s.energy === 2, 'advance via authored cost');
      key('1');
      reports.isoWin = await wait((s) => s.cell === 'exit' && s.energy === 1, 'complete route puzzle');
      await shot('play-06-isometric');
    });
    if (gamePid) { await stop(); gamePid = undefined; }
    await probe('hex logistics', async () => {
      reports.hex = await start('map', { map: ids.hex });
      expect('hex reads its own graph', reports.hex.map === ids.hex && reports.hex.cells === 4, reports.hex);
      await shot('play-07-hex');
      key('2');
      await wait((s) => s.notice === 'INSUFFICIENT CARGO', 'reject empty cargo route');
      key('1');
      await wait((s) => s.cell === 'mine' && s.cargo === 3, 'collect cargo');
      key('1');
      await wait((s) => s.cell === 'hub' && s.cargo === 2, 'move freight to hub');
      key('1');
      reports.delivered = await wait((s) => s.cell === 'port' && s.deliveries === 1 && s.cargo === 0, 'deliver freight');
      await shot('play-08-delivered');
    });
    if (gamePid) { await stop(); gamePid = undefined; }
    await probe('direct screen preview entry', async () => {
      reports.directScreen = await start('screen', { view: ids.settings });
      expect('screen playtest bypasses project startup and opens settings', reports.directScreen.screen === ids.settings, reports.directScreen);
    });
    if (gamePid) { await stop(); gamePid = undefined; }
    json(path.join(out, 'runtime-results.json'), { ids, reports, issues });
    console.log(`Game: ${game}\nFirst use: ${fresh}\nEvidence: ${out}`);
    if (issues.some((r) => !r.name.endsWith('authoring') && r.name !== 'audio preview')) process.exitCode = 1;
  } finally {
    if (gamePid) await call('playtest', { action: 'stop' }).catch(() => {});
    app.kill();
  }
}

main().catch((err) => { console.error(err); process.exitCode = 1; });
