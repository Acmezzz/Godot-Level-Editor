extends RefCounted
## _canvas_input_ctrl：从 src/canvas/editor_canvas.gd 拆出的控制器（审查 8.3 表）。宿主状态经 alias 引用。
##
## v2 §2.2：没有工具概念——**层类型决定左键语义**。
##   地形 / 装饰 / 碰撞：左键按住拖动连续涂，右键拖动擦除。
##   实体：左键点空处 = 放置当前选中资产，点实体 = 选中并拖动；右键 = 删除该实体。
## 框选由 cvs.select_mode（左栏「框选」开关）决定：打开时任意层普通左键拖动即框选；
## 关闭时保留 Ctrl+拖动框选作为兼容入口。两条路径都不依赖工具。

var cvs   # 宿主引用

func _init(host) -> void:
	cvs = host
func _unhandled_input(event: InputEvent) -> void:
	# 重建窗口期拦截输入：cvs.map_root 已 queue_free 但变量还指向它（BUG-06）
	if cvs.map_root != null and not is_instance_valid(cvs.map_root):
		return
	var pos = cvs.get_global_mouse_position()
	if event is InputEventMouseButton:
		var b := event as InputEventMouseButton
		if b.pressed:
			match b.button_index:
				MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
					# E1（批次 12）：滚轮缩放以鼠标为锚——鼠标下的世界点缩放前后不动（公式同 map_thumb BUG-13）
					var zw0: float = cvs.zoom
					cvs.zoom = clampf(cvs.zoom * (1.15 if b.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15), 0.5, 6.0)
					if not is_equal_approx(cvs.zoom, zw0):
						cvs.cam_pos += cvs.get_local_mouse_position() / zw0 - cvs.get_local_mouse_position() / cvs.zoom
					cvs._update_cam()
				MOUSE_BUTTON_MIDDLE:
					cvs._panning = true
				MOUSE_BUTTON_LEFT:
					_on_left_press(pos, b)
				MOUSE_BUTTON_RIGHT:
					_on_right_press(pos)
		else:
			if b.button_index == MOUSE_BUTTON_MIDDLE:
				cvs._panning = false
			if b.button_index == MOUSE_BUTTON_RIGHT:
				cvs._rmb_erase = false
			if b.button_index == MOUSE_BUTTON_LEFT:
				_on_left_release(pos)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if cvs._panning:
			cvs.cam_pos -= mm.relative / cvs.zoom
			cvs._update_cam()
		if cvs._drag_entity != null:
			cvs._move_drag_preview(pos)
			return
		if cvs._move_active:
			cvs._move_region_preview(pos)
			return
		if cvs._drag_spawn:
			cvs._drag_spawn_to(pos)
		if cvs._rmb_erase:
			cvs._erase_at(pos)
		if cvs._drag_paint and not cvs._drag_box:
			# 连续涂：只看层，不看工具
			if cvs.active_layer != cvs._ent_layer_index():
				cvs._apply_tool(pos)
		var c = cvs._cell_of(pos)
		cvs.cursor_info.emit("%d,%d" % [c.x, c.y])
		cvs.queue_redraw()


## 左键按下：按「当前层类型 + 修饰键」分派
func _on_left_press(pos: Vector2, b: InputEventMouseButton) -> void:
	# A1.1 吸管：Alt+左键取光标格瓦片（任何层下可用）
	if b.alt_pressed:
		cvs._pick_tile(pos)
		return
	# A6：Space+左键拖拽平移
	if Input.is_key_pressed(KEY_SPACE):
		cvs._panning = true
		return
	if cvs._paste_mode:
		cvs._paste_region(cvs._cell_of(pos))
		return
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
		return
	# 出生点标记可直接拖动——但只在实体层：在地形层上它只是路过的装饰，
	# 挡住那一格的笔刷会让人以为「这一格画不上」。框选模式下让位给框选。
	if not cvs.select_mode and cvs.active_layer == cvs._ent_layer_index() and cvs._on_spawn(pos):
		if cvs.is_layer_locked(cvs._ent_layer_index()):
			cvs._hint("实体层已锁定：解锁后再移动出生点")
			return
		cvs._push_undo()
		cvs._drag_spawn = true
		cvs._drag_start = pos
		return
	if cvs.active_layer == cvs._ent_layer_index():
		_on_entity_layer_press(pos, b)
	else:
		_on_tile_layer_press(pos, b)


## 实体层：框选模式下优先框选/整组拖动；否则点实体 = 选中并拖动，点空白 = 放置
func _on_entity_layer_press(pos: Vector2, b: InputEventMouseButton) -> void:
	var hit = cvs._entity_at(pos)
	if cvs.select_mode:
		# 框选开关打开：
		#   a) 按在「当前已选集合」的成员上 → 直接拖（单选也能拖，整组一起走）；
		#   b) 按在已框选组的外接框内 → 整组拖；
		#   c) 其余一律框选——包括压在「没被选中」的实体上，起手必须是拉框。
		# 先走 a/b 而不是无脑框选，否则框完之后永远拖不动（用户报的核心问题）。
		if hit != null and (cvs.selected_multi.has(hit) or hit == cvs.selected_entity):
			cvs.selected_entity = hit
			cvs._begin_entity_drag(hit, pos)
			return
		if cvs._inside_multi_box(pos):
			cvs._begin_group_drag(pos)
			return
		cvs._drag_paint = true
		cvs._drag_box = true
		cvs._drag_start = pos
		return
	if hit != null and cvs.selected_multi.size() > 1 and cvs.selected_multi.has(hit):
		# 按在「已框选的成员」上：保持整组，直接整组拖。
		# 不调 _select_entity_at，否则会先把选区塌缩成单选。
		cvs.selected_entity = hit
		cvs._begin_entity_drag(hit, pos)
	elif hit != null:
		cvs._select_entity_at(pos)
		cvs._begin_entity_drag(hit, pos)
	elif cvs._inside_multi_box(pos):
		# 按在已有框选范围内（但没按到具体某个实体）：拖动整组
		cvs._begin_group_drag(pos)
	elif b.ctrl_pressed:
		# 空白处 Ctrl+拖动 = 框选（没有工具按钮之后，这是唯一的框选入口）
		cvs._drag_paint = true
		cvs._drag_box = true
		cvs._drag_start = pos
	elif cvs.stamp_scene == "":
		# 没选资产就点到空白：把「先选资产」这条前置条件说出来，而不是静默无反应
		cvs._hint("先在左栏资产列表选一个实体，再左键放置")
	else:
		cvs._apply_tool(pos)


## 瓦片 / 装饰 / 碰撞层：拖动连续涂，框选模式下左键拖动 = 区域框选（兼容 Ctrl+拖动）
func _on_tile_layer_press(pos: Vector2, b: InputEventMouseButton) -> void:
	if cvs.is_layer_locked(cvs.active_layer):
		cvs._hint("当前图层已锁定：解锁后再编辑")
		return
	# 框选开关：优先于涂刷，否则每次起手都会先落一笔
	if cvs.select_mode or b.ctrl_pressed:
		# 区内起手 = 搬走这块（否则框完之后只能复制，不能移动）
		if cvs._in_region_sel(pos):
			cvs._begin_region_move(pos)
			return
		cvs._drag_paint = true
		cvs._drag_box = true
		cvs._drag_start = pos
		return
	cvs._push_undo()
	cvs._apply_tool(pos)
	cvs._drag_paint = true


## 右键 = 擦除。实体层删实体、其余层擦瓦片/碰撞，语义与左键对称。
func _on_right_press(pos: Vector2) -> void:
	if cvs._paste_mode:
		cvs._paste_mode = false
		cvs.queue_redraw()
		return
	if cvs.map_root == null:
		return
	cvs._push_undo()
	cvs._erase_at(pos)
	cvs._rmb_erase = true


func _on_left_release(pos: Vector2) -> void:
	cvs._panning = false
	if cvs._move_active:
		cvs._finish_region_move()
		return
	if cvs._drag_spawn:
		cvs._drag_spawn = false
		cvs._mark()
		return
	if cvs._drag_entity != null and is_instance_valid(cvs._drag_entity):
		cvs._finish_entity_drag()
		return
	if not cvs._drag_paint:
		return
	if cvs._drag_box:
		if cvs.active_layer == cvs._ent_layer_index():
			cvs._box_select(cvs._drag_start, pos)
		else:
			cvs._region_sel = cvs._cell_rect(cvs._drag_start, pos)
			cvs._hint("区域已选 %dx%d（Ctrl+C 复制三层，拖空白处可重选）" % [cvs._region_sel.size.x, cvs._region_sel.size.y])
	cvs._drag_paint = false
	cvs._drag_box = false


func cancel_paste_mode() -> void:
	cvs._paste_mode = false
	cvs.queue_redraw()
