# 执行方案 · 资产 / 实体 / 功能三层通用化

> 定稿：2026-11-20 · 工程 `D:\Game\BIRD\Level Editor`（Godot 4.7.2）
> 前提：当前**没有任何游戏工程**，所以**不做任何旧数据兼容**，数据结构可以直接改。
> 定位：本文是**实施顺序与结构决策**的唯一依据。字段级契约落地后同步进
> [GAME_SIDE_STANDARD.md](GAME_SIDE_STANDARD.md)，功能面同步进 [EDITOR_FEATURES.md](EDITOR_FEATURES.md)。
> 旧计划 `docs/EXECUTION_PLAN.md`（图层开放化 + 脚本演出）已实施完毕，由本文接替，不再维护。

## 0. 摘要

编辑器不为某个游戏类型服务，只为游戏侧的**资产**与**功能**服务：资产负责空间组装（摆在哪），
功能负责事件组装（发生什么）。本方案把两者的声明、数据与编辑入口补齐，
并**先修掉 8 处「编辑器会悄悄丢数据 / 说过能存其实存不住」的写盘缺陷**（§2.1）。

七批改动（0–6），按依赖顺序推进，每批可独立提交、独立验收：

| 批 | 主题 | 触及数据契约 |
|---|---|---|
| 0 | 数据保真（往返测试）+ 契约自检 | 否（只改写盘方式） |
| 1 | 清单统一：`assets[]` 两类三形 + 瓦片条目改资产 id | 是（清单 + 瓦片条目，抬 v5） |
| 2 | 地图统一：`objects[]` + 通用摆放节点 `EntityNode` | 是（实体段、浮点坐标、transform） |
| 3 | 功能与事件组装：时机池、字段类型扩展、事件去特殊化 | 是（清单 + 绑定） |
| 4 | 时间轴：步骤带时间并可可视化编辑 | 是（内容 steps） |
| 5 | 空间能力：碰撞类型与层参数声明、非正方形与等距、路径/多边形 | 是（清单 + 层 + 对象） |
| 6 | UI 与校验收口：资产浏览器、事件面板、问题抽屉 | 否 |

第 0 批先做，因为它保证后面每一批的改动都能被往返测试立刻抓住。
格式版本 `5` 覆盖第 1、2 批的全部形状变更，中间态约束见 4.1 的「版本策略」。

**本次补充（遮挡模型）**：§3.7 定死了"层是硬边界、同层三段容器 + y-sort、排序点跟资产声明"，
并新增 `zPolicy` / `sortAnchor` 两个对象键、palette 条目 `ySortOrigin`。它落在第 5 批，
第一步是半天的 Godot 能力验证（逐瓦片 y 排序是否成立）。

## 1. 结构公理（本方案依据，已与用户逐条确认）

### 1.1 两类资产

| | 场景 scene | 实体 entity |
|---|---|---|
| 能力 | 纯摆放，只有可视化 | 承载功能 |
| 放置产生实例码 | **否** | **是**（4 位随机码） |
| 可绑功能 | 否 | 是 |
| 典型 | 地形图块、背景图、装饰图、任意尺寸立绘/背景板 | 角色、敌人、道具、触发器、事件区、区域 |

- 场景有两种**形态（shape）**：`tile`（瓦片批量，进图集切格涂刷）与 `image`（图片实例，
  任意像素尺寸、可缩放旋转、不按格）。二者都是场景，都不产码。
- 实体 = 资产外观 + 功能绑定。**外观可以为空**（无 visual 的实体仍是实体，码规则完全一致）。
- 地图 = 摆放资产的容器。摆放物统一称 **object**（场景实例 + 实体实例），
  只是场景实例没有码、不能挂功能。

### 1.2 功能与内容

- **功能 = 执行逻辑 + 触发条件**，实现 100% 在游戏侧。
- **内容（content）= 功能暴露给编辑器的可编辑项**，编辑器只渲染表单、存值。
- **字段只规范大类**：`input`（string/int/float/bool）或 `choice`（选项来源），
  外加读取呈现形式（单行/多行、滑杆、开关、色板等）。语义与可选值由游戏侧声明。
- **choice 选项来源**：游戏侧声明「能加载什么」——`options[]` 具体选项，或 `source` 动态来源
  （当前已实现 `content:` / `entity:` / `entity_inst:` / `map` / `audio:` / `layer:`）；
  具体条目由**编辑器**在运行时向工程数据动态拉取，游戏侧不写死条目。
- **可复用的非空间编辑单元**（条件判断、演出步骤、音频、状态机分支……）都是**同一形状的声明池**：
  `{id, code, name, fields}`。编辑器不认识它们的语义，只按声明渲染，池之间用同一个字段码空间。

### 1.3 身份与命名

- **ID 五个逻辑段**：地图 / 类型 / 实例 / 功能 / 内容；实例段前四段各 4 位码，
  内容段 6 位（见 GAME_SIDE_STANDARD §5）。
- **创建产生 ID，修改不改 ID，删除清除 ID**。
- **显示名（地图名 / 类型 name / 内容 name）一律不进 ID**，改名不破坏任何引用。
- **所有执行引用写码**；人类 id 只用于显示与目录名。

### 1.4 不可动摇的实现硬契约

来自已验证的三路审查结论，改造中必须保持（详见记忆与 `EDITOR_FEATURES.md`）：

1. 层操作**快照先行**：先 `extract()` 再改快照再 `load_data()`，不直接改活体 meta。
2. `extract()` 在 `load_data` 的 await 重建窗口返回 `{}`；所有写盘/撤销路径必须拦空快照。
3. 声明域补码**零依赖**（用 `content_id.field_codes()` 收集，池之间不互相 preload）。
4. 异步恢复互斥（`_restoring` 旗）。
5. 手势**零副作用起手**（首个真实改动前才压撤销）。
6. 手势被打断先收尾，再开始新手势。

## 2. 现状缺陷（读实现确认，带证据）

只列**会造成丢数据、表达不了、或内部自相矛盾**的项；纯 UI 偏好不在此列。

### 2.1 写盘会静默丢数据（最高优先）

| # | 缺陷 | 证据 |
|---|---|---|
| D1 | 地图顶层是 **6 键白名单**，游戏侧写进地图顶层的自定义键在保存后消失 | `src/core/undo_history.gd:141-148` |
| D2 | 实体条目是**白名单重建**（`scene/code/layer/x/y/flip_h/props/functions`），实体级未知键丢失——只有 `props` 内部才保未知键 | `undo_history.gd:116-126` |
| D3 | 坐标被压成整数格：**校验器允许 float（`is int or is float`），但载入用 `int()` 截断、写盘用 `floori` 取整**——浮点支持是"半截"的，看似可写、实际存不住 | 校验 `map_data_validation.gd:92-94`；载入 `editor_canvas.gd:319`；写盘 `undo_history.gd:122-123` |
| D4 | 内容库复制只建 `{id, function, name, fields, steps}` 五键 → 内容顶层未知键丢失 | `src/ui/content_editor.gd:1163-1169` |
| D5 | 内容文件 `"function"` 键**只写不读**，无漂移检测：清单改功能码后，旧内容文件继续带着旧码 | 写入 `content_editor.gd:1033/1165`；读取路径无校验 |
| D6 | `ensure_codes` 只补内存，清单写回是**另一个时机**：内容文件可能先带着新码落盘，清单却没保存 → 码漂移。实测更糟：`Ctrl+S` 在内容视图只走 `content_editor.commit()`，**完全不写清单**，新补的码要等用户切到别的视图再按保存才落盘 | `src/manifest.gd:96-104`（内存补码）vs `src/app.gd:679-715`（保存才写盘）；`src/ui/project_shell.gd:127-135`（内容视图分支不调 `save_manifest`） |
| D7 | `manifest.version` 永远被重置成 `1`：JSON 数字解析成 float，`is int` 判断为假 | `manifest.gd:69-71` |
| D8 | 地图 `version` 无人校验；`upgrade()` 只改版本号、不迁移 | `src/map_data_validation.gd` 全文无 `version`；`map_store.gd:76-81` |

D1/D2/D3/D4 的共性：**用白名单重建代替合并**。第 0 批统一改成「以读入的原对象为底，
只覆盖编辑器管辖的键」——与 `meta` 现有做法（`undo_history.gd:132-139`）保持一致。

### 2.2 资产模型缺口

| # | 缺陷 | 证据 |
|---|---|---|
| D9 | 场景只有「瓦片」一种形态。想做图片实例（任意像素尺寸、不按格）只能伪装成实体，于是白拿一个实例码、还能误挂功能 | `tileset_cache.gd:26,34` 只建正方形单格图集 |
| D10 | **无 thumb 的非内置实体在左栏根本不出现**，等于放不出来 | `src/ui/palette_panel.gd:205`（`tex == null and not builtin → continue`） |
| D11 | 实体被硬绑 `Sprite2D` + `scene` meta + `flip_h`：`Sprite2D` 类型标注散布 9 个文件、`selection_ops.gd` 内 29 处 | `rg -c Sprite2D src`；`selection_ops.gd:12-37,184-185,386-390` |
| D12 | 无视觉资产只能靠 `is_builtin()` 特判进画布，且尺寸/位置语义另写一套（矩形左上格） | `builtin_kinds.gd:55-56`；`undo_history.gd:114-115`；`editor_canvas.gd:329-332` |
| D13 | 每层一个 `TileMapLayer` 共用同一 `tile_set`：无每层独立网格尺寸/投影 | `editor_canvas.gd:265-278` |

### 2.3 功能与事件组装缺口

| # | 缺陷 | 证据 |
|---|---|---|
| D14 | 归一化视图只保留 `id/code/name/fields/conditions/steps`，`trigger/timing/view/parts` 等声明**不进视图**——UI 无从渲染，不是"忽略"而是"看不见" | `src/content/function_decl.gd:100-123` |
| D15 | 触发时机无声明位；事件区的时机另有一套 `props.event/mode/once`，与实例 `functions[]` 双轨未打通 | `canvas_draw.gd:273-294`（读 `props.event/mode/once` 画标签）；GAME_SIDE_STANDARD §2.7 |
| D16 | 字段只有 4 种 input 类型 + choice；无 `vector`/`color`/`range` 等呈现形式，`multiline` 是非声明的隐式约定 | `field_widgets.gd` 全量 |
| D17 | 功能 id 用 `is_valid_id` 校验（**允许 `.`**），内容目录用 `_is_valid_kind`（**禁 `.`**）→ 校验通过但读写必失败 | `manifest_validation.gd:61-64` vs `content_store.gd:33-34` |
| D18 | `entity_ref` 的 `of` 键**只用于下拉过滤**（`content_editor.gd:542-543`），**复制粘贴重映射完全忽略它**（`selection_ops.gd:299` 只看 `type == "entity_ref"`）→ 声明里写的类型约束在重映射时不起作用。另：`GAME_SIDE_STANDARD` §2.4.2 明写「`of` 编辑器完全不读」，与实现不符，是**过时文档** | `content_editor.gd:542-543`；`selection_ops.gd:293-301` |
| D19 | choice 来源粒度偏窄：能取当前图实例、清单实体类型、地图列表、内容目录、音频池、当前图层；**没有「本图全部实体（跨类型）」「项目内所有地图的实例」「其他图层」**这类来源。注：`entity_inst:` 后缀留空即列全部实例，所以「本图全部实体」其实已覆盖，真正缺的是**跨图实例**与**按类型组的显式声明** | `content_editor.gd:906-965`（6 种 source 已实现） |

### 2.4 时间性表达缺口

| # | 缺陷 | 证据 |
|---|---|---|
| D20 | `steps` 是纯线性数组，**无时间、无时长、无轨道、无并行**：只能表达"下一步"，表达不了"同时"与"3 秒后" | 内容 steps 契约 GAME_SIDE_STANDARD §2.5.3；`content_editor` 步骤子面板 |
| D21 | 无时间轴视图，演出只能靠 ↑↓ 挪顺序 | `content_editor.gd:1183-1437` |

### 2.5 空间能力缺口

| # | 缺陷 | 证据 |
|---|---|---|
| D22 | 碰撞类型/形状是编辑器硬编码（4 类 3 形），游戏侧无法声明自己的碰撞语义 | `collision_view.gd:19-24,50-59` |
| D23 | 层只有 `id/name/visible`：无视差、无 y 排序、无偏移、无缩放 | `map_data_validation.gd:51-73` |
| D24 | 无路径/折线/多边形/任意区域资产，只能拿事件区矩形近似 | 无对应实现 |

### 2.5.1 遮挡表达缺口（新查，本次补充）

| # | 缺陷 | 证据 |
|---|---|---|
| D28 | **同层内先画瓦片后画实体**，瓦片永远在实体下面——"高草盖脚 / 桥面盖人"表达不了 | `editor_canvas.gd:265-278`（每层 TileMapLayer 先于实体容器建立） |
| D29 | 无 `ySort` / 视差 / 层偏移缩放：同层内谁盖谁只能靠摆放先后，作者无法控制"走到树前/树后" | `editor_canvas.gd:268-278`；`map_data_validation.gd:51-73` |
| D30 | 无**排序点**概念（只有 `flip_h`，缩放写到节点 `spr.scale`），y 排序即使开了也没有可信基准 | `editor_canvas.gd:441-453`（`_fit_sprite`）；`undo_history.gd:116-126` |

> 另注（不算缺陷，但要写进方案）：**仓库里没有随附任何游戏工程数据**——
> `editor/` `maps/` `content/` 三个目录在本仓库都不存在（`git ls-files` 确认）。
> 所以"迁移旧数据"的实际范围是**用户本地工程**，不是仓库内容。方案里的迁移脚本必须
> 对缺失目录、空清单、半截数据都能安全跑过。

### 2.6 UI 与校验收口

| # | 缺陷 | 证据 |
|---|---|---|
| D25 | 事件的 `props`（`mode/event/once/require_flag`）**没有任何编辑控件**，要改只能手改 JSON——与"事件是正常实体、功能绑在实例上"直接矛盾 | GAME_SIDE_STANDARD §2.7 明写 |
| D26 | 校验结果只在打开地图时算一次，无问题抽屉/无持续提示 | `app.gd` 校验调用点 |
| D27 | 资产目录号称"可改的图鉴"，但只能改挂载，不能声明新的实体类型/场景 | `src/ui/asset_panel.gd` |

## 3. 目标数据契约

三份文件的分工不变：**清单**声明有什么、**地图**记录摆了什么、**内容**记录填了什么。
下面只写变化与新增；未提到的键保持 GAME_SIDE_STANDARD 现有语义。

### 3.1 清单：`assets[]` 统一资产表

现状 `tiles[]`（图集）与 `entities[]`（实体类型）是两张表，语义差别隐含在「谁有 prefab」里。
改为**一张 `assets[]`，用 `kind` 显式区分**，`shape` 细分场景形态：

```json
"assets": [
  {
    "id": "terrain", "kind": "scene", "shape": "tile",
    "name": "地形件套", "atlas": "assets/tiles/terrain_atlas.png",
    "cell": {"w": 16, "h": 16},
    "palette": [{"cell": [0, 0], "name": "单块", "cat": "地面"}],
    "gridProjection": "orthogonal"
  },
  {
    "id": "bg_forest", "kind": "scene", "shape": "image",
    "name": "森林背景", "texture": "assets/bg/forest.png",
    "editorSize": [1280, 720],
    "anchor": "top_left"
  },
  {
    "id": "portal", "kind": "entity",
    "name": "传送门", "prefab": "scenes/objects/portal.tscn",
    "thumb": "editor/previews/portal.png",
    "editorSize": [10, 10], "role": "portal",
    "code": "FY9F", "functions": ["teleport"], "fields": []
  },
  {
    "id": "trigger_zone", "kind": "entity",
    "name": "事件", "code": "TZ99", "builtin": true, "role": "trigger",
    "visual": {"mode": "rect", "color": "#4fc3f7", "alpha": 0.35},
    "sizeFields": ["w", "h"], "functions": [], "fields": []
  }
]
```

| 键 | 适用 | 说明 |
|---|---|---|
| `kind` | 全部 | `scene` / `entity`。**决定放置是否产码、能否挂功能**，也是唯一的类型判据 |
| `shape` | scene | `tile`（瓦片批量）/ `image`（图片实例）。entity 不需要 |
| `atlas` + `cell` + `palette` | scene/tile | 沿用现 `tiles[]` 语义；**`cell` 是该图集的切片尺寸**（可非正方形、可大于地图格），`tileSize` 仍是**地图格**尺寸——两者分工不同，别合并。palette 条目可带 `ySortOrigin`（逐瓦片排序点，见 3.7） |
| `texture` + `editorSize` + `anchor` | scene/image | 单张图片，任意像素尺寸；`anchor` = `top_left` / `center` / `bottom_center`（同时是 y-sort 的排序点基准，见 3.7） |
| `prefab` + `thumb` | entity | 沿用现语义 |
| `visual` | entity（可选） | 无 prefab/thumb 时的编辑器呈现：`{"mode": "rect"/"sprite"/"none", "color": …, "alpha": …}` |
| `sizeFields` | entity（可选） | 声明「尺寸写在 `props` 的哪两个键里」，取代 `is_builtin()` 硬编码矩形语义 |
| `gridProjection` | scene/tile | `orthogonal` / `isometric`（第 5 批落地；见 §4.5） |

**旧键处理**：加载期**不**接受 `tiles[]` / `entities[]`（零兼容原则不变）。
用户本地工程用一次性迁移脚本（4.1 第 8 条）搬成 `assets[]`；跑完之后旧键分支不存在，
校验器看到旧键直接报「未知键/缺少 assets」。这样代码里只有一套形状，不会新旧两套并行。

**`tiles[]` 的索引契约作废**：地图瓦片条目现在写 `atlas` 索引，依赖清单数组序。
改为写**资产 id**（见 4.1 第 7 条），从此清单重排不再破坏既有地图。这是本方案里唯一"改了就回不去"的
契约变更，收益是彻底消除「新图集只能追加末尾」这条脆弱约定。

### 3.2 地图：`objects[]` 统一摆放物

现状顶层是 `tiles` / `collision` / `entities` 三个平行段。改为：

```json
{
  "version": 5,
  "meta": { "name": "TEST", "w": 95, "h": 56, "code": "K7QM",
            "layers": [{"id": "K2M8", "name": "资产层", "visible": true}] },
  "spawn": [28, 28],
  "tiles": {"K2M8": [[21, 24, "terrain", 1, 2]]},
  "collision": [{"x": 21, "y": 24, "type": "solid", "shape": "r45"}],
  "objects": [
    {"asset": "portal", "code": "QK3T", "layer": "K2M8", "x": 31, "y": 28,
     "transform": {"scale": [1, 1], "rotation": 0, "flip_h": false},
     "props": {"target_point": "L8WM"}, "functions": []},
    {"asset": "bg_forest", "layer": "K2M8", "x": 0, "y": 0,
     "transform": {"scale": [1, 1], "rotation": 0},
     "props": {}}
  ]
}
```

| 键 | 说明 |
|---|---|
| `asset` | 资产 id。`scene` 键作废（同一字段两种语义容易混） |
| `code` | **仅 entity 有**。scene 实例永不产码（这是两类资产的核心差别，必须在数据上可辨） |
| `transform` | `{scale:[sx,sy], rotation: 弧度, flip_h: bool, flip_v: bool}`；**缺省整键省略** |
| `x` / `y` | **浮点格坐标**（可 0.5 精度，也可超出格）；缺省语义仍是"格中心"，`anchor` 非 `center` 的资产按 `anchor` 换算 |
| `props` | 沿用（只丢空值，保留未知键） |
| `functions` | 沿用，但绑定结构扩展（3.5） |
| `visible` | 可选布尔，**编辑器专用显示开关**（缺省 true，缺省省略）。游戏侧应忽略，见 §5 |
| `zPolicy` | 可选，`auto`（缺省）/ `below` / `above`。**同层内的分组**，不是全局 z；缺省省略。见 3.7 |
| `sortAnchor` | 可选 `[dx, dy]`（像素），覆盖资产的排序点偏移。**只在排序点需要单独挪**时写（悬空招牌、挂墙火把），缺省省略。见 3.7 |

**为什么把 `tiles` 留在顶层而不并进 `objects`**：瓦片是"按格批量"，一个图层一个网格容器；
图片/实体是"单个实例"。硬并成一种会让每层都要为瓦片开特殊路径，反而更复杂。
`objects[]` 收的是**实例型摆放物**（scene/image + entity），瓦片仍是按层键控的批量数据。

`collision` 从「定长数组 + 位置约定」改为**对象**：加字段不再靠第 5 位、第 6 位。

### 3.3 内容：不变的部分 + 一处收紧

`content/<功能id>/<内容ID>.json` 的 `{id, function, name, fields, steps}` 保持。
**新增要求**：`function` 键成为**必读校验项**——读内容时与清单声明的功能码比对，
不一致标为「码漂移」问题（可一键修正为当前码）。这是 D5 的修法。

内容顶层未知键**保留**（第 0 批修 D4）。

### 3.4 功能声明：时机、呈现、字段类型

```json
"functions": {
  "hp": {
    "name": "生命值", "code": "H7K2",
    "fields": [
      {"id": "max", "code": "A1B2", "name": "上限", "kind": "input", "type": "int", "default": 100},
      {"id": "tint", "code": "C3D4", "name": "受击色", "kind": "input", "type": "color"},
      {"id": "offset", "code": "E5F6", "name": "飘字偏移", "kind": "input", "type": "vector2"},
      {"id": "curve", "code": "G7H8", "name": "衰减", "kind": "input", "type": "range",
       "min": 0, "max": 1, "step": 0.01},
      {"id": "sfx", "code": "J9K1", "name": "音效", "kind": "choice", "source": "audio:"}
    ],
    "triggers": ["on_damage", "on_zero"],
    "timing": {"mode": "instant"},
    "view": {"group": "战斗", "icon": "res://..."}
  }
}
```

| 键 | 说明 |
|---|---|
| `triggers` | 该功能**能被什么时机唤起**（时机 **id** 数组，与 `conditions` 同风格）。编辑器把它解析成下拉候选（显示时机名、存时机码），校验时先把绑定里的码映回 id 再查是否在此列表内。**时机本身的判定仍是游戏侧代码** |
| `timing` | 该功能是瞬发还是持续（`instant` / `duration` / `continuous`）。影响内容表单是否出现时长字段，以及时间轴上的条块形状 |
| `view` | 呈现提示：分组、图标、颜色。纯 UI |
| 字段 `type` 扩展 | 新增 `color` / `vector2` / `range` / `asset_ref`（选资产 id）；`multiline` 从隐式约定升为显式键 |

`triggers` 的候选来源：清单顶层新增 **`triggers` 池**（`{id, code, name}`，与 `audio` 同形），
游戏侧声明"我的游戏里有哪些时机"（`on_enter_map` / `on_touch` / `on_interact` / `on_damage` /
`on_timer`……），功能按 **id** 引用它。这样**时机也成了游戏侧声明、编辑器呈现**，
不给任何玩法写死。绑定里存的是**时机码**（执行引用一律写码）。

### 3.5 实例上的事件组装（补齐 D15/D25）—— 含一处待拍板

**待拍板 Q7：时机到底该挂在「绑定」上还是「功能声明」上？**

用户的公理是「功能 = 执行逻辑 + 触发条件」，触发条件属于**功能**。按这条公理，同一份功能内容
不该因为挂在不同实例上就有不同的触发时机，于是时机应该只由功能声明决定，绑定上不带 `trigger`。
但现实中同一功能确实可能既要在「进入地图」时跑、又要在「触碰」时跑（例如"播放过场"）。
两条路：

| 方案 | 形状 | 优点 | 缺点 |
|---|---|---|---|
| **A 只挂声明** | 功能声明里 `triggers: [...]`；绑定不带时机，游戏侧按场景自己挑 | 严格守公理；一份内容一个语义 | 同一功能要两种时机就得声明两个变体功能（`play_on_enter` / `play_on_touch`），或由游戏侧在代码里挑，编辑器无从表达 |
| **B 绑定上可覆盖**（本方案原写法） | 声明 `triggers` 是候选集；绑定可选填 `trigger`，空 = 用声明默认 | 表达力完整；变体不必造重复声明 | 时机成了「实例级参数」，与"条件归功能"略有张力 |

**我的建议：B，但把语义写成「绑定只做时机选择，不引入新判断」**。理由有三条：
① 时机是**什么时候问条件**，不是条件本身——文档里已明确区分「触发时机与条件是两回事」
   （见 GAME_SIDE_STANDARD §2.5），时机本来就不属于条件范畴；② 声明的 `triggers` 是**白名单**，
绑定只能在声明允许的时机里挑，游戏侧仍然完全掌控"这个功能允许被什么时机唤起"；
③ A 方案要靠造变体功能来覆盖，会把声明池吹大，而声明池是游戏侧手写的、越少越好。

**这一条写进待确认（Q7）**，下面按 B 展开；若改成 A，删掉绑定的 `trigger` 键即可，其余不变。

```json
"functions": [
  {"fn": "X7K2", "content": "TEST-FY9F-QK3T-dialogue-7M2XK9",
   "name": "打招呼", "order": 1, "parallel": false,
   "trigger": "XK7Q", "enabled": true}
]
```

| 键 | 说明 |
|---|---|
| `trigger` | 可选。本条绑定的时机，**磁盘上写时机码**（执行引用一律写码）；编辑器下拉显示名、存码。空 = 用功能声明的第一个时机 |
| `enabled` | 可选布尔（缺省 `true`，缺省省略）。编辑器只存取，游戏侧解释 |

**条件参数的位置不变**：仍随该功能的同一份内容文件走（`fields` 里，见 GAME_SIDE_STANDARD §2.5.1）。
本方案不动这条已定稿的决定——绑定上**不**新增条件块，避免把一份内容拆成两处存。

**事件区（`trigger_zone` → 显示名「事件」）的去特殊化**：`props.mode` / `props.once` /
`props.event` 三键**作废**——"事件"就是绑定了功能的实体：时机由 `trigger` 表达、
一次性归功能字段、`props.event` 指向的"事件 id"概念由实例的 `functions[]` 直接取代。
`props` 只剩 `w/h`（用 `sizeFields` 声明）。
**注意**：给 `w/h` 配编辑控件 = 重开此前被明确删掉的「触发区编辑 UI」，
必须你单独点头（Q8）；不点头就维持"只能手改 JSON"，第 3 批不做表单。

**无视觉实体怎么办**：不特判、不内置种类。`visual.mode = "rect"` 是**资产声明**，
编辑器按声明画彩色矩形（与碰撞叠加同一套绘制）；`visual.mode = "none"` 则只画一个 1 格角标。
内置 `trigger_zone` 保留为"默认提供的一个 `visual: rect` 实体"，但**不再有专属代码路径**
（`is_builtin()` 特判从放置、命中、区域复制、撤销、内容 ID 生成各点全部移除）。

### 3.6 碰撞与层：声明化

**碰撞不在层栈里。** 整个地图只有**一张**碰撞网格，不参与层的 z 序，不进 `meta.layers`：

- 编辑器里它永远画在最上面（红色叠加，`CollisionView`，`z_index = 2`），层级下拉末尾只是
  一个「碰撞元层」编辑入口，不是真层。
- 运行时它**完全不渲染**，游戏侧只读 `collision[]` 建 `StaticBody2D` / `Area2D`。
- 因此不存在"碰撞被瓦片挡住"、"多层碰撞谁优先"这类问题——只有一张。

```json
"collisionTypes": {
  "solid":    {"name": "阻挡", "shape": "rect",  "gameplay": "block"},
  "one_way":  {"name": "单向", "shape": "rect",  "gameplay": "one_way"},
  "ladder":   {"name": "攀爬", "shape": "rect",  "gameplay": "area"},
  "hazard":   {"name": "伤害", "shape": "rect",  "gameplay": "area"},
  "slope_r":  {"name": "右坡", "shape": "triangle_r"},
  "water":    {"name": "水",  "shape": "rect",  "gameplay": "area"}
}
```

| 键 | 说明 |
|---|---|
| `shape` | 编辑器画什么形状：`rect` / `triangle_r` / `triangle_l` / `circle` / `polygon` |
| `gameplay` | 游戏侧自己的解释标签，编辑器**只存取不解释**（对应现状 4 类语义） |

层参数扩展（全部可选，缺省保持现行为）：

```json
{"id": "K2M8", "name": "远景", "visible": true,
 "parallax": 0.5, "ySort": false, "offset": [0, 0], "scale": 1.0}
```

| 键 | 说明 |
|---|---|
| `parallax` | 视差系数，1.0 = 跟随，0.5 = 半速，0 = 固定 |
| `ySort` | 该层内**瓦片与实例一起**按排序点 y 绘制（见 3.7） |
| `offset` / `scale` | 层的整体偏移与缩放 |

### 3.7 遮挡模型：层是硬边界，同层靠 y-sort（本次补充的重点）

这是"能不能解决所有画面问题"的答案所在。分三级，每一级的边界要清楚：

**① 层间：只按上下顺序，硬边界。**
不同层只按栈序遮挡，**任何对象都不能越过层**。这条不是可配的"默认值"，是刻意封死的：

- Godot 里 `z_index` 优先级高于树序，一旦允许随便写 `z_index`，就会出现"某个对象莫名盖住
  上层全部内容"这种查不出来的 bug。
- 所以编辑器**不把 `z_index` 写进数据**，层序就是唯一的跨层规则。
- 需要跨层例外时的唯一做法：把那个对象**挪到更高的层**（数据可读、可解释）。

**② 同层内：三个子容器，不用 z_index。**

```
层容器（不启用 y_sort）
├── below  子容器   ← 永久被同层所有东西盖住
├── auto   子容器   ← 启用 y_sort_enabled，按排序点 y 排序
└── above  子容器   ← 永久盖住同层所有东西
```

- 容器之间用**树序**保证顺序，容器内部用 **y-sort** 保证顺序——两套机制互不干扰，
  全程不写 `z_index`，也不跨层。
- 最终可见顺序 = 层 N+1 的 (below → auto → above) 在层 N 之上。
- 对象用 `zPolicy: auto | below | above` 选组，缺省 `auto`。
- **`zPolicy` 是同层内的分组，不是全局 z**。默认 auto 是关键：否则会出现"一半对象参与
  y 排序、另一半不参与"的混乱。
- 未开 `ySort` 的层：auto 组退化为**摆放先后顺序**（树序）。作者若在意顺序，就该开 ySort。

**③ 排序点：决定"脚底"在哪。**
`ySort` 比较的是排序点的 y，不是图片中心。排序点的来源按优先级：

| 层级 | 键 | 缺省 |
|---|---|---|
| 资产声明 | `anchor`（`top_left` / `center` / `bottom_center`） | `center` |
| 实例覆盖 | 对象 `sortAnchor`（可选，像素偏移） | 用资产声明 |
| 瓦片 | palette 条目 `ySortOrigin`（像素，相对切片顶部） | 切片底部 |

**④ 同层瓦片与实体交错（"高草盖脚、桥面盖人"）。**
现状同层固定"瓦片全部先画、实体后画"，表达不了交错。修法（**需先验证**）：
Godot 4.3+ 的 `TileMapLayer` + `TileSet` 逐瓦片 `y_sort_origin` 支持让瓦片和兄弟节点一起排序。

**实施前置动作（第 5 批第一步）**：搭 30 行验证场景（两个 TileMapLayer + 一个 Sprite2D，
父节点 y-sort），确认逐瓦片交错真的成立。
- 成立 → 层开 `ySort` 时把瓦片图层与 auto 容器放进同一 y-sorted 父节点；
  地图数据**一个键都不加**，排序依据跟资产声明走（palette 条目 `ySortOrigin`）。
- 不成立 → 退回"palette 条目分 tier + 每层开多个 TileMapLayer"，多一个数据维度，能不用就不用。

**⑤ 一个资产 = 一个排序点（作者踩坑预警）。**
树冠和树干画在同一张图上时，角色永远只能整体在树前**或**整体在树后，穿不过去。
要真正"走到树前也能走到树后"，必须把树干、树冠拆成两个资产（或用 `below`/`above` 分组）。
这是**图集设计问题**，编辑器只能提示，不能自动解决。

**⑥ 明确归游戏侧、编辑器不做的部分**：

| 不做 | 原因 |
|---|---|
| 运行时改变遮挡（桥塌、上车、开门、拾取消失） | 靠功能代码改 `zPolicy` / 换层 / 改排序偏移 |
| 高度维度（飞行单位、跳跃中、2.5D 高差） | 运行时给排序偏移加在 `sortAnchor` 基准上 |
| 对象内部部件顺序（武器盖身体） | prefab 内部节点结构 |
| 半透明淡出、走到树后变透明 | 运行时材质 / shader / 动画 |
| 非 y 的层间例外 | 只能挪层（见 ①） |

**编辑器给作者的可见性**（第 5 批，纯绘制、无新数据）：选中对象时在排序点画小十字；
层未开 `ySort` 但同层混放场景与实体时给状态栏提示。没有这个可视化，y-sort 就是看不见的
隐式规则，作者只能靠试。

## 4. 分批实施

每批 = 一个可独立提交、独立验收的单元；批内再按"数据结构 → 读路径 → 写路径 → UI"四段推进。

### 4.0 第 0 批：数据保真 + 契约自检（不动数据形状）

**目标**：先让"读进来什么、写出去还是什么"，否则后面每批改动都会在保存时被白名单吞掉。

改动点：

| 文件 | 改动 |
|---|---|
| `src/core/undo_history.gd` | `extract()` 改为**合并式**：以 `cvs.map_data.duplicate(true)` 为底（保留顶层未知键），再覆盖 `meta/spawn/tiles/collision/entities`；实体条目同样以读入的原条目为底再覆盖已知键（需在加载时把原条目存到节点 meta，如 `spr.set_meta("_raw", e)`），不再白名单重建 |
| 同上 | `version` 改为读 `MapStore.FORMAT_VERSION` 常量，不写字面量（D8 的一半） |
| `src/ui/content_editor.gd:1163-1169` | 复制内容时以 `src.duplicate(true)` 为底，只覆盖 `id/name/function`（D4） |
| `src/content/*_decl.gd` | 归一化视图**保留未知键**：`out[fid] = src.duplicate(true)` 再规范化已知键（D14 的前置） |
| `src/manifest.gd:69-71` | 版本号判断改为「`is float` 也接受并 `int()` 化」，不再无条件重置（D7） |
| `src/map_data_validation.gd` | 增加 `version` 校验：缺失/非数字 = 错误；大于 `FORMAT_VERSION` = 错误（打不开新图）；小于 = 警告（D8） |
| `src/content/content_editor.gd`（读路径） | 读内容后比对 `function` 键与当前功能码，不一致记为"码漂移"问题（D5） |
| `src/ui/project_shell.gd:127-135` + `src/app.gd` | 内容视图 `Ctrl+S` 时，若 `ensure_codes` 补过码（清单脏），**顺带保存清单**；或统一让内容写盘前先确保清单已落盘（D6） |

第 0 批**不改任何数据形状、不抬版本号**，只修"写出去少东西"。迁移脚本留给第 1 批
（它才是改形状的那一批）。

测试（扩 `tests/`）：

1. **roundtrip 保真**：构造带未知顶层键 / 未知实体键 / 浮点坐标 / 未知 meta 键的地图，
   `load_data` → `extract` → 逐键比对，未知键必须原样存在。
2. **内容复制保真**：带未知顶层键 + 未知字段键的内容，复制后未知键仍在。
3. **版本自检**：`manifest.version` 存 float 后读回仍是原值；地图 `version: 99` 报错误。
4. **码漂移**：手工把内容 `function` 改成别的码，读入后产生一条 issue。

**验收**：32 个既有用例（6 套件）+ 新增 4 组全绿；打开任何图保存后 `git diff` 只应有格式差异、无键丢失。

### 4.1 第 1 批：`assets[]` 统一资产表（清单）

**目标**：场景与实体在数据里显式可分；场景支持图片实例；资产声明决定编辑器怎么画。

顺序：

1. **`src/assets/asset_decl.gd`（新增）**：归一化 `assets[]`，输出
   `{id, kind, shape, name, code, palette, atlas, texture, editorSize, anchor, prefab, thumb,
   visual, sizeFields, functions, fields, gridProjection}`，未知键保留。
   提供 `scenes()` / `entities()` / `by_id()` / `palette_of()`。
2. **`src/manifest.gd`**：改读 `assets[]`；`entity_editor_size()` 迁到 `asset_decl`，
   `prefab_collision_size` 保留。**不做旧键内归一化**（零兼容，「旧键处理」见 3.1）。
3. **`src/manifest_validation.gd`**：改校验 `assets[]`——`kind` 必须 `scene`/`entity`；
   scene 必须二选一（`atlas` 或 `texture`）；entity 必须有 `prefab` **或** `visual`（二者都没有 = 错误，
   这正是 D12 的修法）；`shape: tile` 必须有 `atlas`。
4. **`src/app.gd:679-715`（保存清单）**：写 `assets[]`，剥 builtin。
5. **`src/ui/palette_panel.gd`**：左栏改为**按 `kind` 分页**——「场景」页列出
   `shape: tile` 的图集/调色板 + `shape: image` 的图片资产缩略；「实体」页列出全部 entity，
   **无 thumb 的按 `visual` 声明画占位图标**（D10 的修法：不再 `continue`）。
6. **`src/canvas/tileset_cache.gd`**：改为按**资产**建 `TileSetAtlasSource`，格尺寸取 `asset.cell`，
   支持 `(w,h)` 非正方形（D9 的一半）；`gridProjection` 非 `orthogonal` 时第 5 批再接。
7. **地图瓦片条目**：第 3 位由「图集索引」改为**资产 id 字符串**。校验、读写、调色板、
   笔刷、区域操作、预览全部改；`TileSet` 的 `source_id` 仍在编辑器内部用整数，但只作映射结果。
8. **`tools/migrate_project.gd`（新增，一次性）**：把用户本地工程搬成新契约——
   清单 `tiles[]`+`entities[]` → `assets[]`；地图 `version` → 5 且瓦片条目第 3 位
   索引 → 资产 id；`meta.layers` 补齐缺省参数。**必须容错**：目录缺失、空清单、
   半截数据一律跳过并打印清单，不中断。跑完删掉脚本（不进长期代码库）。

**版本策略**：格式版本 `5` 覆盖第 1、2 批的**全部**形状变更（清单 `assets[]`、瓦片条目写资产 id、
地图 `objects[]`）。因此 v5 在**第 1 批到第 2 批完成之间是开发中间态**——
`objects[]` 还没落地时，v5 地图里仍然是旧的 `entities` 段。这一点必须写清，不能装作干净：

- 中间态期间**不要接任何游戏工程**；验收只看编辑器自身能开、能存、测试全绿。
- 第 2 批完成后 v5 契约才冻结，此后任何形状改动都必须再抬版本（写进 GAME_SIDE_STANDARD）。
- 一次性迁移脚本（`tools/migrate_project.gd`）接受"v4 → v5"与"v5 中间态 → v5 终态"两种输入，
  幂等：已经终态的数据再跑一遍不产生改动。

改动面（按依赖）：

| 位置 | 改动 |
|---|---|
| `editor_canvas.gd:265-278` | 每层建 `TileSet` 时按**该层实际用到的资产**建源，而不是全清单共用 |
| `undo_history.gd:70-81` | 瓦片条目写 `[x, y, <资产id>, ax, ay]` |
| `tool_ops.gd` / `canvas_input.gd` | 笔刷记录资产 id，落笔时查 `source_id` |
| `selection_ops.gd` 区域复制 | 瓦片条目直接带 id，不再做索引重映射 |
| `content_preview.gd` / `asset_panel.gd` | 读 `assets[]` |
| `tests/test_map_v4.gd` | 瓦片条目断言改 5 元含字符串第 3 位 |

**验收**：清单改 `assets[]` 后编辑器照常打开、瓦片照常涂刷、图集重排不错位；
**图片场景资产此时只能"声明成功"，还放不到画布上**（放置走 `objects[]`，要等第 2 批）。
这条中间态要如实写进当时的 commit message。

### 4.2 第 2 批：`objects[]` + 通用摆放节点（地图）

**目标**：场景实例与实体实例统一数据形状；实体不再硬绑 `Sprite2D`；支持亚格与 transform。

1. **`src/canvas/entity_node.gd`（新增，`Node2D` 派生）**：一个摆放物的唯一运行时表示。
   - `meta`: `asset`（资产 id）、`code`（仅 entity）、`props`、`functions`、`layer`
   - 子节点：`visual`（`Sprite2D` / `ColorRect` / `Polygon2D` / 无，按 `visual` 声明构建）
   - 属性：`data_transform: Dictionary`；`_draw()` 不再依赖 `Sprite2D.flip_h`
   - **命中/框选/拖动/复制全部改操作 `EntityNode`**，不再 `as Sprite2D`
2. **`src/canvas/editor_canvas.gd`**：`load_data` 建 `EntityNode`；`ents_all()` 返回 `Array[Node2D]`；
   `entity_display_size_of()` 改为按 `assets[]` 声明 + `scale` 计算。
3. **`undo_history.gd`**：写 `objects[]`（3.2）+ `transform`（缺省省略）+ **浮点坐标**（去掉 `floori`）。
4. **`selection_ops.gd`**：所有 `_cell_of` 吸附改为「吸附开关关闭时保留浮点位置」；
   剪贴板条目带 `asset/transform`（D3 的修法）；`_ent_cell` 的「左上格 vs 中心格」两套语义
   **由 `anchor` 统一**（取代 `is_builtin()` 判断）。
5. **`map_data_validation.gd`**：校验 `objects[]`，`code` 只在 `kind: entity` 的资产上合法
   （scene 实例带 code = 错误，直接拦住"给背景发码"这种误用）。
6. **吸附开关**：状态栏加「吸附到格」开关（默认开）。关闭后实体可放在任意像素位置，
   存浮点格坐标。
7. **`selection_ops._snapshot_region()`**：现在存**活体节点引用**，改为存数据快照
   （与硬契约"快照先行"对齐，也避免节点被 free 后区域粘贴拿到失效引用）。
8. **对象级 `visible`**：数据侧只做读写与默认值（缺省 true、缺省省略、不写冗余键），
   UI 开关放第 6 批。复制/粘贴/区域操作随对象带走该键。

**验收**：放一个图片场景 → 保存 → 重开位置不漂；关掉吸附拖到半格处，保存重开仍在原位；
实体与场景混选、区域复制、跨图粘贴都正常；`rg "as Sprite2D" src` 只剩 `visual` 内部。

### 4.3 第 3 批：功能声明升级 + 事件组装

**目标**：时机、呈现、字段类型由游戏侧声明；事件区彻底去特殊化。

1. **`src/content/trigger_decl.gd`（新增）**：`triggers` 池归一化（与 `audio_decl` 同形：
   `{id, code, name}`，码由 `ensure_codes` 补发）。时机**不带字段**——它只是一个被引用的标签，
   参数一律在功能内容里。所以 `field_codes()` 不需要纳入它。
2. **`src/content/function_decl.gd`**：归一化保留并解析 `triggers` / `timing` / `view`（D14）；
   未知键保留（第 0 批已做）。
3. **`src/ui/field_widgets.gd`**：新增 `color`（颜色按钮 + 弹窗）、`vector2`（两个 SpinBox）、
   `range`（H slider + SpinBox）、`asset_ref`（资产下拉，按 `kind` 过滤）、`multiline` 显式化（D16）。
4. **`content_id.field_codes()`**：时机池无字段，**不需要**纳入码空间；但要给时机池补
   `ensure_codes`（条目码，与 `audio_decl` 同一份代码形状）。现状 `field_codes()` 用
   `for pool in ["functions", "conditions", "steps"]` 硬遍历（`content_id.gd:43-63`），
   新增池时按同一纪律判断「有没有字段」。
5. **`src/ui/content_editor.gd`**：绑定行增加「时机」下拉（候选 = 功能声明的 `triggers`，
   显示时机名、存时机码）；保存绑定写 `trigger` / `enabled`。
6. **内置 `trigger_zone`**：`builtin_kinds.gd` 声明改为
   `{id: "trigger_zone", kind: "entity", name: "事件", role: "trigger", code: "TZ99",
     visual: {mode: "rect", color: "#4fc3f7", alpha: 0.35}, sizeFields: ["w", "h"]}`，
   **删除** `props.event/mode/once` 的写入与绘制分支（`canvas_draw.gd:273-294` 重写为通用
   `visual` 绘制）；`is_builtin()` 只保留"合并/剥离清单"用途，不再参与放置逻辑。
7. **新建图模板**：`map_store.new_map()` 的两层仍叫「资产层 / FL」，但不再暗示任何语义。
8. **（待 Q8 点头才做）** `w/h` 尺寸表单。不点头就跳过这一步，事件区尺寸维持手改 JSON。

**验收**：声明一个 `visual: rect` 的实体（无 prefab、无 thumb）→ 左栏可见可放、画布显示彩色矩形、
可挂功能；声明一个带 `triggers` 的功能 → 绑定行出现时机下拉；改时机值保存后地图里 `trigger` 正确。

### 4.4 第 4 批：时间轴

**目标**：步骤能表达"何时、多久、与谁并行"，并可视化编辑。**读写同一份 `steps`**，不新增文件。

内容 steps 条目扩展（缺省省略，保持现有线性数组可读）：

```json
"steps": [
  {"step": "<move_to码>", "fields": {...}, "at": 0.0, "duration": 1.5, "track": 0, "blocking": true},
  {"step": "<play_anim码>", "fields": {...}, "at": 0.0, "duration": 1.5, "track": 1},
  {"step": "<wait码>", "fields": {...}, "at": 1.5, "duration": 0.5}
]
```

| 键 | 语义 | 缺省 |
|---|---|---|
| `at` | 起始时间（秒），相对该功能绑定的开始 | 顺序累加（现有线性行为） |
| `duration` | 持续时长；0 = 瞬发 | 0 |
| `track` | 轨道号（同轨不重叠、不同轨并行） | 0 |
| `blocking` | 是否阻塞后续同轨步骤 | `true` |

1. **`src/content/step_timeline.gd`（新增）**：纯数据工具——`to_timeline(steps)` 计算缺省 `at`
   （线性累加）、`from_timeline()` 回写、重叠/轨道冲突检测（只警告，不阻断）。
2. **`src/ui/timeline_view.gd`（新增）**：横轴时间、纵轴轨道；步骤画成条块（宽 = duration），
   可拖左右改 `at`、拖右边缘改 `duration`、上下拖换轨；双击开该步参数表单。
3. **`content_editor.gd` 演出子面板**：列表视图与时间轴视图**两个页签，同一份数据**；
   列表视图保留 ↑↓/复制/删除（现有行为不丢）；切到时间轴时按 `at/duration` 布局。
4. **校验**：`at < 0`、`duration < 0`、同轨重叠 = 警告；`step` 码未声明 = 警告（现有行为）。

**不做的**：不做关键帧曲线、不做嵌套时间轴、不做音频波形——这些都超出"编辑器只组装"的边界。

### 4.5 第 5 批：空间能力

1. **非正方形与等距**：`asset.cell = {w, h}` + `gridProjection`。
   `tileset_cache` 建源时按 `cell` 设 `texture_region_size`；投影为 `isometric` 时
   `TileMapLayer` 的 `tile_set.tile_shape` 设对应值，并加**坐标转换层**
   （`src/canvas/grid_space.gd`：格 ↔ 像素，正交/等距两套），全部 `_cell_of` 与落点换算走它。
   **范围明确**：只支持正交与 Godot 原生矩形等距（菱形 tile_shape）。六边形不做
   （见 §7 能力天花板）；斜 45° 伪等距也不做——那是图集设计问题，不是坐标问题。
2. **碰撞类型声明**：`collisionTypes` 池（3.6）；`collision_view.gd` 按声明画形状与颜色；
   碰撞条目从定长数组改对象（3.2 已定）。
3. **层参数**：`parallax/ySort/offset/scale` 进 `meta.layers`，编辑器按此做预览
   （远景层半速跟随、层偏移缩放），游戏侧读同字段实现。
4. **遮挡模型（3.7，本批重点）**，按此顺序做：
   1. **前置验证**（第一步，半天）：搭 30 行场景验 `TileMapLayer` 逐瓦片 `y_sort_origin`
      能否与兄弟 `Sprite2D` 一起排序。结论决定第 4.3 步走哪条路。
   2. **三段容器**：层容器下建 `below` / `auto` / `above` 三个子容器，`auto` 开
      `y_sort_enabled`；对象按 `zPolicy` 入组（缺省 `auto`）；**全程不写 `z_index`**。
   3. **排序点**：`anchor`（资产）+ `sortAnchor`（实例覆盖）算排序点；选中时画小十字。
   4. **瓦片参与排序**：验证通过 → 开 `ySort` 的层把瓦片图层与 auto 容器放同一 y-sorted 父节点，
      palette 条目 `ySortOrigin` 生效；不通过 → 退回 palette 分 tier + 每层多个 TileMapLayer。
   5. **作者提示**：层未开 `ySort` 但同层混放场景与实体 → 状态栏提示；同一资产既要盖人又要被人盖
      → 提示"拆成两个资产"（3.7 ⑤）。
5. **路径 / 区域资产**：`shape: "path"` / `shape: "polygon"` 的场景——`objects[]` 里
   存 `points: [[x,y],...]`，画布上点击加控制点、拖动移动、右键删点。
   用途：巡逻路线、摄像机路径、光照区域、刷怪区。**这是纯数据表达，不产码、不挂功能**。
6. **任意尺寸视觉**：`editorSize` + `anchor` 已覆盖；`visual.mode: "sprite"` 支持
   九宫格/切片（`ninepatch` 声明）。

### 4.6 第 6 批：UI 与校验收口

1. **资产浏览器**（`asset_panel` 升级）：三栏——场景 / 实体 / 声明池。
   可**新建资产条目**（写清单），不再只是"点选挂载"（D27）。新建流程：选 kind → 选 shape →
   填路径/尺寸 → 生成 id 与 code。
2. **事件面板**：选中实体 → 右栏显示其 `functions[]` 列表（现有内容编辑器已覆盖大部分）；
   补「时机」「启用」两个控件与拖拽排序（现在只有 ↑↓ 概念）。
3. **问题抽屉**：底部可折叠条，汇总「清单校验 + 地图校验 + 内容码漂移 + 引用悬空」，
   点击跳到对应对象（D26）。持久化在状态栏一个计数徽标上。
4. **引用检查**：全项目扫描 `props` 里的 `entity_ref` / `target_map` 值，指向不存在对象 =
   列在问题抽屉，可一键清除或跳转（现有"指向预览"已是底子）。
5. **一致性自检入口**：菜单一项「检查项目完整性」，跑全部校验并输出报告。

## 5. 回答：要不要给带 visual 的实体加「可不可视化」开关

**推荐：加，但它有三个不同层次，必须分清，别混成一个开关。**

| 层 | 是什么 | 放哪 | 谁解释 |
|---|---|---|---|
| **① 资产声明** `visual` | 这类资产**有没有**可画的东西、怎么画（sprite / rect / none） | 清单 `assets[].visual` | 编辑器（怎么画）；游戏侧不看 |
| **② 实例可见性** `visible` | 这一**个**摆了的东西在编辑器里要不要显示 | 地图 `objects[].visible`（缺省 true） | **只有编辑器**，游戏侧不读 |
| **③ 游戏侧可见性** | 运行时这个对象显不显示（隐形墙、暗门、未激活开关） | 走**功能字段**，例如 `{"id": "hidden", "kind": "input", "type": "bool"}` | **只有游戏侧** |

**结论与理由**：

- **要加的是 ②**，理由跟用户的"事件区像碰撞一样显示成彩色块"完全一致：颜色矩形是**编辑器的
  可视化替身**，不是游戏里的外观。既然如此，用户当然会想临时把这个替身藏起来看底下的画面。
  没有它，用户只能靠"临时删掉再撤销"来偷看——这是明确的可用性缺口。
- **不要给 ③ 造编辑器字段**。运行时隐不隐形是玩法语义（暗门、隐形墙、未解锁的 NPC），
  必须由游戏侧把它声明成一个**功能字段**（`kind: input, type: bool`），编辑器渲染成勾选框、
  存进内容。这样它自动获得：内容复用、复制跟随、游戏侧统一读法。
  编辑器如果自己造一个 `visible` 字段，就会和游戏侧的真实语义打架（编辑器藏了 ≠ 游戏里藏了）。
- **① 不是开关，是声明**。`visual: none` 只是"这类资产本来就没有外观"，跟
  "有外观但我想先不画"是两件事。用 `mode` 表达前者，用 ② 表达后者。
- **② 的存储口径**：写在 `objects[]` 里、缺省 `true`（缺省省略，不写冗余键）。
  它是**编辑器显示状态**，游戏侧读到应当**忽略**。这条要在 GAME_SIDE_STANDARD 里明写，
  避免游戏侧误当运行时开关。若用户后续希望"编辑器里藏起来的东西游戏里也不显示"，
  那就不是 ② 而是 ③，应当改由功能字段承担——两者不要合并。

**UI 落点**（第 6 批）：选中对象的信息条加一个眼睛图标；**层级别**已有层显隐，
对象级别补一个即可，不做"按 kind 一键全隐"这种批量开关（用不上，且会让人误以为改了数据）。

## 6. 游戏侧要跟着改的部分（规范增补清单）

落地时同步进 `docs/GAME_SIDE_STANDARD.md`：

| 章节 | 增补内容 |
|---|---|
| §1 数据落点 | 新增 `assets[]` 不再是 `tiles[]`+`entities[]`；地图 `version: 5` |
| §2.2 图集 | 瓦片条目第 3 位由**索引**改为**资产 id**；新增 `cell`（图集切片尺寸，可非正方形）；清单 `tileSize` 仍是地图格尺寸，两者分工不同 |
| §2.3 图层 | 新增 `parallax/ySort/offset/scale` 四个可选键及缺省语义；**补一节遮挡模型**（层是硬边界、同层三段容器、y-sort、排序点），以及"游戏侧不得写 `z_index`、按三个子容器建树"的硬要求（3.7） |
| §2.4 实体类型 | 迁到 `assets[]` + `kind`；新增 `visual` / `sizeFields`；`prefab` 与 `visual` 二选一 |
| §2.5 功能声明 | 新增 `triggers` / `timing` / `view`；字段类型新增 `color/vector2/range/asset_ref/multiline` |
| §2.5.4（新） | `triggers` 池：游戏侧声明时机列表（`{id, code, name}`），功能按 id 引用；语义与判定全在游戏侧 |
| §2.7 事件区 | **整节重写**：去掉 `props.event/mode/once`；改为"事件 = 绑定了功能的实体" |
| §3.2 瓦片条目 | 5 元第 3 位改字符串资产 id |
| §3.3 碰撞 | 定长数组 → 对象；类型集由清单 `collisionTypes` 声明 |
| §3.4 实体条目 | 改 `objects[]` + `asset` + `transform` + 浮点坐标 + `visible`（编辑器专用）+ `zPolicy` / `sortAnchor`（3.7） |
| §4 内容 | `function` 键成为必读校验项；`steps` 条目新增 `at/duration/track/blocking` |
| §5 身份码 | 明确 **scene 实例不产码**；`assets[].code` 只有 entity 有 |
| §7.2 实现模式 | 补「按 `asset` 查 `assets[]` 分发」与「`transform` 应用」示例 |
| §11 已知边界 | 删除已修的（无 thumb 放不出、事件区无编辑 UI、瓦片索引契约）；保留真边界 |

**顺带要纠正的过时表述**（本次核对发现，属既有文档失实，改动很小可一并做）：

- `GAME_SIDE_STANDARD.md:193` 写「`of` 键编辑器完全不读」——实际 `content_editor.gd:542-543`
  用它构造 `entity_inst:<of>` 过滤下拉。真实缺口是「`of` 只在**下拉过滤**生效，
  复制粘贴重映射不读它」（D18）。

## 7. 能力天花板（明确不做，避免以后再讨论）

这些不是"以后再做"，是**结构上不属于编辑器**：

| 不做 | 理由 |
|---|---|
| 任何玩法实现（战斗、AI、背包、任务判定） | 归游戏侧；编辑器只组装声明与参数 |
| 流图 / 节点图式逻辑编辑 | 用户已定"线性事件列表 + 条件库 + 步骤池"，不做可视化脚本 |
| 内置 HUD / 菜单 / 对话框布局编辑 | UI 布局必须与 UI 代码同处修改，拆两处互相牵制 |
| 3D / 多视角（非平面投影） | 编辑器是 2D 格子摆放；真 3D 需要完全不同的数据与交互 |
| 完整等距菱形自动衔接 / 六边形平铺 | 第 5 批只做矩形等距的坐标转换；斜 45° 伪等距与六边形归游戏侧图集设计 |
| 动画曲线 / 关键帧编辑器 | 时间轴只是步骤条目的时间布局，不做属性动画曲线 |
| 存档 / 运行时状态编辑 | 编辑器只产出静态数据 |

**遮挡相关的边界**（3.7 ⑥，单列防误读）：运行时遮挡变化（桥塌/上车/开门）、高度维度
（飞行/跳跃/2.5D）、对象内部部件顺序、半透明淡出、跨层例外——**全部归游戏侧**，
编辑器只提供静态声明。详见 3.7 第 ⑥ 节。

## 8. 验收与测试口径

- **每批必须扩测试**（`tests/run_tests.gd`，数据层纯逻辑）。第 0 批先建立"保真"基线，
  后续每批至少加 2–3 个用例覆盖新契约的读写往返。
- **跑测试**：`godot --headless --path . --script res://tests/run_tests.gd`。
  **不要在命令前套 `timeout`**（Windows TIMEOUT.exe 会抢走命令，造成假绿）。
- **每批收尾**：`--headless --check-only --script <每个改过的 .gd>` 逐文件过一遍。
- **视觉验收归用户**：测试不覆盖画布/绘制/交互手感。
- **提交粒度**：一批一到两个 commit，标题写清批次；只本地提交，不 push。

## 9. 风险与回退

| 风险 | 影响 | 处理 |
|---|---|---|
| 瓦片条目第 3 位改字符串 | 既有地图全部失效 | 第 1 批的 `tools/migrate_project.gd` 一次跑完；仓库本身不含任何工程数据，风险仅限用户本地工程 |
| `EntityNode` 替换 `Sprite2D` | `selection_ops` 29 处类型标注全改，回归面大 | 分两步：先加 `EntityNode` 但内部仍包一个 `Sprite2D`（行为不变），再逐处替换引用 |
| 等距/投影 | 坐标换算散布在落点、命中、区域、撤销、导出 | 先把所有换算收敛到 `grid_space.gd` 单点（第 5 批前置），再开投影 |
| 时间轴与列表双视图 | 两套编辑路径易写出不一致 | 数据单向：两个视图都只调 `step_timeline` 的读写函数，不各自拼数组 |
| **逐瓦片 y 排序未验证**（3.7 ④） | 若 Godot 4.7 的 `y_sort_origin` 不能与兄弟节点一起排，"高草盖脚"做不了 | 第 5 批第一步先做 30 行验证；不成立退回"palette 分 tier + 每层多个 TileMapLayer"，代价是多一个数据维度 |
| 三段容器改变现有节点树 | 现有一层一 `TileMapLayer` + 一实体容器的假设散布在画布/区域复制/跨图粘贴/撤销恢复 | 容器结构收敛在 `editor_canvas` 一处（建树 + 层内节点查询），其余代码只经 `_layer_display_node()` 之类接口取节点，不直接认树形 |
| 本方案改动面大 | 中途停在第 2 批会半新半旧 | 每批都可独立停在"测试全绿 + 文档同步"的状态；第 1、2 批之间有临时共存期（`assets[]` 与 `objects[]` 已上、`version: 5` 已抬，但场景图片实例还不能放到画布上——它要等第 2 批的 `EntityNode`）。这个中间态的标签与开关策略必须显式写下，不能靠记忆 |

## 10. 待确认（需要用户拍板才能定稿）

| # | 问题 | 我的建议 |
|---|---|---|
| Q1 | `assets[]` 合并 `tiles[]`+`entities[]` 是否接受？（替代方案：保留两张表，只给 `tiles[]` 加 `shape`） | 接受合并。一类资产一张表，`kind` 是唯一判据，避免"哪张表里有什么"的隐式规则 |
| Q2 | 瓦片条目第 3 位由索引改资产 id 是否接受？ | 接受。代价是一次迁移，收益是永久摆脱"图集只能追加末尾" |
| Q3 | `props.event/mode/once` 三键作废是否接受？（事件改为纯绑定功能 + `trigger` 时机） | 接受。否则"事件"永远有第二条数据通路，双轨必然漂移 |
| Q4 | 对象级 `visible`（编辑器专用显示开关）是否要？ | 要，理由见 §5 |
| Q5 | 地图 `version` 抬到 5 并让校验拒绝更高版本是否接受？ | 接受。`assets[]` 与 `objects[]` 合成同一个 v5（无外部消费者，不必为中间态单独抬版本） |
| Q6 | 路径/多边形场景（`shape: path/polygon`）是否要？ | 要，但排在第 5 批最后，可单独砍掉不影响其他批次 |
| Q7 | 触发时机挂**绑定**（声明给白名单，绑定选一个）还是只挂**功能声明**（同一功能要两种时机就造变体）？ | 挂绑定（方案 B），理由见 §3.5：时机是"什么时候问条件"，不是条件本身 |
| Q8 | 事件区要不要**尺寸编辑控件**？此前「触发区编辑 UI」是被明确删掉的，重开需你点头 | 要一个最小表单（只填 `w/h`）。理由是现在 `w/h` 无 UI 只能手改 JSON，与"事件是正常实体"矛盾。**若你不想重开，就维持现状（手改 JSON），此条从第 3 批删掉** |
| Q9 | 对象级 `visible` 是「编辑器显示」还是「运行时也生效」？ | 编辑器显示（见 §5）。若你希望运行时也生效，则改走功能字段，`objects[].visible` 就不要了 |
| Q10 | 遮挡模型按 3.7 采纳：层间硬边界（不写 `z_index`）+ 同层三段容器（`below`/`auto`/`above`）+ y-sort + 排序点跟资产声明，并新增 `zPolicy`/`sortAnchor`/`ySortOrigin`？ | 采纳。这是"能不能解决所有画面问题"的关键补丁；不采纳则只能靠多开层硬凑，层数会膨胀 |
