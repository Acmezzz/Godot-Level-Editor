# 能力补齐方案（CEILING_PLAN）

> 2026-11-21 起草。REFACTOR_PLAN 第 0–6 批全部落地后的天花板扩展方案。
> 目标：把 2026-11-20 能力分析判定的硬限制逐条补齐，覆盖面从「约 45 类」推向
> 「除时间轴重度类型外的全部格子类」。
> 配套纪律不变：每批验收 = bird-editor MCP 三连（check_scripts → warn_scan → run_tests）
> + 试玩实测；只本地 commit；拍板点未经用户点头不实施。

## 定位红线（本方案不动这些）

- 编辑器仍是「空间摆放器 + 实例功能绑定器」；不造帧级动画编辑器、谱面编辑器、卡牌定义器。
- 不重开：触发区编辑 UI（Q8 与历史红线）、校验 UI（Q25/Q31）、BG/装饰层、4 元组瓦片、
  关卡清单/世界拓扑。
- 顶栏两入口（设置 ▾ / 地图 ▾）不合并。
- 碰撞多边形形状（Q6 已砍）不做；碰撞**类型**下拉通用化做（第 6 批）。

## 批次总览

> **实施对账（2026-11-21 动工前逐文件核对）**：本方案起草时依据的是 2026-11-20 能力分析，
> 而 REFACTOR 第 5 批（空间能力：等距/图层参数/实体变换）在第 5 批之后落地——
> 下列批次有多项**已经存在**，动工前先核对、勿重复实现。

| 批 | 主题 | 状态（2026-11-21） |
| --- | --- | --- |
| 1 | 字段系统补齐 | ✅ 3385433——vector2/color/range/asset_ref 核对后**早已存在**，实际补 array + choice multiple |
| 2 | 等距网格 | ✅ 已在 REFACTOR 第 5 批落地（资产级 gridProjection，校验/画布/瓦片集齐） |
| 3 | v5 格式：瓦片翻转/旋转 + 层 blend | ⏸ 待拍板点 3（图层 parallax/ySort/offset/scale 已在第 5 批落地；缺瓦片 alternative 与 blend） |
| 4 | 实体变换 | ✅ 已在第 5 批落地（data_transform scale/rotation/flip_h/flip_v + 翻转交互） |
| 5 | 时间轴补齐 | ✅ steps 时间轴视图已落地；帧动画预览 ✅ ddad276（资产 frames[]，8fps 预览） |
| 6 | 开放决策收口 | ✅ 碰撞类型声明池 + 试玩面板通用化（bc11621）+ 事件区行为参数——**经查 mode/event/once 已在第 3 批去特殊化作废**（语义归 functions[]），该项本已解决；✅ target_map 改存地图码——0ca8a52（meta.code 4 位码，跨图引用全码化，改名不再破引用）；⏸ steps 嵌套 kind:"steps"——唯一未拍板项 |
| 7 | 文档收口 | 随批进行（GAME_SIDE_STANDARD 已同步 array/multiple/frames） |

## 第 1 批：字段系统补齐

**目标**：消灭「复杂数据手写 DSL」的退化体验。字段声明在游戏侧（清单功能声明），
编辑器按声明渲染——本批只扩**编辑器的表达**，不动「功能在项目侧」的模型。

**新增字段类型**：
- `vector2`：双数字输入，存 JSON 数组 `[x, y]`。
- `color`：取色器，存 `#rrggbb(aa)` 字符串。
- `array`：可增删行容器，行内只允许基础类型（string/int/float/bool/choice），不嵌套。
- `choice` 扩展 `multiple: true` 多选。

**改动面**：function_decl.gd（类型契约）→ field_widgets.gd（四类控件）→
manifest_validation / map_data_validation（校验）→ GAME_SIDE_STANDARD.md 同步。

**验收**：四类新类型声明 → 表单编辑 → 读回保真 → 校验通过；旧五类零回归。

**拍板点**：vector2 存储形态（数组 vs "x,y" 字符串，建议数组）；array 元素类型集合。

## 第 2 批：等距网格

**目标**：解锁等距/斜45 视角族——性价比之王（一个洞挡整个视角族）。

**数据契约**：`meta.projection = "orthogonal"（缺省）| "isometric"`；菱形宽高比固定 2:1
（即斜45），不做可调比例。

**改动面**：tileset_cache.gd（TILE_SHAPE_ISOMETRIC + 非正方 tile_size）→
grid_space.gd（world↔grid 投影变换）→ canvas_draw.gd（菱形网格线/瓦片绘制原点）→
canvas_input.gd（命中测试走新变换）→ map_dialogs.gd（新建地图加投影选择）→
content_preview.gd（等距预览可后置，先画包围盒）→ map_export.gd（导出带 projection）。

**验收**：等距图新建/摆放/擦除/框选/碰撞/导出全链路；正交图全回归零变化。

**风险**：菱形半格命中边界；等距绘制序按 (x+y, x) 排（瓦片重叠遮挡正确）。

## 第 3 批：v5 格式 bump——瓦片翻转/旋转 + 图层参数

**目标**：一次 bump 收掉两个数据层缺口，避免两次迁移。

**数据契约（v4 → v5）**：
- 瓦片五元组 → 增第 6 位 alternative（翻转 H/V + 旋转 90° 步进，Godot alternative_tile 编码）。
- `meta.layers[]` 增可选参数：`parallax: [x, y]`、`y_sort: bool`、`blend: 枚举（mix/add/mul）`。
- 迁移走 migrate_project.gd v4→v5 一次性脚本（零兼容红线不变：不做加载期兼容）。

**改动面**：map_format.gd / map_store.gd / tool_ops.gd（set_cell 传 alternative）→
layer_ops.gd（层弹窗加参数三行）→ canvas_draw.gd（视差 = 层级绘制偏移系数）。

**验收**：翻转瓦片摆放/读回/导出；视差层画布可见差异；v4 样例迁移无损；正交零回归。

**拍板点**：翻转编码形态；地图软边界 A/B/C 顺路拍（影响 bump 内容）。

## 第 4 批：实体变换

**4a 步进旋转**（保持格语义）：objects[] 增可选 `rot: 0|90|180|270`；
entity_factory / undo_history / selection_ops（R 键旋转 + 属性面板下拉）；
canvas_draw 旋转绘制；命中测试按旋转后矩形。

**4b 自由变换**（离格）：可选键 `x/y` 浮点 + `rot` 任意角 + `scale`；
undo_history 的格中心 floori 吸附改为「资产声明 snap 可关」；
selection_ops 加拖拽把手（角点缩放/旋转柄）；命中测试按变换后多边形。

**拍板点**：4b 是否本轮做（解锁经营/种田离格类，但动命中/撤销核心）；
资产 `snap: bool` 默认值（建议 true 保持现状）。

**验收**：旋转/缩放实体命中正确、撤销链正确、导出含变换、格语义类型零回归。

## 第 5 批：时间轴补齐（简易）

**目标**：把「演出级」时间编辑做完整，**不越界到帧级**。

- steps 时间条可视化：steps_panel 加横向时间块视图（时长/延时拖拽调整）。
- 帧动画预览：资产声明 `frames[]`（多帧贴图路径），资产面板/画布循环预览。
- 音频触发点在时间条上显示（audio 池已有，缺可视对齐）。

**明确不做**：逐帧 hitbox、谱面、关键帧曲线——这些类型仍判「编辑器无关」，
游戏侧自备工具，本编辑器不背这层。

**验收**：steps 时间条拖拽生效读回正确；帧动画预览正确；67 用例全绿。

## 第 6 批：开放决策收口

按拍板结果实施，每一条都先拍板再动：

- **碰撞类型下拉通用化**：写死四项 → 读清单 collision_types 声明
  （collision_types.gd 已是声明文件，收通用化收尾）。
- **试玩面板 bird 残留二选一**：playtest flags 状态池（照 audio 池模式）或删面板。
- **target_map 改存地图码**（全系统唯一怕改名的引用）。
- **steps 嵌套 `kind:"steps"`**：解锁分支树。
- **事件区行为参数（mode/once/require_flag）改自带功能** ⚠️ 涉及触发区编辑 UI 红线，
  须用户明确点头才动。
- **地图软边界 A/B/C**（若未在第 3 批顺路拍掉）。

## 第 7 批：文档收口

- EDITOR_FEATURES.md：新功能全量收录 + §12 已知边界重写
  （剩余边界：多视角、帧级时间轴、卡牌/叙事专用池）。
- GAME_SIDE_STANDARD.md：v5 契约 + 新字段类型 + projection + 变换字段。
- 能力结论重排：54 类型三档表更新（预计正当行 ~30 / 可用 ~20 / 无关缩到 3）。

## 拍板点汇总（开工前逐条点头）

> 批次 1/2/4/5 已按方案建议值实施完毕（vector2=数组 / 等距 / 实体变换 / 简易时间轴）；
> 开放拍板项只剩下面三条。

3. v5 bump（瓦片翻转/旋转 + 层 blend）——**唯一剩的数据层缺口**，动工条件：你点头 + 拍板翻转编码。
5. 试玩面板 bird 残留：留（flags 状态池，照 audio 池模式）还是删。
6. 事件区行为参数（mode/once/require_flag）改自带功能——触发区编辑 UI 红线，须明确点头。

> **全部落定（2026-11-21「按你推荐的做」）**：
> ✅ ① v7 bump（瓦片 6 元 alt + 层 blend）——0d9a614；
> ✅ ⑤ 试玩面板——通用化（清单 playtest 声明驱动），bc11621；
> ✅ ⑥ 事件区行为参数——经查 mode/event/once 已在第 3 批作废（语义归 functions[]），本已解决。
> 未拍板遗留：target_map 改存地图码（需先建地图身份码体系，建议缓）、steps 嵌套 kind:"steps"。

> ~~卡牌 cards 池~~ 已删（2026-11-21）：cards 就是 assets 定义（字段声明费用/效果）+
> 上场实体实例，专用池 = 把第 3 批刚拆掉的特殊化请回来。卡组/抽牌规则在游戏侧。

## 明确仍不覆盖（做完本方案也不宣称）

- 多视角（同一数据多视图表示）——等距批后视角族仍缺这一支，拍板后单列。
- 格斗帧动画 / 节奏谱面 / 竞速曲线赛道——需专门工具，编辑器不背。
- 视觉小说叙事编辑器——叙事流编排无专用界面（multiline 字段只兜简单分支）。
- 卡牌定义器——不需要：卡 = assets 定义 + 上场实体；缺的只是资产浏览器的过滤视图，属 UI 打磨。



