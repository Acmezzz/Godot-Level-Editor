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
	# 事件区这类带 sizeFields 的资产：落下去要带默认尺寸与触发方式，
	# 否则就是个看不见的空实例（默认值来自资产声明的缺省，而非硬编码 id）
	if n.decl.get("sizeFields", null) is Array:
		n.props = {"w": 2, "h": 2, "mode": "enter", "event": "", "once": true}
	n.refresh_visual()   # props 就位后按 sizeFields 定尺寸
	n.layer_id = cvs.layer_id(cvs.active_layer)
	n.position = cvs.snap_point(pos, n)
	(cvs.layer_ents[cvs.active_layer] as Node2D).add_child(n)
	cvs._ensure_code(n)
	cvs._mark()
	# 放置即选中（"放置→配置"不断档）；连放不受影响
	cvs.entity_selected.emit(n)
