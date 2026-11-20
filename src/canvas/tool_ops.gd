extends RefCounted
## _tool_ops_ctrl：从 src/canvas/editor_canvas.gd 拆出的控制器。宿主状态经 cvs 引用。
##
## 没有工具概念。`_apply_tool` = 执行一次左键：语义跟资产走（place_kind）——
## 选了可摆放资产（实体 / 图片场景）= 放置（落当前层）；选了瓦片 = 涂刷
## （当前层；碰撞元层走 set_collision_cell）。
## 擦除（右键）只看层：命中实例删实例，否则擦瓦片/碰撞。矩形填充已按用户要求删除。

var cvs   # 宿主引用

func _init(host) -> void:
	cvs = host
func _apply_tool(pos: Vector2) -> void:
	if cvs.is_layer_locked(cvs.active_layer):
		cvs._hint("当前图层已锁定：解锁后再编辑")
		return
	if cvs.place_kind == "object":
		_stamp(pos)
	else:
		_paint(cvs._cell_of(pos))


func _brush_cells(c: Vector2i) -> Array:
	var out := []
	var half = cvs.brush_size / 2
	for dy in cvs.brush_size:
		for dx in cvs.brush_size:
			out.append(Vector2i(c.x + dx - half, c.y + dy - half))
	return out


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
			var same: bool = had and cm != null and str(cm.get("type", "solid")) == cvs.collision_type \
				and str(cm.get("shape", "")) == cvs.collision_shape
			if not same:
				if not cvs._paint_pushed:
					cvs._push_undo()   # 笔画内首个真实改动前压一次快照（点击不动 = 零副作用）
					cvs._paint_pushed = true
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
				or layer.get_cell_atlas_coords(bc) != cvs.paint_cell:
			if not cvs._paint_pushed:
				cvs._push_undo()   # 笔画内首个真实改动前压一次快照（点击不动 = 零副作用）
				cvs._paint_pushed = true
			layer.set_cell(bc, src, cvs.paint_cell)
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
	if cvs._is_grid_layer(cvs.active_layer):
		for bc in _brush_cells(cvs._cell_of(pos)):
			if cvs.collision.get_cell_source_id(bc) != -1:
				return true
		return false
	var layer = cvs._layer_node(cvs.active_layer)
	if layer == null:
		return false
	for bc in _brush_cells(cvs._cell_of(pos)):
		if layer.get_cell_source_id(bc) != -1:
			return true
	return false


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
		cvs.entity_selected.emit(cvs.selected_entity)
		cvs._mark()
		return
	# 碰撞元层擦除走统一入口（类型元数据一并清）——有真实改动才 _mark（热路径同 _paint）
	var changed := false
	if cvs._is_grid_layer(cvs.active_layer):
		for bc in _brush_cells(cvs._cell_of(pos)):
			if cvs.collision.get_cell_source_id(bc) != -1:
				cvs.set_collision_cell(bc, false)
				changed = true
	else:
		var layer = cvs._layer_node(cvs.active_layer)
		if layer == null:
			return
		for bc in _brush_cells(cvs._cell_of(pos)):
			if layer.get_cell_source_id(bc) != -1:
				layer.erase_cell(bc)
				changed = true
	if changed:
		cvs._mark(false)   # 纯瓦片/碰撞擦除，实体集不变


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
	# 否则就是个看不见的空实例；mode/event/once 已作废，语义归 functions[]。
	if n.decl.get("sizeFields", null) is Array:
		n.props = {"w": 2, "h": 2}
	n.refresh_visual()   # props 就位后按 sizeFields 定尺寸
	n.layer_id = cvs.layer_id(cvs.active_layer)
	n.position = cvs.snap_point(pos, n)
	cvs._place_in_layer(n, cvs.active_layer)
	cvs._ensure_code(n)
	cvs._mark()
	# 放置即选中（"放置→配置"不断档）；连放不受影响
	cvs.entity_selected.emit(n)

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

# —— 自动生成碰撞：从**当前层**瓦片推导碰撞（层栈化后「当前层自审」，不再认 terrain id） ——
## strategy: "full"(全部) / "top"(仅顶部表面) / "outline"(仅外轮廓)
## replace=true 先清空碰撞层再生成
func generate_collision(strategy := "full", replace := false, one_way_top := false) -> int:
	if map_root == null:
		_hint("无地图：先新建或打开一张地图")
		return 0
	if is_layer_locked(collision_index()):
		_hint("碰撞层已锁定：先解锁")
		return 0
	# 预判：无可生成（且不是替换模式）就不压撤销快照——与 _erase_hits 的「不压空撤销」同纪律
	if not replace and count_auto_collision(strategy, false) == 0:
		_hint("没有可生成的碰撞格（换策略或换层再试）")
		return 0
	var src := _layer_node(active_layer)
	if src == null or active_layer == collision_index():
	 # _layer_node 对碰撞元层返回 collision 节点本身——自动碰撞若不拦，
	 # 就会从碰撞层读瓦片生成碰撞（自己抄自己）
		_hint("切到一个瓦片层再用自动碰撞（当前是碰撞元层）")
		return 0
	_push_undo()
	if replace:
		for c in collision.get_used_cells():
			set_collision_cell(c, false)
	var added := 0
	for c in src.get_used_cells():
		if not _collision_wanted(c, strategy):
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
func count_auto_collision(strategy := "full", replace := false) -> int:
	if map_root == null:
		return 0
	var src := _layer_node(active_layer)
	if src == null or active_layer == collision_index():
		return 0   # 碰撞元层不是瓦片来源（同 generate_collision）
	var n := 0
	for c in src.get_used_cells():
		if not _collision_wanted(c, strategy):
			continue
		if not replace and collision.get_cell_source_id(c) != -1:
			continue
		n += 1
	return n

func _collision_wanted(c: Vector2i, strategy: String) -> bool:
	match strategy:
		"top":
			return not _has_terrain_at(c + Vector2i(0, -1))
		"outline":
			return not _has_terrain_at(c + Vector2i(1, 0)) \
				or not _has_terrain_at(c + Vector2i(-1, 0)) \
				or not _has_terrain_at(c + Vector2i(0, 1)) \
				or not _has_terrain_at(c + Vector2i(0, -1))
		_:
			return true
