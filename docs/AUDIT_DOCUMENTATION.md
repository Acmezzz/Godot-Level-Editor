# 初版代码审查 · 任务一：文档 / 开发规范 / 代码注释一致性

> 核对方法：**只把 `src/**/*.gd` 的实际实现当作事实来源**，文档与注释一律视为「待验证的断言」。
> 每条结论都给出「文档行号 ↔ 代码行号」的双向锚点；判定为 `[OK] 一致` / `[NG] 不符` / `△ 表述不完整或过时` / `! 文档内部自相矛盾`。
> 本文不评价功能好坏（那是《AUDIT_CODE.md》与《AUDIT_2D_CAPABILITY.md》的事），只回答「写的和做的是否一回事」。

---

## 0. 结论速览

| 审查对象 | 总体判定 | 要点 |
|---|---|---|
| `EDITOR_FEATURES.md` | **基本对齐，但有 8 处过时/失真** | 主体架构描述（清单驱动、三视图、五段身份码、层栈、时间轴）与实现吻合；失真集中在**字段类型清单、collision 校验口径、删层语义、map_ref 口径、写盘路径表述、平台限制披露** |
| `GAME_SIDE_STANDARD.md` | **主体契约正确，但有 5 处硬错误** | 数据契约（v7 六元瓦片、objects[]、码表、props 保留策略、校验粒度）大体准确；硬错误是 **`of` 键"不读"、删层语义、地图名保留名清单、`_ensure_code` 位置、map_ref 校验口径** |
| 代码头注释 / 模块注释 | **约 1/3 存在失实或过时** | 拆分重构后残留的路径注释、格式版本残留、"承诺了但未实现"的能力描述是主要问题；也有相当一部分注释准确甚至自认局限（正例） |

**最需要警惕的一类**：`project_audit.gd` / `grid_space.gd` / `editor_canvas.gd` 的头注释描述了**并不存在的能力**。这正好印证「不能相信注释」——若按注释推断审计覆盖面，会误以为内容码漂移、混投影都有防护。

---

## 1. `EDITOR_FEATURES.md` 与实际代码对齐核对

### 1.1 逐条问题清单

| 编号 | 文档位置 | 文档断言 | 实际代码 | 判定 |
|---|---|---|---|---|
| D-01 | `:82` 目录树 | 字段控件 `input（string/int/float/bool/color/vector2/range/asset_ref）` | `manifest_validation.gd:17` `INPUT_TYPES` 共 **9 种，含 `array`**；`field_widgets.gd` 有 array 控件分支 | [NG] 过时，漏 `array` |
| D-02 | `:634` §10.1 校验表 | 「字段 `type` 不在 `string/.../asset_ref` \| 错误」 | 同上，白名单含 `array` | [NG] 过时，漏 `array`；且与本文 `:420` §7.1（列了 `array`）自相矛盾 |
| D-03 | `:648` §10.2 校验表 | 「`collision` 条目**不是数值（2–4 元）** \| 错误」 | `map_data_validation.gd:65-79`：collision 条目**必须是对象** `{x,y,type?,shape?}`；`:71` 明确「v5 arrays are retired」，是数值数组才报 error | [NG] v5 旧口径，描述**反了** |
| D-04 | `:263` §4 图层表 | 「删层 = 删内容（该层瓦片与实体一并删，撤销可回）」 | `layer_ops.gd:210-214` 过滤的是退役键 `entities`，`objects[]` 一个没删；实体反被挪到最底层（`editor_canvas.gd:365-369`） | [NG] 与实现不符，见 C-02 |
| D-05 | `:665` §10.3 | 「`map_ref` 指向不存在的**地图文件**」 | `content_form.gd:281-288` 下拉值写 `meta.code`（地图码）；`GAME_SIDE_STANDARD.md:231`、本文 `:711` 也说写码 | ! 文档内部矛盾 + 校验端确实按文件名（C-05） |
| D-08 | `:722` §12 | 「编辑器写盘**只有一条路径**：`editor_canvas.extract()`」 | 地图 JSON 写盘确实统一走 `extract()`（`map_file.gd:196,297,339`）；但 `app.gd:198` 写 `user://settings.cfg`、`content_store.gd` 写内容文件、`app.gd:578` 清单写回、`:539` 试玩 prefs 都绕过 | △ 表述过宽，应改为「**地图数据**写盘只有一条路径」 |
| D-09 | `:716` §12 | 「试玩进程**跟踪**基于 Windows `tasklist` 轮询；其它平台视为一直在运行」 | `playtest.gd:18` 启动本身硬编码 `OS.create_process("cmd", ["/c", cmd])`，无平台分支，非 Windows **启动即失败** | △ 披露不全，遗漏了更严重的启动侧限制 |
| D-10 | `:622-637` §10.1 | 清单校验项共 12 行 | `manifest_validation.gd:267-298` 有 `_validate_playtest()`，但 `:43` 缩进在 `collisionTypes` 分支内、通常不执行（C-06） | △ 校验表未列 playtest 项；且「实现有、文档无」与 D-12 的「文档有、实现无」正好相反 |

### 1.2 确认对齐的部分（避免只挑错）

以下内容逐条核对后**与实现一致**，文档质量较高的部分：

- `:86-89` 「清单驱动」「`app.gd` 与 `editor_canvas.gd` 是两个宿主，只保留引导代码与同名薄包装」→ `app.gd`、`editor_canvas.gd` 的委托结构吻合（`editor_canvas.gd:741-850` 全是薄包装）。
- `:414-440` 内容系统（实例 → 功能 → 内容）：`fn` 写执行码、`content` 空串 = 未填、`order` 即执行顺序、`parallel`/`enabled` 只存取 → `fn_bind.gd`、`content_form.gd` 吻合。
- `:420-422` 字段 `kind` 两分支、`array` 用 `of` 指元素类型、认不出的声明只读展示 → `field_widgets.gd` 吻合。
- `:539` 试玩配置由 `playtest.flags/params` 驱动、值存 `user://playtest_prefs.json`、按地图独立 → 与 `playtest.gd`、`map_file.gd` 的 prefs 逻辑吻合（**结构校验失效是 C-06，不是文档错**）。
- `:561` 「键盘入口唯一在 `app._shortcut_input`，画布在 `SubViewport` 里收不到键盘」→ `app.gd:246-401` 集中处理吻合。
- `:646` 「瓦片条目不是 6 元（x, y, 资产id, atlas_x, atlas_y, alt 0-7）」→ `map_data_validation.gd:52` 与 `undo_history.gd:85` 吻合（**但 `undo_history.gd:70-71` 的注释还写 5 元，见 D-13**）。
- `:713` 正式保存有 `maps/.history/*.1..3` 三轮备份 → `map_store.gd:164-200` 吻合。
- `:715` 「校验只做静态数据检查，不验证运行时可达性」→ 与实现一致，属诚实的自认。
- `:725-726` 等距只覆盖涂刷与格号、幽灵/选区/锚点仍轴对齐、六边形不做 → `grid_space.gd`、`editor_canvas.gd:455-460` 吻合（**是自认局限，不是错误**；但 `:726` 之外另有注释虚报混投影警告，见 D-11）。
- `:727-729` 层参数无编辑控件、碰撞生成不区分声明形状、sortAnchor 只参与数据 → 与 `editor_canvas.gd:279-292`（有预览无控件）、`entity_node.gd` 吻合。

---

## 2. `GAME_SIDE_STANDARD.md` 正确性核对

### 2.1 硬错误（会导致游戏侧按规范接错）

| 编号 | 位置 | 规范断言 | 实际代码 | 后果 |
|---|---|---|---|---|
| **D-17** | `:230` | 「**`of` 键编辑器完全不读（没有解析代码）**。写它只是给人看的注释。」 | `content_editor.gd:532-546`：`:543` `var of := str(fd.get("of", ""))`，`:544` 用它拼 `source = "entity_inst:" + of` 来**限定下拉只列指定类型的实例** | 游戏侧作者若信文档，就不会写 `of` 来限定引用类型，下拉会列出全部实例，引用型字段的编辑体验直接失效。而本文 `:221` 的示例和 `:193-194` 又都把 `of` 当有效声明 → **文档内部也自相矛盾** |
| **D-04** | `:122` | 「删层 = 删内容（该层瓦片与实体一并删除，撤销可回）」 | `layer_ops.gd:210-214` 未删 `objects[]`（C-02） | 游戏侧按规范假设「删层后该层实体引用必然悬空」，实际实体仍在且被改层，运行时引用解析结果不可预期 |
| **D-07** | `:31-32` | 「不是 `CON/PRN/AUX/NUL`。**游戏侧拼路径前照此校验**」 | `manifest.gd:47-52` 的保留名清单还含 **`com1`–`com9`、`lpt1`–`lpt9`**，且 `:51` 用 `stem == reserved or stem.begins_with(reserved + ".")` 处理带扩展名的情况 | 规范给游戏侧的校验规则不完整：按文档实现会漏掉 `COM1`/`LPT1` 等 Windows 保留设备名，在 Windows 上创建这类地图文件会失败 |
| **D-06** | `:654` | 「实例码分配规则（`_ensure_code`，**editor_canvas.gd**）」 | `_ensure_code` / `_fresh_inst_code` 定义在 `src/canvas/entity_factory.gd:81,88`；`editor_canvas.gd:850` 仅是转发 `return _entity_factory_ctrl._ensure_code(n)` | 指错文件，游戏侧排查码分配时找不到实现 |
| **D-05** | `:231` | 「`map_ref`（值 = 地图码，下拉列图名，v7）」 | 生产端 `content_form.gd:286` 确实写码 [OK]；校验端 `project_audit.gd:68` 按 `<值>.json` 查文件 [NG]（C-05） | 规范本身写对了，但**编辑器实现没跟上规范**，合法数据被自检误报。修实现而非改规范 |

### 2.2 表述不完整 / 内部口径待统一

| 编号 | 位置 | 说明 |
|---|---|---|
| D-22 | `:215-216` vs `:650-652` | 前者说「**props 只剩几何/引用**，数值类参数一律不进 props」，后者说「游戏侧可以往 `props` 里塞自己的数据，编辑器不认识的键原样保留」。两者语义可调和（前者指编辑器不主动写、后者指不删除），但字面上像矛盾，建议前者明确改成「编辑器**只主动写**几何/引用类键」。代码以 `undo_history.gd:108-112,146`（只丢空值、以 `n.raw.duplicate(true)` 为底）为准，即 `:650-652` 的口径是对的 |
| D-23 | `:231` | 「`type` 其余取值…编辑器同样不特殊处理——按字符串对待」，但 `map_ref`/`entity_ref` 明明有专用下拉（`content_editor.gd:539-546`）。建议把 `entity_ref`/`map_ref` 从「其余取值」里摘出来单独说明 |
| D-24 | `:655` | 「无论复制多少次、引用多少次都不会被复用或**重编**」，而粘贴时会生成**新码**（`selection_ops.gd:275`）。「永不回收」的原意是「旧码不挪作他用」，措辞易被读成「复制保留原码」。建议改成「粘贴/复制产生的是新实例、发新码；旧实例码永不回收、永不复用」 |
| D-25 | `:55-59` | 校验项清单描述与 `manifest_validation.gd` 大体吻合，但**没有提到 `playtest` 校验**（且该校验被 C-06 吞掉），也没提到 `screenSize`/`playCommand`/`godotExe`/`contentDir` 缺结构校验（C-14）。游戏侧会以为配错顶层键会被清单校验拦住 |

### 2.3 确认正确的条款（规范主体是可靠的）

以下条款逐条比对代码后**判定正确**，说明规范的整体设计是站得住的：

| 规范位置 | 断言 | 代码证据 |
|---|---|---|
| `:42` | `tileSize` 必须 > 0，缺省 16 | `manifest_validation.gd:44-46`；`editor_canvas.gd:173` |
| `:45-46` | `tiles`/`entities` 顶层键出现即报错 | `manifest_validation.gd:22-25` |
| `:50` | `contentDir` 不允许 `..` 或绝对路径 | `content_store.gd:root_dir()`（`rel.begins_with("/")`/`contains("..")` 返回 `""`） |
| `:55-59` | 资产 id 空/重复、字段码跨池同码、时机 id/码重复、未声明功能/条件引用报错 | `manifest_validation.gd:52-136,225-243,302-375` |
| `:122` 前半 | 新建层默认插到栈顶之下 | `layer_ops.gd:180-184` `if L.size() >= 2: L.insert(L.size()-1, entry)` [OK] |
| `:186` | 资产 `code` 缺省由编辑器补发并随清单写回 | `manifest.gd:102-110` 调各 `ensure_codes()`，`app.gd:578` 写回 |
| `:194` / `:226-227` | 复制/粘贴按声明重映射实例码；区域粘贴盲替换 | `selection_ops.gd:275-278`（`copied` 映射表）、`region_ops.gd:362-367` `_remap_refs_in` [OK]（但 C-01 令其不可用） |
| `:228` | `fields[].id` 必须非空且唯一 | `manifest_validation.gd:481` `if fid2 == "" or fields.has(fid2)` [OK] |
| `:539` / `:541` / `:606` | `entities[]` 键报错、collision 旧数组形态报错 | `map_data_validation.gd:61-62`、`:71` [OK] |
| `:548` | `meta.code` 4 位地图身份码，改名不改变它 | `map_store.gd:254-276` 纯 rename，不改内容 [OK]（**但复制也不改 = C-04**） |
| `:628-629` | `objects[].asset` 校验、只有 `kind=entity` 能带 `code` | `map_data_validation.gd:139-156` [OK] |
| `:650-652` | props「只丢空值」，未知键/嵌套字典/数组原样保留 | `undo_history.gd:109-112,120,146` [OK] |
| `:677` | 内容文件 `fields` 的键是字段执行码、无回退 | `content_form.gd:68,197` [OK] |

> **对「开发规范文档写的是否正确」的直接回答**：数据契约层（地图/内容/清单的形状、码表、props 保留策略、校验粒度）**写得相当准确**，可以作为游戏侧接入依据；但有 5 处硬错误（D-17 / D-04 / D-07 / D-06 / D-05 的实现侧）和 4 处表述问题，**其中 D-17 影响最大且是纯文档错误**，建议优先修。

---

## 3. 代码注释正确性（头注释 / 模块注释）

> 用户特别要求审查头注释与模块注释。以下按「失实 → 过时 → 正确」分组，全部给出代码锚点。

### 3.1 虚报了不存在的能力（最危险）

| 编号 | 文件:行 | 注释原文 | 实际情况 | 判定 |
|---|---|---|---|---|
| **D-12** | `project_audit.gd:2-3` | 「全项目一致性审计…清单校验 + 地图校验 + **内容码漂移** + 引用悬空」 | `audit():13-29` 只有 3 步，无 `ContentStore`、无内容目录扫描；文件顶部只 preload 了 3 个模块（`:6-8`）。反倒是 `EDITOR_FEATURES.md:664-665` 的描述与实现一致 | [NG] 头注释虚报 |
| **D-11** | `grid_space.gd:4` | 「等距图要求全部瓦片资产同投影（**混投影校验给警告**）」 | `manifest_validation.gd:431-434` 只做 `gridProjection` 枚举值校验；`:431` 的注释自己写「先只做枚举校验」 | [NG] 虚报 |
| **D-11** | `editor_canvas.gd:455` | 「任一瓦片资产声明 isometric 即等距（**混投影由清单校验给警告**）」 | 同上；`:456-460` 实现是静默「任一即等距」，混投影会把正交资产全画错位且无提示 | [NG] 虚报 |
| D-18 | `layer_ops.gd:189` | 「删层 = 删内容：快照上摘掉层声明，**该层瓦片与实体一并过滤**（撤销可回）」 | `:211-214` 过滤的是 `entities`，实体根本没删（C-02） | [NG] 描述不存在的实现 |
| D-19 | `playtest.gd:17` | 「**Windows 下**经 cmd /c 执行整条命令」 | `:18` 无条件 `OS.create_process("cmd", ["/c", cmd])`，无 `OS.get_name()` 分支；`is_alive():27-28` 倒是有平台判断 | [NG] 暗示了不存在的分支 |

### 3.2 格式版本 / 重构路径残留（过时）

| 编号 | 文件:行 | 注释 | 实际 | 判定 |
|---|---|---|---|---|
| **D-13** | `undo_history.gd:70-71` | 「tiles = {层id: [[x,y,资产id,ax,ay]...]」（**5 元**） | `:85` 实际写 6 元 `[c.x, c.y, aid, ac.x, ac.y, alt]`；v7 起第 6 位是变换位（`map_format.gd:16-18`），缺了它变换数据就丢 | [NG] 格式版本残留，且容易误导改动者 |
| **D-14** | `app.gd:40,49,53` | 「core/**editor_state.gd**」「core/**side_actions.gd** 控制器」 | 实际文件是 `src/canvas/editor_state.gd`、`src/map/side_actions.gd`；同一文件 `:73` 的 preload 和 `:687` 的委托注释却写对了 `src/map/side_actions.gd` | [NG] 拆分重构残留，同文件内自相矛盾 |
| **D-15** | `map_format.gd:21-22` | 「Godot 的 alternative_tile 把变换编在**第 12/13 位**（TRANSFORM_FLIP_H/V/TRANSPOSE）」 | 常量是 4096(bit12) / 8192(bit13) / **16384(bit14)**；注释漏了 transpose 的第 14 位，且 `:34/:43` 代码用了错误的 `12288`（C-03） | [NG] 注释与实现**都**错 |
| D-16 | `content_form.gd:211` | 「`entity_inst:<id,id>`…、**map（地图文件）**、audio:」 | `:281-288` 的 `source == "map"` 返回的是 `meta.code`（地图码），`:286` 注释自己写明了「值 = 地图码（v7）」 | [NG] 同文件内口径不一致 |
| D-26 | `map_format.gd:6-8` | v4 段描述 `tiles={层id:[[x,y,atlas,ax,ay]...]}`、`实体 entities[] 加 layer` | 这些是 v4 历史形态，虽然 `:9-17` 有 v5/v6/v7 演进说明，但 `:6-8` 用平铺陈述句、没有显式标注「历史」，读者容易误当现状 | △ 建议改为「历史版本」小节 |
| D-27 | `editor_canvas.gd:348-349` | 「objects[] 统一收场景图片与实体」 | 正确 [OK]，但同段 `:365-369` 的「层找不到落底层」这一**静默改层行为没有任何注释说明**，而它正是 C-02 的帮凶 | △ 缺注释（不是错，是漏） |

### 3.3 确认正确的注释（正例，应保留）

| 文件:行 | 注释 | 核对结果 |
|---|---|---|
| `grid_space.gd:8` | 「六边形不做（能力天花板）」 | [OK] 与 `to_px`/`to_grid` 只有 orthogonal/isometric 两套、`manifest_validation.gd:433` 枚举锁死一致 —— **诚实的自认** |
| `undo_history.gd:20-23` | 「空快照 = extract() 的重建窗口哨兵，恢复它等于清空整图——拒绝」 | [OK] 与 C-07 的竞态分析完全对应，说明作者预见了这个坑，只是层操作链没遵守 |
| `undo_history.gd:68-69` | 「重建窗口期（load_data 的 await 一帧）：不产出快照，防 free 后访问」 | [OK] 与 `editor_canvas.gd:200-209` 的 `await tree.process_frame` 吻合 |
| `map_store.gd:23-24` | 自认「同秒且同尺寸的改动仍无法识别」 | [OK] 与 `_read_cached():25-34` 吻合（C-16 属已知取舍） |
| `map_store.gd:103-104` | 「meta.code 项目内唯一」 | [OK] 契约正确 —— 问题在实现（C-04 复制时没遵守） |
| `editor_canvas.gd:171-172` | 「此前只建 tileset 时读了它，tile_px 本体从不赋值（恒 16）——tileSize≠16 的项目全画布错位」 | [OK] 修复记录，`:173` 已赋值 |
| `undo_history.gd:100-101` | 「以加载时保存的原条目为底（保留游戏侧自定义键）…白名单重建会让未知键在保存时蒸发」 | [OK] 与 `:120` `n.raw.duplicate(true)` 吻合，和 `GAME_SIDE_STANDARD.md:650-652` 一致 |
| `function_decl.gd:29-31` | 「补发缺失的功能码/字段码，只补空的，不碰重复码」 | [OK] 与 `ensure_codes` 实现吻合 |
| `manifest_validation.gd:2-5` | 模块职责描述（清单结构与能力校验） | [OK] 与 `validate():20-47` 覆盖范围吻合（C-06 的缩进 bug 属实现疏漏，不是注释失实） |
| `map_format.gd:9-17` | v5/v6/v7 演进（第 3 位改资产 id、entities 并入 objects、collision 改对象、瓦片 5→6 元） | [OK] 与 `map_data_validation.gd`、`map_store.gd:84-101` 吻合 |
| `content_form.gd:87` | 「码漂移：内容文件的 function 键与当前功能执行码不一致」 | [OK] 概念存在且描述准确 —— 只是这个检查没有进 `project_audit`（C-09） |

### 3.4 注释问题的根因

归纳下来有三类，建议有针对性地治理：

1. **拆分重构残留**：`app.gd:40/49/53` 的 `core/*` 路径、`layer_ops.gd` 的方法转发注释 —— 文件搬过家，注释没跟着改。建议加一条 CI 检查：注释中出现的 `res://` / `*.gd` 路径必须能解析到真实文件。
2. **格式版本残留**：`undo_history.gd:70-71` 的 5 元 tiles、`map_format.gd:6-8` 的 v4 描述 —— 升级到 v7 时只改了代码与部分注释。建议把格式说明**单点收敛**到 `map_format.gd`，其它文件只引用、不复述。
3. **「计划当已完成」**：混投影警告、内容码漂移这两处，注释写的是设计意图而非现状。建议区分 `## TODO` / `## 计划` 与 `## 现状`，或者干脆补上实现（见 C-09 / C-15）。

---

## 4. 建议的文档修订清单（按优先级）

| 优先级 | 动作 | 关联 |
|---|---|---|
| **1** | 修 `GAME_SIDE_STANDARD.md:230`：`of` 键**会被** `content_editor.gd:543` 读取并用于限定下拉类型；同步修 `:221` 示例与 `:193-194` 的口径 | D-17 |
| **1** | 修 `GAME_SIDE_STANDARD.md:31-32`：保留名补全 `com1-9`/`lpt1-9` 与「带扩展名同样命中」规则 | D-07 |
| **1** | `EDITOR_FEATURES.md:648`：改为「collision 条目不是对象 `{x,y}` / 仍是 v5 定长数组 \| 错误」 | D-03 |
| **1** | `EDITOR_FEATURES.md:82` 与 `:634`：字段类型补 `array`（共 9 种） | D-01 / D-02 |
| **1** | `GAME_SIDE_STANDARD.md:122`、`EDITOR_FEATURES.md:263`：删层语义**先按 C-02 修实现**；若决定保留「一并删」契约则文档不动，只修代码 | D-04 |
| **2** | `EDITOR_FEATURES.md:665` 与 `GAME_SIDE_STANDARD.md:231` 统一为「值 = 地图码」；实现按 C-05 改用 `code_map` | D-05 |
| **2** | `project_audit.gd:2-3` 删掉「内容码漂移」，或按 C-09 补实现后保留 | D-12 |
| **2** | `grid_space.gd:4`、`editor_canvas.gd:455` 删掉「混投影给警告」，或按 C-15 补 warning | D-11 |
| **2** | `undo_history.gd:70-71` 改为 6 元；`app.gd:40/49/53` 改真实路径；`map_format.gd:21-22` 改 bit12/13/14 | D-13/14/15 |
| **2** | `EDITOR_FEATURES.md:716` 补「试玩**启动**当前仅 Windows」；`:722` 收窄为「地图数据写盘」；§10.1 补 playtest 校验行 | D-09/08/10 |
| **3** | `GAME_SIDE_STANDARD.md:215/231/655` 措辞统一；`layer_ops.gd:189`、`playtest.gd:17`、`content_form.gd:211` 注释校正 | D-22/23/24/18/19/16 |
| **3** | 建立文档-代码锚点表：每条规范条款标注「由哪个 .gd 的哪个函数保证」，便于后续变更时同步 | 治理建议 |

---

## 5. 本任务的核验边界

- 只核对了 `EDITOR_FEATURES.md`、`GAME_SIDE_STANDARD.md` 与 `src/**/*.gd`；`README.md` 的目录结构 / 验证命令仅作为交叉参考，未逐条校验 `tests/`、`tools/`（用户限定「只需要查看 `src/` 里的代码」，这两个目录不在范围）。
- 文档中的示例 JSON（`GAME_SIDE_STANDARD.md:165-168,243-255,522-539` 等）只做了**结构形状**比对，未逐字段跑解析验证。
- 注释审查覆盖：全部 58 个文件的头注释已提取比对；模块内注释为逐文件阅读时抽查，重点覆盖画布/数据层/校验/试玩/内容表单，**不能声称 100% 行级覆盖**。
- 本机无 Godot，未运行测试；`EDITOR_FEATURES.md:682-698` 列出的测试条目只作为「测试意图」参考，未验证这些测试是否真的通过或覆盖本文发现的问题。
