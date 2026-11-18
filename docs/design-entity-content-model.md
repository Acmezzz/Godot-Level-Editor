# 实体-内容统一模型设计（原生功能 / 附加内容 / 挂点 / 元功能）

> 日期：2026-11-18
> 背景：方向性重构讨论——"内容库实质上是实体功能的集合；传送本质上也是实体的一个内容"。
> 本文把这句话落成可实施的模型与迁移路径。
> 与审查文档的关系：修正 feature-review T9 的结论（该条推荐 builtin 化，**按本模型改为角色声明化**）；
> 落地 T14（能力门禁）、H4（组件声明化）、K7（实例分布）三条已有提案。

---

## 0. 一句话模型

**实体是载体；它的功能分两层——"写入的原生功能"（游戏代码实现，只能调参数）
和"挂上去的附加内容"（内容库组件，可自由组合）；原生功能在关键时机暴露"挂点"供内容附着；
原生功能里可复用的位移/给予类动作收编为"元功能"（actions），供内容编排调用。**

| 概念 | 定义 | 编辑器对应面 | 游戏对应面 |
|---|---|---|---|
| 载体（实体） | 地图上的一个实例，三层标识的实例层 | 画布/调色板/属性面板 | prefab 实例化 |
| **原生功能** | 实体天生的行为，代码写死，**只能调参数不能改逻辑** | **实体资产**（类型级默认值）+ 属性面板（实例级覆盖） | 实体脚本 |
| **附加内容** | 挂到具体实体/定义上的可组合内容 | **内容库 / 内容抽屉**（槽位） | 内容执行器 |
| **挂点（hook）** | 原生功能暴露的"这里可以挂内容"的时机 | 内容抽屉按声明渲染槽位 | 在代码里触发该挂点 |
| **元功能（action）** | 收编进 actions schema 的原生动作，可被任何内容调用 | 事件编辑器动作下拉（schema 驱动，零编辑器代码） | 动作执行器 |
| **角色（role）** | 实体类型声明的"编辑器连接语义"标签 | 连接工具（配对/校验/连线/选点）按 role 识别 | 与游戏逻辑无关，纯编辑器 UX |

---

## 1. 用传送把模型讲清楚

### 1.1 传送的三种形态，分别落在模型的不同层

| 形态 | 例子 | 归属层 |
|---|---|---|
| 玩家主动、可复用、双向的连接 | 传送门、图间出口 | **原生功能实体**（role=portal/exit）+ 连接工具 |
| 剧情编排中的一次性位移 | NPC 对话完把你传走 | **元功能**（actions 里的 `teleport`） |
| "走到这里触发东西"的载体 | 触发区 | 原生功能实体（role=trigger），挂点 on_enter |

### 1.2 判定规则（写进 dev-standard）

- **玩家主动、反复使用的连接** → 原生功能实体（配对 UX、落点复用、能力门禁都靠它）；
- **剧情编排中的一次性位移/给予** → 元功能动作（NPC 送你回家 = `interact_event`
  步骤 `[dialogue, teleport]`——传送成为内容可调用的元功能）；
- **原生功能想"在关键时机附带内容"** → 挂点（portal 的 on_enter 可以先播段台词再传送）。

### 1.3 这组规则下，"传送系统"不再是独立子系统

它降级为**连接工具**：编辑器里一组按 role 识别、服务任意传送类实体的
通用 UX（配对、跨图选点、校验、连线绘制）。删掉的是"编辑器硬编码认识 portal/exit
这两个 scene id"这件事，不是连接工具本身。

---

## 2. 你已经做对的部分：两块拼图正好各就各位

- **实体资产界面 = 原生功能参数层**：stats/fields 的类型级默认值在这里调，
  即改即存清单——正是"写入的功能只能调参数"的正确操作面。
- **内容库/内容抽屉 = 附加内容层**：defs 组件槽位（对话/互动事件/商店）挂到具体实体，
  即"让一个 NPC 对话完把我传走"的组合层。

**缺的是三块，正好构成这次重构的全部内容**：
1. **实体资产缺"实例分布"清单**（你自己已经指出的）——该类实体散布在哪些图、各几个、
   点击跳转。原生命令的参数层没有实例视图。
2. **连接原语半硬编码**（feature-review T9）——portal/exit/spawn_point 既是游戏清单声明的实体，
   又被编辑器到处按 scene id 硬编码。按本模型改为 **role 声明**，编辑器只认声明。
3. **元功能未收编**——actions.json 里还没有 teleport 这类"调用原生功能"的动作；
   挂点（hooks）也还没有声明机制。

---

## 3. 数据契约设计（地图 JSON 不变）

### 3.1 清单实体条目新增两个可选字段

```json
{
  "id": "exit",
  "name": "跨图出口",
  "prefab": "scenes/exit.tscn", "thumb": "editor/previews/exit.png",
  "role": "exit",
  "hooks": ["on_enter"],
  "fields": [...], "stats": [...]
}
```

- `role`：编辑器连接语义。首版取值 `portal / exit / landing / trigger`；
  **缺省 = 普通实体**（不参与任何连接工具）。编辑器按 role 识别，不再按 scene id。
- `hooks`：该类型实体暴露的内容挂点列表（名字由游戏侧定，如 on_enter/on_death）。
- 兼容：role/hooks 缺省时，编辑器**回退按 scene id 识别** portal/exit/spawn_point
  （现有清单无需改动即可继续工作）；declared role 优先于 id 回退。

### 3.2 元功能：actions.json 收编 teleport

```json
"teleport": {
  "params": {
    "target_map":   { "type": "string", "required": true },
    "target_point": { "type": "entity_ref", "required": true },
    "transition":   { "type": "string" }
  }
}
```

- 游戏侧实现执行器调用自己的传送流程；编辑器**零改动**——事件编辑器的动作下拉
  与参数控件本来就是 schema 驱动的（含 target_point 的实体引用下拉）。
- 同批可收编的元功能候选：`give_item`（剧情给物品）、`heal`、`move_entity`。
  先只做 teleport，其余等真实需求。

### 3.3 附加内容的槽位 = 标准槽位 + 挂点

def 的 components 键即槽位名：标准槽位（dialogue/shop/interact_event）语义不变；
挂点槽位（如 on_enter/on_death）由清单 hooks 声明，内容抽屉按声明渲染。
组件执行顺序规则不变：同槽内按数组顺序（once/when 匹配）；
跨槽的触发时机由游戏代码决定（NPC 的互动流程先 on_interact 再 dialogue 再 shop——
这是 prefab 代码，不是编辑器约定）。

---

## 4. 编辑器重构清单（去硬编码点）

以下位置把"scene id == portal/exit/spawn_point"替换为 role 查询
（`EditorManifest.role_of(manifest, sid)`，缺省回退 id）：

| 位置 | 现状硬编码 | 改为 |
|---|---|---|
| `map_validate.gd` | portal/exit/spawn_point 白名单校验 | 按 role 收集三类实体再校验 |
| `cross_map.gd` | ALLOWED_REUSE / picked_scene 判断 | role 判断 |
| `canvas_draw.gd` | 引用连线、map_export 颜色表 | 按 role 取连线/颜色 |
| `cross_map_picker.gd` | "只有 exit 可配对"等交互判断 | role 判断 |
| `props_panel.gd` | portal 配对 UI、exit 的 map_ref 特例 | role 判断 |
| `content_dock`/asset_panel | （顺带）builtin 过滤、角色徽章 | role 徽章显示 |

- `builtin_kinds`：trigger_zone 的 kind 条目补 `"role": "trigger"`（与声明体系合流）。
- 顺带修正 feature-review T9：**不 builtin 化**——portal/exit 有 prefab 有美术，
  是游戏实体；编辑器只需要 role 声明。trigger_zone 仍是唯一 builtin（无美术、
  纯编辑器可视语义）。

---

## 5. 实体资产补"实例分布"清单（你指出的缺口）

### 5.1 数据

- 来源：`MapStore.read_all`（侧栏刷新链已有，资产页可复用或接缓存）；
  按清单实体 id 统计每张地图的实例数与 ent_id 列表。

### 5.2 UI（资产详情页新增一节"实例分布"）

```
实例分布
┌────────────────────────────────────────────┐
│ level1 × 3   [定位]   level2 × 1   [定位]  │
│  · e_12 (10,8)  · e_15 (33,8)  · e_21 (2,14)│
└────────────────────────────────────────────┘
```

- 每行：地图名 × 数量 + [定位] 按钮 → 打开该图并 focus 第一个实例
  （复用 `side_actions._focus_entity` 的定位链路）。
- 展开显示 ent_id + 格坐标（对齐实体大纲的搜索能力）。
- 改名/删除场景的引用确认（K7 资产删除引用检查）直接复用这个数据源。

---

## 6. 挂点模型：把 trigger_zone、怪物 on_death、portal on_enter 统一

- **trigger_zone 的本质** = "原生功能就是触发事件"的实体（role=trigger，
  挂点 on_enter/interact/auto 对应它的 props.mode）。模型上它不再是特例，
  而是挂点体系的第一名成员。
- **怪物的 on_death**：清单怪物实体声明 `hooks: ["on_death"]`，
  游戏代码在死亡时触发该挂点；def 里 `"on_death": [{"id": "evt.drop_loot", "once": false}]`
  ——掉落、剧情、成就钩子全部变成内容，不用改实体代码。
- **portal 的 on_enter**：进门先播段台词再传送，也是内容组合，不写死在传送代码里。
- 编辑器侧只需：内容抽屉/def 编辑器**按清单 hooks 声明渲染槽位**（H4 的延伸）；
  校验（content_validate）对挂点槽位引用的资源种类做与标准槽位相同的检查。

---

## 7. 迁移路径（三阶段，每阶段独立可交付）

### 阶段 1：role 声明 + 实例分布（纯编辑器，半天到一天）

- dev-standard 增加"角色与挂点"章（契约先行）；
- 编辑器 `role_of()` 助手 + §4 清单里的六处硬编码替换（id 回退保证旧清单照常工作）；
- 实体资产加"实例分布"节（§5），顺带 editorSize 行（T5）与 K7 删除引用检查。

### 阶段 2：teleport 元功能（游戏侧为主，1 小时）

- 游戏侧 actions.json 加 teleport + 执行器调用自己的传送流程；
- 编辑器零改动（schema 驱动）——立刻可以搭"NPC 对话完传送"的内容。

### 阶段 3：挂点声明化（中等，与 H4 components.json 合并做）

- 游戏侧声明 hooks；def 组件槽位按声明渲染（抽屉/def 编辑器）；
- trigger_zone 的 kind 条目并入声明体系（role=trigger，props.event 兼容保留）；
- content_validate 支持挂点槽位校验。

---

## 8. 明确不做 / 边界重申

- **不做运行时脚本化内容**：内容仍是声明式数据（步骤/槽位/参数），
  逻辑永远在游戏代码——"挂点"只是时机名，不是脚本注入。这是契约 §0.1 的红线，不破。
- **条件表达式 v2 照旧推迟**（feature-review T12 结论不变）：挂点不改变匹配模型，
  once/when(flag) 够用。
- **地图 JSON 不变**：scene/def/props 三层不动；本模型全部发生在清单声明与内容 schema 层。
- **trigger_zone 保持 builtin**：它是唯一"无美术、纯编辑器可视语义"的种类；
  role 声明是给**游戏实体**用的（portal/exit 有 prefab，不该 builtin）。

---

*备注：本文是方向性设计，实施前按三阶段排期；阶段 1 交付后即可验证 role 体系，
阶段 2 是最小见效单元（游戏侧一小时）。T9 修正记录在 §4；与 H4/T14/K7 的合并关系见各节。*