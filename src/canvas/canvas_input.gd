extends RefCounted
## _canvas_input_ctrl：从 src/canvas/editor_canvas.gd 拆出的控制器。宿主状态经 cvs 引用。
##
## 没有工具概念——**place_kind（瓦片/摆放物）决定左键语义**；实例选择/拖动与层无关。
## 全局手势：中键拖动 = 平移（任意层）；滚轮 = 以鼠标为锚缩放。
## 瓦片 / 碰撞：左键按住拖动连续涂，右键拖动擦除。
## 摆放（place_kind="object"）：左键点空处 = 放置当前选中资产，
## 点实例 = 选中并拖动（任何层都可以选）；右键 = 删除该实例。
## 框选由 cvs.select_mode（左栏「框选」开关）决定：打开时任意层普通左键拖动即框选；
## 关闭时保留 Ctrl+拖动框选作为兼容入口。两条路径都不依赖工具。
##
## 所有拖拽/平移状态收敛到 cvs.gesture 单一枚举（见 editor_canvas.Gesture）。
## 起手即 begin_gesture，松手即 end_gesture；任何新起手都顶掉旧手势，不可能叠加。

var cvs   # 宿主引用
var _spawn_moved := false   # 出生点拖动本次是否真的动过格（点击不动 = 零副作用）
# 阶段三：纯悬停的重画闸——上一帧鼠标所在格与像素点（手势中不用它们，一律重画）
var _hover_cell := Vector2i(-999999, -999999)
var _hover_px := Vector2(-1e9, -1e9)
var _hover_hot := false   # 上次悬停时是否在框选组热区内（进入/离开都要重画加亮）

func _init(host) -> void:
	cvs = host

func _unhandled_input(event: InputEvent) -> void:
	# 重建窗口期拦截输入：cvs.map_root 已 queue_free 但变量还指向它
	if cvs.map_root != null and not is_instance_valid(cvs.map_root):
		return
	# 未装载地图：坐标换算依赖 grid/tile 尺寸，提前返回（E14：无图时鼠标不动画布）
	if not cvs.is_map_ready():
		return
	var pos = cvs.get_global_mouse_position()
	# E1 临时选点：模式独占左键命中与悬停候选，其余手势（中键平移/滚轮缩放）照常
	if cvs.pick_mode_active:
		if event is InputEventMouseMotion:
			var hov: String = cvs.pick_candidate_at(pos)
			if hov != cvs.pick_mode_hover:
				cvs.pick_mode_hover = hov
				cvs.queue_redraw()
			return
		if event is InputEventMouseButton:
			var pb := event as InputEventMouseButton
			if pb.pressed and pb.button_index == MOUSE_BUTTON_LEFT:
				var cand: String = cvs.pick_candidate_at(pos)
				cvs.pick_mode_code = cand
				cvs.pick_mode_hover = cand
				if cand != "":
					cvs.pick_mode_picked.emit(cand)
				else:
					cvs._hint("这里没有可选实例：只有实体有实例码，能进引用字段")
				cvs.queue_redraw()
				return
			if pb.pressed and pb.button_index == MOUSE_BUTTON_RIGHT:
				# 右键 = 取消（空码是合法提交值，不能和取消混用）
				cvs.pick_mode_cancelled.emit()
				return
	if event is InputEventMouseButton:
		var b := event as InputEventMouseButton
		if b.pressed:
			match b.button_index:
				MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
					# 滚轮缩放以鼠标为锚——鼠标下的世界点缩放前后不动。
					# 局部鼠标读于缩放前（=锚点世界坐标）：S-half = (L-cam)*zw0，
					# 代入 cam1 = cam0 + (S-half)*(1/zw0 - 1/z1) 化简得下式；光标在屏中心时相机不动
					var lm: Vector2 = cvs.get_local_mouse_position()
					var zw0: float = cvs.zoom
					cvs.zoom = clampf(cvs.zoom * (1.15 if b.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15), 0.5, 6.0)
					if not is_equal_approx(cvs.zoom, zw0):
						cvs.cam_pos += (lm - cvs.cam_pos) * (1.0 - zw0 / cvs.zoom)
					cvs._update_cam()
				MOUSE_BUTTON_MIDDLE:
					# 起手前先取消未完成的编辑手势（E05）：否则 PAN 直接顶掉手势，
					# 预览留在活体上、提取/保存会读到未提交坐标。
					if cvs.cancel_preview_gesture():
						cvs._hint("已取消未完成的编辑")
					cvs.begin_gesture(cvs.Gesture.PAN, MOUSE_BUTTON_MIDDLE)
				MOUSE_BUTTON_LEFT:
					_on_left_press(pos, b)
				MOUSE_BUTTON_RIGHT:
					_on_right_press(pos)
		else:
			# 松手只处理「是这一颗键起的那个手势」，避免中键松手误杀左键起手的平移
			if b.button_index == MOUSE_BUTTON_MIDDLE and cvs.gesture == cvs.Gesture.PAN \
					and cvs.gesture_button == MOUSE_BUTTON_MIDDLE:
				cvs.end_gesture()
			if b.button_index == MOUSE_BUTTON_RIGHT and cvs.gesture == cvs.Gesture.ERASE:
				cvs.end_gesture()
			if b.button_index == MOUSE_BUTTON_LEFT:
				_on_left_release(pos)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		match cvs.gesture:
			cvs.Gesture.PAN:
				cvs.cam_pos -= mm.relative / cvs.zoom
				cvs._update_cam()
			cvs.Gesture.ENTITY_DRAG:
				cvs._move_drag_preview(pos)
			cvs.Gesture.ENTITY_VERTEX:
				cvs._move_vertex_preview(pos)
			cvs.Gesture.ENTITY_RESIZE:
				cvs._move_resize_preview(pos)
			cvs.Gesture.LINK_DRAG:
				cvs._move_link_preview(pos)
			cvs.Gesture.REGION_MOVE:
				cvs._move_region_preview(pos)
			cvs.Gesture.SPAWN_DRAG:
				# 点击不动 = 不压撤销、不置脏：首次格间移动前才压快照，松手动过才 _mark
				var c0: Vector2i = cvs.grid.pick_cell((cvs.spawn as Node2D).position)
				var c1: Vector2i = cvs.root_cell(pos)
				if c1 != c0 and not _spawn_moved:
					# 压快照会取消预览手势并把出生点归位到起手快照（E05：撤销基线 = 原位）。
					# 取消同时结束了手势，这里按同一颗键重新起手，拖动继续、松手才会置脏。
					cvs.push_undo()
					cvs.begin_gesture(cvs.Gesture.SPAWN_DRAG, MOUSE_BUTTON_LEFT)
					_spawn_moved = true
				cvs._drag_spawn_to(pos)
			cvs.Gesture.ERASE:
				# 路径补格（E13）：两次鼠标事件之间经过的格全部擦，快速拖动不漏格
				_erase_path(pos)
			cvs.Gesture.PAINT:
		# 连续涂：PAINT 手势只从瓦片/碰撞按下起手，与层无关；同样补格路径
				_paint_path(pos)
		var c = cvs._active_cell(pos)
		cvs.cursor_info.emit("%d,%d" % [c.x, c.y])
		# 阶段三：悬停只失效高亮。手势中每帧都要重画预览（跟手）；没手势时的纯悬停
		# 只在「换格 / 进出框选组热区 / 位移 ≥ 2px」时重画——鼠标每次微动都付一整帧
		# _draw（网格 + 实例叠加 + 连线）没有必要，2px 内的预览错位肉眼不可见。
		if cvs.gesture != cvs.Gesture.NONE:
			_hover_hot = cvs._inside_multi_box(pos)
			cvs.queue_redraw()
		else:
			var hot: bool = cvs._inside_multi_box(pos)
			if c != _hover_cell or hot != _hover_hot or pos.distance_squared_to(_hover_px) >= 4.0:
				_hover_cell = c
				_hover_px = pos
				_hover_hot = hot
				cvs.queue_redraw()

## 笔画当前格（活动层局部）：涂/擦与坐标栏共用
func _stroke_cell(pos: Vector2) -> Vector2i:
	return cvs.grid.pick_cell(cvs._active_local(pos))

## 涂刷补格：从上一格到当前格逐格执行 _apply_tool（同一笔只压一次撤销）
func _paint_path(pos: Vector2) -> void:
	# 锁定层：拖动中每个 motion 都会进这里，一次提示就够（起手处已提示，写入侧也有守卫）
	if cvs.is_layer_locked(cvs.active_layer):
		return
	var c := _stroke_cell(pos)
	var cells: Array = [c] if not cvs._stroke_has_last \
		else cvs.grid.cells_between(cvs._stroke_last_cell, c)
	cvs._stroke_last_cell = c
	cvs._stroke_has_last = true
	for bc: Vector2i in cells:
		if cvs.place_kind == "object":
			cvs._apply_tool(pos)
			return   # 摆放不补格：一次鼠标事件只落一个实例
		cvs._paint(bc)
	if cells.size() > 1 and cvs._paint_pushed:
		cvs.queue_redraw()

## 擦除补格：经过的格全擦；实例命中只对当前点判（擦实例不做路径插值）
func _erase_path(pos: Vector2) -> void:
	# 锁定层：拖动中每个 motion 都会进这里，一次提示就够（起手处已提示，写入侧也有守卫）
	if cvs.is_layer_locked(cvs.active_layer):
		return
	if cvs._entity_hit_on(cvs.active_layer, pos) != null:
		cvs._erase_at(pos)
		cvs._stroke_has_last = false
		return
	var c := _stroke_cell(pos)
	var cells: Array = [c] if not cvs._stroke_has_last \
		else cvs.grid.cells_between(cvs._stroke_last_cell, c)
	cvs._stroke_last_cell = c
	cvs._stroke_has_last = true
	cvs._tool_ops_ctrl.erase_cells(cvs._tool_ops_ctrl._brush_cells_multi(cells))


## 左键按下：按「当前层类型 + 修饰键」分派
func _on_left_press(pos: Vector2, b: InputEventMouseButton) -> void:
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
		return
	# 吸管：Alt+左键取光标格瓦片（任何层下可用）。放在 map_root 守卫之后
	if b.alt_pressed:
		cvs._pick_tile(pos)
		return
	# Space+左键拖拽平移（同样先取消未完成编辑：平移不提交候选值）
	if Input.is_key_pressed(KEY_SPACE):
		if cvs.cancel_preview_gesture():
			cvs._hint("已取消未完成的编辑")
		cvs.begin_gesture(cvs.Gesture.PAN, MOUSE_BUTTON_LEFT)
		return
	if cvs._paste_mode:
		cvs._paste_region(cvs._cell_of(pos))
		return
	# 出生点标记可在实体放置模式下直接拖动——瓦片/碰撞笔刷优先，
	# 框选模式下让位给框选。当前图层锁定时也不拖。
	if not cvs.select_mode and cvs.place_kind == "object" and cvs._on_spawn(pos):
		if cvs.is_layer_locked(cvs.active_layer):
			cvs._hint("当前图层已锁定：解锁后再移动出生点")
			return
		_spawn_moved = false   # 撤销快照推迟到首次真移动前才压（点击不动 = 零副作用）
		cvs._spawn_origin = (cvs.spawn as Node2D).position
		cvs.begin_gesture(cvs.Gesture.SPAWN_DRAG, MOUSE_BUTTON_LEFT)
		cvs._drag_start = pos
		return
	# 碰撞元层没有资产可摆：无论左栏还留着什么笔刷，点击都必须是「涂碰撞」。
	# 否则 place_kind == "object" 时点击走摆放分支（撞上出生点还会开始拖出生点）。
	if cvs._is_grid_layer(cvs.active_layer):
		_on_tile_layer_press(pos, b)
		return
	if cvs.place_kind == "object":
		_on_object_layer_press(pos, b)
	else:
		_on_tile_layer_press(pos, b)


## 摆放模式（任何层都行）：框选模式下优先框选/整组拖动；否则点实体 = 选中并拖动，点空白 = 放置
func _on_object_layer_press(pos: Vector2, b: InputEventMouseButton) -> void:
	# 双击边加点（R-02）：命中线段就近插点；顶点附近 = 让位常规交互（拖拽顶点/选中）
	if b.double_click and cvs._add_vertex_at(pos):
		return
	# 顶点把手（R-02）：选中 poly/path 实例顶点优先于尺寸把手/移动/框选/放置
	var vi: int = cvs._vertex_handle_hit(pos)
	if vi >= 0:
		cvs._begin_vertex_drag(cvs.selected_entity, vi)
		return
	# 尺寸把手（R-04）：选中 sizeFields 实例的右下角把手优先于移动/框选/放置
	if cvs._resize_handle_hit(pos):
		cvs._begin_entity_resize(cvs.selected_entity, pos)
		return
	# E2 连线把手：选中实例的引用端点。优先于移动/框选，低于顶点/尺寸把手——
	# 端点一般落在别的实例上，两个把手通常不重叠；重叠时几何编辑优先。
	var lh: Dictionary = cvs._link_handle_hit(pos)
	if not lh.is_empty():
		cvs._begin_link_drag(lh, pos)
		return
	var hit = cvs._entity_at(pos)
	if cvs.select_mode:
	# 框选开关打开：
	# a) 按在「当前已选集合」的成员上 → 直接拖（单选也能拖，整组一起走）；
	# b) 按在已框选组的外接框内 → 整组拖；
	# c) 其余一律框选——包括压在「没被选中」的实体上，起手必须是拉框。
	# 先走 a/b 而不是无脑框选，否则框完之后永远拖不动（用户报的核心问题）。
		if hit != null and (cvs.selected_multi.has(hit) or hit == cvs.selected_entity):
			cvs.selected_entity = hit
			cvs._begin_entity_drag(hit, pos)
			return
		if cvs._inside_multi_box(pos):
			cvs._begin_group_drag(pos)
			return
		cvs.begin_gesture(cvs.Gesture.BOX, MOUSE_BUTTON_LEFT)
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
		# 空白处 Ctrl+拖动 = 框选（框选开关关闭时的兼容入口）
		cvs.begin_gesture(cvs.Gesture.BOX, MOUSE_BUTTON_LEFT)
		cvs._drag_start = pos
	elif cvs.stamp_asset == "":
		# 没选资产就点到空白：把「先选资产」这条前置条件说出来，而不是静默无反应
		cvs._hint("先在左栏资产列表选一个资产，再左键放置")
	else:
		cvs._apply_tool(pos)


## 瓦片 / 碰撞：拖动连续涂，框选模式下左键拖动 = 区域框选（兼容 Ctrl+拖动）
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
		cvs.begin_gesture(cvs.Gesture.BOX, MOUSE_BUTTON_LEFT)
		cvs._drag_start = pos
		return
	# 撤销覆盖不在这里压：涂刷是笔画制——首个真实改动前由 _paint stroke_begin 开始差量记录
	# （点击不动 = 零副作用，空点不再挤掉一条真实历史）。
	# （点击不动 = 零副作用，空点不再挤掉一条真实历史）
	cvs._paint_pushed = false
	cvs._stroke_has_last = false
	cvs._apply_tool(pos)
	cvs._stroke_last_cell = cvs.grid.pick_cell(cvs._active_local(pos))
	cvs._stroke_has_last = true
	cvs.begin_gesture(cvs.Gesture.PAINT, MOUSE_BUTTON_LEFT)


## 右键 = 擦除。实体放置模式删实体、其余擦瓦片/碰撞，语义与左键对称。
func _on_right_press(pos: Vector2) -> void:
	if cvs._paste_mode:
		cvs._paste_mode = false
		cvs.queue_redraw()
		return
	if cvs.map_root == null:
		return
	# 先判「这一格真能擦」再压撤销——锁定层/空白处不留下空快照
	if cvs.is_layer_locked(cvs.active_layer):
		cvs._hint("当前图层已锁定：解锁后再擦除")
		return
	# 左键手势进行中被右键打断：先按左键松手的语义收尾，再进擦除流程。
	# 否则 begin_gesture(ERASE) 直接顶掉旧手势——实体悬在预览位、区域搬迁半途而废。
	if cvs.gesture_button == MOUSE_BUTTON_LEFT and cvs.gesture != cvs.Gesture.NONE:
		match cvs.gesture:
			cvs.Gesture.ENTITY_DRAG:
				if cvs._drag_entity != null and is_instance_valid(cvs._drag_entity):
					cvs._finish_entity_drag()
			cvs.Gesture.ENTITY_RESIZE:
				cvs._finish_entity_resize()
			cvs.Gesture.ENTITY_VERTEX:
				cvs._finish_vertex_drag()
			cvs.Gesture.REGION_MOVE:
				cvs._finish_region_move()
			cvs.Gesture.LINK_DRAG:
				# 右键打断连线 = 取消（没有数据改动可收尾，只清暂存）
				cvs._link_node = null
				cvs._link_fd = {}
				cvs._link_hover = ""
				cvs._link_can_clear = false
			cvs.Gesture.SPAWN_DRAG:
				if _spawn_moved:
					cvs._mark()   # 与左键松手同语义：动过才置脏
		cvs.end_gesture()
	# 顶点删点（R-02）：右键顶点 = 删点，优先于擦除（poly≥3/path≥2 保底在实现里）
	if cvs._delete_vertex_at(pos):
		return
	# 空白处起手也进入追踪（E13）：从此处按住划过瓦片，沿途补擦。
	# 撤销快照推迟到首个真实改动前压（空起手 = 零副作用）。
	if not cvs._erase_hits(pos):
		cvs._paint_pushed = false
		cvs._stroke_has_last = true
		cvs._stroke_last_cell = _stroke_cell(pos)
		cvs.begin_gesture(cvs.Gesture.ERASE, MOUSE_BUTTON_RIGHT)
		return
	# H01：不预压快照。实例命中走 InstanceKey 差量（§7.5 阶段二），
	# 瓦片/碰撞命中交给 erase_cells 首改 stroke_begin。左笔画的差量已在上面 end_gesture→stroke_end 定格。
	cvs._paint_pushed = false
	cvs._stroke_has_last = true
	cvs._stroke_last_cell = _stroke_cell(pos)
	cvs._erase_at(pos)
	cvs.begin_gesture(cvs.Gesture.ERASE, MOUSE_BUTTON_RIGHT)


func _on_left_release(pos: Vector2) -> void:
	# 只收尾「左键起的手势」。中键起的平移不该被左键松手打断（的另一面）。
	if cvs.gesture_button != MOUSE_BUTTON_LEFT:
		return
	match cvs.gesture:
		cvs.Gesture.REGION_MOVE:
			# 先收尾再清手势：_finish_region_move 靠 gesture 判断这次搬动是否有效
			cvs._finish_region_move()
			cvs.end_gesture()
		cvs.Gesture.SPAWN_DRAG:
			cvs.end_gesture()
			if _spawn_moved:
				cvs._mark()   # 点击不动零副作用：不置脏、不无效化索引、不丢重做栈
		cvs.Gesture.ENTITY_DRAG:
			if cvs._drag_entity != null and is_instance_valid(cvs._drag_entity):
				cvs._finish_entity_drag()
			cvs.end_gesture()
		cvs.Gesture.ENTITY_RESIZE:
			cvs._finish_entity_resize()
			cvs.end_gesture()
		cvs.Gesture.LINK_DRAG:
			# 先收暂存再清手势？_finish_link_drag 自己清暂存，手势由这里收
			cvs.end_gesture()
			cvs._finish_link_drag()
		cvs.Gesture.ENTITY_VERTEX:
			cvs._finish_vertex_drag()
			cvs.end_gesture()
		cvs.Gesture.BOX:
			cvs.end_gesture()
			if cvs.place_kind == "object":
				cvs._box_select(cvs._drag_start, pos)
			else:
				cvs._region_sel = cvs._cell_rect(cvs._drag_start, pos)
				cvs._hint("区域已选 %dx%d（Ctrl+C 复制各层瓦片+实体，拖空白处可重选）" % [cvs._region_sel.size.x, cvs._region_sel.size.y])
		cvs.Gesture.PAINT, cvs.Gesture.PAN:
			cvs.end_gesture()


func cancel_paste_mode() -> void:
	cvs._paste_mode = false
	cvs.queue_redraw()
