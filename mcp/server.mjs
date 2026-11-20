#!/usr/bin/env node
// bird-editor MCP server：把本项目的日常验证操作封装成结构化工具（零依赖，stdio JSON-RPC）
// 注册于 ZCode config.json mcp.servers；工具返回过滤后的 JSON，不吐原始 stdout
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import process from 'node:process';

const argv = process.argv.slice(2);
const argOf = (n) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : null; };
const PROJECT = argOf('--project') || process.cwd();
const GODOT = argOf('--godot') || 'D:/Steam/steamapps/common/Godot Engine/godot.windows.opt.tools.64.exe';

const isNoise = (l) => BANNER.test(l) || HELPER.test(l) || l.trim() === '';
const BANNER = /^Godot Engine v/;
const HELPER = /^\[godot_ai game_helper\]/;

function runGodot(args) {
  return new Promise((resolve) => {
    const p = spawn(GODOT, args, { cwd: PROJECT });
    let out = '', err = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { err += d; });
    p.on('error', (e) => resolve({ exit: -1, out, err: err + String(e) }));
    p.on('close', (code) => resolve({ exit: code, out, err }));
  });
}

function keepOnly(text, pattern) {
  return (text || '').split('\n').filter((l) => !isNoise(l) && pattern.test(l));
}

const TOOLS = [
  {
    name: 'check_scripts',
    description: '批量 parse 检查项目内 .gd 脚本（headless --check-only）。返回每文件 {path, ok, errors[]}。paths 支持 src/ui/map_file.gd 或 res:// 前缀',
    inputSchema: {
      type: 'object',
      properties: {
        paths: { type: 'array', items: { type: 'string' }, description: '项目相对路径列表' },
      },
      required: ['paths'],
    },
  },
  {
    name: 'run_tests',
    description: '跑 tests/run_tests.gd 全套（当前 67 用例）。返回 {passed, failed, failures[], output_tail}',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'warn_scan',
    description: '跑 tools/warn_scan.gd 自研静态警告扫描器。返回 {files, fails, lines}',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'headless_script',
    description: '跑项目内任意 res:// .gd 脚本（tools/screenshot.gd、migrate_project.gd 等）。返回 {exit, output_tail}',
    inputSchema: {
      type: 'object',
      properties: {
        script: { type: 'string', description: 'res:// 路径或项目相对路径' },
        args: { type: 'array', items: { type: 'string' } },
      },
      required: ['script'],
    },
  },
];

const ERRPAT = /Parse Error|SCRIPT ERROR|Failed to load|Error loading|parse error/i;

async function callTool(name, a) {
  if (name === 'check_scripts') {
    const results = [];
    for (const raw of a.paths) {
      const p = String(raw).replace(/^res:\/\//, '').replaceAll('\\', '/');
      const r = await runGodot(['--headless', '--check-only', '-s', 'res://' + p]);
      const errors = [...keepOnly(r.out, ERRPAT), ...keepOnly(r.err, ERRPAT)];
      results.push({ path: p, ok: errors.length === 0, errors });
    }
    return { ok: results.every((x) => x.ok), results };
  }
  if (name === 'run_tests') {
    const r = await runGodot(['--headless', '-s', 'res://tests/run_tests.gd']);
    const all = [...keepOnly(r.out, /.*/), ...keepOnly(r.err, /.*/)];
    let passed = null, failed = null;
    for (const l of all) {
      const m = l.match(/TESTS-DONE passed=(\d+) failed=(\d+)/);
      if (m) { passed = Number(m[1]); failed = Number(m[2]); }
    }
    const failures = all.filter((l) => /^FAIL |SCRIPT ERROR|Parse Error/i.test(l));
    return { passed, failed, failures, output_tail: all.slice(-25) };
  }
  if (name === 'warn_scan') {
    const r = await runGodot(['--headless', '-s', 'res://tools/warn_scan.gd']);
    const lines = [...keepOnly(r.out, /.*/), ...keepOnly(r.err, /.*/)];
    let files = null, fails = null;
    for (const l of lines) {
      const m = l.match(/SCAN-DONE files=(\d+) fails=(\d+)/);
      if (m) { files = Number(m[1]); fails = Number(m[2]); }
    }
    return { files, fails, lines };
  }
  if (name === 'headless_script') {
    const s = String(a.script).replace(/^res:\/\//, '').replaceAll('\\', '/');
    const extra = Array.isArray(a.args) ? a.args : [];
    const r = await runGodot(['--headless', '-s', 'res://' + s, ...extra]);
    const all = [...keepOnly(r.out, /.*/), ...keepOnly(r.err, /.*/)];
    return { exit: r.exit, output_tail: all.slice(-60) };
  }
  throw new Error('unknown tool: ' + name);
}

function send(msg) { process.stdout.write(JSON.stringify(msg) + '\n'); }

const rl = createInterface({ input: process.stdin });
rl.on('line', (line) => {
  const t = line.trim();
  if (!t) return;
  let msg;
  try { msg = JSON.parse(t); } catch { return; }
  if (msg.id === undefined || msg.id === null) return; // 通知不回包
  (async () => {
    if (msg.method === 'initialize') {
      return {
        protocolVersion: (msg.params && msg.params.protocolVersion) || '2024-11-05',
        capabilities: { tools: {} },
        serverInfo: { name: 'bird-editor', title: 'BIRD 关卡编辑器验证工具', version: '0.1.0' },
      };
    }
    if (msg.method === 'tools/list') return { tools: TOOLS };
    if (msg.method === 'tools/call') {
      const params = msg.params || {};
      try {
        const result = await callTool(params.name, params.arguments || {});
        return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] };
      } catch (e) {
        return { isError: true, content: [{ type: 'text', text: String((e && e.stack) || e) }] };
      }
    }
    if (msg.method === 'ping') return {};
    throw new Error('method not supported: ' + msg.method);
  })().then(
    (result) => send({ jsonrpc: '2.0', id: msg.id, result }),
    (err) => send({ jsonrpc: '2.0', id: msg.id, error: { code: -32603, message: String((err && err.message) || err) } })
  );
});
process.stdin.on('end', () => process.exit(0));
