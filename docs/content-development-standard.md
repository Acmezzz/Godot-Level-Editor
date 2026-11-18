# 内容开发标准（编辑器 ↔ 游戏对齐契约）

> 版本：v1（2026-11-17）
> 适用：`D:\Game\BIRD\Level Editor`（编辑器）与 `D:\Game\BIRD\bird`（游戏运行时）
> 定位：这是**双方实现的最低契约**。编辑器按此校验，游戏按此执行；任一方变更字段或动作，必须先改本文件。

---

## 0. 总原则

1. **编辑器只编辑声明式数据，不执行游戏代码。** 动作必须由游戏工程在 `content/schema/actions.json` 中声明。
2. **地图只存"在哪里、引用谁"，不存剧情正文。**
3. **三层标识**：种类（`scene`）→ 定义（`def`）→ 实例（`id`）。功能靠定义里的**组件**组合，不做互斥种类。
4. **未知字段忽略、未知动作警告不崩溃。** 保证旧内容在新运行时可打开。
5. **所有内容资源是 JSON，UTF-8，两空格或 Tab 缩进不限。** 写盘由编辑器原子替换。

### 0.1 设计取舍（为什么是这个形态）

- **JSON 而非 `.tres`**：地图、清单、关卡清单全是 JSON；JSON 可跨工程读取、便于编辑器原子写与迁移，避免 `.tres` 的脚本路径耦合。
- **有序步骤列表而非节点图**：易排序、易校验、易 diff；需要复杂分支时再演进（事件里可加 `branch` 步骤）。参考 RPG Maker 事件页模型。
- **运行时留在游戏工程**：不学 Dialogic 把执行器和编辑器绑进插件——本项目编辑器与游戏是分离工程。
- **明确的禁区**：地图 JSON 不写对话正文；事件步骤不写脚本字符串；编辑器不执行游戏代码（试玩走现有 `playCommand`）。

---

## 1. 目录与命名

```
<项目>/content/
  defs/<id>.json
  dialogues/<id>.json
  events/<id>.json
  shops/<id>.json
  schema/actions.json
```

清单可覆盖根目录：

```json
{ "contentDir": "content", "items": [{ "id": "item.ore", "name": "矿石" }] }
```

**资源 id 规则**（编辑器 `ContentStore.is_valid_id` 强制，游戏侧不额外放宽）：

- 允许：字母、数字、`_`、`.`、`-`
- 禁止：空串、首尾空白、以 `.` 开头或结尾、`..`、`/`、`\`、`:`
- 文件名 = 内部 `id`；不一致时以文件名为准，编辑器会报错。
- `schema` 只有一份，文件名固定 `actions.json`。

### 1.1 ID 与命名（两回事，永不混用）

- **ID = 游戏端身份**：稳定、参与引用；一经被引用尽量不变。
- **name = 给开发者看的显示名**：随时可改，**永不参与引用**；每类内容资源都应填写。

| 对象 | 存储格式 | 示例 | 分配规则 |
|---|---|---|---|
| 地图 | 文件名（小写蛇形约定） | `tundra_1` | 手填，过 `is_valid_map_name` |
| 实体 | `e_<n>`，**图内唯一** | `e_12` | 每图计数器（载图重置）；跨图引用用 `(target_map, target_point)` 二元组 |
| 层级全名 | **仅显示组合，不落盘** | `tundra_1.e_12` | UI 拼接（地图名 + 实体 id），避免地图改名迁移实体引用 |
| 内容组(def) | `grp.<地图>.<实体>` | `grp.tundra_1.e_12` | 创建时自动，后缀去重 |
| 对话/事件/商店 | `<prefix>.<语义短名>[.<n>]` | `dlg.greet` / `dlg.greet.2` | 短名可自定（小写蛇形），序号去重 |
| flag | 小写蛇形 | `met_blacksmith` | 手填，事件 `set_flag` 即声明 |
| 物品/能力 | `item.<名>` / 小写词 | `item.ore` / `dash` | 清单 `items` / `abilities` 声明 |

---

## 2. 三层实体

### 2.0 资产分层（地形与实体的分界）

| 资产类 | 是什么 | 拥有 | 不拥有 |
|---|---|---|---|
| 地形/装饰（tiles 层） | **铺路**，纯视觉 | 图集格、palette 分组 | 行为、字段、交互 |
| 碰撞（grid 层） | 地形的物理语义 | 类型（solid/one_way/ladder/hazard/斜坡，格式演进见 §11） | 视觉 |
| 实体（entities 层） | **承载功能**，有交互行为（触发或非触发） | prefab、字段、stats、role、hooks、def | — |

分界判据：**游戏里有行为/交互的 → 实体；只负责看的 → 地形**。
血药、跳台、存档点都是实体（其"会不会治疗/弹跳"是写入代码的原生功能，只能调参数）；
`trigger_zone` 无图但有行为 = 实体（编辑器内置特例）。

**内置种类定位规则（B6，批次 12）**：只有「没有贴图、但编辑器需要画它的可视语义」的实体才进 builtin_kinds（目前唯一成员 trigger_zone）。游戏逻辑实体一律走清单 + prefab（移动平台、检查点、存档点都是实体）——防止内置种类变成第二套游戏逻辑，污染编辑器中立性。

### 2.1 地图实体

```json
{
  "scene": "npc",
  "id": "e_42",
  "def": "town.blacksmith",
  "x": 12, "y": 8,
  "flip_h": false,
  "props": {}
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `scene` | 是 | 种类，必须存在于清单 `entities[].id` |
| `id` | 是 | 地图内唯一实例 id，事件/传送引用它 |
| `def` | 否 | 定义 id；缺省时按 `scene` 走旧路径 |
| `x` / `y` | 是 | 格坐标（整数） |
| `flip_h` | 否 | 水平翻转 |
| `props` | 否 | 实例覆盖层：`stats` 与组件级特例 |

**属性优先级**：实例 `props.stats` > 定义 `stats` > 清单 `stats[].default`。

### 2.2 定义

```json
{
  "version": 1,
  "id": "town.blacksmith",
  "kind": "npc",
  "name": "铁匠",
  "prefab": "scenes/npcs/blacksmith.tscn",
  "thumb": "editor/previews/blacksmith.png",
  "stats": { "hp": 20, "speed": 0 },
  "components": {
    "dialogue": [
      { "id": "grp.town.e_42.dialogue", "once": true },
      { "id": "dlg.blacksmith_idle", "when": "met_blacksmith" },
      { "id": "dlg.blacksmith_default" }
    ],
    "shop": [{ "id": "shop.blacksmith" }],
    "interact_event": [{ "id": "evt.blacksmith_first_meet" }]
  }
}
```

- `kind` 必须等于使用它的地图实体的 `scene`，否则编辑器报错。
- `components` 目前支持：`dialogue`、`shop`、`interact_event`、`enemy_profile`。
- 组件可任意组合；同一 NPC 可同时有对话 + 商店 + 互动事件。

**每个槽位是"有序条目数组"**（`dialogue` / `shop` / `interact_event`）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | string | 必填，指向该种类的资源 |
| `once` | bool | 可选。播完写 `<组id>.<组件>.<资源id>.done`，之后不再命中 |
| `when` | string | 可选。flag 名；该 flag 为假时跳过本条 |

**匹配规则（游戏侧必须照此实现）：**

```
for entry in components[slot]:            # 顺序 = 优先级
    if entry.when and not GameState.flag(entry.when):
        continue
    if entry.once and GameState.flag(done_key(entry)):
        continue
    return play(entry)                     # 第一条命中的直接播，不再往后看
return nothing                             # 全部不命中 = 这个槽位当前无内容
```

- **顺序即优先级**，没有额外的 `priority` 字段。编辑器提供 ↑↓ 调整。
- 典型配置：`[初遇 once] → [flag 解锁的闲聊 when] → [兜底循环]`。
- 一个槽位只放一条时行为与旧版完全一致。
- 旧写法 `"dialogue": {"id": "x"}` 仍然合法，等价于只有一条的数组。

**组件优先级**（游戏侧互动命中时）：`interact_event` > `dialogue` > `shop`。
槽位内部再按上面的顺序规则选条。需要"先对话再开店"时，
用互动的 event 编排，不要在 NPC 上硬编码顺序。

### 2.3 种类登记

新增种类必须先写进清单 `entities[]`，定义才能引用：

```json
{
  "id": "npc",
  "name": "NPC",
  "prefab": "scenes/npcs/npc_base.tscn",
  "thumb": "editor/previews/npc.png",
  "fields": [],
  "stats": []
}
```

`trigger_zone` 是内置种类，不需要 prefab（见第 6 节）。

**字段类型（H5，批次 11）**：`fields[].type` 取值 `string`、`entity_ref`、`map_ref`、`enum`（声明 options 数组，编辑器出下拉）、`bool`（开关）。清单声明 + 编辑器生成控件；游戏侧解释值。

### 2.4 角色与挂点（role / hooks，可选声明）

实体类型条目可带两个可选声明字段（缺省 = 普通实体）：

- `"role"`：**编辑器连接语义**，首版取值 `portal / exit / landing / trigger`。
  编辑器的连接工具（配对/跨图选点/校验/连线）按 role 识别，
  **不再按 scene id 硬编码**；role 缺省时编辑器按 id 回退识别（旧清单零改动兼容）。
- `"hooks"`：该类型暴露的内容挂点列表，名字由游戏侧定（如 `on_enter` / `on_death`）。
  挂点进入 def 组件槽位，与标准槽位同规则（顺序 = 优先级，once/when）。

```json
{
  "id": "exit",
  "name": "跨图出口",
  "role": "exit",
  "hooks": ["on_enter"],
  "fields": [], "stats": []
}
```

**组件声明化（H4，批次 11）**：游戏工程可维护 `content/schema/components.json`（与 actions.json 同级）：
`{"components": {"<槽位名>": {"kind": "<内容种类>", "multi": true|false, "label": "中文名"}, ...}}`。
声明存在时编辑器按声明渲染槽位/校验/跳转；无声明回退内置常量（向前兼容）。新增组件：先改声明，再实现游戏侧执行器。

**出生 marker 与传送落点（K8，批次 12）**：出生 marker = 玩家从哪进图（每图唯一，编辑器出生点工具画的绿十字，存地图 spawn 字段）；`spawn_point` 实体 = 传送/出口可复用落点（可多个，role=landing，显示名「传送落点」，画布青色描边）。文档里「出生」专指前者，「落点」专指后者。

判定规则：**玩家主动、反复使用的连接** → 原生功能实体（role 声明 + 连接工具）；
**剧情编排中的一次性位移/给予** → actions 元功能（如 teleport）；
**原生功能想在关键时机附带内容** → 挂点。传送不再是独立系统，而是这条规则下的三层分工。

---

## 3. 对话

```json
{
  "version": 1,
  "id": "dlg.blacksmith",
  "name": "铁匠初遇",
  "speakers": { "self": { "name": "铁匠", "portrait": "assets/portraits/blacksmith.png" } },
  "start": "n1",
  "nodes": [
    { "id": "n1", "speaker": "self", "text": "你来得正好。", "next": "n2" },
    { "id": "n2", "speaker": "", "text": "炉火映着墙上的旧剑。", "next": "n3" },
    { "id": "n3", "speaker": "self", "text": "要买点什么吗？",
      "choices": [
        { "text": "看看货。", "action": "open_shop", "next": "" },
        { "text": "改天吧。", "next": "end" }
      ] },
    { "id": "end", "end": true }
  ]
}
```

| 字段 | 说明 |
|---|---|
| `name` | 可选；显示名（给人看，不参与引用；缺失时 UI 回退显示 id） |
| `speakers` | 可选；`speaker` 为空串或未登记 = 旁白 |
| `start` | 必填，必须指向存在的节点 |
| `nodes[].next` | 可空；空且无 choices = 终止 |
| `nodes[].end` | `true` 显式终止 |
| `choices[].next` | 必填，必须指向存在的节点 |
| `choices[].action` | 可选；游戏侧命名的轻动作，如 `open_shop` |
| `choices[].require` | 可选；flag 条件，首版支持 `flag` / `not_flag` |

**校验规则**：节点 id 唯一、起始节点存在、`next`/选项目标不悬空、不可达节点警告、无终止节点警告。

**运行时契约**：

- 按 `start` 逐节点推进；有 `choices` 时阻塞等待玩家选择。
- `action` 先于 `next` 执行；`action` 未注册时警告并继续。
- 旁白（`speaker == ""`）由游戏侧决定样式，编辑器不假设 UI。

---

## 4. 事件

```json
{
  "version": 1,
  "id": "evt.blacksmith_first_meet",
  "name": "铁匠初遇演出",
  "once": true,
  "steps": [
    { "type": "camera_focus", "target": "e_42", "duration": 0.6 },
    { "type": "dialogue", "dialogue": "dlg.blacksmith" },
    { "type": "play_animation", "target": "e_42", "animation": "hammer" },
    { "type": "wait", "seconds": 0.5 },
    { "type": "set_flag", "flag": "met_blacksmith", "value": true },
    { "type": "camera_reset" }
  ]
}
```

- `name` 可选；显示名（给人看，不参与引用；缺失时 UI 回退显示 id）。
- `steps` 有序执行，`dialogue` 与 `wait` 阻塞到完成。
- `once: true` 表示只播一次，运行时写入 flag `evt.<id>.done`。
- `target` 一律是**地图实例 id**（`e_42`），不是定义 id。

### 4.1 动作 schema

游戏工程维护 `content/schema/actions.json`：

```json
{
  "version": 1,
  "actions": {
    "dialogue": {
      "params": { "dialogue": { "type": "dialogue_ref", "required": true } }
    },
    "camera_focus": {
      "params": { "target": { "type": "entity_ref", "required": true },
                  "duration": { "type": "float", "default": 0.5 } }
    },
    "play_animation": {
      "params": { "target": { "type": "entity_ref", "required": true },
                  "animation": { "type": "string", "required": true } }
    },
    "wait": { "params": { "seconds": { "type": "float", "default": 0.5 } } },
    "teleport": {
      "params": { "target_map": { "type": "string", "required": true },
                  "target_point": { "type": "entity_ref", "required": true },
                  "transition": { "type": "string" } }
    },
    "set_flag": {
      "params": { "flag": { "type": "string", "required": true },
                  "value": { "type": "bool", "default": true } }
    }
  }
}
```

**参数类型**：`bool`、`int`、`float`、`string`、`array`、`dict`，
以及可选范围声明 `min`/`max`/`step`（H1，批次 11）：编辑器生成数值控件用，游戏侧忽略。

以及引用类型 `dialogue_ref`、`event_ref`、`shop_ref`、`def_ref`、`entity_ref`（均为字符串 id）。

**规则**：

- 编辑器只提供 schema 里声明的动作；未声明 = 校验错误。
- 必填参数缺失 = 校验错误；类型不符 = 校验错误。
- schema 缺失时编辑器只做结构检查，不猜测游戏能力。
- 游戏侧新增动作：先改 `actions.json`，再实现执行器；顺序反了会被校验拦下。

### 4.2 执行器契约

游戏侧实现一个按序执行的 runner：

```gdscript
# 伪代码，游戏工程自行落地
func run(event_id: String) -> void:
    if event.once and GameState.flag("evt." + event_id + ".done"):
        return
    for step in event.steps:
        match step.type:
            "dialogue":      await DialogueRunner.play(step.dialogue)
            "camera_focus":  await CameraRig.focus(step.target, step.duration)
            "play_animation": ActorRegistry.play(step.target, step.animation)
            "wait":          await get_tree().create_timer(step.seconds).timeout
            "set_flag":      GameState.set_flag(step.flag, step.value)
            "camera_reset":  CameraRig.reset()
            _:               push_warning("未实现的动作: " + step.type)
    if event.once:
        GameState.set_flag("evt." + event_id + ".done", true)
```

- 未知动作：警告 + 跳过，**不中断整段演出**。
- 取消/跳过演出：runner 需支持中断，已执行的 `set_flag` 不回滚。

---

## 5. 商店

```json
{
  "version": 1,
  "id": "shop.blacksmith",
  "name": "铁匠商店",
  "currency": "gold",
  "entries": [
    { "item": "item.ore", "price": 12, "stock": 5 },
    { "item": "item.sword", "price": 80, "stock": -1 }
  ]
}
```

| 字段 | 规则 |
|---|---|
| `name` | 可选；显示名（给人看，不参与引用；缺失时 UI 回退显示 id） |
| `item` | 必须是清单 `items[].id` |
| `price` | 数字，不能为负 |
| `stock` | 整数，且只能是 `-1`（无限）或 `>= 0`（有限）；H2（批次 11）：非整数/小于 -1 一律校验错误 |
| `currency` | 可选，缺省 `gold`；游戏侧解释 |

**校验规则**：条目是对象、物品不重复、物品存在、价格非负、库存合法。

---

## 6. 触发区域

`trigger_zone` 是内置种类，地图实体形态：

```json
{
  "scene": "trigger_zone",
  "id": "e_50",
  "x": 10, "y": 6,
  "props": {
    "w": 3, "h": 2,
    "mode": "enter",
    "event": "evt.cave_intro",
    "require_flag": "",
    "once": true
  }
}
```

| 字段 | 规则 |
|---|---|
| `w` / `h` | 正整数，格数；矩形范围 `[x, x+w) × [y, y+h)` |
| `mode` | `enter` / `interact` / `auto` |
| `event` | 必填，必须指向存在的事件 |
| `require_flag` | 可选；flag 为 false 时不触发 |
| `once` | 可选；与事件自身 `once` 取逻辑或 |

**语义**：

- `enter`：玩家首次进入矩形时触发一次判定。
- `interact`：玩家在矩形内按互动键时触发。
- `auto`：玩家在矩形内时持续判定（仍受 `once` / `require_flag` 约束）。

**游戏侧落地**：实例化为 `Area2D` + `RectangleShape2D`，尺寸 `w × tileSize`、`h × tileSize`，
位置取实体格坐标乘以 `tileSize`。触发区不写入碰撞图层，不阻挡移动。

---

## 7. 存档与 flag

- flag 单一命名空间：`{ "met_blacksmith": true, "gold": 120 }`。
- 事件只写 `evt.<id>.done`；业务 flag 由事件里的 `set_flag` 写。
- 按 Godot 官方存档建议：`GameState` 进 `"Persist"` 组，`save() -> Dictionary`，逐行 JSON 写 `user://`。
- 首版不存对话进度；重播与否由事件 `once` / flag 决定。

---

## 8. 版本与迁移

- 每类资源都有 `version`（当前 `1`）。读入时低版本走升级函数，高版本只警告不改写。
- 重命名资源 → 编辑器扫描全工程引用并同步；游戏侧不维护第二份映射。
- 删除资源 → 编辑器先列引用方；有引用时禁止直接删除。
- 新增字段：默认值必须保证旧数据仍合法；新增必填字段 = 破坏性变更，需 bump `version`。

---

## 9. 校验归属

| 规则 | 归属 | 位置 |
|---|---|---|
| 资源 id 合法、路径安全 | 编辑器 | `content_store.gd` |
| 对话图完整性 | 共享逻辑 | `dialogue_model.gd` |
| 事件动作与参数 | 共享逻辑 | `event_model.gd` + `actions.json` |
| 商店条目 | 共享逻辑 | `shop_model.gd` |
| 定义种类与组件 | 共享逻辑 | `def_model.gd` |
| 地图 ↔ 内容引用 | 共享逻辑 | `content_validate.gd` |
| 运行时行为 | 游戏 | 执行器 / DialogueRunner |

编辑器把上述 issue 与地图校验合并展示；游戏侧可复用同一批模块做启动自检。

---

## 10. 最小对接清单（游戏侧开工顺序）

1. 清单加 `contentDir` 与 `items`。
2. 地图加载读 `def`，按定义取 prefab/stats，实例化后挂 `def_id` 与组件。
3. 实现 `EventRunner`，先支持：`dialogue`、`wait`、`set_flag`、`camera_focus`、`camera_reset`。
4. 实现 `DialogueRunner`：逐节点、旁白、选项、`action`。
5. 实现 `trigger_zone` → `Area2D`，按 `mode` 触发事件。
6. 实现商店 UI 与 `open_shop` 动作。
7. 写 `content/schema/actions.json`，与第 4.1 节示例对齐。
8. 启动时跑一次内容自检（直接复用编辑器模块或移植同规则）。

完成以上八步，编辑器产出的内容即可被游戏直接消费。

---

## 11. 地图格式演进规划（批次 9 实施，当前格式不变）

> 已拍板：碰撞类型化（含斜坡）与多图集**同一次格式 bump**，避免两次迁移。
> 本节只做契约预留说明；实施前地图 JSON 保持现状，游戏侧无需提前适配。

- **碰撞类型**：`collision` 条目由 `[x, y]` 扩展为 `[x, y, type, shape]`；
  缺省 `solid`，旧数据零迁移。首批类型：`solid / one_way / ladder / hazard`；
  `shape` 表达斜坡形状（空 = 矩形；`r45 / l45` 等 45° 三角，实施时定稿）。
- **多图集**：`tiles` 条目由 `[x, y, ax, ay]` 扩展为 `[x, y, atlas, ax, ay]`；
  缺省 `atlas = 0`（现有单图集数据零迁移）。清单允许声明多张图集，
  解除 manifest_validation 的单图集锁（T21）。
- 实施批次与游戏侧同步要求见 [execution-plan.md](execution-plan.md) 批次 9；
  动实现前先在本节定稿字段（契约变更先改本文件）。