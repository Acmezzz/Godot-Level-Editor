extends RefCounted
## _tool_ops_ctrl：从 src/canvas/editor_canvas.gd 拆出的控制器。宿主状态经 cvs 引用。
##
## 没有工具概念。`_apply_tool` = 执行一次左键：语义跟资产走（place_kind）——
## 选了实体类型 = 放置（落当前层）；选了瓦片 = 涂刷（当前层；碰撞元层走 set_collision_cell）。
## 擦除（右键）只看层：命中实体删实体，否则擦瓦片/碰撞。矩形填充已按用户要求删除。

var cvs   # 宿主引用

func _init(host) -> void:
	cvs = host
func _apply_tool(pos: Vector2) -> void:
	if cvs.is_layer_locked(cvs.active_layer):
		cvs._hint("当前图层已锁定：解锁后再编辑")
		return
	var c = cvs._cell_of(pos)
	if cvs.place_kind == "entity":
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
	# 碰撞元层涂刷走统一入口（类型/形状元数据跟笔刷的 collision_type/shape 走）
	if cvs._is_grid_layer(cvs.active_layer):
		for bc in _brush_cells(c):
			cvs.set_collision_cell(bc, true, cvs.collision_type, cvs.collision_shape)
		cvs._mark(false)   # 只改碰撞，实体集没动
		return
	var layer = cvs._layer_node(cvs.active_layer)
	if layer == null:
		return
	for bc in _brush_cells(c):
		layer.set_cell(bc, cvs.paint_atlas, cvs.paint_cell)
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
	# 擦除只看当前层：命中本层实体删实体，否则擦本层瓦片/碰撞
	var hit: Sprite2D = cvs._entity_hit_on(cvs.active_layer, pos)
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
	# 碰撞元层擦除走统一入口（类型元数据一并清）
	if cvs._is_grid_layer(cvs.active_layer):
		for bc in _brush_cells(cvs._cell_of(pos)):
			cvs.set_collision_cell(bc, false)
	else:
		var layer = cvs._layer_node(cvs.active_layer)
		if layer == null:
			return
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
	# 碰撞元层不摆实体
	if cvs.active_layer == cvs.collision_index():
		cvs._hint("碰撞层不摆放实体：切回层栈再放")
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
	# 实体落当前层（图层管放在哪一层）
	spr.set_meta("layer", cvs.layer_id(cvs.active_layer))
	# 触发区没有缩略图，落下去要带默认矩形与触发方式，否则就是个看不见的空实体
	if cvs.BuiltinKinds.is_builtin(cvs.stamp_scene):
		spr.texture = null
		spr.set_meta("props", {"w": 2, "h": 2, "mode": "enter", "event": "", "once": true})
		spr.position += Vector2(cvs.tile_px, cvs.tile_px) * 0.5
	else:
		spr.set_meta("props", {})
	(cvs.layer_ents[cvs.active_layer] as Node2D).add_child(spr)
	cvs._fit_sprite(spr, cvs.stamp_scene)
	cvs._ensure_code(spr)
	cvs._mark()
	# 放置即选中（"放置→配置"不断档）；连放不受影响
	cvs.entity_selected.emit(spr)


## 当前层自审：自动碰撞的「有没有地形」判定跟着 active_layer 走（不再认 terrain id）。
func _has_terrain_at(c: Vector2i) -> bool:
	return cvs._has_terrain_at(c)
