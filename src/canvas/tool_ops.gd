extends RefCounted
## _tool_ops_ctrl：从 src/canvas/editor_canvas.gd 拆出的控制器。宿主状态经 cvs 引用。
##
## 没有工具概念。`_apply_tool` = 执行一次左键：语义跟资产走（place_kind）——
## 选了可摆放资产（实体 / 图片场景）= 放置（落当前层）；选了瓦片 = 涂刷
## （当前层；碰撞元层走 set_collision_cell）。
## 擦除（右键）只看层：命中实例删实例，否则擦瓦片/碰撞。矩形填充已按用户要求删除。

var cvs   # 宿主引用

const TilesetCache := preload("res://src/canvas/tileset_cache.gd")
const MapFormat := preload("res://src/map/map_format.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")   # 挂载补齐（C09）

func _init(host) -> void:
	cvs = host
func _apply_tool(pos: Vector2) -> void:
	if cvs.is_layer_locked(cvs.active_layer):
		cvs._hint("当前图层已锁定：解锁后再编辑")
		return
	# 世界鼠标 → 活动层局部（E02）。碰撞元层的索引 = layer_count()，
	# clamp 到 0..layer_count()-1 会把它夹进最后一个瓦片层——首笔画到别的层空间去，
	# 后续 mouse-motion 却用 _active_local（根空间），同一笔前后格号不连续。
	var lp: Vector2 = cvs._active_local(pos)
	if cvs.place_kind == "object" and not cvs._is_grid_layer(cvs.active_layer):
		_stamp(lp)
	else:
		_paint(cvs.tile_grid_for_layer(cvs.active_layer).pick_cell(lp))


func _brush_cells(c: Vector2i) -> Array:
	var out := []
	var half = cvs.brush_size / 2
	for dy in cvs.brush_size:
		for dx in cvs.brush_size:
			out.append(Vector2i(c.x + dx - half, c.y + dy - half))
	return out

## 路径上的多格笔刷展开（去重）：补格路径与笔刷边长共存
func _brush_cells_multi(cells: Array) -> Array:
	var seen := {}
	var out: Array = []
	for c: Vector2i in cells:
		for bc: Vector2i in _brush_cells(c):
			if not seen.has(bc):
				seen[bc] = true
				out.append(bc)
	return out


## 瓦片/碰撞笔画不压整图快照（H01）：首个真实改动前 stroke_begin 开始差量记录。
## 实例增删与全局操作仍走 push_undo 整图快照，不在这里。
func _ensure_stroke_undo() -> void:
	if not cvs._paint_pushed:
		cvs._undo_history_ctrl.stroke_begin()
		cvs._paint_pushed = true


func _paint(c: Vector2i) -> void:
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
		return
	# 锁检查放在写入口：补格路径（_paint_path）直调这里，不经过 _apply_tool
	if cvs.is_layer_locked(cvs.active_layer):
		cvs._hint("当前图层已锁定：解锁后再编辑")
		return
	# 有真实改动才 _mark：拖动涂刷每个 mouse-motion 都进这里，无条件 mark 会让
	# 碰撞视图整层重画、内容预览按 map_rev 的缓存反复失效重建（热路径）
	var changed := false
	# 碰撞元层涂刷走统一入口（类型/形状元数据跟笔刷的 collision_type/shape 走）
	if cvs._is_grid_layer(cvs.active_layer):
		for bc in _brush_cells(c):
			var had: bool = cvs.collision.get_cell_source_id(bc) != -1
			var cm = cvs._collision_meta.get(bc, null)
			# 缺省值归一后比较（E13）：无 meta = solid+矩形；重复画同一缺省不在撤销栈里留空步
			var ct := str(cm.get("type", "solid")) if cm != null else "solid"
			var cs := str(cm.get("shape", "")) if cm != null else ""
			var same: bool = had and ct == cvs.collision_type and cs == cvs.collision_shape
			if not same:
				_ensure_stroke_undo()
				cvs._undo_history_ctrl.stroke_touch_collision(bc)
				cvs.set_collision_cell(bc, true, cvs.collision_type, cvs.collision_shape)
				changed = true
		if changed:
			cvs._mark_collision()   # P01：只改碰撞，红块镜像重画；瓦片/实体都没动
		return
	var layer = cvs._layer_node(cvs.active_layer)
	if layer == null:
		return
	# 笔刷记的是资产 id，落笔时映射到 TileSet source_id（磁盘数据同样写 id）
	var src: int = cvs.source_of_asset(cvs.paint_asset)
	if src < 0:
		cvs._hint("当前笔刷的资产不在清单里：左栏重新选一个瓦片")
		return
	var lid: String = cvs.layer_id(cvs.active_layer)
	var tile_grid: GridSpace = cvs.tile_grid_for_layer(cvs.active_layer)
	var meta: Dictionary = cvs.map_data.get("meta", {})
	for bc in _brush_cells(c):
		if tile_grid != cvs.grid and not tile_grid.cell_in_map(bc, int(meta.get("w", 1)), int(meta.get("h", 1))):
			continue
		if layer.get_cell_source_id(bc) != src \
				or layer.get_cell_atlas_coords(bc) != cvs.paint_cell \
				or MapFormat.alt_of_godot(layer.get_cell_alternative_tile(bc)) != cvs.tile_alt:
			_ensure_stroke_undo()
			cvs._undo_history_ctrl.stroke_touch_tile(lid, bc)
			cvs.write_tile_row(lid, layer, [bc.x, bc.y, cvs.paint_asset, cvs.paint_cell.x, cvs.paint_cell.y, cvs.tile_alt])
			changed = true
	if changed:
		# 阶段三：只失效这一笔写的那一层（三角自绘按层重画，其它层数据没动）
		cvs._mark_tiles_layer(cvs.active_layer)


## 这一格到底有没有东西可擦——起手前先判，避免压空撤销快照。
## 只看当前层：命中本层实体 = 可擦，否则看本层瓦片/碰撞。
func _erase_hits(pos: Vector2) -> bool:
	if cvs.map_root == null:
		return false
	if cvs._entity_hit_on(cvs.active_layer, pos) != null:
		return true
	var lp: Vector2 = cvs._active_local(pos)
	if cvs._is_grid_layer(cvs.active_layer):
		for bc in _brush_cells(cvs.grid.pick_cell(lp)):
			if cvs.collision.get_cell_source_id(bc) != -1:
				return true
		return false
	var layer = cvs._layer_node(cvs.active_layer)
	if layer == null:
		return false
	var lid: String = cvs.layer_id(cvs.active_layer)
	for bc in _brush_cells(cvs.tile_grid_for_layer(cvs.active_layer).pick_cell(lp)):
		if layer.get_cell_source_id(bc) != -1 or not cvs.unresolved_tile(lid, bc).is_empty():
			return true
	return false


## 按格批量擦除（瓦片/碰撞），返回是否有真实改动。路径补格与起手共用。
## 撤销覆盖在首个真实改动前接上（H01 差量记录；空擦 = 零副作用、不留空条目）。
func erase_cells(cells: Array) -> bool:
	# 锁检查放在写入口本身：补格路径（_erase_path 直调）不经过 _apply_tool，
	# 任何新增调用者也自动受锁约束，不再依赖调用方各自记得查。
	if cvs.is_layer_locked(cvs.active_layer):
		cvs._hint("当前图层已锁定：解锁后再擦除")
		return false
	var changed := false
	var layer = null
	if not cvs._is_grid_layer(cvs.active_layer):
		layer = cvs._layer_node(cvs.active_layer)
		if layer == null:
			return false
	var lid: String = cvs.layer_id(cvs.active_layer) if layer != null else ""
	for bc in cells:
		var has: bool = cvs.collision.get_cell_source_id(bc) != -1 if layer == null \
			else layer.get_cell_source_id(bc) != -1 or not cvs.unresolved_tile(lid, bc).is_empty()
		if not has:
			continue
		_ensure_stroke_undo()
		if layer == null:
			cvs._undo_history_ctrl.stroke_touch_collision(bc)
			cvs.set_collision_cell(bc, false)
		else:
			cvs._undo_history_ctrl.stroke_touch_tile(lid, bc)
			cvs.erase_tile(lid, layer, bc)
		changed = true
	if changed:
		if layer == null:
			cvs._mark_collision()   # P01：擦的是碰撞层
		else:
			cvs._mark_tiles_layer(cvs.active_layer)   # 阶段三：只重画被擦的那一层
	return changed


func _erase_at(pos: Vector2) -> void:
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
		return
	# 锁检查下沉到写入函数入口：右键擦除不经过 _apply_tool，直调也拦住
	if cvs.is_layer_locked(cvs.active_layer):
		cvs._hint("当前图层已锁定：解锁后再擦除")
		return
	# 擦除只看当前层：命中本层实例删实例，否则擦本层瓦片/碰撞
	var hit: EntityNode = cvs._entity_hit_on(cvs.active_layer, pos)
	if hit:
		# H01：拖动中扫过实例：先 stroke_end 定格已记格（差量两步各回半程：先回实例，再回瓦片）。
		if cvs._undo_history_ctrl._stroke_open:
			cvs._undo_history_ctrl.stroke_end()
			cvs._paint_pushed = false
		# §7.5 阶段二：实例删除走 InstanceKey 差量；场景图片（无码）回退整图快照。
		var pre: Dictionary = cvs._undo_history_ctrl.inst_rows([hit])
		if not bool(pre.get("ok", false)):
			cvs.push_undo()
		# B2b：释放统一为 remove_child + free——queue_free 帧末才消失，同帧擦除→保存会把刚删实体写进文件
		if cvs.selected_entity == hit:
			cvs.selected_entity = null
		cvs.selected_multi.erase(hit)
		(hit.get_parent() as Node2D).remove_child(hit)
		hit.free()
		if bool(pre.get("ok", false)):
			cvs._undo_history_ctrl.inst_commit(pre.get("rows", {}))
		cvs.commit_selection(cvs.selected_entity)
		cvs._mark_ents()
		return
	# 碰撞元层擦除走统一入口（类型元数据一并清）——有真实改动才 _mark（热路径同 _paint）
	erase_cells(_brush_cells(cvs._active_cell(pos)))


func _stamp(pos: Vector2, drawn: Array = []) -> void:
	place_object(cvs.stamp_asset, cvs.active_layer, pos, false, drawn)


func place_object(asset: String, layer: int, pos: Vector2, exact := false, drawn: Array = []) -> EntityNode:
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
		return null
	if layer < 0 or layer >= cvs.layer_count():
		cvs._hint("请选地图中的实例图层")
		return null
	if cvs.is_layer_locked(layer):
		cvs._hint("当前图层已锁定：解锁后再放置")
		return null
	if not cvs.is_placeable(asset):
		cvs._hint("请在资产列表选择可摆放的资产")
		return null
	var n: EntityNode = cvs.make_object(asset)
	# §7.5 阶段二：实体新增走 InstanceKey 差量（只记录这一条）。场景图片没有实例码，
	# 差量无从寻址——这类改动在动手前压整图快照。
	var via_delta := n.is_entity()
	if not via_delta:
		cvs.push_undo()
	# 带 sizeFields 的资产（事件区这类实例各自定尺寸）落下去要带默认尺寸，
	# 否则就是个看不见的空实例；键名与缺省值都从声明/原字典取（E10），不写死 w/h。
	var sf: Array = n.decl.get("sizeFields", []) if n.decl.get("sizeFields", null) is Array else []
	if sf.size() >= 2:
		var p: Dictionary = n.props
		if not p.has(str(sf[0])):
			p[str(sf[0])] = 2
		if not p.has(str(sf[1])):
			p[str(sf[1])] = 2
		n.props = p
	# poly/path 资产（R-02 几何段）：落下带缺省点集——优先声明 visual.points，
	# 没声明按类型给最小形状（poly 一格三角形 / path 两点横线），否则是看不见的空实例
	if not drawn.is_empty():
		n.refresh_visual()
		n.position = pos
		var inverse := n.transform.affine_inverse()
		n.points_write(drawn.map(func(p): return inverse * p))
	elif n.visual_type() != "rect" and not (n.props.get("points", null) is Array):
		var pts: Array = n.points_local()
		if pts.is_empty():
			var cw := float(cvs.grid.tile.x)
			var ch := float(cvs.grid.tile.y)
			if n.visual_type() == "path":
				pts = [Vector2(0, 0), Vector2(cw, 0)]
			else:
				pts = [Vector2(0, 0), Vector2(cw, 0), Vector2(0, ch)]
		n.points_write(pts)
	n.refresh_visual()   # props 就位后按 sizeFields 定尺寸
	n.layer_id = cvs.layer_id(layer)
	if drawn.is_empty():
		n.position = pos if exact else cvs.snap_point(pos, n)
	# C09：放置即补齐类型挂载（不依赖选中事件），写出 mounted 继承行
	if n.is_entity():
		var fill: Dictionary = FunctionDecls.fill_bindings(cvs.manifest, n.asset, n.functions)
		if bool(fill.get("changed", false)):
			n.functions = fill.get("functions", [])
	cvs._place_in_layer(n, layer)
	cvs._ensure_code(n)
	# 快照已在动手前压好（场景图片）；实体走差量，这里是唯一的撤销记账点。
	if via_delta:
		cvs._undo_history_ctrl.inst_commit_add([n])
	cvs._mark_ents()
	# 放置即选中（"放置→配置"不断档）；连放不受影响。
	# 走选择提交入口（E09）：单选/多选/信息条一起更新，Del 不会再删到旧组。
	cvs.commit_selection(n)
	return n

## —— 从 editor_canvas.gd 并入：碰撞自动生成（宿主经 cvs 转发） ——

var active_layer:
	get: return cvs.active_layer
var collision:
	get: return cvs.collision
var map_root:
	get: return cvs.map_root

func _has_terrain_at(c: Vector2i) -> bool:
	return cvs._has_terrain_at(c)
func _hint(t: String) -> void:
	cvs._hint(t)
func _layer_node(i: int) -> TileMapLayer:
	return cvs._layer_node(i)
func _mark(ents_changed := true) -> void:
	cvs._mark(ents_changed)
func _mark_tiles() -> void:
	cvs._mark_tiles()
func _mark_collision() -> void:
	cvs._mark_collision()
func collision_index() -> int:
	return cvs.collision_index()
func is_layer_locked(i: int) -> bool:
	return cvs.is_layer_locked(i)
func set_collision_cell(c: Vector2i, on: bool, type := "solid", shape := "") -> void:
	cvs.set_collision_cell(c, on, type, shape)

# —— 自动生成碰撞：从合法源层瓦片推导碰撞（层栈化后「源层自审」，不再认 terrain id） ——
## 当前停在碰撞元层时回退到第一个普通层；源层选择见 cvs._collision_source_layer()。
## strategy: "full"(全部) / "top"(仅顶部表面) / "outline"(仅外轮廓)
## replace=true 先清空碰撞层再生成
func generate_collision(strategy := "full", replace := false, one_way_top := false, src_override := -1) -> int:
	if map_root == null:
		_hint("无地图：先新建或打开一张地图")
		return 0
	if is_layer_locked(collision_index()):
		_hint("碰撞层已锁定：先解锁")
		return 0
	var src_idx: int = int(src_override if src_override >= 0 else cvs._collision_source_layer())
	if cvs.has_independent_tile_grid(src_idx):
		_hint("独立格系不能直接生成根空间碰撞，请使用格图或自由轮廓。")
		return 0
	var src := _layer_node(src_idx) if src_idx >= 0 else null
	if src == null:
		_hint("切到一个瓦片层再用自动碰撞（当前是碰撞元层）")
		return 0
	# 预判：无可生成（且不是替换模式）就不压撤销快照——与 _erase_hits 的「不压空撤销」同纪律
	if not replace and count_auto_collision(strategy, false, src_idx) == 0:
		_hint("没有可生成的碰撞格（换策略或换层再试）")
		return 0
	cvs.push_undo()
	if replace:
		for c in collision.get_used_cells():
			set_collision_cell(c, false)
	var added := 0
	for c in src.get_used_cells():
		if not _collision_wanted(c, strategy, src_idx):
			continue
		if collision.get_cell_source_id(c) != -1:
			continue
		# 顶部策略可生成 one_way（自动碰撞策略扩展，契约类型 one_way）
		var typ := "one_way" if (strategy == "top" and one_way_top) else "solid"
		set_collision_cell(c, true, typ)
		added += 1
	_mark_collision()   # P01：自动碰撞只写碰撞层，红块重画即可
	cvs.queue_redraw()
	return added

## 预览：不写入，只算会新增多少格
func count_auto_collision(strategy := "full", replace := false, src_override := -1) -> int:
	if map_root == null:
		return 0
	var src_idx: int = int(src_override if src_override >= 0 else cvs._collision_source_layer())
	if cvs.has_independent_tile_grid(src_idx):
		return 0
	var src := _layer_node(src_idx) if src_idx >= 0 else null
	if src == null:
		return 0   # 没有普通瓦片层可作来源（同 generate_collision）
	var n := 0
	for c in src.get_used_cells():
		if not _collision_wanted(c, strategy, src_idx):
			continue
		if not replace and collision.get_cell_source_id(c) != -1:
			continue
		n += 1
	return n

func _collision_wanted(c: Vector2i, strategy: String, src_idx: int) -> bool:
	match strategy:
		"top":
			# 顶面 = 视觉上方没有地形。六边（E16）：上方是两格（奇偶行各一），
			# 两格都空才算顶面，不能只查 (0,-1)。
			for u: Vector2i in cvs.grid.up_neighbors(c):
				if cvs._has_terrain_in(u, src_idx):
					return false
			return true
		"outline":
			# 轮廓 = 任一真实邻格为空（六边按六邻、三角按三邻；E16/B3）
			for nb: Vector2i in cvs.grid.neighbors_any(c):
				if not cvs._has_terrain_in(nb, src_idx):
					return true
			return false
		_:
			return true
