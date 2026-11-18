# 优化修改重构 — 执行计划（唯一排期真源）

> 日期：2026-11-18
> 状态：**12 批次全部完成**（2026-11-18），12/12 门禁绿；实跑修正已记入 §4.1。
> 汇总来源：三份审查文档（code-review / ux-design-review / feature-review，2026-11-18）已随计划完成删除；条目编号（A/B/T/K/E/F/C/H）的历史出处仅存本计划 §4.1 批次记录；实体-内容模型设计见 design-entity-content-model.md（保留）。
> 规矩：契约变更先改 dev-standard 再实现；每批跑 parse_all + 相关门禁（不新增测试脚本）；
> headless 确认退出；每批独立可交付。

---

## 1. 决策基线（已拍板，实现时以此为准）

### 1.1 资产分层：地形 vs 实体

| 资产类 | 是什么 | 拥有 | 不拥有 |
|---|---|---|---|
| 地形/装饰（tiles 层） | **铺路**，纯视觉 | 图集格、palette 分组 | 行为、字段、交互 |
| 碰撞（grid 层） | 地形的物理语义 | 类型（T1 后：solid/one_way/ladder/hazard/斜坡） | 视觉 |
| 实体（entities 层） | **承载功能**，有交互行为（触发或非触发） | prefab、字段、stats、role、hooks、def | — |

- 分界判据：**游戏里有行为/交互的 → 实体；只负责看的 → 地形**。
  血药、跳台、存档点 = 实体（原生功能）；trigger_zone 无图但有行为 = 实体（builtin 特例）。
- UI 上调色板两页签已是此分界的体现；此表进 dev-standard（批次 0）。

### 1.2 ID 与命名分离

- **ID = 游戏端身份**：稳定、参与引用、机器优先，一经引用尽量不变。
- **命名 name = 给开发者看**：显示名（中文随意），随时可改，永不参与引用。
- 实现面：dialogues/events/shops 资源补可选 `name` 字段（defs 已有）；
  内容库列表/抽屉徽章/校验条目 **名称优先显示、id 弱化为副文本**；搜索两者都匹配；
  新建资源时允许自定义语义短名（默认仍 dlg.N 兜底）。

### 1.3 ID 规范（全项目统一，进 dev-standard）

| 对象 | 存储格式 | 示例 | 分配 |
|---|---|---|---|
| 地图 | 文件名（小写蛇形约定） | `tundra_1` | 手填，is_valid_map_name |
| 实体 | `e_<n>`，**图内唯一** | `e_12` | 每图计数器（载图重置）；层级全名=显示组合 |
| 内容组(def) | `grp.<地图>.<实体>` | `grp.tundra_1.e_12` | 创建时自动，后缀去重 |
| 对话/事件/商店 | `<prefix>.<语义短名>[.<n>]` | `dlg.greet` / `dlg.greet.2` | 前缀+短名（可自定），序号去重 |
| flag | 小写蛇形 | `met_blacksmith` | 手填 + 补全（ux A3.3） |
| 物品/能力 | `item.<名>` / 小写词 | `item.ore` / `dash` | 清单 items / abilities 声明 |

### 1.4 实体 ID 方案（受托决策，含论证）

**采用：每图作用域 + 计数器按图重置 + 安全空洞复用 + 层级全名仅作显示组合。**

- **存储** `e_<n>`，图内唯一；**计数器载图重置**（修 canvas.ent_id_counter 跨会话累积——
  现状同一会话先开 A 图再开 B 图，B 图新实体会接着 A 图的号往上排）。
- **层级全名 `tundra_1.e_12` = 显示时组合，不落盘**。把"地图-实体-实例"的层级感
  做进 UI（大纲/属性面板/日志统一显示组合名，搜索支持）；不把地图名烤进存储 id 的原因：
  地图改名需要迁移**所有** entity_ref（其他图出口落点、事件步骤 target），
  侵入面大、收益只是存储美观——用组合显示拿到全部可读性收益，零迁移成本。
- **跨图引用保持 `(target_map, target_point)` 二元组**——全局唯一性由配对达成，
  这正是现有 exit 数据结构，不动。
- **空洞复用（安全版）**：删除实体后的空号，在**引用扫描通过**的前提下复用最小空位
  （扫描范围：全部地图的 entity_ref 类 props + 全部事件步骤的 entity_ref 参数 +
  跨图出口 target_point）。有引用则跳过该号取下一个。依赖 D2 的 read_all 缓存，
  与之同批交付；未做缓存前维持高水位+1（不复用），空洞保留。
- 关联：内容组 id 自动跟随（grp.<地图>.<实体> 已是此形）；trigger_zone/事件对实体 id
  的引用全部不受影响（存储格式不变）。

### 1.5 其余拍板

- **斜坡 = 做**：与 T1 碰撞类型化同一次格式 bump（`[x,y,type,shape]`），游戏侧手感调教另排；
- **多图集 = 做方向已定**：与 T1 同次 bump（`[x,y,atlas,ax,ay]`，缺省 atlas=0）；
- **条件表达式 v2 = 继续推迟**；**地图改名 = 纯 rename + 独立复制**（T16）；
- **实体-内容模型三阶段**照 design 文档执行（role 声明 → teleport 元功能 → hooks 声明化）。

---

## 2. 批次计划

每批给出：工作项（来源编号）｜验收｜预估。验收统一含 parse_all + 指定门禁脚本全绿。

| 批次 | 工作项 | 验收（门禁+手工点） | 预估 |
|---|---|---|---|
| **0 契约先行** | dev-standard：资产分层表、ID 规范 §1.3、name 字段、role/hooks、teleport 动作示例、碰撞类型/斜坡/多图集格式定义；authoring 补 name 用法 | 文档评审 | 半天 |
| **1 正确性小改** | A1 快捷键守卫、A2 validate_all 双参、A4 metadata 索引、A5 草稿过滤、A8 未知 props 保留、F4 死键、B2 press 冗余 push、**计数器按图重置（K26a）** | data_layer+content_model+shortcut；手工：TextEdit 里 Ctrl+Z 不动地图 | 半天 |
| **2 数据安全** | A6 草稿归位、A3 补 flip_h/def_id/ent_id、A7 echo 过滤+重建代数守卫、B3 floori、B2b 释放统一、**K19 轮转备份**、T17 底线明示 | data_layer+regress；手工：草稿保存写回正式名、长按 Ctrl+Z | 一天 |
| **3 模型阶段1** | role 声明（六处硬编码替换+id 回退）、实体资产"实例分布"、editorSize 行（T5）、K7 删除引用检查 | def_regression+data_layer；手工：改清单 role 后连接工具正常、实例分布跳转 | 一天 |
| **4 撤销与一致性** | B1 触发区尺寸撤销、B5 商店契约、B10 effective_stats、B8 删除后重建面板、B9 tileset 键、C1 资产界面 builtin 过滤 | content_model+def_regression+regress | 半天 |
| **5 主循环手感** | 吸管 A1.1、nudge A2.2、Ctrl+D A2.3、图层面板 A1.3、快捷键包 A6、MRU K3 | shortcut_test+regress；手工：Alt 吸管、方向键微调 | 一天 |
| **6 剧情编排** | 步骤排序 A3.1、flag 补全 A3.3、预演 A3.2、内容库搜索 A3.6、**name 显示（§1.2）**、E3/E4 小 UX | content_model+content_panel；手工：预演走分支 | 一天 |
| **7 元功能+试玩** | teleport 动作（游戏侧 schema+执行器）、K25 热重载（游戏侧 R 键）、A5.1 试玩日志（游戏侧写+编辑器尾随） | content_model（schema 校验）；手工：NPC 对话完传走、R 重载 | 一天 |
| **8 校验与安全网** | T23 保存即校验+常驻计数、K24 落点碰撞检查、K13 孤儿资源检测、A4.3 外部变更检测、**K26b 安全空洞复用**（依赖 D2 缓存） | data_layer+content_model；手工：保存出问题角标 | 一天 |
| **9 碰撞类型化+多图集** | T1 `[x,y,type,shape]`、斜坡、K4 `[x,y,atlas,ax,ay]`、T21 校验放开、CollisionView 分色分形、自动碰撞策略扩展 | data_layer+regress；手工：单向平台/斜坡涂刷+游戏侧读 | 两天 |
| **10 体验批次** | D1–D8 缓存化、E2 分帧进度、F3 单击跳转、K18 地图右键管理（含 T16 纯 rename+复制）、T20 清单 UI（bgGroups/items） | data_layer+regress；手工：大项目流畅度 | 两天 |
| **11 契约扩展** | H1 参数 min/max/step、H2 stock 整数化、H4+hooks 阶段3（components.json）、H5 字段类型（enum/bool） | content_model+content_panel | 两天 |
| **12 扫尾批次** | E5-E8/C5/C6 一行级、E1 缩放锚点、A2.1 盖章选中、C2 粘贴重映射、T6 批量挂/摘 def、K10 出口角标、K8 落点语义、B6 导出中立化+tileSize、K22 清单 version、F2/F5/B6 规则文档 | 12 门禁全量 | 半天 |

---

## 3. 依赖关系（决定批次先后）

- 批次 0（契约）→ 批次 3（role）/批次 9（碰撞格式）/批次 11（H4/H5）都读它的定义；
- 批次 1 → 批次 2（A7 的 echo 过滤在 A1 守卫之上合并更稳）；
- 批次 2 的 A3（ent_id 进区域剪贴板）→ 批次 3 的实例分布/引用扫描复用它的数据；
- **K26b 安全空洞复用依赖 read_all 缓存**——批次 8 前先把批次 10 的 D2 缓存拆出来做；
- 批次 9（格式 bump）一次做完碰撞类型+斜坡+多图集，避免两次地图迁移；
- 批次 11 的 hooks 声明化 = design 阶段 3，排在 teleport 元功能（批次 7）见效之后。

---

## 4. 修订审查档案的记录

- feature-review 追加：T24（ID 与命名未分离）、K26（实体 id 跨图累积/空洞，拆 K26a 计数器重置→批次 3 前置、K26b 安全复用→批次 8）；
- feature-review §9.3 拍板项更新：斜坡=做（并入批次 9）、多图集=做（同 bump）、
  改名=纯 rename（批次 10）、能力门禁 T14=方向已定（排批次 9 后或与阶段 2 并行）；
- 其余审查档案不变（编号是稳定引用，只追加不重排）。

### 4.1 进度记录

- 2026-11-18：**批次 0 完成**（dev-standard 九处契约 + authoring name 用法）；
  **批次 1 完成**（A1/A2/A4/A5/A8/F4/B2/K26a）；**批次 2 完成**（A6/A3/A7/B4/B2b/K19/T17）；
  **批次 3 完成**（role_of 助手 + map_validate/cross_map/cross_map_picker/props_panel/level_list/map_store
  六处 role 化 + id 回退；实体资产"实例分布"UI、K7 删除引用检查、T5 editorSize 行）；
  **批次 4 完成**（B1 触发区尺寸撤销、B5 商店库存整数契约、B10 effective_stats 三层合并显示、
  B8 删除后重建面板、B9 tileset 缓存键含 tileSize、C1/B7 图鉴过滤与拒绝删除内置种类）；
  **批次 5 完成**（A1.1 吸管 Alt+左键、A2.2 方向键微调含撤销会话、A2.3 Ctrl+D 原位复制、
  A6 快捷键包（Ctrl+Shift+Z/±缩放/Home 整图入视野/Tab 循环选中/Enter 开抽屉/Ctrl+N/O/Space 平移）、
  A1.3 图层面板（调色板列常驻，行内 👁/🔒）、K3 MRU 瓦片行）；
  **批次 6 完成**（A3.1 步骤 ↑/↓ 排序、A3.3 flag 选择器 + EventModel.declared_flags、
  A3.2 对话预演（纯数据导航，不执行游戏代码）、A3.6 内容库搜索 + name 显示、
  E3 非法数字提示、E4 悬空引用直显）；
  **批次 7 完成**（actions.json 落地含 teleport 元功能声明、PlayLog 试玩日志（游戏侧写
  editor/playtest.log，编辑器退出后尾随显示）、K25 热重载（R=热重载保留状态，F5=完整重启）。
  teleport 执行器待游戏侧内容运行时（§10 对接）建 EventRunner 后接入——契约与编辑器侧已就绪）；
  **批次 8 完成**（D2 read_all mtime 缓存 + 写后失效闭环、T23 保存即校验、
  K24 落点碰撞占位检查、K13 孤儿内容资源检测、A4.3 外部变更检测、K26b 安全空洞复用）。
  每批验收均为 12 门禁全绿（编辑器 10 + bird 2），headless 退出码逐一确认。
- 环境注记：run_gates.ps1 在 Git Bash→powershell 链路下捕获不到 Godot（GUI 子系统）的
  输出与退出码（12 项全部 exit=空），门禁改用 bash 循环直跑逐项验证；脚本保留待 Windows 终端直接使用。
- **批次 9 完成**（地图格式 v3 + 类型化碰撞全链路 + 多图集，12 门禁全绿）：
  - 契约：dev-standard §11 定义 v3——collision `[x,y,type,shape]`（type: solid/one_way/ladder/hazard，
    shape: ""=矩形 / r45/l45 斜坡；solid+矩形缺省零冗余），terrain/decor `[x,y,atlas,ax,ay]`（atlas=源索引）；
  - 编辑器：set_collision_cell 统一写入口（涂刷/擦除/矩形/粘贴/自动生成全走此口，_collision_meta 跟随）；
    CollisionView 按类型分色（solid 红/one_way 琥珀/ladder 青/hazard 品红）+ 斜坡三角形；
    区域剪贴板与撤销快照携带 atlas/type/shape；调色板多图集导航（图集列表→类别→资产）+ MRU 键 "atlas:x,y"；
    顶栏碰撞类型/形状下拉；生成碰撞对话框 one-way 选项；吸管连 atlas 一起吸；
  - bird：MapLoader.build 运行时挂载清单 tiles[1..] 为 TileSet 源（tiles[0]=.tres 源 0 契约保留）；
    类型化碰撞物理——solid+矩形走隐形瓦片（.tres 烘焙物理），one_way/ladder/hazard 走手动节点
    （Area2D 挂组 ladder/hazard，斜坡=CollisionPolygon2D 三角），TypedCollision 容器节点承载；
  - 门禁：data_layer_test 两个过时断言更新（多图集解锁、升级目标 v3）；parse_bird 收入 map_loader；
    undo 快照 version 同步 3。
  - 备注：teleport 执行器仍待游戏侧 EventRunner（§10 对接）。
- **批次 10 完成**（体验优化，12 门禁全绿）：
  - 缓存化：D1 实体缩略图按项目缓存（换项目失效）、D3 ContentStore 文件级 mtime 缓存
    （写/改名/删除显式失效；目录 mtime 在 Windows 上不可靠 → list 不缓存，修订记录）、
    D4 背景预览纹理按 rel 路径缓存、D5 实体 by_id 索引脏标记缓存（_mark/load_data 置脏）、
    D7 调色板瓦片纹理缓存（atlas+cell 键）、D8 空状态 visibility_changed 连接一次；
  - D6 SpinBox 提交时机：4 处 value_changed 只写内存、失焦统一 save_manifest（U-01 原则）；
  - E2 批量导出分帧：每图一帧 await + 状态栏进度（"导出 i/n：名…"）；
  - F3 校验/关卡列表 item_activated → item_clicked（单击即跳转）；
  - K18/T16 地图右键管理：地图列表右键 → PopupMenu（重命名/创建副本）→ 纯 rename
    （MapStore.rename_map/duplicate_map，文件级操作不迁移引用，拍板落地）+ 当前图改名同步 cur_map_name；
  - T20 清单管理界面：新增 src/ui/manifest_panel.gd（bgGroups 图层表单：img/scale/z/alpha/mirror
    增删改 + 组新建；items 表：id/name 增删）+ 顶栏「清单」按钮 + _set_mode("manifest") 模式；
  - 教训：markers 渐进插入要带标记续接（标记在头=后插在前，标记不续接=静默丢失）——
    本批次两次大段插入因模式用错产生孤儿块/顺序颠倒，均靠 rg 验证兜住。
- **批次 11 完成**（契约扩展，12 门禁全绿）：
  - 契约先行：dev-standard §4.1 参数可选 min/max/step（H1）、§5 stock 整数化措辞（H2，代码 B5 已实现）、
    §2.3 字段类型 enum/bool（H5）、§2.4 组件声明化 components.json（H4）；
  - H1：事件编辑器数值参数控件吃声明范围（min/max/step，缺省 ±99999/0.1），值钳制进范围；
  - H2：shop_model 校验（整数且 -1 或 ≥0）+ shop_editor 控件整数化已在批次 3 落地，本批补齐契约文档；
  - H4：def_model 增加声明读取（components.json 声明优先，缺省回退内置常量，向前兼容）——
    components_list/component_kind/component_label/component_multi 四个动态访问器；
    validate/_validate_component/references/content_validate/def_editor 全链路改走声明；
    bird/content/schema/components.json 落地（dialogue/shop/interact_event 三槽位）；
  - H5：属性面板新增 enum（options 下拉）与 bool（开关）字段控件；资产编辑器字段类型选择器补齐两项；
  - 门禁：12/12 全绿；调用链修正（_check_component_refs 补 manifest 参数）记录在案。
- **批次 12 完成**（审查条目扫尾，12 门禁全绿）：
  - 实跑修正（用户验收反馈）：C6 回退——单次居中量取不准裁切内容，恢复两段式（闪烁<裁切）；
    C5 公式修正——漏乘视差系数，按「地图宽×scale+视口宽」双边覆盖；K10 字体改 ThemeDB.fallback_font（Node2D 无 Control 主题接口）。
  - 一行级：E5 背景组选原值不置脏、E6 候选名回退用候选实体 scene、E7 徽章改状态栏、
    E8 空清单清 area 输入框、C6 弹窗单次居中（去 1×1 闪烁）、C5 背景平铺份数按地图+视口动态算；
  - 手感/功能：E1 滚轮缩放以鼠标为锚（公式同 map_thumb）、A2.1 盖章后自动选中（放置→配置不断档）、
    C2 区域粘贴块内引用重映射（id_map + props 深遍历，块外引用不动）、
    T6 批量编辑新增「定义」下拉（挂/摘 def，一个撤销步，bulk_set_def）、
    K10 跨图出口画「↗图名」角标（有 target_map 才画）、K8 落点实体青色描边 + 出生/落点语义分层写进 dev-standard；
  - 导出中立化（B6）：render_preview 签名改图集数组 + tileSize 参数；**修复批次 9 遗留——
    _blit_tile 未按 v3 多图集解析**（5 元条目按 atlas 索引取源）；实体颜色改 scene id 稳定 hash 调色板（不再硬编码游戏实体名）；
  - 契约/文档：K22 清单缺省补 version=1；F2 抽屉「选已有…」常驻（与 EDITOR_FEATURES §8.6 承诺对齐）；
    F5 图层/图集支持面写进 EDITOR_FEATURES §2；B6 内置种类定位规则完整版进 dev-standard；
  - 去向标注：A1.2 瓦片翻转 = 格式 bump 级（第 5 元素 flip），预留到下次格式演进与 rotation 一并做；
    A1.4 装饰联动笔刷 = 审查原文自评「可选增强，先记录不排期」。
  - 至此三份审查文档条目全部闭环：已实施 ~90 条、远期/待拍板/预留项均有明确去向记录。
  - 实跑修正（用户截图实证）：顶栏 20+ 控件单行最小宽超窗口（1792）撑爆根布局——右侧面板
    与顶栏右端一起被窗口裁掉。拆两行：第一行品牌/文件组+模式/试玩，第二行图层/工具/编辑/生成/导出/清单。

- **UI/UX 重构 R1–R4 完成**（2026-11-18；设计依据 uiux-redesign / uiux-review 两份文档已随重构完成删除，
  结论与本条即唯一历史记录；12 门禁全绿 + 截图回归）：
  - R1 项目页：新增 src/ui/project_shell.gd —— 资产/内容/清单三个全屏视图共用一个壳（左列三页签横跳、
    固定「← 返回画布」、状态栏常驻、Esc/Ctrl+S 在输入框内也生效）；app._set_mode 只切 map/project 两大面；
    三个旧视图构建函数合并为 _build_project_view（面板别名保持既有调用点不变）；
    P0 七项随批清零：徽章堆积（_issue_nodes 先清后加）、背景钮（_bg_btn 真正入布局）、manifest 滚动+列头+列宽、
    asset editorSize 爆炸、输入框失焦提交替代每击键写盘、Del 无图守卫、跨图配对加确认框；
  - R2 检查器右栏：新增 src/ui/levels_panel.gd（关卡清单 + 世界拓扑从右栏页签移入项目页清单视图）；
    新增 src/ui/collapsible.gd（结构建在 _init，宿主 add_child 前可填充 body）；
    side_panel 改为 340px 检查器列（标题行 + inspector_slot 挂 props_scroll + 地图列表/实体大纲/校验三折叠区），
    左栏收窄到 252px；旧层/关卡/world 页签逻辑整体删除；
  - R3 工具条+图层单点：顶栏收成单一全局行（品牌+地图名+新建/打开/保存+项目/试玩配置/试玩），
    新增画布工具条（六工具互斥 + 剪切/复制/粘贴 + 导出/尺寸/背景组）与上下文条（笔刷仅涂刷类、
    碰撞类型/形状/生成碰撞/对齐仅碰撞层，其余显示「当前层无额外选项」）；顶栏图层 ●/○ 删除，
    图层面板为显隐/锁定唯一操作面（当前层 ACCENT 高亮）；数字键按工具条顺序重排（4 盖章/5 属性/6 出生点），
    工具钮 tooltip 带键位；工具条包一层横向滚动 —— 修掉「按钮最小宽撑爆根布局、右栏被推出屏幕」的体量问题；
  - R4 抽屉+收口：抽屉 360→480，「放大/还原」切换（上限 620 —— 900 会把检查器挤没，实测侧栏宽度归零）；
    内容库最大宽 720 居中 + 「+ 新建」下沉到列表列头；UiKit 补 popup_buttons/popup_shell/del_button/
    LABEL_W(72)/LABEL_W_LONG(96)/符号常量，field_row 标签宽全库收敛两档；所有自建弹窗补取消/关闭出口
    （批量编辑/对齐/生成碰撞/地图尺寸/导出/选已有/预演/flag 选择）；符号表统一（▶ 只给播放/预演、
    →/↳ 导航、✕ 删除、+ 新建、👁/🔒 图层开关，全角＋与 × 删除混淆清除）；「?」快捷键速查弹窗；
    多选时检查器字段区压暗 + 提示行；enum 字段补 options 编辑列；删除资产无引用时也确认；
    保存即校验有错误时自动展开校验区并填列（不再只报数字）；两处改名入口命名为「改名并迁移引用」/「重命名地图（只改文件名）」；
    审计补漏：清单背景组补「重命名组」（与新建/删除同级，走标准弹窗）、删除组补取消出口约定；
    删除 props_panel 末尾悬空注释、event 编辑器空态与校验错误重复文案；落点选择钮补 tooltip；
  - 门禁（12 项全绿，按 tests/run_gates.ps1 口径）：parse_all / regress / data_layer_test / content_model_test / content_panel_test / def_regression_test / entity_copy_regression_test /
    props_undo_regression_test / portal_mode_regression_test / shortcut_test + bird/parse_bird + bird/launch_args_test.tscn。
    portal_mode_regression_test 随 P0-5 更新：选点后先断言确认框存在且目标图未被写盘，再 emit confirmed 走完流程；
  - 截图回归：tools/screenshot.gd 新增 project / project_content / project_manifest / topbar / help / dock_wide /
    multi_dim 模式与 SHOT_W/SHOT_H 覆盖（1680×946 与 1366×768 两种宽度取证）。
---

## 5. 开发规矩（每批执行时遵守）

1. 契约变更：先改 dev-standard → 再动代码（双方同步改）；
2. 每批结束跑 parse_all + 该批验收列出的门禁脚本，确认 headless 退出；
3. 不新增测试脚本，覆盖并入对应子系统脚本；
4. 文档与实现同时改（docs 三份标准 + 本计划的状态列更新）；
5. 视觉验收由你自测；我提供的"手工验收点"仅是提示清单。
