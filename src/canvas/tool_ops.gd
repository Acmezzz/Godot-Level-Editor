extends RefCounted
## _tool_ops_ctrl：从 src/canvas/editor_canvas.gd 拆出的控制器。宿主状态经 cvs 引用。
##
## 没有工具概念。`_apply_tool` 现在是「按当前层的语义执行一次左键」：
## 实体层 = 放置当前资产；其余层 = 涂刷（碰撞层走 set_collision_cell）。
## 擦除（右键）同样只看层。矩形填充已按用户要求删除。

var cvs   # 宿主引用

func _init(host) -> void:
	cvs = host
func _apply_tool(pos: Vector2) -> void:
	if cvs.is_layer_locked(cvs.active_layer):
		cvs._hint("当前图层已锁定：解锁后再编辑")
		return
	var c = cvs._cell_of(pos)
	if cvs.active_layer == cvs._ent_layer_index():
		_stamp(c)
	else:
		_paint(c)


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
	# 碰撞层涂刷走统一入口（类型/形状元数据跟笔刷的 collision_type/shape 走）
	if cvs._is_grid_layer(cvs.active_layer):
		for bc in _brush_cells(c):
			cvs.set_collision_cell(bc, true, cvs.collision_type, cvs.collision_shape)
		cvs._mark(false)   # 只改碰撞，实体集没动
		return
	var layer = cvs._layer_node(cvs.active_layer)
	for bc in _brush_cells(c):
		layer.set_cell(bc, cvs.paint_atlas, cvs.paint_cell)
	cvs._mark(false)   # 只改瓦片层


## 这一格到底有没有东西可擦——起手前先判，避免压空撤销快照。
func _erase_hits(pos: Vector2) -> bool:
	if cvs.map_root == null:
		return false
	if cvs.active_layer == cvs._ent_layer_index():
		return cvs._entity_hit(pos) != null
	if cvs._is_grid_layer(cvs.active_layer):
		for bc in _brush_cells(cvs._cell_of(pos)):
			if cvs.collision.get_cell_source_id(bc) != -1:
				return true
		return false
	var layer = cvs._layer_node(cvs.active_layer)
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
	if cvs.active_layer == cvs._ent_layer_index():
		var hit: Sprite2D = cvs._entity_hit(pos)
		if hit:
 # B2b：释放统一为 remove_child + free——queue_free 帧末才消失，同帧擦除→保存会把刚删实体写进文件
			if cvs.selected_entity == hit:
				cvs.selected_entity = null
			cvs.selected_multi.erase(hit)
			cvs.entities.remove_child(hit)
			hit.free()
			cvs.entity_selected.emit(cvs.selected_entity)
			cvs._mark()
		return
	# 碰撞层擦除走统一入口（类型元数据一并清）
	if cvs._is_grid_layer(cvs.active_layer):
		for bc in _brush_cells(cvs._cell_of(pos)):
			cvs.set_collision_cell(bc, false)
	else:
		var layer = cvs._layer_node(cvs.active_layer)
		for bc in _brush_cells(cvs._cell_of(pos)):
			layer.erase_cell(bc)
	cvs._mark(false)   # 纯瓦片/碰撞擦除，实体集不变


func _stamp(c: Vector2i) -> void:
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
		return
	# 锁检查下沉到写入口本身，绕过 _apply_tool 的直调也拦住
	if cvs.is_layer_locked(cvs.active_layer):
		cvs._hint("当前图层已锁定：解锁后再放置")
		return
	if cvs.stamp_scene == "":
		cvs._hint("先在左栏资产列表选一个实体再放置")
		return
	cvs._push_undo()
	var spr := Sprite2D.new()
	spr.texture = cvs.thumbs.get(cvs.stamp_scene)
	spr.position = Vector2(c.x * cvs.tile_px + cvs.tile_px / 2.0, c.y * cvs.tile_px + cvs.tile_px / 2.0)
	spr.set_meta("scene", cvs.stamp_scene)
	spr.set_meta("functions", [])
	# 触发区没有缩略图，落下去要带默认矩形与触发方式，否则就是个看不见的空实体
	if cvs.BuiltinKinds.is_builtin(cvs.stamp_scene):
		spr.texture = null
		spr.set_meta("props", {"w": 2, "h": 2, "mode": "enter", "event": "", "once": true})
		spr.position += Vector2(cvs.tile_px, cvs.tile_px) * 0.5
	else:
		spr.set_meta("props", {})
	cvs.entities.add_child(spr)
	cvs._fit_sprite(spr, cvs.stamp_scene)
	cvs._assign_id(spr)
	cvs._mark()
	# 放置即选中（"放置→配置"不断档）；连放不受影响
	cvs.entity_selected.emit(spr)


func _has_terrain_at(c: Vector2i) -> bool:
	return cvs.terrain.get_cell_source_id(c) != -1
