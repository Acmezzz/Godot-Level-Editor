// MCP server 端到端驱动测试：initialize → tools/list → tools/call
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

const child = spawn('node', ['mcp/server.mjs', '--project', process.cwd()], { stdio: ['pipe', 'pipe', 'pipe'] });
const rl = createInterface({ input: child.stdout });
const pending = new Map();
let nextId = 1;

function rpc(method, params) {
  const id = nextId++;
  const payload = JSON.stringify({ jsonrpc: '2.0', id, method, params });
  return new Promise((resolve) => {
    pending.set(id, resolve);
    child.stdin.write(payload + '\n');
  });
}

rl.on('line', (l) => {
  let m;
  try { m = JSON.parse(l); } catch { return; }
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
});

const t0 = Date.now();
const init = await rpc('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'driver', version: '0' } });
console.log('INIT ok=', !!init.result, 'server=', init.result && init.result.serverInfo.name);

const list = await rpc('tools/list', {});
console.log('TOOLS =', list.result.tools.map((t) => t.name).join(', '));

const chk = await rpc('tools/call', { name: 'check_scripts', arguments: { paths: ['src/ui/map_file.gd', 'src/canvas/editor_canvas.gd'] } });
const chkData = JSON.parse(chk.result.content[0].text);
console.log('CHECK ok=', chkData.ok, JSON.stringify(chkData.results.map((r) => r.path + ':' + r.ok)));

const ws = await rpc('tools/call', { name: 'warn_scan', arguments: {} });
const wsData = JSON.parse(ws.result.content[0].text);
console.log('WARNSCAN files=', wsData.files, 'fails=', wsData.fails);

const ts = await rpc('tools/call', { name: 'run_tests', arguments: {} });
const tsData = JSON.parse(ts.result.content[0].text);
console.log('TESTS passed=', tsData.passed, 'failed=', tsData.failed, 'failures=', tsData.failures.length);

console.log('ELAPSED', Date.now() - t0, 'ms');
child.kill();
process.exit(0);
