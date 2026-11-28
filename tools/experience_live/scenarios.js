const fs = require('node:fs');
const path = require('node:path');

const field = (id, code, name, type, extra) => ({ id, code, name, kind: 'input', type, ...extra });
const choice = (id, code, name, source) => ({ id, code, name, kind: 'choice', source });

function configure(m, dir, godot) {
  m.projectName = '航站试验场';
  m.tileSize = 32;
  delete m.preview;
  delete m.mapGenerators;
  m.assets = [
    { id: 'floor', name: '地板', kind: 'scene', shape: 'tile', atlas: 'tile.png', cell: { w: 16, h: 16 } },
    { id: 'wall', name: '墙面', kind: 'scene', shape: 'tile', atlas: 'entity.png', cell: { w: 16, h: 16 } },
    { id: 'beacon', name: '信标', kind: 'entity', code: 'BCON', thumb: 'entity.png', visual: {}, functions: ['cue', 'rule'] },
    { id: 'hud', name: '固定状态条', kind: 'entity', code: 'HUD0', visual: {} },
  ];
  m.audio[0].name = '警报提示';
  m.functions = {
    cue: { name: '多轨演出', code: 'CUE0', steps: true, repeatable: true, triggers: ['interact'], timebase: 'seconds', timePreview: { audioField: 'music' },
      fields: [choice('music', 'MUS0', '参考音频', 'audio:')] },
    route: { name: '去往', code: 'RTE0', fields: [field('target', 'DST0', '去向', 'flow_target', { maps: true, screens: true })] },
    option: { name: '调整音量', code: 'OPT0', fields: [field('volume', 'VOL0', '音量（0～1）', 'float', { min: 0, max: 1 })] },
    rule: { name: '章节规则', code: 'RUL0', fields: [field('energy', 'STA0', '初始行动力', 'int', { min: 1 })] },
  };
  m.steps = {
    say: { name: '显示对白', code: 'SAY0', fields: [field('text', 'MSG0', '对白', 'string', { multiline: true })] },
    sound: { name: '播放声音', code: 'SND0', fields: [choice('clip', 'CLP0', '播放音频', 'audio:')] },
    reveal: { name: '显示图层', code: 'REV0', fields: [choice('layer', 'LYR0', '可见图层', 'layer:')] },
    fade: { name: '全屏转场', code: 'FAD0', fields: [] },
    follow: { name: '调用另一条内容', code: 'FLW0', fields: [field('next', 'NXT0', '接续', 'flow_target', { contentTypes: ['route'] })] },
  };
  m.triggers = { entered: { name: '进入地图', code: 'ENT0', eventTargets: { contentTypes: ['rule'] } },
    interact: { name: '交互', code: 'USE0' } };
  delete m.conditions;
  m.playtest = { executable: godot, args: ['--path', dir, '--rendering-method', 'gl_compatibility', '--resolution', '800x480', '--', '--map=%mapfile%'],
    projectEntry: true, mapEntry: true, viewEntry: true, report: true, captureFrames: true };
  m.viewports = [{ id: 'wide', name: '宽屏', w: 800, h: 480 }, { id: 'compact', name: '掌机', w: 420, h: 360 }];
  m.cellGraphEdgeTypes = { path: { name: '运输边', fields: [field('cost', 'CST0', '通过成本', 'int', { min: 0 }),
    field('gate', 'GAT0', '解锁条件', 'string')] } };
  return m;
}

async function author(call, expect, out) {
  const { id: draft } = await call('manage_draft', { action: 'create', name: '视角与演出实测' });
  let revision = 0;
  const ids = {};
  const apply = async (ops) => {
    const result = await call('apply_changes', { draft, revision, operations: ops });
    revision = result.revision;
    for (const [alias, value] of Object.entries(result.aliases)) ids[alias.slice(1)] = value;
  };
  const map = (as, name, width, height, projection) => ({ op: 'map.create', as, name, width, height, projection });
  const layer = (m, as, name, options) => ({ op: 'layer.put', map: `$${m}`, as, data: { name, ...options } });
  const tile = (m, l, cells) => ({ op: 'tiles.set', map: `$${m}`, layer: `$${l}`, cells });
  const row = (y, x0, x1, asset = 'floor') => Array.from({ length: x1 - x0 + 1 }, (_, i) => ({ x: i + x0, y, asset, atlas: [0, 0] }));
  const put = (fn, as, name, fields, extra = {}) => ({ op: 'content.put', function: fn, as, data: { name, fields, ...extra } });
  const dest = (fn, content) => ({ function: fn, content: `$${content}` });
  const group = (as, name, drawingMap, maps, drawOrder, events) => ({ op: 'group.put', as, data: { name, drawingMap: `$${drawingMap}`,
    maps: maps.map((m) => `$${m}`), drawOrder, ...(events && { events }) } });
  const pulses = Array.from({ length: 24 }, (_, i) => ({ id: `pulse${i}`, x: 4 + i % 16, y: 3 + Math.floor(i / 16) }));
  const pulseSteps = pulses.map(({ id }, i) => ({ step: 'REV0', at: 0.35 + i * 0.042, duration: 0.55,
    track: 3 + i % 4, fields: { LYR0: `$${id}` } }));
  await apply([
    map('side', '01 信标回廊', 22, 10, 'orthogonal'), map('iso', '02 折叠信号站', 10, 8, 'isometric'),
    map('hex', '03 六角矿港', 12, 9, 'hexagonal'),
    map('back', '共享绘制 远景', 20, 9, 'orthogonal'), map('mask', '共享绘制 前景', 22, 10, 'orthogonal'),
    map('hudmap', '共享绘制 状态条', 5, 3, 'orthogonal'),
    layer('side', 'sideFloor', '主体地形', { parallax: 1 }), layer('side', 'reveal', '警报光带（初始隐藏）', { visible: false, blend: 'add' }),
    layer('side', 'tri', '警戒带三角格', { tileGrid: { gridProjection: 'orthogonal', gridTopology: 'triangles' } }),
    ...pulses.flatMap(({ id, x, y }, i) => [layer('side', id, `扫光 ${String(i + 1).padStart(2, '0')}`, { visible: false, blend: 'add' }),
      tile('side', id, row(y, x, x))]),
    layer('iso', 'isoFloor', '操作区'), layer('hex', 'hexFloor', '物流区'),
    layer('back', 'stars', '慢速远景', { parallax: 0.25 }), layer('back', 'clouds', '反向远景', { parallax: -0.5 }),
    layer('mask', 'over', '前景梁', { parallax: 1.35 }), layer('hudmap', 'hudlayer', '屏幕内容'),
    tile('side', 'sideFloor', row(5, 0, 21).concat(row(6, 0, 21, 'wall'), row(7, 0, 21, 'wall'), row(4, 3, 3, 'wall'))),
    tile('side', 'reveal', row(2, 5, 15)), tile('side', 'tri', row(5, 2, 39, 'wall').filter((x) => x.x % 2 === 0)),
    tile('back', 'stars', row(2, 0, 18).filter((x) => x.x % 4 === 1)),
    tile('back', 'clouds', row(3, 0, 18, 'wall').filter((x) => x.x % 4 === 0)),
    tile('mask', 'over', row(1, 0, 15, 'wall')),
    tile('iso', 'isoFloor', Array.from({ length: 6 }, (_, i) => row(i + 1, 1, 7)).flat()),
    tile('hex', 'hexFloor', Array.from({ length: 5 }, (_, i) => row(i + 2, 1, 10)).flat()),
    { op: 'map.patch', map: '$side', data: { spawn: [2, 4] } },
    { op: 'collision.set', map: '$side', cells: [{ x: 3, y: 4, type: 'solid' }] },
    { op: 'collision.set', map: '$mask', cells: [{ x: 3, y: 3, type: 'solid' }] },
    { op: 'instance.put', map: '$side', as: 'beacon', data: { asset: 'beacon', layer: '$sideFloor', x: 3, y: 3 } },
    { op: 'instance.put', map: '$hudmap', as: 'hud', data: { asset: 'hud', layer: '$hudlayer', x: 1, y: 1 } },
    put('rule', 'rule', '章节二：3 点行动力', { STA0: 3 }),
    group('gback', '共用天际线', 'back', ['side', 'iso'], -2, { ENT0: dest('rule', 'rule') }),
    group('gmask', '回廊前景梁', 'mask', ['side'], 2), group('ghud', '固定状态条', 'hudmap', ['side'], 5),
    put('route', 'toIso', '接续等距谜题', { DST0: { map: '$iso' } }),
    { op: 'content.put', function: 'cue', as: 'cue', map: '$side', instance: '$beacon', data: { name: '警报：三轨揭示与转场', fields: { MUS0: 'AUD0' }, steps: [
      { step: 'SAY0', at: 0.05, duration: 1.35, track: 0, fields: { MSG0: 'Beacon online. Follow the light.' } },
      { step: 'REV0', at: 0.05, duration: 0.85, track: 1, fields: { LYR0: '$reveal' } },
      { step: 'SND0', at: 0.05, duration: 1, track: 2, fields: { CLP0: 'AUD0' } },
      ...pulseSteps,
      { step: 'FAD0', at: 1.7, duration: 1.8, track: 1, fields: {} },
      { step: 'FLW0', at: 3.55, track: 0, fields: { NXT0: dest('route', 'toIso') } },
    ] } },
    { op: 'binding.put', map: '$side', instance: '$beacon', as: 'binding', function: 'cue', data: { content: '$cue', trigger: 'USE0' } },
  ]);
  const graph = (mapId, layerId, positions, links) => ({ op: 'map.patch', map: ids[mapId], data: { meta: { cellGraph: {
    spaces: { play: { name: '行动区', layer: ids[layerId], origin: [0, 0], axisX: [32, 0], axisY: [0, 32] } },
    cells: Object.entries(positions).map(([id, [x, y, delta]]) => ({ id, name: id, space: 'play',
      polygon: [[x - 16, y], [x, y - 11], [x + 16, y], [x + 13, y + 8], [x, y + 12], [x - 13, y + 8]], props: { cargo: delta || 0 } })),
    edges: links.map(([from, to, cost, gate], i) => ({ id: `r${i}`, from, to, type: 'path', props: { cost, gate: gate || '' } })),
  } } } });
  const text = (id, label, x, y, w, h, size = 24) => ({ id, kind: 'text', text: label, anchors: [x, y, x + w, y + h], fontSize: size });
  const button = (id, label, y, target) => ({ ...text(id, label, 0.22, y, 0.56, 0.1), kind: 'button', target });
  await apply([
    graph('iso', 'isoFloor', { start: [-50, 86], switch: [12, 116], exit: [57, 77] },
      [['start', 'switch', 1], ['start', 'exit', 1, 'needs_switch'], ['switch', 'exit', 1]]),
    graph('hex', 'hexFloor', { start: [80, 88], mine: [146, 125, 3], hub: [204, 81], port: [267, 119] },
      [['start', 'mine', 0], ['start', 'port', 2], ['mine', 'hub', 1], ['hub', 'port', 2]]),
    put('route', 'toSide', '打开横版回廊', { DST0: { map: ids.side } }),
    put('route', 'toMenu', '返回航站菜单', { DST0: { view: 'menu' } }),
    put('route', 'toSettings', '打开设置界面', { DST0: { view: 'settings' } }),
    put('route', 'toHex', '直接进入物流试验', { DST0: { map: ids.hex } }),
    put('option', 'vol', '安静：设置为 25%', { VOL0: 0.25 }),
    { op: 'view.put', view: 'menu', data: { name: '航站菜单', layout: { viewport: 'wide', elements: [
      text('title', 'NIGHT TERMINAL', 0.22, 0.16, 0.56, 0.11, 36), button('start', 'S  /  Enter the signal corridor', 0.37, dest('route', 'toSide')),
      button('settings', 'D  /  Audio settings', 0.50, dest('route', 'toSettings')), button('hex', 'H  /  Hex freight route', 0.63, dest('route', 'toHex')),
    ] } } },
    { op: 'view.put', view: 'settings', data: { name: '声音设置', layout: { viewport: 'wide', elements: [
      text('title', 'AUDIO SETTINGS', 0.22, 0.16, 0.56, 0.11, 36), button('volume', 'V  /  Set audio to 25%', 0.37, dest('option', 'vol')),
      button('back', 'D  /  Back to menu', 0.50, dest('route', 'toMenu')),
    ] } } },
    { op: 'startup.set', data: { target: { view: 'menu' } } },
  ]);
  ids.screen = 'menu';
  ids.settings = 'settings';
  const validation = await call('validate', { draft });
  fs.writeFileSync(path.join(out, 'validation.json'), JSON.stringify(validation, null, 2));
  expect('candidate validates with actual declarations and references', validation.valid, validation.issues);
  for (const name of ['side', 'iso', 'hex'])
    await call('capture_editor', { target: 'draft_map', draft, map: ids[name], width: 900, height: 560 }, `author-${name}-draft.png`);
  await call('publish', { draft, revision });
  const { id: testDraft } = await call('manage_draft', { action: 'create', name: '反例：时机码校验' });
  const bad = await call('apply_changes', { draft: testDraft, revision: 0, operations: [
    { op: 'binding.put', map: ids.side, instance: ids.beacon, binding: ids.binding, data: { trigger: 'interact' } },
  ] });
  const badValidation = await call('validate', { draft: testDraft });
  await call('capture_editor', { target: 'draft_map', draft: testDraft, map: ids.side, width: 600, height: 420 }, 'author-unpublished-trigger.png');
  await call('manage_draft', { action: 'discard', draft: testDraft, revision: bad.revision });
  fs.writeFileSync(path.join(out, 'invalid-trigger-validation.json'), JSON.stringify(badValidation, null, 2));
  return ids;
}

module.exports = { author, configure };
