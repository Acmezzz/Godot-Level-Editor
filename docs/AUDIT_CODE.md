# 初版代码审查 · 任务二：代码缺陷、逻辑错误、优化与基础功能缺失

> 审查对象：`src/**/*.gd`（58 个 GDScript 文件，约 13635 行）
> 审查原则：**只以实际代码为准，不采信注释**。注释只在「注释是否正确」这一项中作为被审查对象。
> 结论分级：**P0** = 静态证据链完整、确定会破坏数据或使核心功能不可用；**P1** = 高风险（概率触发 / 需运行复现 / 平台相关）；**P2** = 优化与一致性；**P3** = 已排除的疑点与改进建议。
> 验证边界：本机未找到 Godot 可执行文件，未运行 `--headless --check-only` 或 `tests/run_tests.gd`，因此**所有"运行时报错"均为静态推断**，见《AUDIT_REPORT.md》第 5 节。

---

## 0. 缺陷总表

| 编号 | 级别 | 一句话 | 主证据 |
|---|---|---|---|
| C-01 | P0 | `cvs._fresh_inst_code()` 方法不存在，复制/粘贴实体必报错 | `selection_ops.gd:275`、`region_ops.gd:195`、`entity_factory.gd:88`、`editor_canvas.gd:845-850` |
| C-02 | P0 | 删层不删实体：操作已退役的 `entities` 键，实体被静默挪到最底层 | `layer_ops.gd:210-214`、`undo_history.gd:170-171`、`editor_canvas.gd:365-369` |
| C-03 | P0 | 瓦片变换位互转用错常量（12288），所有翻转/旋转瓦片保存即损坏、往返不幂等 | `map_format.gd:25-45` |
| C-04 | P0 | 复制地图不重发 `meta.code`，地图身份码重复 | `map_store.gd:279-298` vs `:103-104` |
| C-05 | P0 | `map_ref` 校验按文件名，实际存的是地图码，合法数据被误报 | `project_audit.gd:68,77` vs `content_form.gd:281-288` |
| C-06 | P0 | `_validate_playtest` 缩进在 `collisionTypes` 分支内，playtest 校验静默失效 | `manifest_validation.gd:41-43,267-298` |
| C-07 | P0 | 层操作 `load_data` 漏 `await`，协程被丢弃，撤销链/重建存在竞态 | `layer_ops.gd:42-43,308-311`、`editor_canvas.gd:165-209` |
| C-08 | P1 | 试玩启动硬编码 Windows `cmd /c`，非 Windows 完全不可用 | `playtest.gd:18` |
| C-09 | P1 | 全项目自检不检查内容文件（内容码漂移），且头注释虚报该能力 | `project_audit.gd:2-3` vs `:13-29` |
| C-10 | P1 | 剪切的图层锁定守卫只查激活层，可绕过锁定层 | `selection_ops.gd:224` vs `:314-320,332` |
| C-11 | P1 | `rename_absolute` 覆盖已存在文件的原子写语义需跨平台验证 | `map_store.gd:207-219` |
| C-12 | P1 | `_save_prefs()` 未判 `FileAccess.open` 返回 null | `app.gd:198-201` |
| C-13 | P1 | 区域粘贴连续两次 `_hint`，层名匹配失败警告被覆盖 | `region_ops.gd:369-373` |
| C-14 | P1 | 清单顶层键 `playCommand`/`godotExe`/`contentDir`/`screenSize` 无结构校验 | `manifest_validation.gd:20-47` |
| C-15 | P1 | 混投影一致性警告不存在，静默按等距渲染 | `manifest_validation.gd:431-434`、`editor_canvas.gd:455-460` |
| C-16 | P2 | mtime 秒级 + size 缓存，同秒同尺寸外部改动漏检 | `map_store.gd:25-34,112-135` |
| C-17 | P2 | `code_map` / 内容表单 map 下拉每次全量读盘，O(n) 文件 IO | `map_store.gd:112-135`、`content_form.gd:281-288` |
| C-18 | P2 | 整图 JSON 字符串快照 × 80 步，大图内存与耗时 | `undo_history.gd:12-13,26-32` |
| C-19 | P2 | C-03 连带：`_paint` 判重失效，重复 `set_cell_alt` | `tool_ops.gd`（判重分支） |
| C-20 | P2 | 外部改动只在保存后提示"已覆盖"，不阻止 | `map_file.gd`（mtime 检测分支） |
| C-21 | P3 | `playtest.gd:57-58` 裸换行字符串**合法**（等价 `split("\n")`），非缺陷，仅建议改写法 | `playtest.gd:57-58` |

---

## 1. P0：确定性缺陷

### C-01 `cvs._fresh_inst_code()` 是不存在的方法（复制/粘贴实体必失败）

**证据链**（全库检索 `_fresh_inst_code` 仅 4 处命中）：

```
src/canvas/entity_factory.gd:81      var c := _fresh_inst_code()          # 内部调用
src/canvas/entity_factory.gd:88      func _fresh_inst_code() -> String:   # 唯一定义
src/canvas/region_ops.gd:195         n.code = cvs._fresh_inst_code()      # 外部调用
src/canvas/selection_ops.gd:275      code = cvs._fresh_inst_code()        # 外部调用
```

`editor_canvas.gd` 只委托了三个实体工厂方法（`:845-850`）：

```gdscript
func make_object(aid: String) -> EntityNode:
	return _entity_factory_ctrl.make_object(aid)
func is_placeable(aid: String) -> bool:
	return _entity_factory_ctrl.is_placeable(aid)
func _ensure_code(n: EntityNode) -> void:
	_entity_factory_ctrl._ensure_code(n)
```

**没有** `_fresh_inst_code` 的委托。`cvs` 在这些控制器里是无类型变量（`region_ops.gd:7` `var cvs   # editor_canvas 宿主`），因此不会被静态类型检查拦下，而是在运行时报 `Invalid call. Nonexistent function '_fresh_inst_code' in base 'EditorCanvas'`。

触发面：

- `selection_ops.gd:274-276`：`paste_at()` 中对**每一个** `n.is_entity()` 的副本无条件调用，即 `Ctrl+C` → `Ctrl+V` 粘贴实体 100% 触发。
- `region_ops.gd:195`：区域粘贴时 `if n.is_entity() and n.code == ""` 条件触发。

也就是说「实体复制粘贴」和「区域粘贴含无码实体」两条核心编辑路径当前是不可用的。

**修复**：在 `editor_canvas.gd` 补一行委托（与 `_ensure_code` 并列），或把两个调用点改为 `cvs._entity_factory_ctrl._fresh_inst_code()`：

```gdscript
func _fresh_inst_code() -> String:
	return _entity_factory_ctrl._fresh_inst_code()
```

建议同时补一条 headless 测试：粘贴一个 `kind: entity` 资产，断言新实例码非空且与原码不同。

---

### C-02 删层不删实体：操作已退役的 `entities` 键

**这是文档契约与实现偏差最严重的一处。**

`layer_ops.gd:189-215`：

```gdscript
## 删层 = 删内容：快照上摘掉层声明，该层瓦片与实体一并过滤（撤销可回）。
func layer_del(i: int) -> void:
	...
	var snap := extract()                       # :197
	...
	var tiles: Dictionary = snap.get("tiles", {})
	tiles.erase(lid)                            # :208  ← 瓦片部分正确
	snap["tiles"] = tiles
	var keep := []
	for e in (snap.get("entities", []) as Array):   # :211  ← 错：读的是退役键
		if str((e as Dictionary).get("layer", "")) != lid:
			keep.append(e)
	snap["entities"] = keep                     # :214  ← 错：又写回退役键
	_load_snap_layers(snap, active_id)
```

`extract()` 的实际产物（`undo_history.gd:155-172`）：

```gdscript
var out: Dictionary = cvs.map_data.duplicate(true) ...
out.erase("entities")   # v5：entities 段已并入 objects[]   :170
out["objects"] = olist                                  :171
```

即快照里**只有 `objects`，`entities` 恒不存在**。`snap.get("entities", [])` 恒为 `[]` → `keep` 恒空 → 该层的实体**一个都没被删掉**。`map_data_validation.gd:61-62` 明确把 `entities` Array 判为 `error`（"retired: use objects[]"），说明这个键在当前格式里是非法的。

**三重后果**：

1. **契约破坏**：`EDITOR_FEATURES.md:263` 与 `GAME_SIDE_STANDARD.md:122` 都写「删层 = 删内容（该层瓦片与实体一并删，撤销可回）」，实现只删了瓦片。
2. **实体被静默改层**：`_load_snap_layers` → `cvs.load_data(snap, ...)` → `editor_canvas.gd:351` 遍历 `objects[]`，`:365-369`：

   ```gdscript
   var lid := str((e as Dictionary).get("layer", bottom))
   var ei := _layer_index_of(lid)
   if ei < 0:
   	ei = 0                       # 删掉的层找不到 → 全部落到最底层
   n.layer_id = layer_id(ei)
   ```

   实体的层归属被悄悄改写为最底层，用户视角是"删了层，实体还在、还换了层"，且没有撤销之外的任何提示。
3. **内存态被污染**：`snap["entities"] = []` 随 `load_data` 进入 `cvs.map_data`（`editor_canvas.gd:169`）。正式保存走 `extract()`，会再次 `out.erase("entities")`，所以**不会写进磁盘 JSON**（这一点经核对 `map_file.gd:196,297,339` 均调用 `app.canvas.extract()` 后写盘，确认）。但 `map_data` 内存态携带非法键，任何直接读 `map_data` 的下游（导出 `map_export.gd`、审计、内容视图）都可能误判。

**修复**：

```gdscript
var keep := []
for o in (snap.get("objects", []) as Array):
	if str((o as Dictionary).get("layer", "")) != lid:
		keep.append(o)
snap["objects"] = keep
```

并同步修正 `layer_ops.gd:189` 的注释（它描述了不存在的实现）。建议补测试：删层后断言 `objects[]` 中不再有 `layer == lid` 的条目，且 `extract()` 输出不含 `entities` 键。

> 关联：所有层操作（`layer_del` / `layer_rename` / 上下移 / 层参数）都走 `_load_snap_layers`，因此 C-07 的 await 问题会叠加在同一批路径上。

---

### C-03 瓦片变换位互转错误：任何翻转/旋转瓦片保存后即损坏

`src/map/map_format.gd:20-45`（完整原文）：

```gdscript
const TILE_FLIP_H := 1
const TILE_FLIP_V := 2
const TILE_ROT90 := 4

static func alt_to_godot(f: int) -> int:
	var g := 0
	if f & TILE_FLIP_H:  g |= 4096
	if f & TILE_FLIP_V:  g |= 8192
	if f & TILE_ROT90:   g |= 12288      # :34
	return g

static func alt_of_godot(g: int) -> int:
	var f := 0
	if g & 4096:   f |= TILE_FLIP_H
	if g & 8192:   f |= TILE_FLIP_V
	if g & 12288:  f |= TILE_ROT90       # :43
	return f
```

Godot 4 的 `TileSetAtlasSource` 变换常量为 `TRANSFORM_FLIP_H = 4096`、`TRANSFORM_FLIP_V = 8192`、`TRANSFORM_TRANSPOSE = 16384`。代码用的 `12288 = 4096 | 8192`，**是"水平+垂直同时翻转"（等价 180° 旋转），根本不是 transpose 位**。

两个独立错误：

1. **写方向错**：`alt_to_godot(4)` 得到 `12288`，Godot 会把它渲染成 H+V 双翻转，而不是转置。
2. **读方向更错**：`g & 12288` 是**两位掩码**，`4096` 或 `8192` 任一置位都会为真。所以一个单纯水平翻转的瓦片 `g=4096` 会被读成 `1 | 4 = 5`（凭空多出 ROT90）。

**往返真值表**（实测推导，非注释）：

| 写入 f | `alt_to_godot` → g | `alt_of_godot(g)` → f' | 是否幂等 |
|---|---|---|---|
| 0 | 0 | 0 | 是 |
| 1 (H) | 4096 | **5** | 否 |
| 2 (V) | 8192 | **6** | 否 |
| 3 (H+V) | 12288 | **7** | 否 |
| 4 (转置) | 12288 | **7** | 否 |
| 5 | 12288 | **7** | 否 |
| 6 | 12288 | **7** | 否 |
| 7 | 12288 | 7 | 是（巧合） |

8 种取值里 6 种读回即变。调用链是 `undo_history.gd:84`（`extract()` 把 `alt_of_godot(tn.get_cell_alternative_tile(c))` 写进 JSON 第 6 位）→ 保存 → 下次打开 `alt_to_godot` 设置回 TileMapLayer，因此**每一次「编辑带变换瓦片 → 保存 → 重开」都会破坏变换数据**。

连带问题：`tool_ops.gd` 的 `_paint()` 用 `MapFormat.alt_of_godot(layer.get_cell_alternative_tile(bc)) != cvs.tile_alt` 判断是否需要重涂，判重恒失效 → 重复 `TilesetCache.set_cell_alt`（C-19，产生额外撤销快照与绘制开销）。

**修复**：把 `TILE_ROT90` 对应的 Godot 位改为 `16384`（`alt_to_godot` 的 `g |= 16384`、`alt_of_godot` 的 `if g & 16384`），并把 `map_format.gd:21-22` 注释里的「第 12/13 位」改为「bit 12/13/14」。注意 Godot 的 transpose 与"90° 旋转"并非等价（旋转 = transpose + flip 组合），v7 头注释 `:16-17` 写「bit2 转置(90°)」语义上也不严谨，建议明确为转置。补**往返幂等测试**：对 f = 0..7 断言 `alt_of_godot(alt_to_godot(f)) == f`。

---

### C-04 复制地图不重发 `meta.code`，破坏地图身份码唯一性

`map_store.gd:279-298`：

```gdscript
static func duplicate_map(m, old_name, new_name) -> String:
	...
	var f := FileAccess.open(src, FileAccess.READ)
	var txt := f.get_as_text()
	f.close()
	if not write_text(path_for(m, new_name), txt):   # 纯文本复制
		return "复制写盘失败"
	return ""
```

而同一文件 `:103-104` 声明：

> 地图码（v7）：`meta.code` 4 位码，**项目内唯一**。跨图引用（`target_map` / `map_ref` 字段）写码。

`new_map()`（`:84-101`）会给每张新图发 `ContentId.new_inst_code()`；`ensure_code()`（`:139-149`）在缺码时补发并避开全项目已占码。**唯独 `duplicate_map` 走的是文本直拷，`meta.code` 与原图完全相同。**

后果：

- `code_map()`（`:112-135`）以 `out[c] = str(mn)` 建表，两个同码文件后者覆盖前者 → 跨图引用解析到不确定的一张图。
- 五段身份码「地图-实体类型-实例-功能-内容」的地图段失去唯一性（`content_id.gd`）。
- `GAME_SIDE_STANDARD.md:548` 承诺「4 位地图身份码，编辑器缺省补发。改名不改变它」——改名确实不改（`rename_map` 纯 rename，`:254-276`），但复制也不改，等于制造了两个同身份地图。
- 实例码同样整体复制。`:278` 注释说「内容原样复制，引用不动」，与 `GAME_SIDE_STANDARD.md:226` 的「复制/粘贴时按声明重映射」形成口径差异（一个是文件级复制、一个是画布级粘贴，需明确区分）。

**修复**：复制时不做文本直拷，改为解析 → 重发身份 → 结构化写盘：

```gdscript
var r := read_path(src, m)
if not bool(r.get("ok", false)): return "原图解析失败"
var d: Dictionary = r["data"]
d.get("meta", {})["code"] = <全项目唯一的新码>     # 可复用 ensure_code 的占用表思路
if not write_json(path_for(m, new_name), d): return "复制写盘失败"
```

至少必须重发 `meta.code`；实例码是否重映射需先定契约（建议文件级复制保持实例码不变，但要在文档写清楚"复制图与原图实例码空间独立，跨图引用请写地图码+实例码"）。

---

### C-05 `map_ref` 校验按文件名，实际存的是地图码

**生产端**（`content_form.gd:281-288`）：

```gdscript
if src == "map":
	var out3: Array = []
	for mn in MapStore.list_maps(manifest):
		var md := MapStore.read(manifest, str(mn))
		var mc := str((md.get("meta", {}) as Dictionary).get("code", ""))
		# 值 = 地图码（v7）：改名不破坏引用；老图缺码时退回图名（保存一次即补码）
		out3.append({"v": mc if mc != "" else str(mn), "t": str(mn)})
	return out3
```

**校验端**（`project_audit.gd:68`）：

```gdscript
var ok_target: bool = maps_dir == "" or FileAccess.file_exists(maps_dir.path_join(str(val) + ".json"))
...
elif typ == "map_ref" and not ok_target:
	out.append({... "message": "目标地图不存在: %s" % str(val), ...})
```

下拉写入的是 4 位地图码（如 `K7QM`），校验却去 `<maps_dir>/K7QM.json` 找文件 → **所有合法的 `map_ref` 都会被误报「目标地图不存在」**；反过来若用户手填图名，校验反而通过（但那是违反契约的值）。`GAME_SIDE_STANDARD.md:231` 明确「`map_ref`（值 = 地图码，下拉列图名，v7）」，`EDITOR_FEATURES.md:711` 也写「跨图引用写地图码（`meta.code`）」。

另一个宽松兜底：`maps_dir == ""` 时 `ok_target = true`，即清单未配置 maps 目录时该检查完全放行。

**修复**：用 `MapStore.code_map(manifest)` 返回的 `{code: 图名}` 键集合判定，与 `canvas_draw.gd:159` 解析出口角标的方式保持一致；老图缺码的兼容值（图名）可保留为次级判定。同时修正 `EDITOR_FEATURES.md:665`（详见《AUDIT_DOCUMENTATION.md》D-05）。

---

### C-06 `_validate_playtest` 被错误缩进，playtest 结构校验静默失效

`manifest_validation.gd:20-47` 的 `validate()` 尾部：

```gdscript
	if data.has("triggers"):
		_validate_triggers(data, issues)
	if data.has("collisionTypes"):
		_validate_collision_types(data, issues)
		_validate_playtest(data, issues)        # :43 ← 缩进在 if 内部
	var tile_size = data.get("tileSize", 16)
	...
```

`collisionTypes` 是**可选**键（缺省池，见 `collision_types.gd`），未声明时整个分支跳过，`_validate_playtest()` 永远不执行。而这个函数（`:267-298`）本该检查 `playtest.flags/params` 的：对象形态、id 非空且唯一、name 非空、flags 的 `arg` 非空、params 的 `arg` 必须含 `%d`。

后果：清单声明了试玩配置但没声明 `collisionTypes` 时，配错的 `arg`、重复 id、非对象结构全部静默放过，直到 `EDITOR_FEATURES.md:539` 描述的试玩配置面板渲染/追加参数时才在运行时暴露。

**修复**：把 `_validate_playtest(data, issues)` 提到 `if data.has("collisionTypes")` 之外，与 `tileSize` 检查并列（它与 collisionTypes 无逻辑依赖）。补测试：无 `collisionTypes` + 缺 `arg` 的 flag 应报 error。

> 附带发现：`EDITOR_FEATURES.md:622-637`（§10.1 清单校验表）根本没有列出 playtest 校验项，文档也没承诺这个校验存在 —— 属于「实现有、文档无」，与 C-09 的「文档有、实现无」正好相反。

---

### C-07 层操作 `load_data` 漏 `await`，协程被丢弃

README 的硬约定：**含 `await` 的委托链必须每层 `await`**。

被委托方 `editor_canvas.gd:165-209` 是协程：

```gdscript
func load_data(data, map_name, keep_cam := false, keep_dirty := false) -> void:
	_rebuild_gen += 1
	var gen := _rebuild_gen
	map_data = data                       # :169（await 之前同步执行）
	...
	if map_root:
		map_root.queue_free()
		var tree := get_tree()
		if tree != null:
			await tree.process_frame       # :206 ← 协程挂起点
	if gen != _rebuild_gen:
		return
	map_root = Node2D.new()               # :210 之后才是真正的重建
	...
```

委托方 `layer_ops.gd:42-43`：

```gdscript
func load_data(data, map_name, keep_cam := false, keep_dirty := false) -> void:
	cvs.load_data(data, map_name, keep_cam, keep_dirty)     # 没有 await，返回类型 void
```

以及 `layer_ops.gd:308-311`：

```gdscript
func _load_snap_layers(snap: Dictionary, active_id: String) -> void:
	load_data(snap, cur_map_name, true, true)   # 同样没有 await
	var ni := _layer_index_of(active_id)
	active_layer = ni if ni >= 0 else 0
```

对比正确写法：`undo_history.gd:23` 是 `await cvs.load_data(d, ...)`，`editor_canvas.gd:752` 是 `return await _undo_history_ctrl.undo()` —— 项目其它地方遵守了约定，**唯独层操作这一条链断了**。

**具体风险**（需 Godot 运行复现，故部分归 P1 特征，但违约本身是静态确定的）：

1. `cvs.load_data` 在 `:206` 挂起后立即返回，`_load_snap_layers` 继续往下走。此时 `map_data` 已被换成新快照（`:169` 在 await 前），所以 `_layer_index_of(active_id)` 读 `layers_decl()` 拿到的是**新**层表，这一步尚能工作 —— 这也是该 BUG 容易被漏掉的原因。
2. 但 `map_root` 已 `queue_free()`、新 root 尚未创建，正好落在 `undo_history.gd:68-69` 明确定义的「重建窗口期」：

   ```gdscript
   func extract() -> Dictionary:
   	if cvs.map_root == null or not is_instance_valid(cvs.map_root):
   		return {}   # 重建窗口期（load_data 的 await 一帧）：不产出快照，防 free 后访问
   ```

   连续执行两个层操作时，第二个操作的 `_push_undo()`（`layer_ops.gd:196,224,260...`）会在这个窗口期把 `JSON.stringify({})` 即 `"{}"` 压入撤销栈。`undo_history.gd:20-23` 有「空快照 = 重建窗口哨兵，恢复它等于清空整图——拒绝」的保护，所以**不会真的清空地图**，但会白耗一次撤销：用户按 Ctrl+Z 以为撤销了，画面毫无变化。
3. 被丢弃的协程在下一帧恢复后仍会走 `_rebuild_gen` 检查并可能继续重建（`editor_canvas.gd:208`），两次层操作交错时存在重复重建 / `active_layer` 指向旧下标的窗口。
4. `layer_*` 系列全部经 `_load_snap_layers`（`:187` 新建、`:215` 删除、`:235` 改名、`:263/:284/:305` 移动与参数），因此影响面是**整组层管理操作**。

**修复**（必须整条链一起改，只改一处无效）：

```gdscript
# layer_ops.gd
func load_data(...) -> void:
	await cvs.load_data(data, map_name, keep_cam, keep_dirty)

func _load_snap_layers(snap: Dictionary, active_id: String) -> void:
	await load_data(snap, cur_map_name, true, true)
	var ni := _layer_index_of(active_id)
	active_layer = ni if ni >= 0 else 0
```

所有 `layer_*` 调用点改为 `await _load_snap_layers(...)`，并逐层透传到 UI 事件回调（`layer_panel.gd` / `app.gd`）。另外建议在 `_push_undo()` 里对空快照直接 `return`（`undo_history.gd:26-32` 目前只检查 `map_root`），从根上避免哨兵入栈。

---

## 2. P1：高风险缺陷与基础功能缺失

### C-08 试玩启动硬编码 Windows，非 Windows 完全不可用

`playtest.gd:18`：

```gdscript
var pid := OS.create_process("cmd", ["/c", cmd])
```

**没有任何平台分支**。`:17` 的注释「Windows 下经 cmd /c 执行整条命令」暗示存在判断，实际没有。`is_alive()`（`:27-28`）倒是做了 `OS.get_name().begins_with("Windows")` 分支，说明作者知道要跨平台，但只覆盖了轮询、没覆盖启动。

`EDITOR_FEATURES.md:716` 只披露了「试玩进程跟踪基于 Windows `tasklist` 轮询；其它平台视为一直在运行」，**没有披露启动本身也只在 Windows 可用** —— 文档披露不全（D-09）。

后果：Linux/macOS 上 `cmd` 不存在，试玩必然失败；且 `:19-20` 的错误信息是「进程启动失败: <整条命令>」，不会提示平台原因，排查成本高。

**修复**：非 Windows 走 `/bin/sh -c`（或直接解析 argv 后 `OS.create_process(exe, args)`）；`playtest.gd:37-45` 已有 `_first_token()` 可复用做 argv 拆分。同时更新 `EDITOR_FEATURES.md:716`。

---

### C-09 全项目自检不检查内容文件，且头注释虚报「内容码漂移」

`project_audit.gd:2-3` 头注释：

```
## 全项目一致性审计（REFACTOR_PLAN 4.6-3/4/5）：清单校验 + 地图校验 + 内容码漂移 +
## 引用悬空，统一产出 {kind, severity, path, message, map, jump} 条目。
```

`audit()` 实际只有三步（`:13-29`）：清单校验、`MapStore.read_path` 全图校验、`_ref_checks()` 引用悬空。文件顶部只 preload 了 `ManifestValidation` / `MapStore` / `AssetDecl`（`:6-8`），**完全没有 `ContentStore`、没有内容目录扫描**。

而「内容码漂移」这个概念在代码里是存在的：`content_form.gd:87` 注释「码漂移：内容文件的 `"function"` 键与当前功能执行码不一致（清单改码后旧文件仍带旧码）」—— 但它只在**打开某个内容条目时**才提示，全项目自检查不到。

值得注意：`EDITOR_FEATURES.md:664-665` 的收集范围写的是「清单校验（10.1）+ 全部地图读盘校验（10.2）+ 引用悬空」，**与实现一致，文档是对的，只有头注释虚报**（D-12）。这属于「基础功能缺失」与「注释错误」双重问题，二选一必须处理：要么补实现，要么删注释。

**建议补实现**（更符合题意）：在 `audit()` 增加第 4 步 —— 遍历 `ContentStore.root_dir()` 下 `content/<功能id>/*.json`，读 `function` 字段与当前 `FunctionDecls` 码表比对，产出 `kind: "content"` 的 warning，并扫描孤立内容（被 0 个实例引用）与损坏 JSON。

---

### C-10 剪切的图层锁定守卫只查激活层，可绕过锁定

`selection_ops.gd:220-226`：

```gdscript
func cut_selection() -> void:
	...
	if cvs.is_layer_locked(cvs.active_layer):       # :224 只查当前激活层
		cvs._hint("当前图层已锁定：解锁后再剪切")
		return
	var sel := _live_selection()
```

同文件的正确范式 `_selection_touches_locked()`（`:314-320`）会遍历选区每个实体、按 `cvs._layer_index_of(n.layer_id)` 查它**自己所属层**的锁；`delete_selection()`（`:332`）和拖拽（`:124`）都用它。`paste_at()`（`:256`）检查目标层也是对的。`region_ops.gd:277,317` 则统一提示「有图层处于锁定状态」。

后果（选区实体所在层 ≠ 激活层时）：

- 锁定层 A 上有选中实体、当前激活层是未锁的 B → `Ctrl+X` 能剪掉 A 的实体，**绕过层锁**。
- 反之 A 未锁、B 锁定 → 明明可以剪切却被误拦。

**修复**：`cut_selection()` 第 224 行改用 `if _selection_touches_locked(sel):`（注意需先取 `sel` 再判断，调整顺序），提示文案对齐 `region_ops.gd` 的「有图层处于锁定状态」。

---

### C-11 原子写的 `rename_absolute` 覆盖语义需跨平台验证（需运行复现）

`map_store.gd:202-219`：

```gdscript
## 地图域 JSON 写盘单入口——先写 .tmp 再原子替换，中途崩溃不会留下半截 JSON。
static func write_json(path, data) -> bool:
	return write_text(path, JSON.stringify(data, "\t"))

static func write_text(path: String, text: String) -> bool:
	var tmp := path + ".tmp"
	if not _write_bytes(tmp, text.to_utf8_buffer()): return false
	var err := DirAccess.rename_absolute(tmp, path)     # :211
	if err != OK:
		DirAccess.remove_absolute(tmp)
		return false
	...
```

`DirAccess.rename_absolute` 在目标文件**已存在**时的行为依平台/实现而异（POSIX rename 覆盖，Windows 上部分实现返回 `ERR_FILE_ALREADY_EXISTS`）。若在本机 Godot 4.7.2 + Windows 上属于后者，则**所有对已存在地图的保存都会失败**（`:212-214` 直接返回 false），这是 P0 级的连锁后果，但静态无法确定，故标 P1 并列入「必须运行验证」清单。

**验证方法**：写一个 headless 脚本，创建临时 JSON → 调 `MapStore.write_text` 覆盖保存 → 断言返回 true 且内容更新。

**加固建议**：不依赖 rename 的覆盖语义，先 `DirAccess.remove_absolute(path)` 再 rename（牺牲一点原子性），或改用 Godot 提供的原子替换 API；同时保留 `.history` 轮转（`:166-171,178-200`）作为兜底。

---

### C-12 `_save_prefs()` 未判空

`app.gd:198-201`：

```gdscript
func _save_prefs() -> void:
	var f := FileAccess.open(PREFS_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(_prefs, "\t"))     # f 可能为 null
	f.close()
```

同项目其它写盘点都做了判空（`map_store.gd:224-231` 的 `_write_bytes`：`if file == null: return false`；`playtest.gd:54-56`；`content_store.gd`），这里不一致。`user://` 目录不可写 / 磁盘满 / 权限异常时，`f == null` → 对 null 调用 `store_string` 直接报运行时错误，可能打断启动/退出流程。

**修复**：`if f == null: push_warning("..."); return`。同类检查建议全库扫一遍 `FileAccess.open` 调用点。

---

### C-13 区域粘贴的警告被立刻覆盖

`region_ops.gd:369-373`：

```gdscript
if not missed.is_empty():   # 跨图粘贴按名匹配失败的层：黄字提示哪几层落了底层
	cvs._hint("有 %d 个层按名匹配失败，其内容落在最底层：%s" % [...])   # :370
cvs._mark()
cvs._paste_mode = false
cvs._hint("区域已粘贴")                                             # :373 无条件覆盖
```

状态栏是单条消息模型，`:370` 的警告存在时间不足一帧，用户永远看不到「有内容被落到最底层」这个**数据归属已改变**的重要提示。

**修复**：把两条合并成一条（如 `"区域已粘贴；%d 个层按名匹配失败，落在最底层：%s"`），或让 `_hint` 支持队列/优先级。

---

### C-14 清单顶层键缺少结构校验

`manifest_validation.gd:20-47` 的 `validate()` 覆盖 `assets` / `functions` / `conditions` / `steps` / `audio` / `triggers` / `collisionTypes` / `tileSize`，但 `GAME_SIDE_STANDARD.md` 与 `EDITOR_FEATURES.md` 提到的以下键**没有任何校验分支**：

| 键 | 用途 | 缺校验的后果 |
|---|---|---|
| `playCommand` | 试玩命令模板（`playtest.gd:8` `resolved_play_command`） | 类型错误/缺变量直到点试玩才暴露 |
| `godotExe` | 游戏可执行文件 | 路径错误无法提前提示 |
| `contentDir` | 内容根目录（`content_store.gd:root_dir`） | 非法值导致内容静默读不到 |
| `screenSize` | 视野预览框（`EDITOR_FEATURES.md:145`） | 非二元数组会让画布绘制拿到异常值 |
| `playtest`（顶层结构） | 试玩面板配置 | 见 C-06，还被缩进 bug 吞掉 |

`manifest.gd:129` 附近的 `substitute_vars` / `resolved_play_command` 只替换首个 token，也未在校验期检查模板变量合法性。

**修复**：在 `validate()` 增加 `_validate_top_level()`，对上述键做「存在即校验形态、类型错报 error、缺键按缺省处理」，并把 `EDITOR_FEATURES.md` §10.1 表格同步补全。

---

### C-15 混投影一致性警告不存在，静默按等距渲染

两处注释都承诺了这个校验：

- `grid_space.gd:4`：「等距图要求全部瓦片资产同投影（**混投影校验给警告**）」
- `editor_canvas.gd:455`：「任一瓦片资产声明 isometric 即等距（**混投影由清单校验给警告**）」

实际 `manifest_validation.gd:431-434` 只做枚举值校验：

```gdscript
# 网格投影：第 5 批才落地等距，先只做枚举校验（拼错就静默按正交画，属静默错）
var gp := str(ad.get("gridProjection", "orthogonal"))
if gp != "orthogonal" and gp != "isometric":
	_add(issues, "error", path + ".gridProjection", "must be ...")
```

`:431` 的注释自己都承认「先只做枚举校验」。而 `editor_canvas.gd:456-460` 的实现是「**任一**资产声明 isometric 即整图等距」：

```gdscript
func _map_projection() -> String:
	for a in <tile assets>:
		if str(a.get("gridProjection", "orthogonal")) == "isometric":
			return "isometric"
	return "orthogonal"
```

后果：一个项目里混用正交与等距瓦片资产时，整图被切成等距，所有正交资产的位置/形状全部错位，**且没有任何警告**。这既是注释失实（D-11），也是基础校验缺失。

**修复**：`_validate_assets` 收集所有 tile 资产的 `gridProjection`，不全等时 `_add(..., "warning", "assets", "mix of orthogonal/isometric projections ...")`。

---

## 3. P2：优化与一致性

### C-16 缓存用秒级 mtime + size，同秒同尺寸改动漏检

`map_store.gd:23-34` 的注释已经自认：

> mtime 是秒级粒度，同秒内外部改文件会被脏缓存吃掉。缓存键补上文件长度——尺寸变了必然重读；**同秒且同尺寸的改动仍无法识别**。

`code_map()`（`:107-135`）用「长度@mtime」拼签名，同样问题。写路径有显式 `project_rev += 1` / `_cache.erase(path)` 失效，所以只影响外部编辑器改动，但 `EDITOR_FEATURES.md:722` 强调游戏侧只读、外部工具改数据是常见工作流。

**建议**：改用 `FileAccess.get_modified_time` 之外的高精度来源（如读取内容算 hash，或使用平台可用的纳秒 mtime），成本低、能彻底消除这类脏读。

### C-17 `code_map` 与内容表单 map 下拉的全量读盘

`map_store.gd:112-135` 每次调用都 `list_maps()` → 对每张图 `FileAccess.open` 取长度与 mtime 拼签名；签名变化时再对每张图 `MapStore.read()` 全量解析。`content_form.gd:281-288` 的 `source == "map"` 每次打开下拉都对每张图 `MapStore.read()`。地图数量上百时是明显的 O(n) 文件 IO。

**建议**：`code_map` 的签名计算改用 `project_rev`（已有写盘版本号，`:15`、`:218`）作为失效锚，避免每张图 open 一次；map 下拉直接复用 `code_map` 而不是逐图 `read`。

### C-18 整图 JSON 快照 × 80 步

`undo_history.gd:12-13,26-32` 用 `JSON.stringify(cvs.extract())` 做整图快照，`UNDO_MAX = 80`。`EDITOR_FEATURES.md:714` 已自认「大图（数千格 + 数百实体）连续操作仍有内存与耗时成本」。

**建议**：中期可考虑增量 diff 快照（只存变更的 tiles/objects 段），或对大图降低 `UNDO_MAX`；短期至少在文档里明确大图建议。此项属已知取舍，不强制改。

### C-19 `_paint` 判重失效（C-03 连带）

`tool_ops.gd` 的 `_paint()` 用 `MapFormat.alt_of_godot(layer.get_cell_alternative_tile(bc)) != cvs.tile_alt` 判断格子是否已是目标瓦片。C-03 使该表达式对任何带变换的格子恒为真，导致重复 `TilesetCache.set_cell_alt`，带来多余绘制与撤销快照噪音。修好 C-03 后此项自动消失，无需单独改。

### C-20 外部改动只在保存后提示「已覆盖」

`map_file.gd` 用 `_opened_mtime` 与 `FileAccess.get_modified_time(path)` 比较来检测外部改动，但检测发生在保存流程里，提示语义是「你覆盖了外部改动」而非事前阻止。`EDITOR_FEATURES.md` §12 提到自动草稿整图覆盖写、不做多版本。

**建议**：在保存前弹确认（保留当前编辑 / 重新载入 / 放弃），而不是事后告知；至少把提示提到写盘之前。

---

## 4. P3：已排除的疑点与建议

### C-21 `playtest.gd:57-58` 裸换行字符串 —— **不是语法错误**

源码：

```gdscript
	var lines := f.get_as_text().split("
")
	f.close()
```

初看是「普通双引号字符串跨物理行」，怀疑会导致整个脚本解析失败（那会是 P0）。经查 Godot 4 GDScript 官方参考，普通字符串字面量**允许**裸换行并会插入换行符；文档明确写道「using `\` followed by a newline inside a string will allow you to continue it in the next line, **without inserting a newline character in the string itself**」—— 反证不加反斜杠的裸换行是合法的且会插入 `\n`。因此这两行等价于 `split("\n")`，`log_tail()` 的分行逻辑正确。

（此前尝试抓取 GDScript 多行字符串文档时超时未得结论，本轮通过 GDScript reference 的转义序列章节与多个语言版本文档交叉确认，故把该项从「高风险疑点」降级为「已排除」。）

**仅作健壮性建议**：改成 `split("\n")`。当前写法对源码编码转换（CRLF/LF）、格式化工具、复制粘贴极其敏感，任何一次换行规范化都会悄悄改变语义；且 Windows 下日志为 CRLF 时 `split("\n")` 每行残留 `\r`（不过 `:62` 的 `strip_edges()` 会清掉，无实际 BUG）。

---

## 5. 基础功能缺失汇总（对照「通用 2D 关卡编辑器」目标）

以下不是 BUG，而是**初版尚未提供的能力**。按「修完能解锁什么」排序：

| 缺失 | 影响 | 相关编号 |
|---|---|---|
| 全项目自检不覆盖内容文件（内容码漂移、孤立内容、损坏 JSON） | 清单改码后旧内容静默失联 | C-09 / D-12 |
| 清单顶层键结构校验 | 试玩/内容路径配错只能运行时发现 | C-14 |
| 混投影一致性警告 | 混用正交+等距资产静默错位 | C-15 / D-11 |
| 六边形网格 | 网格类游戏的一个完整视角缺席（文档已列为天花板） | 见《AUDIT_2D_CAPABILITY.md》A |
| 等距仅覆盖涂刷与格号 | 幽灵预览/选区框/实例锚点仍轴对齐近似 | 同上 |
| 层参数（parallax/ySort/offset/scale/blend）无编辑控件 | 数据结构已有（`editor_canvas.gd:279-292` 能预览），只能手改 JSON | 同上 R-04 |
| `transform` 旋转/缩放无编辑控件 | `entity_node.gd:58` 已支持 `{scale, rotation, flip_h, flip_v}`，只有 `F` 键翻转 H | 同上 R-04 |
| 碰撞形状按整格矩形生成 | `collisionTypes` 声明了 shape 但不参与生成 | 同上 R-05 |
| `trigger_zone` 的 w/h 无控件、`sortAnchor` 只进数据不进画布 | 触发区/排序点只能改 JSON | 同上 |
| 无 autotile、无图集编辑器、无新建资产流程 | 资产扩充必须手改清单 | 同上 D 类 |
| 试玩非 Windows 不可用 | 跨平台交付受阻 | C-08 |
| 复制地图不刷新身份码 | 复制功能产生非法数据 | C-04 |
| 删层不删实体 | 删层功能语义错误 | C-02 |
| 层操作撤销链竞态 | 层管理撤销可能空转 | C-07 |

> 关于「哪些 2D 游戏类型 / 视角做不了、具体是哪个部分、应该怎么补充或修改」——这是任务三，单独成篇见 **`docs/AUDIT_2D_CAPABILITY.md`**。

---

## 6. 修复优先级路线图（任务二部分）

**第 1 批（数据正确性，必须先修，改动都很小）**：C-01 → C-02 → C-03 → C-04 → C-06。
这 5 项都是几行级改动，但分别决定「粘贴能不能用」「删层对不对」「瓦片变换会不会被保存破坏」「地图身份唯不唯一」「试玩配置校验是否生效」。**建议在修的同时把对应的 headless 测试补上**（尤其是 C-03 的 0..7 往返幂等、C-02 的删层断言），防止回归。

**第 2 批（一致性 / 契约）**：C-05 → C-07 → C-10 → C-13 → C-12。
C-05 与 C-07 分别修「审计口径」和「异步链」，都需要跨文件一起改，改动前请先把调用链列全（C-07 涉及 `layer_ops.gd` 全部 `layer_*` 与 UI 回调）。

**第 3 批（需运行验证 / 平台）**：C-11 → C-08 → C-09 → C-14 → C-15。
C-11 请优先跑一次 headless 覆盖写验证 —— 若 `rename_absolute` 在 Windows 上确实不覆盖，它会直接升级为 P0。

**第 4 批（优化）**：C-16 → C-17 → C-18 → C-20 → C-21 / C-19（C-19 随 C-03 自动修复）。
