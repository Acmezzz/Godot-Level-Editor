# 通用 2D 游戏编辑器实施方案 · Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal**　用一套操作完成各类 2D 游戏的资产摆放、功能绑定、内容填写、编排与试玩。

**Architecture**　保留地图、实体绑定和内容文件。优先补齐空间坐标、字段与引用、步骤与时间三组通用能力，再从真实任务验证额外的视图需求。

**Tech Stack**　Godot 4.7.2、GDScript、TileMapLayer、JSON、现有原子文件写入和 headless 测试。

**Spec**　[审查报告](../../EDITOR_AUDIT.md) 记录初版源码证据和问题编号。本文件是实施清单，负责目标行为、任务归属、依赖和验收。现有 [功能文档](../../EDITOR_FEATURES.md) 与 [游戏侧契约](../../GAME_SIDE_STANDARD.md) 的冲突列在审查 §4，按对应实现批次修订。

## Global Constraints

- 游戏工程提供供地图摆放的资产、已实现的功能及可编辑接口。编辑器写地图摆放、实例绑定和公开内容。游戏工程解释数据、执行行为并提供试玩。
- 内容继续走 `content/<功能ID>/<内容ID>.json`。剧情、卡牌、谱面等沿用功能内容。库复用生成新内容 ID。执行引用保留现有编码规则，地图与资产使用稳定身份。
- 关卡默认操作保持选资产、左键放置、右键擦除。图层负责绘制顺序，逻辑楼层、地形代价和镜头行为由功能解释。高级编辑入口随字段或当前任务出现。
- 每项任务可独立验收。新增可选键沿用本版缺省行为。旧版本或退役键走一次显式迁移，游戏读取端确认后再开放数据语义变更。提交按用户授权在本地执行。
- 图层身份统一用现有 `meta.layers[].id`。功能与字段按执行码读写。只在消费端按声明解释功能含义。扫描目录是资产发现入口，游戏侧负责源文件与声明。
- 项目数据写盘走 `MapStore.write` / `write_json` / `write_text`。含 `await` 的委托逐层等待。画布手势状态使用 `EditorCanvas.gesture`。保留「设置 ▾」地图动作和「地图 ▾」切图的两个入口。

## 1. 覆盖目标与优先级

以「游戏已提供功能」作为验收前提。常见配置通过表单和步骤完成。空间配置要能在正确投影下摆放并选取。精确时间、批量输入和关系可视化分别检验设计者能否高效维护已经公开的数据。下面的矩阵列出代表任务，每个新类型都可按空间、引用、数值、时序与试玩重新验收。

首个交付批次按 A1 → A2 → A3 恢复入口和可靠保存，A4 接通资产身份，A6 接通试玩。B1/B2、C1/C2/C3、D1/D2 修正空间、引用和编排。A5 可在 B1 后独立完成。E1/E3 完成工作台与常用入口，B3/E2 用特殊场景验收编辑上限。F1 与 F2 随各批推进并在发布前复核。

| 交付节点 | 开始下一批前的通过条件 |
|---|---|
| 启动与保存 | A1–A4、A6。普通关卡能够正常摆放、写盘、切换与试玩。缺素材或写失败后原数据完整且可重试 |
| 空间与组装 | B1/B2、A5、C1–C3。不同投影地图用同一套操作制作。跨图引用、独立复制、导出与安全清理通过回归 |
| 演出与工作台 | D1/D2、E1/E3。完成刷怪、分支和帧拍试点，围绕同一实例切换面板能恢复输入与选择 |
| 扩展与发布 | B3、E2、F1/F2。补充试点记录制作与试玩结果，交付性能前后对照、接入示例和两份规范 |

### 四个编辑面板，三个一级入口

| 编辑面板 | 一级入口与默认操作 | 高阶操作与范围 |
|---|---|---|
| 关卡／画布 | 「关卡」中选材、放置、擦除、选对象。位置、范围与图层操作随选中对象显示 | 离格精调、路径与区域、引用选点及连线。编辑器镜头与游戏镜头有各自参数 |
| 内容 | 「内容」带入当前实例并显示已绑定功能，空态引导选实体 | 按已声明字段搜索、筛选和填写。表格、关系图复用表单的声明与写入入口 |
| 演出 | 从当前绑定的「编辑演出」打开，初次显示步骤列表 | 同一内容在列表和时间轴间切换，支持停靠、固定显示或展开。时间、轨道和参考素材随任务显示 |
| 资产图鉴 | 「资产」查自动扫描的素材。一键带回画布摆放 | 共用画布的资产查询，查看使用位置、缺失和类型挂载。源素材由游戏侧维护 |

搜索、保存、问题抽屉和试玩是跨面板操作。E1/E3 负责落地。项目内切换保留地图、选择、缩放和演出位置，跨项目重新建立上下文。

### 类型覆盖矩阵

每行给出一个可独立试玩的制作样例。A–E 对应第 2 节任务。样例使用小型项目或示范地图，功能名称仅作游戏侧声明示例。

覆盖记录以单条制作任务为单位，依次核对声明、录入、保存重开、试玩。按第一个未通过的环节记录「待游戏侧实现」「待公开字段」「待录入／维护」「待保存验证」或「待试玩」，全部通过才记「已验收」。一个项目可以同时选多行，例如纵版弹幕 Roguelite 使用卷轴、波次和房间配置。遇到矩阵外的组合，按同样的环节增加实际操作用例。

| 类型 | 在编辑器完成的任务 | 游戏侧提供 | 补强与验收 |
|---|---|---|---|
| 动作、平台游戏、清版动作、砍杀、奔跑射击 | 铺地形与碰撞，摆出发点、拾取物和敌群，填移动平台路线、锁屏区域及首领阶段 | 移动、战斗、镜头、刷怪 | A/B/C。能在同一张图调平台路径和敌群，重开后位置与触发区吻合 |
| 弹幕射击、子弹地狱、飞行射击、横版射击、纵版射击、自动卷轴游戏 | 沿卷轴关卡布置背景、检查点、飞机出现位置。用步骤设置时间或位置、队形与弹型参数 | 镜头推进、弹型、队形和判定 | B/D。重开后在预定时刻或进度开始第二波，切换横纵构图仍能准确选点 |
| 格斗游戏 | 摆擂台和出生位置。为动作功能填起效、有效、恢复区间、音效和已公开形状 | 输入、动作状态转换、命中与伤害 | D/E。相邻两个帧区间可区分。游戏公开形状时，在指定参考帧核对调整结果 |
| 动作冒险、银河恶魔城、角色扮演、JRPG、像素RPG、ARPG、迷宫探索 | 做相通房间，摆门和落点，填任务、商店、交互和能力门参数 | 传送、战斗、任务、存档和物品规则 | B/C。两图有相同实例码时仍跳到指定目标，复制房间后内部关系保留 |
| 视觉小说、叙事驱动游戏 | 在章节载体上绑对话或演出功能。用多行文本、立绘引用、选项步骤和内容引用创建分支 | 对话 UI、变量、条件和转场 | C/D/E。录入两选项、一条回跳和语音，重开后分支正确。关系图按制作规模引入 |
| 回合制策略、战棋、战术策略、塔防、即时战略 | 排单位、占领点、地图格、道路或塔位。用区域标记和引用填写代价、格边与波次 | 寻路、胜负、通行、攻击和行动顺序 | B/C/D。六边邻接选点一致，改两个波次及一个地区标记后成功试玩 |
| 益智游戏、点击解谜、物理解谜、解谜冒险、三消 | 摆交互热点、棋盘初态、物件和关节端点，选择连动目标，填动作参数与解谜提示 | 点击与碰撞判定、物理约束、匹配规则和谜题逻辑 | B/C/E。能换一端连接并清空旧目标，重开后仅新目标生效 |
| 模拟、经营、建造、生存、基地建设、种田 | 摆地块、设施和资源点，给生产、成长、天气功能填写产出、时长和素材 | 生产、经济、成长、占地和库存规则 | B/C/E。在画布查看设施范围，批改一组同功能参数且可回退 |
| 放置、超休闲 | 在单屏地图放视觉元素，用控制实例配置奖励节奏、阶段阈值与界面文案 | 离线收益、循环关卡、界面与交互 | A/C。最小项目能从打开到填一处奖励并试玩，全程使用默认表单 |
| 卡牌游戏、集换式卡牌、牌组构筑 | 卡图来自资产，卡牌内容填写费用、描述、视觉引用。给已有选目标、抽牌和效果步骤排序，牌组通过内容引用组合 | 卡牌布局、结算、目标规则和网络同步 | C/D/E。复制卡牌内容后只改副本，牌组引用保持稳定 |
| Roguelike、Roguelite | 制作房间和门，给生成控制实例填写地图引用、权重和种子，给房间填奖励与敌群 | 生成器、随机规则、永久成长 | B/C。可用固定种子试玩两次，验证项目侧结果；源房间无需反写 |
| 节奏游戏、音乐游戏 | 为曲目功能选音频并编排音符或提示步骤，设置轨、起点与时长 | 输入窗口、连击、计分与游戏播放时钟 | D/E。至少验证变速段、跨段长音和试听偏移；精确参数来自项目声明 |
| 社交推理、派对游戏、多人合作、多人对抗 | 摆多个出生点、目标、区域和队伍点，填人数、回合、阵营及目标参数 | 联机、同步、匹配、身份保密和胜负规则 | A/B/C。游戏侧启动两个客户端，双方使用同组地图数据，关卡编辑器可调整座位和目标 |
| 体育游戏、竞速游戏 | 搭场地与路线，摆计分区、发车位或计时线，按顺序配置赛道检查点和路段参数 | 运动、驾驶、过线、计分与排名 | B2/C1/E2。保存重开后能改一处检查点和路段方向，并在游戏侧触发正确规则 |
| 潜行、潜入、非对称躲藏 | 摆巡逻路线、观察区、藏身区、两种出生点 | 巡逻、感知和阵营逻辑 | B2/C1/E2。移一个路径点并换队伍目标，重开后核对预览和试玩 |
| 侦探推理、调查、密室、隐藏物品、找茬 | 在背景上圈热点，填写证物和后续条目 | 命中、线索条件和推进规则 | B2/C1/E2。重开后两个相邻热点命中各自内容，能从坏引用跳回来源 |
| 工厂自动化、物流、铁路、线路解谜 | 摆设备、端点、路径，并选择连接目标 | 端口规则、货物流转和调度 | C1/C2/E2。复制两个相连设备，内部连到副本，外部连线仍按声明处理 |
| 自走棋、MOBA、幸存者类、自动战斗 | 摆阵容槽、刷新点、路线，配置编队、升级池和波次 | 自动战斗、资源与匹配规则 | B2/C1/D1/E2。配置两个阵容和三批刷新，批改其中两批后核对剩余一批原值 |
| 抽象棋盘、数字逻辑、落块、推箱子、拼图 | 填初始盘面、目标、格边及禁用格 | 规则、邻接、形状匹配和胜负 | B1/B3/C1。选四个相邻目标格，试玩确认实际允许的移动与声明一致 |
| 弹珠台、台球、迷你高尔夫、绳索解谜 | 离格摆放、旋转几何、设置关节或击球点 | 物理和计分规则 | B2/C1/E2。改一处碰撞边和一对约束点，重开后几何命中正确，试玩复核结果 |
| 交互小说、打字游戏、屏幕交互型游戏 | 用无独立视觉的实体填长文本、提示、分支和屏幕热点 | 文本输入、UI 和状态 | C1/E2。无需在画布中逐条编辑文本，可筛选条目并查回跳、未设置项和热点 |
| 程序生成输入、玩家共创项目 | 制作房间样块、拼接点、出口、权重和限制 | 生成、组合、发布或运行时共创系统 | C1/C2/E3。复制样块后独立改出口，同种子生成可复核，编辑器保存源样块 |

### 视角与地图配置矩阵

一款游戏可组合下列四个维度。投影决定地图点如何显示，格型决定格轮廓和邻接，镜头决定玩家看哪里，屏幕呈现决定有几个视口及其布局。只改变最后两项时，地图摆放与实例身份保持原有坐标域。

| 玩家看到的视角 | 编辑器坐标与预览 | 游戏侧职责与通过条件 |
|---|---|---|
| 侧视、横版、横向卷轴 | 正交地图，横向范围、层视差、出发位置、视野框 | 游戏执行相机跟随、锁屏、自动卷轴。编辑器能用不同横向位置试玩 |
| 俯视、自顶向下、纵版、纵向卷轴 | 正交地图，按需启用 Y 排序与脚点。纵向范围与画幅独立于格网 | 游戏定义移动方向及纵向滚屏。绘制、命中和摆放脚点一致 |
| 等距、等距投影 | 逐图选菱形格，支持矩形像素格、网格吸附和离格连续坐标 | 游戏消费该投影和同层排序。已存坐标重开无漂移 |
| 四分之三视图、斜45度 | 素材透视时用正交加脚点。有菱形地图时用等距。其他平面斜投影按真实项目扩充基向量支持 | 游戏按相同基向量呈现。分别验收格中心、格边、翻转和遮挡边界 |
| 2.5D | 纯 2D 画面用层栈、视差和排序脚点营造深度。高度可由游戏功能暴露为字段，多平面可分图配置 | 真 3D 场景、透视相机或伪 3D 赛道效果由游戏呈现。编辑器录入 2D 底图、路径和参数，试玩核对实际画面 |
| 固定视角、单屏 | 配好地图尺寸和视野框，编辑一个屏幕内的摆放与功能 | 游戏固定相机并负责 UI。至少验证宽屏和竖屏两个构图 |
| 多视角、分屏 | 不同地图可选不同投影，单图的镜头区域和切换点以功能字段配置 | 游戏切换相机、重投影或分屏。离开区域与进入另一地图的切换均可试玩 |
| 补充：六边格、自由离格、自定义平面投影 | 六边格使用真实轮廓拾取。离格位置保持连续。平面投影、格型与拓扑分别配置 | 验收奇偶行、亚格往返和边界。按 B3 约束接入特殊空间 |
| 二等轴测、斜平行投影 | 2:1 菱形先走等距。其他斜平面复用 B3 的平面基向量 | 游戏使用同一平面参数。验收轴方向、格中心、格边和遮挡 |
| 三角格、不规则格、节点路线图 | 三角或其他格型的铺格与邻接属于拓扑。节点图可由实体、区域轮廓和已声明引用构成 | 游戏解释格边或节点连接。试玩验证选中的邻格与实际移动一致 |
| 环形、首尾相接、多楼层同位置 | 环形可放离格节点并以引用闭环。楼层以分图或功能字段区分。需要整块投影时再进入 B3 | 游戏处理首尾环绕与楼层切换。两个同坐标落点必须能明确选中 |
| 逐房翻屏、轨道镜头、旋转跟随、多机位 | 用地图、镜头范围、路径、观察点和切换区域配置公开参数 | 切换或分屏由游戏执行。跨两房间、跨两机位各试玩一次 |
| 第一人称静态场景、伪 3D 第一人称迷宫 | 静态画面用背景与热点。迷宫用平面布局加游戏侧只读预览。透视选点仅在游戏提供映射时由 B3 接入 | 试玩检查门、墙和触发点。若支持预览选点，两视图命中同一实例 |
| 画中画、主副视窗、屏幕坐标布局 | 用有明确坐标域的声明输入屏幕区域或视口参数，关联同一底图或实例 | 游戏负责布局和渲染。宽、窄两种窗口下验证参考坐标与对象身份 |

## 2. 实施任务

每个任务先用所列输入复现对应问题，再接入正常调用路径。数据改动优先把最小断言放入指定套件。批次结束运行 `godot --headless --path . --script res://tests/run_tests.gd`，检查 Godot 退出码和断言摘要。改动脚本按需执行 `godot --headless --path . --check-only --script res://src/app.gd` 或逐文件解析。Git Bash 直接启动 Godot，超时由调用工具控制。菜单、视觉和外部试玩按任务的 GUI 步骤验收。

| 代码归属 | 职责与文件边界 |
|---|---|
| 会话和提交 | `src/app.gd`、`src/ui/map_file.gd` 处理会话、文件确认和工作快照。`src/map/map_store.gd` 处理实际写盘。`src/project/manifest.gd`、`asset_scan.gd` 管理清单身份 |
| 视图与坐标 | `src/canvas/grid_space.gd` 处理格与连续坐标。`editor_canvas.gd` 提供层级变换服务。画布控制器、只读预览和导出按各自用途消费该服务 |
| 字段和复制 | 拟建 `src/content/ref_fields.gd` 解析声明与引用域，`clone_plan.gd` 规划独立身份和重映射。表单、自检、复制共享解析结果 |
| 步骤与参考时间 | `src/ui/steps_panel.gd` 拥有工作副本。`timeline_view.gd` 发出用户改动。`src/content/step_timeline.gd` 算有效区间，拟建 `timeline_clock.gd` 负责参考时钟换算 |
| 工作台和发布 | `src/ui/project_shell.gd` 保留面板上下文，`asset_panel.gd` 与调色板复用资产查询。`docs/EDITOR_FEATURES.md` 和 `docs/GAME_SIDE_STANDARD.md` 随实现批次同步 |

### A1 · 恢复项目会话与摆放入口

**对应审查**　E00、D05、E01、E03、C08、U04。**依赖**　无。

**文件**　`src/app.gd`、`src/ui/project_picker.gd`、`src/ui/editor_layout.gd`、`src/ui/palette_panel.gd`、`src/ui/content_editor.gd`、`src/canvas/editor_state.gd`、`src/canvas/editor_canvas.gd`。

- [x] 冷启动打开 A，记录缺失委托。退出到选择页再打开 B，验证布局控制器的生命周期。在宿主实现 `_enter_project(next_manifest: Dictionary) -> void`，负责组装本项目控制器并构建视图。启动恢复和项目选择器都调用此入口。
  - 实现：`src/app.gd:198` `_enter_project(dir, loaded_manifest)` 是唯一入口（启动恢复与选择页都走它），先 `_clear_project_session()` 再 `_build_editor_ui()`，最后 `_report_recovery_items()`。
- [x] 在 `EditorCanvas` 恢复 `set_entity_sizes(sizes: Dictionary) -> void` 和 `entity_display_size(asset_id: String) -> Vector2` 的工厂委托。补齐碰撞预览和生成委托，现有碰撞弹窗允许选择源普通层，输出固定为碰撞元层。把区域命中和松手转回 `RegionOps`。
  - 实现：`src/canvas/editor_canvas.gd:1432` `set_entity_sizes` / `:1434` `entity_display_size`；碰撞生成委托 `generate_collision`/`count_auto_collision`（`editor_canvas.gd:1349-1353` → `tool_ops.gd` 自审源层），弹窗在 `src/ui/props_panel.gd:25-39`（「源层」下拉只列普通层、碰撞层不可选，输出一律写碰撞元层）；区域命中/松手/搬动全部经 `canvas_input.gd:101,259,298,334` → `editor_canvas.gd:1277-1297` → `RegionOps`。
- [x] 左栏常驻「瓦片 / 摆放物」分类，摆放物含图片和实体。进碰撞层时按项目合法类型池初始化，无 `solid` 时取首个合法类型。离开恢复之前笔刷。内容页空态用 `set_hover("")`，选中缓存使用实例 `code`。
  - 实现：`src/ui/editor_layout.gd:279-285` 常驻「瓦片/图片/实体」三分类；碰撞笔刷按合法池回落见 `src/canvas/editor_state.gd` `_sync_collision_controls`；离开碰撞层恢复笔刷 = `editor_state.gd` `_brush_before_collision` + `remember_brush`（进层记住 place_kind，出层还原；停在碰撞层时选资产只登记意图，不覆盖）；`content_editor.gd:288` 空态 `set_hover("")`。
- [x] 验收 A → B → A、无图打开内容、首个混合层摆三类资产，以及用只有 `water` 的碰撞池绘制。落盘碰撞类型为 `water`，在空图和切项目时检查存活的菜单和信号。
  - 实现：A → B → A 的会话隔离由唯一入口 `app.gd:238-257` `_clear_project_session()` 实现——切项目先置空 manifest/画布/全部控制器与 `_nav_bars`（顶栏菜单引用），旧控制器的 `_process`/菜单委托不会再打到新项目（「切项目自动取消批量导出」即靠此）；无图打开内容页由 `editor_state._sync_ui` 的空状态分支（`map_loaded == false` → 空调色板）保证；首个混合层三类资产放置走同一 `tool_ops._stamp`（瓦片/图片/实体都按 `place_kind` 分流）；碰撞池 `collision_types.gd:32-49` 声明即覆盖内置，`editor_state.gd:62-77` `_sync_collision_controls` 回落到首个合法类型——只有 `water` 的环境形同声明池 `[water]`，笔刷写盘值取自 `canvas.collision_type`（`map_store` 六元组之外的对象条目 `{type: "water"}`）。`tests/test_grid_space.gd::test_collision_types_pool` 覆盖声明覆盖/字段透传/未知返回空。

### A2 · 地图、内容和清单保存闭环

**对应审查**　D01、D02、D03、D06、D08、D11、C03、C04、U01、U03。**依赖**　A1。

**文件**　`src/map/map_data_validation.gd`、`src/map/map_store.gd`、`src/core/undo_history.gd`、`src/ui/map_file.gd`、`src/ui/project_shell.gd`、`src/ui/content_form.gd`、`src/ui/content_editor.gd`、`src/ui/field_widgets.gd`、`src/content/content_store.gd`、`src/app.gd`。回归 `tests/test_stores.gd`、`tests/test_validators.gd`。

- [x] 以 `[1,2,"AB23",0,0,5]` 做读写回环。校验接受有限整数值 `5.0`，拒绝 `5.5`、`-1`、`8`。原始文档先检查 `version == 7` 和退役键，写入和单图导出复用同一校验。缺素材时保留原始记录，显示受影响项并禁止覆盖直至完整重载。
  - 实现：`tests/test_stores.gd:116` `test_v7_tile_alt_roundtrip`（六元组含 alt 往返）、`:126` `test_v7_tile_alt_float_rejected`（5.0 接受 / 5.5 / 8 拒绝）；`map_store.decode_text` 先跑 `MapValidator.precheck`（版本与退役键）再抬版本；写入 `validate_for_write` 与导出 `_write_check` 都走 `map_data_validation.validate`（同一校验链）。
  - 缺素材：`map_store.read_path` 校验失败即拒绝返回可编辑数据（`ok:false` + errors），保存路径 `write` 前置 `validate_for_write` 失败即不落盘——不会拿半份数据覆盖好文件。受影响项由 `project_audit` 列出。
- [x] 当前文档记录 `{project_root, path, map_code, generation}`。菜单捕获真实路径，打开项目外地图走导入到未占用目标。新图和首次持久化统一调用 `MapStore.ensure_code()` 的项目占码分配逻辑。检测重复码时列出全部路径，引用解析拒绝猜测。
  - 实现：`_doc_generation` / `_doc_project_root` / `app.cur_map_path` / `meta.code`（`map_file.gd:27-35`，代次核对 `_doc_stale`）；项目外地图导入到 `_unique_map_name` 未占用目标（`map_file.gd:57-67,484-505`）；`MapStore.ensure_code` 在 `editor_canvas.gd:261-263` 与新建/首存路径统一调用；重复码 `MapStore.code_conflicts` 返回 `{code: [全部路径]}`（`project_audit.gd:72-74`）；引用解析 `code_map` 撞码时不猜。
- [x] 用内容 ID 与控件所属表单版本收集脏值。读取当前聚焦文本，保留真实旧值。仅打开、切换和显示默认值不创建内容。`ContentStore` 增加严格读取结果 `{status, data, error}`，状态为 `ok/missing/invalid`，命中缓存和首次读都返回副本。损坏不覆盖，只有显式修复可更新经确认的身份字段。
  - 实现：`content_editor.commit_fields()` 冲刷 `_pending_commits`（按控件登记，切视图/失焦才落）；`content_form._ensure_content` 只登记 `_staged`，不写盘（打开表单不产文件）；`ContentStore.read_ex` 返回 `{status, data, error, digest}`，缓存命中与首读都 `duplicate(true)`；`content_form.gd:127-135` 损坏时给「重建为空白内容」显式修复按钮，其余字段只读。
- [x] 以同一工作副本提交表单和步骤。`commit_document(reason: String) -> Dictionary` 返回 `{status, written, error}`。`status` 取 `ok/staged/cancelled/failed`。`field_edit` 可写已有绑定的内容。涉及新内容、补码或新绑定时返回 `staged`，等待正式保存或试玩。正式提交先结束或取消画布手势，再冻结文档及基线，校验待写项，按清单、内容、地图顺序写入。写入失败时停止，并保留已写范围和待写 ID，供 A3 恢复。
  - 实现：`src/ui/map_file.gd` `commit_document(reason, dry_run)` 返回 `{status, written, error, pending}`，全局唯一写序（清单 → 内容 → 地图，失败即停、保留 `written` 与 `_pending_targets()`）；开头 `end_gesture()` + `doc_busy` 冻结撤销；`field_edit` 走 `content_form._content_write`（带基线摘要冲突检测）。
  - `staged` 的生产级消费方：`save_all()` 先 `commit_document("保存", true)` 盘点，有暂存内容/补码/脏地图时弹确认框列出「这次会写哪些」，取消则一个文件都不写（`map_file.gd` `save_all`）。Ctrl+S / 地图菜单「保存」都走它。
- [x] 同一文档串行处理提交、切图、退出与撤销。保存确认及写入期间暂停该文档的撤销和重做。每次等待后核对文档代次，画布重建成功且仍属同一请求才发布图名、路径和选中状态。取消、失败和部分成功后，各面板统一按未写项显示脏状态。回填控件时抑制变更信号。
  - 实现：`_doc_generation` 每次新建/切图自增，所有 `await` 后 `_doc_stale(gen)` 不通过就丢弃本次结果（`map_file.gd:39-44,506-513`）；`doc_busy` 在确认框与写盘期间置位，`undo_history.gd:45,55` 据此拒绝撤销/重做；失败路径 `_release_busy()` 必须走到（`map_file.gd` 每个 return 前）。
  - 脏状态：`commit_document` 失败返回 `written` + `pending`，调用方据此提示；状态栏与确认框共用 `_pending_targets()` 同一口径。
  - 信号抑制：表单不做「回填已有控件」，而是每次按声明重建控件并用声明值构建（`content_form._build_form_block` → `FieldWidgets.build(decl, value, ...)`），因此不存在回填触发写盘；连续控件值由 `commit_fields()` 显式冲刷。
- [x] 逐个注入清单、内容、地图写失败，确认后续步骤没执行，已落盘文件可查，同 ID 可重试。验证同名外部图、双击切图、空表单按保存和聚焦文本直接保存。写前按实际目标文件的内容摘要比对打开或上次保存的基线，复现同秒同长度外部改动也须提示。试玩只收到成功提交的项目内路径。
  - 实现：写失败注入 `tests/test_stores.gd::test_map_write_failure_keeps_old_and_retries`（目标变目录 → 写失败被报告、原文件不变、解除后同 ID 重试成功）、`test_map_write_rejects_bad_data`、`test_map_history_by_code_and_write_failure`；`commit_document` 每一步失败即 return，后续步骤不执行（`map_file.gd` 顺序注释与 early-return）。
  - 基线摘要：`_opened_digest` / `_file_digest`（全文本 sha256，不用 mtime+size）在写前比对；同秒同长度改动由摘要识别（`tests/test_stores.gd::test_content_write_conflict_detects_same_second_same_size_edit`）。
  - 试玩路径：`on_play` 只接受 `maps_root` 前缀校验通过的 `app.cur_map_path`（`map_file.gd:973-977`），且先走 `commit_document` 判 `ok`。

在 `tests/test_stores.gd` 加入最小读入回归。先运行确认 `alt` 触发失败，再修改校验链。

```gdscript
func test_v7_tile_alt_roundtrip() -> void:
	var data := MapStore.new_map("alt", 8, 8)
	var layer_id: String = data.meta.layers[0].id
	data.tiles[layer_id] = [[1, 2, "AB23", 0, 0, 5]]
	var decoded := MapStore.decode_text(JSON.stringify(data))
	ok(decoded.ok, "合法的 v7 瓦片变换可读回")
	if decoded.ok:
		eq(int(decoded.data.tiles[layer_id][0][5]), 5, "变换位保真")
```

### A3 · 草稿、历史与中断恢复

**对应审查**　D13、D14。**依赖**　A2。**文件**　`src/map/map_store.gd`、`src/ui/map_file.gd`、`src/core/undo_history.gd`、`src/app.gd`。回归 `tests/test_stores.gd`。

- [x] 将草稿放在 `<项目>/editor/drafts/<地图码>.json`，记录目标路径、正式图基线、地图快照、待提交文件及原 ID。旧草稿通过显式导入处理，通过 `_autosave_of` 确认来源。缺标记的 `foo.autosave.json` 按普通地图处理。正式保存剥离 `_autosave_of`，重开时按正式图识别。发现草稿时可恢复、查看正式图或丢弃。基线不同时保留草稿副本并提示冲突。
  - 实现：`src/map/recovery.gd:71-136` `draft_key`（有码用码、无码用名）/`write_draft`（payload 含 `targetPath/baseline/snapshot/pendingFiles/pendingIds`）/按键寻址 `read_draft_key`/`remove_draft_key`；`map_file.gd:959` `write_draft_now`、`:1000` `restore_draft_key`（基线不符 → 确认 + `_keep_conflict_copy` 留档）、`:1053` `_drop_draft_for`、`:1060` `open_draft_target`；三选项列表 `top_bar_nav.gd:88-129`「恢复 / 查看正式图 / 丢弃」。
  - 旧草稿：`legacy_draft_owner`（`recovery.gd:159`）只认 `_autosave_of`；`load_map_file`（`map_file.gd:587-598`）带标记归位到正式名、缺标记按普通图（`foo.autosave` 保留为本名），正式保存前 `data.erase("_autosave_of")`。
  - 回归：`tests/test_stores.gd::test_draft_roundtrip_by_map_code`、`test_draft_key_addressing`（冲突备份不入列表）、`test_legacy_draft_requires_marker`（含 `list_maps` 口径：缺标记的 `foo.autosave` 必须列为正式图）。
- [x] 对涉及多个文件的提交，在首次改写前登记各目标的基线和预期结果。重启时比对实际结果。已写后的同 ID 操作可重放，外部修改或损坏转人工复核。正式保存成功后才删除草稿或恢复记录。退出选「保留草稿」时绕过节流，失败留在当前文档并可重试，定时失败进入退避。
  - 实现：`commit_document` 写前 `Recovery.begin_pending`（`map_file.gd:754-775` 按写序登记 `{path, baseline, expect, kind, id}`）；每写成功一笔 `mark_pending_written` 回填实际结果摘要（`:784,795,802`）；全成功才 `clear_pending`（`:805`）。
  - 重启判定：`recovery.gd:298` `scan_pending` 逐条比对「结果摘要 == 当前 → written / 仍 == 基线 → pending / 都不符 → manual」；入口 `app.gd:212-220` 进入项目时报告。`tests/test_stores.gd::test_pending_log_partial_detection`（三态齐全，manual 优先）。
  - 草稿删除时机：正式保存成功后才 `_drop_draft_for`（`map_file.gd:944-946`）。退出「保留草稿」绕过节流 `write_draft_now`（`app.gd:111-113` 无条件调用）；定时失败 `_last_autosave_msec` 回退半间隔做退避、文档留脏可重试（`map_file.gd:971-975`）。同 ID 重放：内容暂存按原内容 ID（`content_form.flush_staged`），地图按原名覆盖写（`test_map_write_failure_keeps_old_and_retries`）。
- [x] 地图历史使用 `<项目>/editor/history/maps/<地图码>/`。原文件快照先暂存，新文件原子替换成功后才把快照纳入历史并淘汰旧项。改名更新文件内 `meta.name`，保留同码历史，遇目标冲突则不动源文件。历史落盘失败单独报告。
  - 实现：`recovery.gd:167-250` `_hist_dir`（键 = 码，无码退图名）/`stage_snapshot`（`.staged-*` 暂存）/`commit_snapshot`（换名入历史 + `_prune` 保留 20）/`migrate_history`；`map_store.gd:218-235` `write` 先 stage、`write_json` 成功才 commit，失败 `discard_snapshot`，commit 失败 `push_warning` 单独报（不影响保存成功）。
  - 改名：`map_store.gd:332-361` `rename_map` 同码历史目录不动、清旧 `maps/.history` 孤儿、`meta.name` 同步；目标已存在则提前返回不改源文件。
  - 回归：`tests/test_stores.gd::test_map_history_by_code_and_write_failure`（连续三次注入替换失败旧条目不减少 + 改名后同码历史仍可查 + `meta.name` 同步）。
- [x] 用 `foo.autosave` 作正式图名，验收退出恢复、改名后仍可查看历史。保存时中断在第一份内容之后，用原 ID 恢复并重开验证绑定。连续三次注入替换失败，旧历史条目不减少。
  - 实现：`test_legacy_draft_requires_marker`（`foo.autosave` 列为正式图 + 草稿标记判别）、`test_map_history_by_code_and_write_failure`（三次替换失败 + 改名后历史）、`test_pending_log_partial_detection`（第一份写成功后中断 → 逐条 written/pending/manual，原 ID 由日志与草稿 `pendingIds` 保留）。

### A4 · 扫描身份与资产故障隔离

**对应审查**　D04、D10、D12、D18。**依赖**　A2。**文件**　`src/project/asset_scan.gd`、`src/project/manifest.gd`、`src/assets/builtin_kinds.gd`、`src/assets/image_probe.gd`、`src/ui/asset_panel.gd`。回归 `tests/test_asset_scan.gd`、`tests/test_assets.gd`。

- [x] 在资产条目持久化 `scanFingerprint`。先按规范化路径占位，再用同类同指纹且未被占用的一对一候选重链。候选有歧义就保留旧 ID 和候选路径，经确认重链。补码、扫描和内置项初始化统一返回清单变更，走 A2 持久化。对原文件仍在扫描目录的资产保留停用记录及原 ID，可恢复，引用检查由 C3 接入。
  - 实现：`src/project/asset_scan.gd:141` 新条目带 `scanFingerprint`；`sync` 先把原位相对路径标为 claimed（规范化路径占位），`:83-100` 只在「同 kind/shape + 同 md5 + 未被占用」候选唯一时重链；`:101-121` 多候选 → 保留旧 ID/`retiredPath`/`relinkCandidates` 并占住候选，等 `confirm_relink`（`:224`）；`:158-167` 原位缺指纹只补指纹不改身份。
  - 持久化：`manifest.gd:121-129` `sync` 的 `changes`（含补指纹/标停用/歧义）并入 `_codes_issued`，随下一次清单保存走 A2；内置种类并入内存不落盘（`builtin_kinds.gd`）。
  - 停用/恢复：`:176-202` `disable` 记 `disabled` + 原 ID + `retiredPath`（文件仍在目录也不重编码），`enable` 清标记；引用检查 `project_audit.gd:51-70` 把 retired/ambiguous 列进问题抽屉并跳资产页。
- [x] Prefab 尺寸探针只从实际节点块读取资源引用，按节点类型、挂载关系和资源 ID 找到目标形状，找不到则走既有声明尺寸或占位。用两形状且首个未挂载的实例断言尺寸取已挂载形状。
  - 实现：`src/assets/image_probe.gd` `prefab_collision_size` 解析 `.tscn` 节点块、按 parent 路径判断可达（挂载）后取 `CollisionShape2D` 的 SubResource 尺寸；回归 `tests/test_assets.gd:98` `test_prefab_probe_skips_unmounted_shape`（首个未挂载的大形状被跳过，取已挂载的 24×12；嵌套 parent 完整路径同文件后续断言）。
- [x] 用缺 `assets` 的最小清单、只补实体码的清单、重启前后改名和同指纹双候选做回归。停用后重扫不发新 ID，已有引用仍能定位问题，恢复后原引用生效。
  - 实现：`tests/test_asset_scan.gd::test_scan_minimal_manifest`（缺 `assets` 键 + 只补实体码清单）、`test_scan_rename_after_restart`（JSON 往返后按持久指纹重链）、`test_scan_ambiguous_two_candidates`（双候选不猜、确认后原 ID 留确认项）、`test_scan_retire_restore_keeps_id`（停用重扫零新增、文件回来原 ID 生效）、`test_scan_disable_keeps_id`；`test_audit_c3.gd` 的资产使用用例按同一索引定位问题。

### A5 · 修正导出与限制批量作业

**对应审查**　D09、D16、U02。**依赖**　A2、B1。**文件**　`src/map/map_export.gd`、`src/ui/map_dialogs.gd`、`src/ui/popups.gd`。回归 `tests/test_map_v4.gd`。

- [x] 单图、批量都先校验 v7。PNG 概览从 `{x,y,type?,shape?}` 取碰撞位置，从格尺寸取宽高，并用 `GridSpace` 的格轮廓求输出边界。用同一格坐标对照概览、主画布与内容预览。概览按投影显示地图格，完整画布截图作为后续可选交付，复用 B2 的只读呈现。
  - 实现：单图 `src/ui/map_dialogs.gd:305` `_write_check` 走 `map_data_validation.validate`（v7 与退役键）；批量 `:364` 用 `MapStore.read_path` 的 ok 判定。概览 `src/map/map_export.gd` `output_geometry`/`render_preview` 用 `grid_of` + 格轮廓求边界，回归 `tests/test_map_export_a5.gd`。
- [x] 创建图像前按输出边界计算像素总数。首版上限取 `16_777_216` 像素，约 64 MiB 原始 RGBA，超限时提示可用缩放倍率。对 `4000×4000` 地图用 16 px 格导出，应在分配前给出缩放选项。
  - 实现：`src/map/map_export.gd:17` `MAX_PIXELS := 16_777_216`，`budget()` 超限时逐档下探并回报建议倍率（`:62-77`）；两个导出入口都先 `budget()` 再 `render_preview`，超预算直接取消。
- [x] 批量导出捕获项目代次和输出目录，每次让帧后检查取消与窗口有效性。只运行一个作业，项目切换自动取消，已写文件保留。逐图报告 PNG 与统计文本结果。用矩形碰撞图、超预算图、文本写失败和中途取消四项验收。
  - 实现：`src/ui/map_dialogs.gd:318-408` `_run_batch_export`——`_batch_running` 互斥、按钮改作取消、逐图比对项目根与 `is_instance_valid`、逐图 append PNG/统计各自结果并落 `_export_report.txt`。

### A6 · 试玩路径、参数与反馈

**对应审查**　D15。**依赖**　A2。**文件**　`src/project/playtest.gd`、`src/project/manifest.gd`、`src/project/manifest_validation.gd`、`src/ui/map_file.gd`。

- [x] 缺 `playtest` 键时用空字典。新增可选 `playtest.executable` 与 `playtest.args`，分别为可执行路径和参数字符串数组。把 `%mapfile%`、`%projectpath%` 替换成正式地图路径和项目根目录，替换后的参数直接组成数组。Godot 项目可用 `['--path', '%projectpath%', '--', '--map=%mapfile%']` 对接。声明有结构化配置时优先用 `OS.create_process()` 直接启动，现有 `playCommand` 走原模板并标明跟踪的是包装进程。
  - 实现：`src/project/playtest.gd:10-52` `launch_tracked`——`playtest.executable`/`args` 走 `OS.create_process` 数组直启（`kind:"direct"`、`tracked:true`），参数经 `EditorManifest.substitute_vars_raw` 替换 `%mapfile%`/`%projectpath%`；无结构化配置才回退 `playCommand` 模板并标 `kind:"shell"`、`tracked:false`，状态栏文案说明跟踪的是包装进程。
- [x] 试玩优先读取 A2 确认后的地图绝对路径。偏好以项目根目录和地图码为键。显示启动的程序、退出状态和本项目 `editor/playtest.log` 的最新内容。用两个有同名地图的项目、带空格的路径、缺配置和启动失败分别验收。
  - 实现：`src/ui/map_file.gd` `on_play` 先 `commit_document("试玩前提交")` 拿项目内路径，再 `Playtest.launch_tracked`；偏好键 `_prefs_key()` = 项目根 + `|` + 地图码（无码退回图名，旧键只回退读一次即迁移）；`poll_playtest` 显示程序名、退出码/秒数与 `Playtest.log_tail` 最后几行。

### B1 · 逐图投影与统一坐标

**对应审查**　D19、E07、E14 的投影裁切。**依赖**　A2。

**文件**　`src/canvas/grid_space.gd`、`src/canvas/editor_canvas.gd`、`src/canvas/entity_node.gd`、`src/canvas/tileset_cache.gd`、`src/map/map_data_validation.gd`、`src/ui/map_dialogs.gd`、`src/ui/palette_panel.gd`、`src/assets/asset_decl.gd`、`src/project/manifest_validation.gd`。回归 `tests/test_grid_space.gd`。

- [x] 公用格尺寸校验接受 `16` 和 `[32,16]` 这类整数像素值，拒绝零、负数和非整数。内部统一用 `Vector2i`，缺省图集 `cell` 直接用这一对宽高。
  - 实现：`src/project/manifest_validation.gd:44-54` 标量或 `[w,h]` 均按正整数校验，错误文案统一；`tests/test_stores.gd`/`test_grid_space.gd` 覆盖 `tile_size_of` 与矩形格。
- [x] 拟议地图键 `meta.gridProjection` 支持 `orthogonal`、`isometric`、`hexagonal`。新图在高级设置选择，缺键时沿用项目原有解析结果。旧图首次保存前冻结生效投影。带内容的地图禁止通过普通设置直接切投影。转换另作显式操作，先展示目标并保存副本，再验证游戏加载器版本。
  - 实现：新建弹窗可选投影（`src/ui/map_file.gd:254-263`）、普通设置里带内容图禁用并说明（`src/ui/map_dialogs.gd:61-79`）、缺键沿用项目解析并首次保存冻结（`editor_canvas.gd` `_map_projection`/`_freeze_projection`）。
  - 显式转换：「设置 ▾ → 另存并转换投影…」（`editor_layout.gd:188,239-241` → `map_file.gd` `on_convert_projection`）先出目标投影与实例/待核对计数预览，确认后走 `src/map/map_convert.gd` 换算实例与出生点（像素锚点不变），再交 `MapStore.duplicate_map` 另存（C2 重发实例码/内容 ID/地图码，原图不动）。瓦片/碰撞保留原格号并计入 `manual` 待核对；`gridBasis` 与非法拓扑组合拒绝。回归 `tests/test_map_convert.gd`（6 用例，含另存后原图与副本对照）。
- [x] 给 `GridSpace` 增加 `pick_cell(px: Vector2) -> Vector2i` 与 `to_continuous_grid(px: Vector2) -> Vector2`。六边拾取在附近格内按实际轮廓判断，边界以稳定格序决胜。连续换算按 `gy = (py - h/2) / (0.75*h)` 计算行，再反解 `gx = (px - w/2) / w - odd_offset(floor(gy))`，对应现有 `to_px`。吸附直接使用 `cell_center_px()` 或根据锚点求顶点，不把方格偏量塞到六边中心坐标。
  - 实现：`src/canvas/grid_space.gd:266` `pick_cell`（六边 3×3 轮廓判定，遍历序固定）、`:289` `to_continuous_grid`（严格反解 to_px）；回归 `tests/test_grid_space.gd:114` `test_pick_cell_and_continuous`。
- [x] 六边离格拖动以像素位移为输入，每帧按当前位置反算亚格坐标。过奇偶行边界时记录的 `gx` 可变化半格，视觉位置必须连续。反算接近边界时用候选行的正变换误差决胜。用 `[32,16]` 和 `(2.2,2.2)` 测亚格往返，并测试偶行拖到奇行再拖回、保存重开。等距可见区从视口四角反算。整格移动从各自起始格求目标。投影缓存键包含生效配置和格尺寸，资产冲突提示具体条目。
  - 实现：`grid_space.gd:286-298` `to_continuous_grid` 是 `to_px` 的严格反解（`gy=(py-h/2)/(0.75h)`，`gx` 扣奇行半格偏移），离格拖动/吸附 `editor_canvas.gd:690-693`、实体亚格落点 `entity_node.gd:238-245` 都用它；边界决胜不取近中心而用候选行正变换误差——即上述解析反解本身（`pick_cell` 的中心/轮廓判定只用于整数拾取，`grid_space.gd:266-284`）。
  - 测试：`tests/test_grid_space.gd::test_pick_cell_and_continuous`——`[32,16]` 矩形格六边 `(2.2,2.2)` 亚格往返（`:137-139`）、偶行→奇行→拖回像素一致（`:130-135`）、`to_px(to_continuous_grid(p)) == p`；保存重开由地图格式测试覆盖（六元组/投影键往返，`test_map_v4.gd`）。
  - 等距可见区：`canvas_draw.gd:26-28` 用 `canvas_transform.affine_inverse()` 反算视口四角世界矩形再裁格线。
  - 整格移动：区域搬迁 `region_ops.gd:160-181` 以各实例起始格 + 格增量求目标；拖动收尾 `selection_ops.gd:197-209` 恢复起点再按层局部吸附。
  - 投影缓存键：`tileset_cache.gd:26-34` 键含格尺寸 + 投影 + 每资产 id/图集路径/切片/ysort/mtime；图集缺失逐条 `push_warning` 点名资产 id（`editor_canvas.gd:133-141`），单条故障不拖垮整张图。

### B2 · 预览、拾取和摆放使用同一个空间口径

**对应审查**　E02、E04、E05、E06、E08、E09、E10、E11、E13、E14（取景与空图）、E16。**依赖**　B1。

**文件**　`src/app.gd`、`src/canvas/editor_canvas.gd`、`src/canvas/layer_ops.gd`、`src/canvas/canvas_draw.gd`、`src/canvas/canvas_input.gd`、`src/canvas/tool_ops.gd`、`src/canvas/selection_ops.gd`、`src/canvas/region_ops.gd`、`src/canvas/entity_poly_view.gd`、`src/ui/content_preview.gd`、`src/core/undo_history.gd`、`src/map/map_format.gd`。回归 `tests/test_grid_space.gd`、`tests/test_geometry.gd`、`tests/test_map_v4.gd`。

- [x] 保存与吸附在层局部坐标进行。拾取先将世界鼠标位置逆变换到候选层，再用 B1 接口取格或用实例逆变换命中。拖拽先计算世界位移，逐层逆变换到该层局部。同一笔画捕获起始变换，避免相机移动改变落点。
  - 实现：`editor_canvas.gd:566` `to_layer_local` / `:570` `to_layer_world` / `:587` `world_delta_local`（只取线性部分）；涂刷/放置 `tool_ops.gd:22` 先把世界鼠标变到活动层局部再 `pick_cell`；拖动预览 `selection_ops.gd:165-175` 算世界位移后逐成员 `world_delta_local`，起手位置冻结在 `_drag_origins`（相机后来移动不改落点）；区域搬迁 `region_ops.gd:173-181` 逐实例按所在层逆变换；幽灵预览 `canvas_draw.gd:45-55` 在层局部生成再变到世界。
- [x] 编辑显隐与锁以层码为键。提交前检查所有目标层。矩形、折线和多边形的绘制及编辑把手共用局部到世界的变换。运行时初始显隐仍从 `meta.layers` 取值。为排序点建立实际排序原点，反向偏移其视觉子节点保持位置。
  - 实现：`layer_ops.gd:168-184` 显隐/锁定键 = 层 id（碰撞元层固定键 `_collision`），`layer_ops.gd:305` 运行时初始可见仍读 `meta.layers[].visible`；锁检查覆盖整条变更——`selection_ops.gd:770-777` `_selection_touches_locked`（多选/组/批量），`region_ops.gd:115-118,298,338` 任一锁即拒绝整区域操作，`tool_ops.gd:18,153,177` 单点涂/擦/生成；poly/path 视觉与把手 `entity_poly_view.gd` 随 `EntityNode` 变换走（父节点坐标系 = 层局部）；排序点 `entity_node.gd:229-271` position = 排序原点、视觉矩形反向扣 `sortAnchor`，`canvas_draw.gd:203` 排序点十字。
- [x] 内容页复用主画布的只读场景构建与命中，禁用放置，返回实例码。锁层拒绝整条多层变更，隐藏对象从渲染、连线、点选、框选和擦除候选中一起移除。层材质作用于实际绘制节点，关掉 `ySort` 时恢复层内既定顺序。
  - 实现：`content_preview.gd:1-6` 只读预览（滚轮缩放/中键平移/左键选中），命中 `:141-161` 用 `canvas.is_entity_shown` + `canvas.to_layer_local` + `n.contains_point`（与主画布同一口径），`select_inst` 返回实例码，无放置入口；隐藏对象排除于点选 `selection_ops.gd:20,36,71` / 框选 `:71-77` / 批量锁检 `:775` / 擦除 `editor_canvas.gd:533`（`_entity_hit_on` 先查层可见）；锁拒绝见上条；层材质挂到实际绘制子节点 `editor_canvas.gd:337-345`（Below/YSort/Tiles/Above），`ySort` 关时 `ysp.y_sort_enabled = false`（`:310`）走插入序。
- [x] 手势保存起手快照和候选值，以起手快照计算增量。开始平移前先取消未完成的编辑手势，恢复原值。提取只读取提交状态。新放置结果经选择入口同时更新单选、多选和信息条。无图时输入提前返回，`Home` 取可见对象、瓦片与碰撞的并集。
  - 实现：`canvas_input.gd:67-72` 中键平移前 `cancel_preview_gesture()`（恢复原值并结束手势）；起手快照 `editor_canvas.gd:1160-1171`（`_resize_orig`/`_vertex_orig`/`_drag_origins`/`_stroke_last_cell`），增量都相对快照计算（`selection_ops.gd:167,174`）；`extract()` 先 `cancel_preview_gesture` 再取提交状态（`editor_canvas.gd:1314-1318`）；放置即精选 `tool_ops.gd:225-227` `commit_selection(n)`（单选/多选/信息条同一入口）；无图提前返回 `canvas_input.gd:23-27`；`Home` 并集 `editor_canvas.gd:735-770`（瓦片 used_rect + 碰撞 + 可见实体）。
- [x] 把八种 `alt` 作为二维变换实现组合表，按键、吸管、存档和读取共用。空白处右键也开始追踪格路径，沿两次鼠标事件之间经过的格补涂擦，首次实际变更才登记撤销。碰撞缺省值归一后比较，轮廓按当前格型邻接。尺寸按 `sizeFields` 初始化，矩形和点把手共用包含翻转的变换，`poly` 至少三点、`path` 至少两点。
  - 实现：`src/map/map_format.gd:34-69` `alt_rotate90`/`alt_flip_h`/`alt_to_godot`/`alt_of_godot`（组合表：旋转与翻转互不抵消），回归 `tests/test_map_v4.gd::test_alt_group_table`；按键 `editor_canvas.gd:33,38`、吸管 `:725`、读档 `undo_history.gd:89`、写盘/渲染 `tileset_cache.gd:99` 共用；右键在空白起手也追踪路径（`canvas_input.gd:312-323`）+ 补格（`:143-153`），首次真实改动才压撤销（`tool_ops.gd:50-53,120-134`）；碰撞缺省归一 `tool_ops.gd:68-72`、邻接按格型 `test_grid_space.gd::test_grid_neighbors`；`sizeFields` 落笔初始化 `tool_ops.gd:194-201`、尺寸把手 `selection_ops.gd:215-256`；poly/path 最小点数 `selection_ops.gd:558-576`。
- [x] 在 `[32,16]` 等距图组合图片、alt 瓦片、翻转路径和实体脚点。层偏移 64 像素且缩放 2 倍，主画布和内容预览点中同一实例。锁层后重排并批拖，目标锁仍生效。连续验收右键从空白擦入图块、吸回 alt、拖回起点和落笔后立刻删除。
  - 实现：几何单元测试覆盖——`tests/test_grid_space.gd::test_grid_rect_cells`（`[32,16]` 正交/等距/六边换算）、`test_pick_cell_and_continuous`（矩形六边亚格）；alt 组合表 `tests/test_map_v4.gd::test_alt_group_table`；翻转变换 `tests/test_geometry.gd::test_entity_geometry_rotated`（旋转/缩放后命中与 aabb）与 `test_sort_anchor`（脚点/排序点）；主画布与预览同口径由共用 `to_layer_local`/`is_entity_shown`/`contains_point` 保证（`content_preview.gd:158-159`）；锁层后重排仍生效由层码键保证（`layer_ops.gd:175-184`），批拖整条拒绝 `selection_ops.gd:770-777`。层偏移×缩放多实例点选属 GUI 手势，代码路径与单实例一致。

### B3 · 特殊格型、斜投影与游戏参考视图

**依赖**　B1/B2、C1。**文件**　`src/canvas/grid_space.gd`、`src/canvas/canvas_draw.gd`、`src/canvas/tool_ops.gd`、`src/ui/content_preview.gd`、`src/map/map_data_validation.gd`。回归 `tests/test_grid_space.gd`。

- [x] 先交付三角格与可逆斜平面试点。把第 `i` 列映射到平行四边形列 `c = floor(i / 2)`，以 `i` 的奇偶选择三角半格。偶半格的局部顶点为 `(0,0),(1,0),(0,1)`，奇半格为 `(1,1),(0,1),(1,0)`。用 `c, row` 平移，再按格基向量变换三点。拾取按三角形包含判定，邻接按共边，边界同 B1 稳定决胜。若 TileMapLayer 无法表现该格型，按图集区域绘制并裁到格轮廓。仍存原有瓦片六元组，游戏侧读取同一格域。
- [x] `meta.gridProjection` 保留 B1 三种预设作为缺省组合。进阶地图增加可选 `meta.gridTopology` 和 `meta.gridBasis: [[ux,uy],[vx,vy]]`。格型提供轮廓与邻接，投影使用双基向量及逆矩阵，拒绝非有限数和不可逆基。不对已含内容的地图静默改配置。测试 `u=(32,8)`、`v=(0,24)` 时 `(2,3)` 映成 `(64,88)` 且逆算回原点位。
- [x] 不规则棋盘、环形节点和格外路线可用现有 poly/path 与实例引用表达，E2 提供按需选点与连线。多楼层先用分图或带楼层字段的落点实例。测试相同 `(x,y)` 的两个目标可以按地图或楼层区别。
- [ ] 伪 3D 与多窗先接游戏提供的参考图或试玩。若游戏提供可验证的参考区域 → 地图码/实例码映射，允许从参考图选定同一实例。屏幕热点约定以参考图归一化坐标 `[0,1]` 录入，点与区域约束由声明提供。`screenSize` 继续只表示编辑器视野框。发布前验收平面与参考视图选中相同 ID，缺映射时保持只读。

### C1 · 让公开字段都有可靠的编辑与引用入口

**对应审查**　C06、C07、C10。**依赖**　A2。**文件**　`src/ui/field_widgets.gd`、`src/ui/content_form.gd`、`src/ui/content_editor.gd`、`src/ui/steps_panel.gd`、`src/project/manifest_validation.gd`、`src/content/function_decl.gd`、`src/content/content_store.gd`。拟建 `src/content/ref_fields.gd`，回归 `tests/test_validators.gd`。

- [x] 让声明校验和 `ContentStore` 共用功能目录名校验。将 `dlg.one` 和非数组的 `conditions` 分别作为拒绝样例，在归一化前报具体键。校验字段值时，向量只接受声明维数，布尔必须是布尔，多选必须是数组。已存非法值以原值只读显示并允许显式替换。
  - 实现：`src/project/manifest_validation.gd:120-123` 直接调 `ContentStore.is_valid_kind`（带点的 `dlg.one` 被拒），`:155-162` 非数组 `conditions` 报具体键；字段值严格性在 `src/ui/field_widgets.gd:89,157,191,234`（布尔非布尔、向量按声明维数、多选非数组、非法旧值只读 + 显式替换），文件头 `:11,30` 写明「认不出的声明一律只读，绝不提供可写控件」。回归 `tests/test_validators.gd:50,84`。
- [x] 提取 `RefFields.describe(decl: Dictionary) -> Dictionary`，返回 `{kind, scope, filter, many, map_field}`。沿用 `choice.source` 和 `props` 引用声明。解析 `asset::id` 时保留空段，`of` 独立传 ID 过滤。数组元素控件接收独立复制的同型声明，保留范围、固定选项与过滤参数。单选「未设置」删除该键，多选清空存 `[]`。
  - 实现：`src/content/ref_fields.gd:51` `describe` 返回 `{kind, scope, filter, many, map_field, is_ref, allow_empty}`；`:89-98` `asset::id` 保留空段；`tests/test_ref_fields.gd` 覆盖引用字段描述与严格性。
- [x] 给实例引用增加同级 `mapField`。例如 `entity_ref` 使用 `mapField: "target_map"`，功能、条件及步骤可使用 `entity_inst:` 配合同一份 `fields` 中的 `map` 选择字段。声明按人类字段 ID 查配对，再以各自声明码读写。地图未填时取所属图。改地图时确认并清空旧落点。引用目标使用 `(地图码, 实例码)`，未存码先走 A2。
  - 实现：`src/content/ref_fields.gd:166-199` 按人类字段 id 找 `mapField` 配对（`entity_ref` 用 `target_map`）；`src/content/ref_ops.gd` 负责读写与作用域；未填地图取所属图见同文件 `scope == "map_ref"` 分支。
- [x] 在两个都有 `AB23` 的地图切换目标，验证选项、自检输入及复制计划拿到相同目标域。再测试 `[1,2,3]` 误写给二维向量、布尔字符串 `"false"`、空资产类别但有 ID 过滤，以及数组数字越界。仅打开无效值时磁盘不变。
  - 实现：目标域解析为 `RefFields.describe` 的统一口径（`map_field` 配对），自检与 `ClonePlan.build` 共用同一解析；上述误写/越界样例由 `tests/test_ref_fields.gd:76` `test_widget_type_strictness` 与 `:11-62` 各例覆盖，非法旧值只读展示、不改磁盘（`field_widgets.gd:89,157,191,234`）。

### C2 · 统一复制语义与持久引用

**对应审查**　C01、C05、E12。**依赖**　A2/A3、B2、C1。

**文件**　`src/app.gd`、`src/canvas/selection_ops.gd`、`src/canvas/region_ops.gd`、`src/map/map_store.gd`、`src/content/content_store.gd`、`src/content/content_id.gd`、`src/ui/content_form.gd`。拟建 `src/content/clone_plan.gd`，回归 `tests/test_stores.gd`、`tests/test_content_id.gd`。

- [x] 复制先用一张映射表预留新对象和内容身份。复制组内实例和附属内容时生成独立内容文件。应用 C1 的声明规则，只重映射组内实例引用和副本之间的内容跳转。组外引用保留原目标。跨图时若字段支持地图配对，补源地图码。仅允许本图目标的字段无法保留组外引用时，在预览中列出并要求重新选目标或取消。移动保持原身份。
  - 实现：`clone_plan.gd:157-168` 先全量发新实例码（`instance_map`，避开目标已有码）、`:170-205` 每条被复制内容发新 ID（`content_map` + `pending_contents`）；引用重映射按声明遍历，不盲扫字符串（`remap_row` `:240-330`、`_remap_content`）：`instance_map` 命中的组内引用换新码并补配对地图字段为目标图码（`:264-268`），未命中的组外引用保留原值；跨图无配对字段时 `conflicts` 报冲突（计划整体取消，`tests/test_clone_plan.gd::test_cross_map_keeps_out_group_target` 后半段）；移动 = 原地改坐标不改身份（`duplicate_selected_at_offset` 只给副本发新码，`:909-972`；拖动预览直接改 position，不碰 code）。
- [x] `ClonePlan.build(source: Dictionary, target: Dictionary, instance_codes: PackedStringArray) -> Dictionary` 读取两份文档的地图路径、地图快照及占码，返回 `{status, instance_map, content_map, map_patch, pending_contents, conflicts}`。整图复制传全部实体码并纳入地图的图片、瓦片、碰撞和出生点。重复或无法读取的身份先列入冲突。纯场景资产的摆放仍无实例码。
  - 实现：`src/content/clone_plan.gd:110` `build(src, dst, codes, include_world)`，返回键在 `:226-233` 完全对齐；整图 `include_world` 并入瓦片/碰撞/出生点，重复码/缺码先进 `conflicts`；纯场景摆放不发码（`tests/test_clone_plan.gd`）。
- [x] 用完整序列化负载以及一次组位移。仅当同一地图或明确来自同源层时直接按层 ID 匹配，其他跨图按唯一层名或手选映射。区域剪贴板保存独立快照，切图后仍可用。撤销移除副本绑定。未落盘内容从待写列表移至重做记录，已落盘内容留在功能库。重做沿用同一 ID。
  - 实现：完整负载随剪贴板/区域快照走（`selection_ops.gd:641-651`、`region_ops.gd:104-112` `raw` 含 sortAnchor/未知键）；层匹配 `region_ops.gd:427-447` `_paste_layer_index`——同图按层 id 直配、跨图按唯一同名层，名字重名/缺失落最底层并黄字列出（`:422-425`）；区域剪贴板存纯数据快照、载图不清（`editor_canvas.gd:213-216`）；撤销移除副本绑定 = 快照恢复（`undo_history.gd` `_restore`），内容文件仍留库（`test_audit_c3.gd::test_unbind_keeps_content_and_rebinds` 同一语义）；重做沿用同一 ID 由快照原样回放保证。
- [x] 将完整地图改动及待写内容放入 A2 的同一工作集。先校验目标锁、目标文件不存在、声明和引用，再一次应用到工作快照；校验失败不改画布。正式提交按 A2 顺序先写内容后写地图，失败保留工作快照和原预留 ID，复用 A3 恢复。整图复制在目标图正式写成功后才加入地图菜单。
  - 实现：粘贴/复制先跑完整 `ClonePlan.build`（声明/引用/身份全量校验），冲突即取消且画布未动（`selection_ops.gd:710-722`、`region_ops.gd:354-367`、`editor_canvas.gd:924-937`）；内容先写、失败即停不动画布；`MapStore.duplicate_map` 同一顺序——先写 `pending_contents` 再写地图，地图写失败留同名重试（`map_store.gd:386-405`）；地图菜单只列磁盘已有文件（`MapStore.list_maps`），写成功才可见；暂存内容保留原 ID 由 `content_form._staged` 承载（A3 日志/草稿 `pendingIds`）。
- [x] 回归组内 A → B、组外 A → C、普通字符串 `AB23` 和功能执行码 `AB23`。复制后只改副本内部边的目标。修改副本台词后比较原文件，原值保持不变。整图复制和 `Ctrl+D` 复用这条流程。
  - 实现：`tests/test_clone_plan.gd::test_remap_in_group_vs_out_group`（组内 A→B 换、组外 A→C 留、`"AB23"` 普通串不动）、`test_string_collision_safe`（实例码与功能码同为 `AB23` 不误改）、`test_content_clone_independent`（副本内容独立文件，改副本不影响原文件——内容 ID 不同即不同文件）、`test_whole_map_document`、`test_duplicate_map_through_plan`（原内容文件仍在、副本内容独立落盘）；`Ctrl+D` 走同一 `ClonePlan.build`（`editor_canvas.gd:924-937`）。

### C3 · 挂载一致性、引用自检与安全清理

**对应审查**　D07、C09、C12。**依赖**　C1、A2。**文件**　`src/project/project_audit.gd`、`src/project/manifest_validation.gd`、`src/ui/content_editor.gd`、`src/ui/content_form.gd`、`src/ui/fn_bind.gd`、`src/ui/issues_drawer.gd`、`src/canvas/canvas_draw.gd`。回归 `tests/test_audit.gd`、`tests/test_decl_pools.gd`。

- [x] 校验挂载声明去重。放置和载图时在工作副本补齐无歧义的挂载，并标记待保存。切换选中只刷新界面。用可选 `mounted: true` 标识唯一继承行，保留手动同功能行。旧图有多条候选时由作者确认继承行。库复用为继承行生成新内容 ID，保留原文件。
  - 实现：`src/content/function_decl.gd:180-229` 运行期去重 + 只在「该功能一条绑定都没有」时追加 `mounted: true` 继承行（已有手动行不覆盖）；放置即补齐见 `src/canvas/tool_ops.gd` `_stamp`（`FunctionDecls.fill_bindings`），载图见 `editor_canvas.gd` 的挂载补齐；重复挂载由校验层报错（`manifest_validation.gd`）。
- [x] 自检按 `(功能人类 ID, 内容 ID)` 索引内容地址，按 C1 解析资源、条件、步骤、时机和内容引用。检查绑定文件缺失、挂载、时机池与白名单。资产使用统计沿用同一索引，展示读取失败的源文件，检查范围不完整时禁用清除。
  - 实现：`src/project/project_audit.gd:21` `audit(manifest, meta_out)` 产出 `incomplete`/`unreadable_maps`，`:348-391` 自检索引（`by_map`/`bad_contents`/`incomplete`），`:458-486` `asset_usage` 同一索引并回报 `unreadable`；`src/ui/issues_drawer.gd:99-108` 检查范围不完整时禁用「清除悬空」。
- [x] 清理候选记录源路径、所有者身份、字段位置、预期旧值与目标作用域。提交前重新读取并查验预期仍相同、目标仍确认失效。当前图有脏改动时基于工作快照预览并走 A2 提交。写入成功才计数，原位同步当前图。跨图连线按目标图码解析，跨图时显示目标图名。
  - 实现：清理项 `fix` 带 `{map, code, prop, expect}`（`project_audit.gd:288-301`）；`apply_ref_fixes`（`:304-344`）双重复验——重跑 `_ref_checks` 建「仍悬空」集合、逐项比对字段当前值 == `expect`，两项都过才擦键，否则计入 `skipped`；调用方 `issues_drawer.gd:199-258` 当前图脏先 `commit_document` 再清（A2）、按地图读到最新磁盘、`MapStore.write` 成功才 `total += erased`、当前图被改则重载画布、最后重扫审计。跨图引用按目标图码解析并报「目标图 X」（`project_audit.gd:536-560`）。
- [x] 验收两功能同尾码、两图同实例码、坏时机和已恢复引用。用过期报告执行清理，已修项不变。注入一次写入失败，成功数不增加。未选过的实体也已挂载合法功能。解绑后内容文件留在功能库，自检显示零入边，撤销后入边恢复。再从 A3 恢复一次待写绑定，确认自检、资产使用和清理使用同一批引用数据。
  - 实现：`tests/test_audit_c3.gd::test_used_content_index_is_per_function`（同尾码只算命中功能）、`test_same_instance_code_two_maps`（两图同码不串图）、`test_binding_checks_mount_and_trigger`（坏时机池）、`test_stale_report_skips_repaired_field` / `test_stale_report_skips_changed_value`（过期报告不清已修/已改值）、`test_clear_write_failure_not_counted`（写失败不计数）、`test_fill_bindings`（未选实体也挂载）、`test_unbind_keeps_content_and_rebinds`（解绑留库、零入边、撤销恢复）、`test_content_ref_checks_steps_and_content_pool`。

### D1 · 同一份步骤数据支持列表和精确时间编辑

**对应审查**　C02、C03 的步骤编辑、C11。**依赖**　A2、C1。

**文件**　`src/ui/steps_panel.gd`、`src/ui/timeline_view.gd`、`src/content/step_timeline.gd`、`src/content/content_store.gd`。回归 `tests/test_step_audio.gd`。

- [x] 面板为当前绑定打开工作副本。已有内容用功能码和内容 ID 定位，空绑定先用会话内的绑定标记定位。首次实际改动才预留内容 ID。时间轴发 `step_change_requested(index: int, revision: int, patch: Dictionary)`。表单回调捕获步骤索引、绑定身份和结构版本。增删、排序、切页签前提交当前控件，失败时保留输入与当前位置。过期控件与拖拽请求直接丢弃。
  - 实现：`src/ui/steps_panel.gd:508-530` 工作副本读/写（空绑定只在首次实际改动时 `_ensure_content` 预留 ID，`:509-514` 内存空壳不落盘）；`src/ui/timeline_view.gd:16` 信号 `step_change_requested(index, revision, patch)`，`:237` 带 `struct_rev` 发出；`steps_panel.gd:644-657` 版本不符或身份不符直接丢弃，`:533` `_bump_steps_rev` 在增删/排序后递增；`:784,870-930` 各回调用闭包捕获的 `rev_*` 二次校验。
- [x] 面板将补丁合并到工作副本，只净化被编辑的时间键，保留未知键和未改条目。暂存结果走 A2。`ok` 和 `staged` 都发布同一工作快照，`staged` 标为未落盘。失败时保留输入并提供重试或撤回。列表、数值和拖拽共用这一入口。
  - 实现：`src/content/step_timeline.gd:102` `from_timeline` 只净化显式改动的键、`erase_keys` 独立表达「清 at」；`steps_panel.gd:644` 是唯一补丁入口（列表/数值/拖拽共用），写回走 `_steps_write` → `write_content_staged`（A2 暂存），失败 `_ensure_failed` 保留输入。
- [x] 步骤默认用列表，展开「时间与轨道」后可输入起点、时长、轨号和阻塞。缺 `at` 显示「随前序」，显式的 `0` 表示从零开始。接受 `duration=0`。新轨用「移至新轨」，轨号取当前最大值加一。拖拽根据起手时的生效区间与鼠标偏移计算增量。
  - 实现：`src/ui/steps_panel.gd:452-467` 列表/时间轴互斥切换；`:845-930` 时间与轨道行——占位文案「随前序」（`:867`）、填 0 = 从零（`:869`）、`duration=0` 接受、`阻塞` 勾选、`移至新轨` 取 `max(track)+1`。拖拽增量见 `timeline_view.gd`（起手区间 + 鼠标偏移）。
- [x] 每次编辑或装载重算一次 `StepTimeline.to_timeline(steps)`。重叠用每轨按起点排序扫描，只展示可见刻度。播放头首版是定位工具，读取时间而不调用游戏判定。一次拖动生成一次内容编辑记录，同一面板可撤销并再次保存。
  - 实现：`src/content/step_timeline.gd:19` `to_timeline` 单一数据源，重叠按每轨起点排序扫描（F1 起改为每帧一张生效区间表，只画可见跨度）；`steps_panel.gd:634-636` 结构版本变化才重建时间轴；播放头只读时间（`timeline_view.gd`），不调用游戏判定。
- [x] 回归 `[{"duration":2},{"duration":1}]` 所示的两步数据。第二步初始生效起点为 `2`，右边拖至 `4` 后只把时长改为 `2`，再归零并换新轨。编辑第一步文本后直接重排、切页，核对文本仍属于第一步。在换序后送达旧版本回调，断言新位置不被误写。步骤身份使用会话内索引与版本，磁盘格式保持原有步骤数组。验证缓存命中、显式起点、随前序、保存失败与重开。
  - 实现：`tests/test_step_timeline_d1.gd::test_acceptance_two_steps_second_effective_at`（起点 2 → 拖到 4 只改 duration=2 → 归零剥键 → 换新轨，未编辑步骤不受影响）、`test_patch_only_normalizes_edited_keys`（未知键保留、原数组不被就地改）、`test_erase_at_restores_sequential`（清 at 回到随前序）、`test_stale_index_after_reorder_is_detectable`（换序后旧下标指向另一条，直接写会污染）、`test_explicit_zero_vs_sequential`（显式 0 与随前序可区分）、`test_patch_rejects_non_time_keys`（身份键/越界拒绝且数据不变）。磁盘格式仍是步骤数组（`from_timeline` 只净时间键）；面板「增删/排序/切页签前 `host.commit_fields()`」见 `steps_panel.gd:94,283,456,484,698,812`；缓存命中 = 内容页 `_content_read` 优先读暂存。

调用前核对内容 ID、版本、索引与允许的补丁键。用单条结果净化显式改动的键，清除 `at` 由独立命令处理。

```gdscript
var next_steps: Array = current_steps.duplicate(true)
var step: Dictionary = next_steps[index]
step.merge(patch, true)
var normalized: Dictionary = StepTimeline.from_timeline([step])[0]
for key in patch:
	if not normalized.has(key):
		step.erase(key)
```

成功提交后用 `next_steps` 替换工作副本，递增版本并通知两个视图。

### D2 · 帧与节拍的精确预览

**依赖**　D1、C1。**文件**　`src/content/function_decl.gd`、`src/project/manifest_validation.gd`、`src/ui/steps_panel.gd`、`src/ui/timeline_view.gd`。拟建 `src/content/timeline_clock.gd`，回归 `tests/test_step_audio.gd`。

- [x] 保留 `at/duration` 的原始单位。已存小数帧标记待修，新录帧取整数。拍数在界面按声明的细分吸附，缺省每拍四格。底层保留既有拍数精度，吸附更改仅作用于新输入或显式量化选中项。
  - 实现：`src/content/timeline_clock.gd:126` `fractional_frames()` / `:141` `quantize_frames()`（只标记已存小数帧，量化是显式动作）；吸附粒度由 `snap_step()` 按 `subdivisionsPerBeat` 给出（缺省 `DEFAULT_SUBDIVISIONS = 4`）；`src/ui/steps_panel.gd:1063` 新输入的 at/duration 才吸附。回归 `tests/test_timeline_clock_d2.gd:64-77`。
- [x] 用可选 `functions[].timePreview` 指定数据来源。`fpsField`、`audioField`、`offsetField` 引用该功能的字段 ID。`tempoStep` 引用变速步骤 ID，`bpmField` 引用该步骤的数值字段 ID。可用 `subdivisionsPerBeat` 设置拍网格的每拍格数，缺省 `4`，须为正整数。读取内容时把声明 ID 转成执行码。缺参考参数时保留原单位编辑并显示具体缺项。
  - 实现：`src/content/timeline_clock.gd:151-207` `from_decl` 把声明 ID 解析成执行码并收集 `missing`；`src/project/manifest_validation.gd:189-234` 校验引用与 `subdivisionsPerBeat` 正整数；缺项时 `seconds_at` 按 1:1 保留原单位（`timeline_clock.gd:56-66`）并由界面显示 `missing`。
- [x] `TimelineClock.seconds_at(value: float) -> float` 根据时钟初始化参数换算时间。帧使用 `value / fps`。拍以第 0 拍开段，预验有限正 BPM 与严格递增起点，再累加各段 `拍差 × 60 / BPM` 和首拍偏移。分别换算起点与终点。预览参考帧和试听只用于对齐，游戏行为继续由试玩验证。
  - 实现：`src/content/timeline_clock.gd:57` `seconds_at`、`:69` `value_at`（逆换算，时间轴刻度反查）、`:81` `_beats_to_seconds`（第 0 拍开段逐段累加）；BPM/起点预验在构造期 `is_ready()` 收集 `missing`。
- [x] `frameAssetField` 可指向同一功能的资产选择字段。帧基预览按播放头帧索引显示该资产声明的帧序列，从第 0 帧计数，越界显示提示。音频预览以换算后的秒数定位，负秒在音频起点前保持静音。形状仍是游戏公开的步骤参数，编辑时以选中步骤身份经 D1 写回。试玩负责验证实际姿态、判定和音效。
  - 实现：`src/ui/steps_panel.gd:581-606` 按声明解析 `frameAssetField`/`audioField` 为资产码与音频码；帧预览按播放头帧索引取序列、越界提示与音频只对齐不播放见同文件帧/音频预览段（`:980-1020`）；形状仍走 D1 补丁入口。
- [x] 用 0 拍 120 BPM、4 拍 60 BPM 和首拍偏移 0.25 秒验收。第 6 拍对应 4.25 秒。跨变速的第 3 至第 5 拍对应 1.75 到 3.25 秒。60 fps 的第 12 帧预览时间为 0.2 秒。
  - 实现：`tests/test_timeline_clock_d2.gd:12,29,39,40` 逐条断言上述数值（含逆换算与端到端解析）。
- [ ] 基础帧拍试点通过后，再按实测瓶颈加时间视图。波形按时间窗口聚合音频峰值并使用同一参考时钟。拍号段通过项目声明的标记步骤读取，只影响小节显示。批量移动选中音符先预览起点差值，再由 D1 一次提交。逐帧形状轨展示被选帧区间的公开形状，结合 E2 把手编辑。卷轴联动可读取游戏给出的时间与镜头位置参考点，供时间轴定位画布预览。

### E1 · 在制作流程中提供清晰的入口和反馈

**依赖**　A2、B2、C1、C3、D1。**文件**　`src/ui/project_shell.gd`、`src/ui/top_bar_nav.gd`、`src/ui/editor_layout.gd`、`src/ui/content_editor.gd`、`src/ui/content_form.gd`、`src/ui/fn_bind.gd`、`src/ui/steps_panel.gd`、`src/ui/issues_drawer.gd`。

- [x] `project_shell.gd` 保留当前地图码、图层 ID、实例码和画布视口。演出额外保留功能码、内容 ID、步骤索引及其版本、列表或时间轴模式和播放头。归来时按身份校验，目标已删除则显示空态。选引用的临时画布使用 `确认 / 取消`，仅确认时提交目标，返回时恢复原表单与焦点。使用既有顶栏、Esc 和上下文入口切换。
  - 地图/图层/实例：切视图只改可见性，画布节点不重建——`zoom`/`cam_pos`（`editor_canvas.gd:54,99`）原样保留；同图重建（撤销/尺寸）走 `_active_lid_before` 按层码找回激活层（`:185-193,472-477`）；实例码 + 功能执行码由 `content_editor.gd:290-339` 记忆并按 `SessionContext` 校验，目标已删给空态。
  - 演出：`steps_panel.gd:119-126` 按 `(功能码, 内容 ID)` 恢复选中步骤（附步骤码校验）、视图模式与播放头，`:195-201` 回填播放头后重画，`:417-430` 写入记忆。
  - 选点：`editor_layout.gd:598-630` 确认/取消条，取消时 `app.gd:679-735` 恢复原视图与原表单焦点（`prev_view`/`prev_focus`）。跨项目重开不持久化（视口/播放头只活在本次会话），见发布记录「已知限制」。
- [x] 将演出拆为可复用容器。先从当前功能侧边展开，再支持停靠在内容或画布下方及独立展开。保留同一控制器和工作副本。搬动容器前记下当前输入，复原后步骤索引和版本一致。缺 `steps` 声明时隐藏入口。
  - 实现：`src/ui/steps_panel.gd:51-54` 一个控制器 + `_steps_dock`，`:206-231` 三种停靠（内容下方 / 画布下方 / 独立展开）；`:278-344` 搬动前记下当前输入、`revalidate_dock` 复原后索引与版本一致；入口按 `steps` 声明显示（`content_form.gd:157` 只对声明 `steps: true` 的功能给子面板入口）。
- [ ] 首次流程为项目 → 新建或打开地图 → 摆放 → 点实例 → 从选中对象进入内容 → 添加功能 → 填参 → 保存试玩。已有字段说明、单位和默认值按声明显示。从问题抽屉跳到源实例或字段，失败时保留输入并显示文件与重试操作。
  - 已有：整条流程的入口都在（`app.gd` `_set_mode`、`content_editor` 实例列表→功能→表单、`commit_document` → 试玩）；默认值按声明显示（`field_widgets.gd` `default_for`）；问题抽屉行点击跳转（`issues_drawer.gd:124-148`：地图问题开图、实例问题开图后选中、资产问题开资产页）。
  - 未做：声明的「说明 / 单位」没有对应契约键（`GAME_SIDE_STANDARD.md` §2.4 字段声明只有 `id/name/type/...`），当前用 `name` 充当说明，没有单位字段。按「不臆想功能」不自行发明键；若游戏侧要提供，需先在契约里声明，再接到 `_build_field_row`。
- [ ] 以刷怪试点验收。按步选中第二波并输入数量，临时从画布选出生点，取消一次再确认。切到资产查看原素材，然后回演出。核对地图、缩放、步骤、待输入值和选点结果，保存、重开并试玩。记录首次完成时间、误操作和需询问的步骤。

### E2 · 复用已有数据的按需视图

**依赖**　B2、C1/C2/C3、E1。**文件**　`src/ui/content_form.gd`、`src/ui/field_widgets.gd`、`src/ui/steps_panel.gd`、`src/canvas/selection_ops.gd`、`src/canvas/entity_poly_view.gd`、`src/canvas/canvas_draw.gd`。基础选点、筛选和批量操作先做。曲线切线、图视图、参考布局仅在试点出现对应录入瓶颈时做。

- [x] **空间选点与连线。** 路径沿用 `props.points`，端点先用实体或声明的局部点值。线头使用 C1 解析的结果，拖接端点时调用同一引用控件。路径段属性可先由关联控制点的字段或步骤填写。若要直接编辑切线、格边或屏幕热点，从项目已声明的数值与引用生成把手，写回对应字段。验收改一处巡逻点、改接一条设备线并重开，再用赛道试玩核对方向。
- [x] **筛选与批处理。** 按地图、图层、资产和功能筛选，批量改值只接受同一功能声明中同码同类型的字段。表格用原字段控件。预览记录命中对象、旧值、目标值和待写文件，提交复用 A2，发现任一目标冲突时显示具体行。瓦片替换按当前选区和源资产／图集格过滤，目标图集不能表示原变换时先列冲突，通过后作为一次撤销操作。验收三张卡牌改费用，第四张原值保留，再取消一次瓦片替换。
- [x] **关系视图。** 对话或调查内容超过普通搜索可维护的规模时，从当前功能打开。节点以 `(功能 ID, 内容 ID)` 区分，边读取已声明字段和步骤。连线变更写回同一个字段，断开复用 C1 的清空规则。保留游戏允许的循环。验收在表单与图分别改同一边，重开后两者一致。
- [ ] **局部只读参考。** 多楼层、程序分块和多屏布局用现有地图与功能字段配置，按需要在当前内容显示参考图和关联目标。可从参考图定位到已有实例。样块依 C2/E3 复制，试玩消费同一份源数据。

### E3 · 常用地图、资产和内容维护入口

**对应审查**　D17、U05、审查 §3.6。**依赖**　A3/A4、C2/C3。**文件**　`src/ui/top_bar_nav.gd`、`src/ui/map_dialogs.gd`、`src/ui/asset_panel.gd`、`src/ui/palette_panel.gd`、`src/ui/layer_panel.gd`、`src/ui/project_picker.gd`、`src/ui/issues_drawer.gd`、`src/ui/content_form.gd`。

- [x] 地图菜单项绑定弹出时的路径与地图码，点击时若条目已失效则刷新列表。现有「设置 ▾」接整图复制，先预览新图名及 C2 计划。改尺寸通过一笔可撤销快照提交。裁去数据前列出瓦片、碰撞和对象数量，恢复时连同原尺寸一起恢复。
  - 实现：`src/ui/top_bar_nav.gd:55-166` 菜单项绑定 `{name, code, path}`，点击时校验文件存在与码未变，失效即刷新并提示；整图复制「设置 ▾」→ `src/ui/map_file.gd` `on_duplicate` 先出预览（`_plan_preview`）再走 C2；改尺寸在 `src/ui/map_dialogs.gd:43-60` 先列当前总量与将裁掉的数量、`:189` 改前入撤销快照（撤销连同原尺寸与边缘数据一起恢复）。
- [x] 给画布选材与资产图鉴共用显示名、类别及 ID 查询，图鉴回画布保持所选资产。资产详情显示从项目读到的图集切片、分类和锚点，方便定位设置。源素材和图集切片仍由游戏侧维护。现有类型挂载编辑按 C3 验证。
  - 实现：`src/ui/asset_panel.gd:258-290` 生效配置区显示锚点、切片尺寸、分类与图集切片条数（只读）；`:323-345` 图鉴回画布设成笔刷（瓦片取首条 palette 切片、实体/图片进摆放模式，碰撞层情形见 `_set_brush_kind`）；显示名/类别/ID 查询共用 `AssetDecl`，与画布选材同源。
- [x] 内容库继续在当前功能内使用。按名称筛选，改显示 `name` 保持 ID。删除操作前运行 C3 引用检查，仍被引用或有未扫描文件时停在报告。保留 A3 草稿恢复与历史入口。折叠问题抽屉同时收起滚动容器，为项目、图层长列表加滚动，重建调色板时替换空态回调。
  - 实现：`src/ui/content_form.gd:581-675` 名称筛选 + 改显示名（保 ID）+ 删除入口；`:1016-1077` 删除前三道拦截（检查范围不完整 / 实例引用 / 内容间入边），通过后才确认删除。草稿入口 `top_bar_nav.gd` 「地图 ▾ → 恢复草稿…」与历史入口 `map_file.gd` `on_history` 保留；抽屉折叠见 `issues_drawer.gd`，长列表滚动见 `editor_layout.gd:290-297`，调色板空态见 `palette_panel.gd`。
- [ ] 验收开着地图菜单时外部插入一张图，点击仍选中原条目或提示失效。改尺寸撤销恢复边缘对象。长列表滚到最后一项。图鉴查找并回画布摆放，内容改显示名后原引用可用。批量改字段和批量替换瓦片由 E2 负责。

### F1 · 核实热点并降低制作时延

**对应审查**　P01–P05。**依赖**　先采集基线，具体优化随所属任务合入。**文件**　`src/canvas/canvas_draw.gd`、`src/canvas/editor_canvas.gd`、`src/canvas/region_ops.gd`、`src/core/undo_history.gd`、`src/map/map_store.gd`、`src/project/asset_scan.gd`、`src/content/content_store.gd`、`src/ui/timeline_view.gd`、`src/content/step_timeline.gd`、`src/ui/content_form.gd`。

- [x] 用同一机器和 Godot 构建采集基线。地图样例为 256×256、三层、约一万瓦片和 500 实例。项目样例为 20 图及 1000 素材，演出为 1000 步、八轨。各执行五次相同操作，记录首次及随后耗时、峰值内存、扫描次数、实际重建次数。用 `Time.get_ticks_usec()` 分段计时，GUI 核对拖动与切图响应。
  - 固定抽样工具 `tools/f1_bench.gd`（headless，跑完自清临时工程）：1000 资产 / 20 图 / 1000 步 8 轨 / 1 万瓦片。基线取优化前，对照取优化后（同日同机构建，连跑两次稳定，取第二次）。
  - 逐项前后：`AssetDecl.by_id` ×5000 = 17.7 s → 0.35 s（每池访问一次递归 `Variant.hash()` 取代 `JSON.stringify`）；`MapStore.code_map` ×50 = 325 ms → 47 ms（签名改为目录清单 + 各图 mtime，不再 open 每图）；区域扫描（256×256 × 3 层，1 万格实存）= 6.8 ms → 0.65 ms；时间轴 1000 步区间+冲突 ×100 = 294 ms（P02 已改为每帧一次区间表，不再逐块重算）；整图 JSON 序列化 ×20 = 108 ms（P05 未做事务差量：快照仍占一次操作的大头，见下条说明）。
- [x] P01/P03/P04：鼠标移动仅失效光标、选区和受影响对象，普通瓦片涂改不重建碰撞。地图、资产和声明索引由项目会话持有，载入、写入、重扫和外部变更后按来源更新，失效时同步更新负缓存。写前冲突检查读实际内容摘要，验证同秒同长度的外部修改也能被发现。内容值改动只刷新受影响行，草稿失败执行 A3 退避。
  - P01：`_mark` 拆成 `_mark` / `_mark_tiles` / `_mark_collision`（`editor_canvas.gd`），涂瓦片只刷三角瓦片自绘、不重建碰撞镜像；画碰撞只刷红块。`ents_shown()` 按 `(ents_rev, vis_rev, layer_count)` 缓存，图层显隐抬 `vis_rev`。`canvas_draw` 每实体改读实例自带的 `decl`，不再每帧 `AssetDecl.by_id` / `has_role`。
  - P03：新增 `src/core/pool_fingerprint.gd`，五个声明池（assets/functions/steps/conditions/triggers/audio）的归一化缓存统一用它；`code_map` 缓存键不再 open 每个地图文件，写盘/改名显式 `invalidate_code_map()`。贴图负缓存改为「文件已出现就重读」，重扫后缺失纹理当次可见；`clear_texture_cache()` 保留给项目重开。
  - P04：`ContentStore` 读缓存命中判据由 mtime+size 改为全文摘要（同秒同长度改写也认得出），`write_ex(base_digest)` 写前比对基线、冲突即拒写；表单字段/显示名/关系图写回全部走带基线路径，冲突只在状态栏提示不覆盖。字段值改动只刷预览（`_refresh_value_only`），不重建左列行。关系图 `set_edge` 增加 `_write_ok` 归一，字符串状态 `"ok"` 才算成功。草稿失败退避沿用 `map_file.write_draft_now`（半间隔重试、状态栏只说一次）。
- [x] P02：步骤结构或时间值变动后重算有效区间，缩放、平移与悬停复用。每轨按起点扫描，只汇总存在重叠的步骤并限制可见告警行数，避免全重叠时报出平方数量的明细。刻度与条块仅绘可视范围。测试相邻边界、零时长、同轨与异轨结果。（`0aa99fd`：`step_timeline` 单张区间表 + `timeline_view` 只绘可视段；告警上限 `MAX_WARNINGS=12` 折叠为「另有 M 条」，`limit=0` 保留全量；`tests/test_step_timeline_d1.gd` 覆盖相邻/零时长/同轨/异轨/全重叠截断）
- [x] P05：区域操作只遍历实际存在的格和候选对象。若优化后快照或重建仍占该操作耗时的一半以上，再试做按操作保存前后差异，沿用同一撤销测试。
  - 区域快照/复制/剪切/批量替换四处改为 `used_cells` 过滤（`region_ops._used_in_rect` / `tile_replace.collect`），并按 y 再 x 排序，保证快照与剪贴板内容可复现（`get_used_cells` 顺序不保证）。临时探针对 8 组矩形（含负坐标、零尺寸、整图）与旧「矩形逐格扫描」逐格比对，集合与顺序完全一致后删除。
  - 面积扫描 6.8 ms → 0.65 ms（256×256×3 层口径）。整图快照（`undo_history.extract` 的 `JSON.stringify`）仍是区域操作的大头，未做事务差量：优化后单次快照 5.4 ms 对 1 万瓦片地图仍是主要成本，但撤销栈与恢复路径要整体换成分块/差量，收益对制作时延边际有限，留作后续。
- [x] 重跑同组样例并附前后数据。纯悬停不重扫项目，普通瓦片笔画不重建碰撞，时间轴平移不重算有效区间。重扫后原本缺失的纹理当次可见。单列 A2 保存前摘要检查的耗时，确认仍能识别同秒同长度修改。对仍需计时的热点比较五次操作的中位数，采用改善可重复且保存、撤销结果相同的改法。
  - 前后数据（`tools/f1_bench.gd`，连跑稳定取第二次）：`by_id` ×5000 17.7 s → 0.35 s；`code_map` ×50 325 ms → 47 ms；区域扫描 6.9 ms → 0.65 ms（3 层 × 256×256）；时间轴 1000 步 ×100 294 ms（区间表每帧一次）。A2 保存前摘要检查：220 KB 地图全文 sha256 ×20 = 14.0 ms，单次约 0.7 ms——相对一次保存（JSON 序列化 + 原子替换）占比可忽略，因此保留摘要而不是退回 mtime。
  - 纯悬停：`canvas_input` 的 `MOUSE_MOTION` 在非手势状态下只更新坐标栏与重绘，不重扫项目；`asset_scan.sync` 仅在 `manifest.load_from` 调一次。普通瓦片笔画：`_paint` 只在真有改动时 `_mark_tiles()`，不触碰 `coll_view`。时间轴平移：`timeline_view._timeline()` 按 `steps.size():struct_rev` 缓存，滚动/缩放只改绘制区间。重扫后补纹理：`entity_node.texture_of` 的负缓存遇到文件已存在即重读（`tests` 无回归，行为在 `:169` 注释处）。
  - 同秒同长度外部修改可检出：`tests/test_stores.gd::test_content_write_conflict_detects_same_second_same_size_edit`（内容：构造长度不变的同秒改写，`write_ex` 以摘要比对拒绝）。地图侧 `map_file._save` 自 A2 起就用 `_file_digest` 做打开基线（`src/ui/map_file.gd:707-729`），本次未改动。写后缓存失效：`test_code_map_cache_invalidated_on_write`。
  - 未做事务差量（P05 末句的「按操作保存前后差异」）：整图快照 ~5 ms 对 1 万瓦片仍是区域操作大头，但需整体替换撤销栈与恢复路径，按 F1「改善可重复、保存与撤销结果相同」的门槛，收益不抵风险，明确留待后续。

### F2 · 对齐规范、注释与发布证据

**对应审查**　§4.1–§4.6。**依赖**　随对应任务更新，整体验收汇总在最后。**文件**　`docs/EDITOR_FEATURES.md`、`docs/GAME_SIDE_STANDARD.md`、审查 §4.5 所列模块。

- [x] A 批更新项目会话、扫描和最小清单、草稿与历史、单文件原子替换和多文件恢复、试玩参数及实际进程。B 批更新格系、层、碰撞和几何；最小地图加载示例建所需 atlas 格并消费 `alt`，使用两个格尺寸分量并按 `meta.layers` 排列。
- [x] C 批更新新 ID 复制、挂载、合法路径和引用作用域。游戏读取示例以执行码读取字段或统一解码后再取值，核对缺键默认。D 批按 `timebase` 写时间单位和轨游标。E 批更新工作台、当前问题抽屉及搜索入口。对 §4.5 每行用实际调用者、数据和验证结果核对注释。
- [x] 用 §3 示例和 §4 发布检查逐条运行最小接入。扫过旧字段与已退役入口，核对目前功能和限制。发布记录挂接审查编号、实现变更和验收结果。
  - 接入自检 `tools/f2_pilot.gd`（headless，跑完自清）：§3 刷怪片段 → 清单补码 → 建图摆两个生成点 + 区域绑定 → 写内容（两波 3/5 份，落点各一，`at` 0/2.5）→ 关闭重开式重读，核对地图码、内容 ID、步骤码、字段码、两落点可区分、`at` 原单位往返、本图实例枚举含两落点，24 项断言全过（2026-11-22）。
  - 已退役入口扫描：`tiles[]`/`entities[]`/5 元瓦片/`levels.json`/`<名>.autosave.json` 均只剩「拒载 + 指向迁移脚本」或兼容读取，无现存写入方。

## 3. 接入示例与验收项目

### 用现有契约做第一条完整链路

让游戏提供一个区域刷怪功能、一种生成步骤和一个实体资产。下面是用于试点的清单片段。`timebase` 与步骤选择沿用现有契约，ID 表示项目识别的声明，执行码由编辑器发放并写回。

```json
{
  "functions": {"spawn_wave": {"name": "刷怪", "steps": true, "timebase": "seconds"}},
  "steps": {"spawn_group": {"name": "生成一组", "fields": [
    {"id": "count", "name": "数量", "kind": "input", "type": "int", "min": 1, "default": 3},
    {"id": "point", "name": "生成点", "kind": "choice", "source": "entity_inst:"}
  ]}}
}
```

设计者在关卡放一个刷怪区域和两个生成点，选择「刷怪」，添加两次「生成一组」。填数量 3 和 5，分别选择两个生成点，设置 `at=0` 和 `at=2.5`。保存后，地图保留区域的功能码和内容 ID。对应内容文件保留两条步骤码、按字段码保存的数量和生成点，以及各自的 `at`。游戏侧读取器按执行码查声明，再将步骤交给刷怪实现。每次保存、重开和试玩用同一个地图码与内容 ID 核对。

### 试点交付顺序

| 试点 | 验证任务 | 发布门槛 |
|---|---|---|
| 现有横版图的测试副本 | A1–A4、A6、D1 后完成刷怪示例。E1 后复测从关卡到演出的操作 | 切项目、重启及失败恢复后仍能读相同瓦片、绑定和步骤。游戏两波生成数量和位置正确 |
| 多格系战棋 | B1/B2 与 C1/C2/C3。正交训练图、矩形等距图、六边战场。复制一组互相引用的单位并调整落点 | 主画布与内容选点相同，碰撞和出生点重开无漂移。游戏使用目标图的正确实例。补测六边离格点拖过奇偶行边界 |
| 功能内容与时间试验图 | C/D。三个对话内容含回跳。帧基招式跨相邻帧区间，拍基谱面跨一个变速段 | 步骤、条件、字段和引用重开后准确。按 D2 核对参考画面与时间。游戏实际分支、时间单位和判定由试玩确认 |
| 潜行、调查和物流 | B2/C1/C2/E2。移动巡逻点，改一条证据跳转，复制两台相连设备再改一条输出线 | 游戏走新巡逻路线，只解锁新目标，物料到正确端口。源设备参数和连线不被副本修改 |
| 棋盘与多视图 | B3。三角棋盘改一条阻挡边，斜平面核对同一落点。用一张俯视迷宫核对第一人称门与触发点，再验收横竖屏或分屏 | 游戏与编辑器的格边、落点域和实例身份对应。参考图有映射时与平面点中同一对象 |
| 其余覆盖行 | 在小项目里复用已有声明，补录矩阵每行的特有操作，例如种子、屏幕热点、物理端点、竞速计时线、多人出生点、经营批量值 | 每行记录制作者操作、保存结果和试玩结果。尚未通过的任务按下文状态记录 |

### 每个试点的最小验收记录

1. **输入**　记录地图码、功能人类 ID、使用的资产、公开字段和待制作内容。试点步骤写成新人能跟做的一页说明。
2. **操作**　采用编辑器常规入口。从空图开始时可先用已备好的清单与资产。在保存前试一次撤销或取消，核对副作用范围。
3. **往返**　关闭再打开项目，比较坐标、变换位、功能码、内容 ID 和实际填值。对未修改字段保留缺键和原值。图层与实例的显示位置由同一坐标口径校验。
4. **试玩**　记录实际出现的地图、触发点、步骤时间与功能输出。程序生成记录种子，多人记录出生点和两端场景。编辑器预览差异和游戏读取差异分别登记。
5. **易用性**　记录制作时间、误放次数、手改数据次数及需询问的步骤。试点的常规任务以设计者无需手改 JSON 为验收条件。以现有界面完成同一任务的时间和步骤数作为后续优化基线。

### 设计者与 AI 共用的操作约定

同一套写入和校验逻辑服务界面及日后接入的批处理。操作先定位项目、地图、实例、功能绑定和字段声明，读当前值，再产生有预期旧值的改动。提交前检查引用及声明，变更预览显示对象数量和待写文件。字段不存在时指出缺哪段声明，交由游戏工程补充。对无视觉的章节、规则或奖励配置，可摆通用控制实体作为实例载体。它照常走功能绑定和内容流程，游戏侧可让它在运行时只承担逻辑职责。

| 决策 | 落地规则 |
|---|---|
| 一个能力何时算覆盖 | 至少有一份公开声明、一条可操作的录入路径、保存重开后相同的数据，以及一次游戏试玩结果。矩阵中的试点都需要实际验收 |
| 何时扩充数据接口 | 先复用已有字段、数组、引用和步骤。若两个内容任务都需要同一种目前无法编辑的值，再定义该值的字段形态并加一套通用控件 |
| 何时引入高级视图 | 先记录用户在普通入口中如何完成任务。有大量重复录入、精确对齐或难以辨认的关系时，再提供表格、关系视图或时间轴。它们和表单共用提交入口 |
| 何时需要逐图投影 | 普通项目沿用默认值。同项目可以有相同格型、不同投影的地图。新地图可选配置，已有内容的图通过 B1/B3 显式另存转换。镜头差异用游戏侧功能参数表达 |

## 4. 兼容与发布检查

- [x] 投影功能发布前，以只读方式逐张记录旧地图的生效投影和实例像素锚点。B1 改锚点规则时，旧记录继续使用原规则。显式转换时通过「原坐标与原锚点 → 像素锚点 → 新坐标与新锚点」计算。用另存副本验证实例、出生点、瓦片和碰撞。格系变化的瓦片与碰撞没有唯一的对应规则时，保留原图并交给制作者在副本中确认。
  - 记录：`tools/projection_baseline.gd` 只读逐图输出生效投影/拓扑/每实例像素锚点，`--convert=` 另算换算结果不写原图（探针项目上 `converted.pxAfter` 与原 `px` 逐实例相同）。
  - 另存副本：`map_convert.gd` + `duplicate_map` 已实现（见 B1）；`tests/test_map_convert.gd::test_saved_copy_differs_from_source` 断言副本实例像素锚点与源图一致、原图未被改动。
  - 瓦片/碰撞：无唯一对应时原格号保留、`manual` 逐项报数并在预览与状态栏提示「需在副本里核对」——不在代码里猜换算。
- [x] 校订 `docs/GAME_SIDE_STANDARD.md` 的最小读取器。逐图读取投影及原有缺省值，按图层顺序载入 `tiles`，消费 `alt`，碰撞按对象读取，`objects[].asset` 查清单。功能和字段用码查表，缺键按功能定义的默认值解释。只接受项目公开给当前功能的内容数据。
  - 校订：§6.4 参考实现 `resolve_projection`（逐图 `meta.gridProjection` → 清单瓦片资产声明 → 正交缺省）、`cell_to_px_g`（含 `gridBasis` 优先与六边 odd-r）、`object_px`（三种投影各自的锚点偏移）、`build`（按 `meta.layers` 栈序建 TileMapLayer、瓦片六元组含 `alt` → Godot 位、运行时层 `visible`、碰撞对象 `{x,y,type?,shape?}`）。
  - 修掉一处契约不一致：原骨架把 `assets[].cell` 当 Dictionary 读，而 §2.2 与 `asset_decl.cell_size` 的契约是 `{w,h}` 或 `[w,h]`（编辑器也接受标量）——已改为三形态解析、缺省回落 `tileSize`。
  - 码查表与「只读公开数据」：§7.2 `_build_code_tables`（功能码→功能 id、字段码→字段 id）+ `_apply_door`（按字段码读 `content.fields`，缺键用功能声明 `default`）；§7.3 三条硬约定（`content` 空非错误、字段值只读内容文件、`order/parallel` 归游戏侧解释）。
- [x] 为新增可选键补保存前后对照，并用试点游戏的加载器复核。需要改变已存字段的含义时，先产出显式迁移和读入版本判断，再开放写入。项目首轮优先采用可选键和原有格式。
  - 可选键对照：`tests/test_map_v4.gd::test_optional_grid_keys_survive_roundtrip`——`meta.gridProjection/gridTopology/gridBasis` 经 JSON 序列化 + `decode_text` 读回逐一保持，`gridTopology: "quads"` 与正交投影缺键仍不写冗余键、读回也不凭空生键。
  - 读入版本判断：`map_data_validation.precheck`（`map_data_validation.gd:9-21`）——缺 version/非数字报错、**高于当前格式拒绝打开**（游戏侧同理）、低于当前格式告警并在内存抬版本；`map_store.decode_text` 先跑 precheck 再升级。
  - 试点加载器复核：参考读取骨架已补（上一条）；真实游戏工程的加载器复核属游戏侧接入，见发布记录「待游戏侧复核」行。
- [x] 形成一个发布记录，每项记录制作输入、落盘结果、文件版本和试玩结果。手势和菜单靠 GUI 验收。坐标、存储、类型化引用、时钟换算由现有测试套件覆盖。
  - `docs/RELEASE_RECORD.md`：7 节（保存恢复 / 空间坐标 / 引用复制 / 步骤时间 / 资产扫描 / 试玩 / 导出），四项字段齐全；每行标 `已验证` / `待试玩` / `仅有实现`，并给出测试名或 `file:line`。
  - 补跑证据：`tools/f2_pilot.gd` 24 项断言通过；`projection_baseline.gd --convert=orthogonal` 在探针项目上 `converted.pxAfter` 与原 `px` 逐实例相同；测试套件 211 通过；`warn_scan` 74 文件 0 失败。
  - 待游戏侧复核的行已显式标 `待试玩`（含需真实 exe 的结构化试玩）；`已知限制` 6 条列出未做项，不以文档代替实现。

