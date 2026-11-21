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

func _init(host) -> void:
	cvs = host
func _apply_tool(pos: Vector2) -> void:
	if cvs.is_layer_locked(cvs.active_layer):
		cvs._hint("当前图层已锁定：解锁后再编辑")
		return
	# 世界鼠标 → 活动层局部（E02）：涂刷格号与摆落点都在层局部空间算
	var lp: Vector2 = cvs.to_layer_local(clampi(cvs.active_layer, 0, maxi(cvs.layer_count() - 1, 0)), pos)
	if cvs.place_kind == "object":
		_stamp(lp)
	else:
		_paint(cvs.grid.pick_cell(lp))


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


## 笔画内首个真实改动前压一次撤销快照（点击不动 = 零副作用）——涂/擦共用。
func _ensure_stroke_undo() -> void:
	if not cvs._paint_pushed:
		cvs._push_undo()
		cvs._paint_pushed = true


func _paint(c: Vector2i) -> void:
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
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
				cvs.set_collision_cell(bc, true, cvs.collision_type, cvs.collision_shape)
				changed = true
		if changed:
			cvs._mark(false)   # 只改碰撞，实体集没动
		return
	var layer = cvs._layer_node(cvs.active_layer)
	if layer == null:
		return
	# 笔刷记的是资产 id，落笔时映射到 TileSet source_id（磁盘数据同样写 id）
	var src: int = cvs.source_of_asset(cvs.paint_asset)
	if src < 0:
		cvs._hint("当前笔刷的资产不在清单里：左栏重新选一个瓦片")
		return
	for bc in _brush_cells(c):
		if layer.get_cell_source_id(bc) != src \
				or layer.get_cell_atlas_coords(bc) != cvs.paint_cell \
				or MapFormat.alt_of_godot(layer.get_cell_alternative_tile(bc)) != cvs.tile_alt:
			_ensure_stroke_undo()
			TilesetCache.set_cell_alt(layer, bc, src, cvs.paint_cell, cvs.tile_alt)
			changed = true
	if changed:
		cvs._mark(false)   # 只改瓦片层


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
	for bc in _brush_cells(cvs.grid.pick_cell(lp)):
		if layer.get_cell_source_id(bc) != -1:
			return true
	return false


## 按格批量擦除（瓦片/碰撞），返回是否有真实改动。路径补格与起手共用。
## 撤销快照在首个真实改动前压一次（空擦 = 零副作用、不留空快照）。
func erase_cells(cells: Array) -> bool:
	var changed := false
	var layer = null
	if not cvs._is_grid_layer(cvs.active_layer):
		layer = cvs._layer_node(cvs.active_layer)
		if layer == null:
			return false
	for bc in cells:
		var has: bool = cvs.collision.get_cell_source_id(bc) != -1 if layer == null \
			else layer.get_cell_source_id(bc) != -1
		if not has:
			continue
		_ensure_stroke_undo()
		if layer == null:
			cvs.set_collision_cell(bc, false)
		else:
			layer.erase_cell(bc)
		changed = true
	if changed:
		cvs._mark(false)   # 纯瓦片/碰撞擦除，实体集不变
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
		# B2b：释放统一为 remove_child + free——queue_free 帧末才消失，同帧擦除→保存会把刚删实体写进文件
		if cvs.selected_entity == hit:
			cvs.selected_entity = null
		cvs.selected_multi.erase(hit)
		(hit.get_parent() as Node2D).remove_child(hit)
		hit.free()
		cvs.commit_selection(cvs.selected_entity)
		cvs._mark()
		return
	# 碰撞元层擦除走统一入口（类型元数据一并清）——有真实改动才 _mark（热路径同 _paint）
	erase_cells(_brush_cells(cvs.grid.pick_cell(cvs._active_local(pos))))


func _stamp(pos: Vector2) -> void:
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
		return
	# 锁检查下沉到写入口本身，绕过 _apply_tool 的直调也拦住
	if cvs.is_layer_locked(cvs.active_layer):
		cvs._hint("当前图层已锁定：解锁后再放置")
		return
	# 碰撞元层不摆实例
	if cvs.active_layer == cvs.collision_index():
		cvs._hint("碰撞层不摆放实例：切回层栈再放")
		return
	if cvs.stamp_asset == "":
		cvs._hint("先在左栏资产列表选一个资产再放置")
		return
	if not cvs.is_placeable(cvs.stamp_asset):
		cvs._hint("这个资产不能直接摆放（图集瓦片请用涂刷）")
		return
	cvs._push_undo()
	var n: EntityNode = cvs.make_object(cvs.stamp_asset)
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
	if n.visual_type() != "rect" and not (n.props.get("points", null) is Array):
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
	n.layer_id = cvs.layer_id(cvs.active_layer)
	n.position = cvs.snap_point(pos, n)
	cvs._place_in_layer(n, cvs.active_layer)
	cvs._ensure_code(n)
	cvs._mark()
	# 放置即选中（"放置→配置"不断档）；连放不受影响。
	# 走选择提交入口（E09）：单选/多选/信息条一起更新，Del 不会再删到旧组。
	cvs.commit_selection(n)

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
func _push_undo() -> void:
	cvs._push_undo()
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
	var src := _layer_node(src_idx) if src_idx >= 0 else null
	if src == null:
		_hint("切到一个瓦片层再用自动碰撞（当前是碰撞元层）")
		return 0
	# 预判：无可生成（且不是替换模式）就不压撤销快照——与 _erase_hits 的「不压空撤销」同纪律
	if not replace and count_auto_collision(strategy, false, src_idx) == 0:
		_hint("没有可生成的碰撞格（换策略或换层再试）")
		return 0
	_push_undo()
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
	_mark(false)   # 自动碰撞只写碰撞层
	cvs.queue_redraw()
	return added

## 预览：不写入，只算会新增多少格
func count_auto_collision(strategy := "full", replace := false, src_override := -1) -> int:
	if map_root == null:
		return 0
	var src_idx: int = int(src_override if src_override >= 0 else cvs._collision_source_layer())
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
			# 轮廓 = 任一真实邻格为空（六边按六邻，E16）
			for nb: Vector2i in cvs.grid.neighbors(c):
				if not cvs._has_terrain_in(nb, src_idx):
					return true
			return false
		_:
			return true
