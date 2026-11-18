extends RefCounted
## _canvas_input_ctrl：从 src/canvas/editor_canvas.gd 拆出的控制器（审查 8.3 表）。宿主状态经 alias 引用。

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
					# A1.1 吸管：Alt+左键取光标格瓦片（任何工具下可用）；A6：Space+左键拖拽平移
					if event.alt_pressed:
						cvs._pick_tile(pos)
						return
					if Input.is_key_pressed(KEY_SPACE):
						cvs._panning = true
						return
					if cvs._paste_mode:
						cvs._paste_region(cvs._cell_of(pos))
						return
					if cvs.map_root == null:
						cvs._hint("无地图：先新建或打开一张地图")
					elif cvs.tool == "rect":
						# BUG-12/B2：press 不推撤销（push 在 _rect_fill 填充前）；锁定层拒绝拖拽起点
						if cvs.is_layer_locked(cvs.active_layer):
							cvs._hint("当前图层已锁定：解锁后再填充")
							return
						cvs._drag_paint = true
						cvs._drag_start = pos
					elif cvs.tool == "stamp":
						cvs._apply_tool(pos)
					elif cvs.tool == "select":
						if cvs._ent_layer_index() == cvs.active_layer:
							var hit = cvs._entity_at(pos)
							if hit != null and cvs.selected_multi.size() > 1 and cvs.selected_multi.has(hit):
								# 按在「已框选的成员」上：保持整组，直接整组拖。
								# 不调 cvs._apply_tool，否则会先把选区塌缩成单选。
								cvs.selected_entity = hit
								cvs._begin_entity_drag(hit, pos)
							elif hit != null:
								cvs._apply_tool(pos)  # 点在实体上 = 单选
								# 按住即进入拖拽（松手时才写位置并标脏）
								cvs._begin_entity_drag(hit, pos)
							elif cvs._inside_multi_box(pos):
								# 按在已有框选范围内（但没按到具体某个实体）：
								# 拖动整组，而不是清掉选区重新框选。
								# 实体很小、彼此又挨得近时，逐点命中太难，这个入口必须有。
								cvs._begin_group_drag(pos)
							else:
								# 空地按下 = 开始框选（拖拽松手完成）
								cvs._drag_paint = true
								cvs._drag_start = pos
						else:
							# 瓦片/碰撞层 = 区域框选（松手定选区，Ctrl+C 捕获三层）
							cvs._drag_paint = true
							cvs._drag_start = pos
					else:
						# P-18：锁定层的无效点击不推撤销快照（否则 80 步栈被相同快照灌满）
						if cvs.is_layer_locked(cvs.active_layer):
							cvs._hint("当前图层已锁定：解锁后再编辑")
							return
						# BUG-04：cvs.spawn 的快照由 cvs._apply_tool 统一推，这里排除避免双重撤销步
						if cvs.tool != "spawn":
							cvs._push_undo()
						cvs._apply_tool(pos)
						if cvs.tool == "paint" or cvs.tool == "erase":
							cvs._drag_paint = true
				MOUSE_BUTTON_RIGHT:
					if cvs._paste_mode:
						cvs._paste_mode = false
						cvs.queue_redraw()
						return
					# 右键 = 快捷擦除（不分图层，直接擦瓦片）
					cvs._push_undo()
					cvs._erase_at(pos)
					cvs._rmb_erase = true
		else:
			if b.button_index == MOUSE_BUTTON_MIDDLE:
				cvs._panning = false
			if b.button_index == MOUSE_BUTTON_RIGHT:
				cvs._rmb_erase = false
			if b.button_index == MOUSE_BUTTON_LEFT and cvs._drag_entity != null and is_instance_valid(cvs._drag_entity):
				cvs._finish_entity_drag()
				return
			if b.button_index == MOUSE_BUTTON_LEFT and cvs._drag_paint:
				if cvs.tool == "rect":
					cvs._rect_fill(cvs._cell_of(cvs._drag_start), cvs._cell_of(pos))
				elif cvs.tool == "select":
					if cvs._ent_layer_index() == cvs.active_layer:
						cvs._box_select(cvs._drag_start, pos)
					else:
						cvs._region_sel = cvs._cell_rect(cvs._drag_start, pos)
						cvs._hint("区域已选 %dx%d（Ctrl+C 复制三层，拖拽可重选）" % [cvs._region_sel.size.x, cvs._region_sel.size.y])
				cvs._drag_paint = false
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if cvs._panning:
			cvs.cam_pos -= mm.relative / cvs.zoom
			cvs._update_cam()
		if cvs._drag_entity != null:
			cvs._move_drag_preview(pos)
			return
		if cvs._rmb_erase:
			cvs._erase_at(pos)
		if cvs._drag_paint and (cvs.tool == "paint" or cvs.tool == "erase"):
			cvs._apply_tool(pos)
		var c = cvs._cell_of(pos)
		cvs.cursor_info.emit("%d,%d" % [c.x, c.y])
		cvs.queue_redraw()


func cancel_paste_mode() -> void:
	cvs._paste_mode = false
	cvs.queue_redraw()
