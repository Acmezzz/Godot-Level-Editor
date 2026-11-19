extends RefCounted
## SelectionOps：从 src/canvas/editor_canvas.gd 拆出的控制器。宿主状态经 cvs 引用。

var cvs   # 宿主引用

func _init(host) -> void:
	cvs = host
## 按实体占位尺寸做外接框命中（旧实现写死 16/20px，大实体边缘点不中/擦不掉）。
## 跨层命中：从顶层向下取第一个命中的层，层内取中心距最近者；无命中返回 null。
func _entity_hit(pos: Vector2) -> Sprite2D:
	for li in range(cvs.layer_count() - 1, -1, -1):
		if li >= cvs.layer_ents.size():
			continue
		var hit := _entity_hit_in((cvs.layer_ents[li] as Node2D).get_children(), pos)
		if hit != null:
			return hit
	return null

## 单层命中核心：遍历给定容器子节点（tool_ops 擦除与跨层选区共用同一规则）
func _entity_hit_in(children: Array, pos: Vector2) -> Sprite2D:
	var best: Sprite2D = null
	var best_d = INF
	for e in children:
		var spr: Sprite2D = e as Sprite2D
		if spr == null or not spr.has_meta("scene"):
			continue
		var dsz: Vector2 = cvs.entity_display_size_of(spr)
		if dsz == Vector2.ZERO:
			dsz = Vector2(cvs.tile_px, cvs.tile_px)   # 未知尺寸退回 1 格
		if Rect2(spr.position - dsz * 0.5, dsz).has_point(pos):
			var d = spr.position.distance_squared_to(pos)
			if d < best_d:
				best = spr
				best_d = d
	return best


func _select_entity_at(pos: Vector2) -> void:
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
		return
	var best: Sprite2D = _entity_hit(pos)
	cvs.selected_entity = best
	cvs.selected_multi.clear()
	if best:
		cvs.entity_selected.emit(best)
	cvs.queue_redraw()


func _entity_at(pos: Vector2) -> Sprite2D:
	return _entity_hit(pos)

func _box_select(a: Vector2, b: Vector2) -> void:
	if cvs.map_root == null:
		return
	# 框选开关下「单击」也会走到这里：拉出的框比半格还小就按点选处理，
	# 否则在框选模式里点一下反而把选区清空（点不到格子中心就选不中任何东西）。
	if (a - b).length() < cvs.tile_px * 0.5:
		_select_entity_at(b)
		return
	cvs.selected_multi.clear()
	var r := Rect2(a.min(b), (a - b).abs())
	for e in cvs.ents_all():
		var spr := e as Sprite2D
		if spr and r.has_point(spr.position):
			cvs.selected_multi.append(spr)
	cvs.selected_entity = null
	if not cvs.selected_multi.is_empty():
		cvs.selected_entity = cvs.selected_multi[0]
		cvs.entity_selected.emit(cvs.selected_entity)
	cvs._hint("%d 个实体被框选" % cvs.selected_multi.size())
	cvs.queue_redraw()


## 多选集合的外接矩形
func _multi_bounds(targets: Array) -> Rect2:
	var r := Rect2()
	var first := true
	for s in targets:
		var p: Vector2 = (s as Sprite2D).position
		if first:
			r = Rect2(p, Vector2.ZERO)
			first = false
		else:
			r = r.expand(p)
	return r

## 框选组的外接框热区外扩量（像素）。框选开关打开时再放宽半格——
## 框选后最常见的下一步就是拖它。绘制（canvas_draw）也读这里，保证所见即所点。
func _multi_hot() -> float:
	return cvs.tile_px * (cvs.K.GROUP_HOT + (0.5 if cvs.select_mode else 0.0))

## 点是否落在「已有框选集合」的外接框内。
## 用于区分「拖动整组」和「重新框选」：落在框内就当作移动整组。
func _inside_multi_box(pos: Vector2) -> bool:
	var targets: Array = cvs._valid_multi()
	if targets.size() < 2:
		return false
	return _multi_bounds(targets).grow(_multi_hot()).has_point(pos)

## —— 实体拖拽移动：按下记录起点，移动只改预览，松手吸附格点并标脏 ——
## 锁检查跟着实体所在层走（实体可属任何栈层）。
func _begin_entity_drag(spr: Sprite2D, pos: Vector2) -> void:
	if cvs.is_layer_locked(cvs._layer_index_of(str(spr.get_meta("layer", "")))):
		cvs._hint("实体所在图层已锁定：解锁后再移动")
		return
	cvs._drag_entity = spr
	cvs._drag_entities = [spr]
	cvs._drag_origins = [spr.position]
	# 框选集合一起拖动（按住的是集合成员时）
	if cvs.selected_multi.size() > 1 and cvs.selected_multi.has(spr):
		cvs._drag_entities = cvs.selected_multi.duplicate()
		cvs._drag_origins.clear()
		for s in cvs._drag_entities:
			cvs._drag_origins.append((s as Sprite2D).position)
	cvs._drag_grab = pos
	cvs._drag_moved = false
	cvs.begin_gesture(cvs.Gesture.ENTITY_DRAG, MOUSE_BUTTON_LEFT)

## 从框内空白处拖动 = 平移整个框选集合（和按住某个成员拖一样，一次撤销步）
func _begin_group_drag(pos: Vector2) -> void:
	var targets0: Array = cvs._valid_multi()
	if targets0.is_empty():
		return
	if cvs.is_layer_locked(cvs._layer_index_of(str((targets0[0] as Sprite2D).get_meta("layer", "")))):
		cvs._hint("实体所在图层已锁定：解锁后再移动")
		return
	var targets: Array = cvs._valid_multi()
	if targets.size() < 2:
		return
	# cvs._drag_entity 指向第一个成员：_finish_entity_drag 靠它判断拖拽是否在进行
	cvs._drag_entity = targets[0] as Sprite2D
	cvs._drag_entities = targets.duplicate()
	cvs._drag_origins.clear()
	for s in cvs._drag_entities:
		cvs._drag_origins.append((s as Sprite2D).position)
	cvs._drag_grab = pos
	cvs._drag_moved = false
	cvs.begin_gesture(cvs.Gesture.ENTITY_DRAG, MOUSE_BUTTON_LEFT)


func _move_drag_preview(pos: Vector2) -> void:
	if cvs._drag_entity == null or not is_instance_valid(cvs._drag_entity):
		cvs._drag_entity = null
		return
	var delta: Vector2 = pos - cvs._drag_grab
	if delta.length() > 1.0:
		cvs._drag_moved = true
	for i in cvs._drag_entities.size():
		var s := cvs._drag_entities[i] as Sprite2D
		if is_instance_valid(s):
			s.position = (cvs._drag_origins[i] as Vector2) + delta
	cvs.queue_redraw()


func _finish_entity_drag() -> void:
	var moved: bool = cvs._drag_moved
	var targets: Array = cvs._drag_entities.duplicate()
	var origins: Array = cvs._drag_origins.duplicate()
	# 记下预览位置（吸附前），用于换算目标格
	var preview := []
	for s in targets:
		preview.append((s as Sprite2D).position if is_instance_valid(s) else Vector2.ZERO)
	cvs._drag_entity = null
	cvs._drag_entities.clear()
	cvs._drag_origins.clear()
	cvs._drag_moved = false
	if not moved or targets.is_empty():
 # 没真正拖动：把预览位移还原
		for i in targets.size():
			if is_instance_valid(targets[i]):
				(targets[i] as Sprite2D).position = origins[i]
		return
	# 恢复原位再「撤销 + 吸附放置」，一次拖拽 = 一个撤销步
	for i in targets.size():
		if is_instance_valid(targets[i]):
			(targets[i] as Sprite2D).position = origins[i]
	cvs._push_undo()
	for i in targets.size():
		var s := targets[i] as Sprite2D
		if not is_instance_valid(s):
			continue
		var cell: Vector2i = cvs._cell_of(preview[i])
		s.position = Vector2(cell) * cvs.tile_px + Vector2(cvs.tile_px, cvs.tile_px) * 0.5
	cvs._mark()
	cvs.queue_redraw()
	cvs._hint("已移动 %d 个实体（Ctrl+Z 撤销）" % targets.size())


func copy_selection() -> void:
	if cvs.map_root == null:
		return
	var sel: Array = cvs.selected_multi.duplicate()
	if sel.is_empty() and cvs.selected_entity and is_instance_valid(cvs.selected_entity):
		sel.append(cvs.selected_entity)
	if sel.is_empty():
		cvs._hint("先选中实体再复制（Ctrl+C）")
		return
	var center := Vector2.ZERO
	for s in sel:
		center += (s as Sprite2D).position
	center /= sel.size()
	cvs._clipboard.clear()
	cvs._last_copy_region = false   # 之后 Ctrl+V 走实体粘贴而不是区域粘贴
	for s in sel:
		var spr := s as Sprite2D
		cvs._clipboard.append({
			"scene": str(spr.get_meta("scene")),
			"code": str(spr.get_meta("code", "")),
			"dx": spr.position.x - center.x,
			"dy": spr.position.y - center.y,
			"flip_h": spr.flip_h,
			"layer": str(spr.get_meta("layer", "")),
			"functions": (spr.get_meta("functions", []) as Array).duplicate(true),
 # deep=true：props 里的嵌套字典各副本独立，避免改一个影响全部
			"props": (spr.get_meta("props", {}) as Dictionary).duplicate(true),
		})
	cvs._hint("已复制 %d 个实体（Ctrl+V 粘贴到光标处）" % cvs._clipboard.size())

## 剪切 = 复制 + 删除，但整件事只算一个撤销步。
## （分别调 copy_selection + delete_selection 会推两次撤销，Ctrl+Z 一次撤不回来）

func cut_selection() -> void:
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
		return
	if cvs.is_layer_locked(cvs.active_layer):
		cvs._hint("当前图层已锁定：解锁后再剪切")
		return
	var sel: Array = cvs.selected_multi.duplicate()
	if sel.is_empty() and cvs.selected_entity and is_instance_valid(cvs.selected_entity):
		sel.append(cvs.selected_entity)
	if sel.is_empty():
		cvs._hint("先选中实体再剪切（Ctrl+X）")
		return
	# 复用复制逻辑生成剪贴板（它负责算中心与相对偏移）
	copy_selection()
	if cvs._clipboard.is_empty():
		return
	cvs._push_undo()
	var n := 0
	for s in sel:
		if is_instance_valid(s):
			(s.get_parent() as Node2D).remove_child(s)
			s.free()
			n += 1
	cvs.selected_multi.clear()
	cvs.selected_entity = null
	cvs._mark()
	cvs.queue_redraw()
	cvs._hint("已剪切 %d 个实体（Ctrl+V 粘贴，Ctrl+Z 撤销）" % n)


func paste_at(pos: Vector2) -> void:
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
		return
	if cvs._clipboard.is_empty():
		cvs._hint("剪贴板为空：先用 Ctrl+C 复制实体")
		return
	# 落点吸附到格子中心：否则保存(格坐标)再载入后位置会漂移
	var base: Vector2 = Vector2(cvs._cell_of(pos)) * cvs.tile_px + Vector2(cvs.tile_px, cvs.tile_px) * 0.5
	cvs._push_undo()
	# 先建副本并给每个 fresh 码；建 旧码→新码 映射，供组内引用重映射
	var copied := {}   # 旧码 → 新码
	var built: Array = []   # [{spr, scene, props, functions}]
	var target: int = cvs.active_layer if cvs.active_layer < cvs.layer_count() else 0
	for t in cvs._clipboard:
		var spr := Sprite2D.new()
		var scene_id := str(t.get("scene", ""))
		spr.texture = cvs.thumbs.get(scene_id)
		spr.position = base + Vector2(t.get("dx", 0.0), t.get("dy", 0.0))
		spr.flip_h = bool(t.get("flip_h", false))
		spr.set_meta("scene", scene_id)
		var code: String = cvs._fresh_inst_code()
		spr.set_meta("code", code)
		var src := str(t.get("code", ""))
		if src != "":
			copied[src] = code
 # 每个副本独立一份数据；组内引用的重映射在下面统一做
		built.append({
			"spr": spr,
			"scene": scene_id,
			"props": (t.get("props", {}) as Dictionary).duplicate(true),
			"functions": (t.get("functions", []) as Array).duplicate(true),
		})
		spr.set_meta("layer", cvs.layer_id(target))
		(cvs.layer_ents[target] as Node2D).add_child(spr)
		cvs._fit_sprite(spr, scene_id)
	# 副本间引用重映射：props 声明驱动（entity_ref fields）+ functions 盲重映射
	for b in built:
		var spr2: Sprite2D = b.spr
		var props2: Dictionary = b.props
		for edef in cvs.manifest.get("entities", []):
			if str(edef.get("id", "")) != str(b.scene):
				continue
			for field in edef.get("fields", []):
				var field_id := str(field.get("id", ""))
				var target_id := str(props2.get(field_id, ""))
				if str(field.get("type", "")) == "entity_ref" and copied.has(target_id):
					props2[field_id] = copied[target_id]
			break
		var functions2: Array = b.functions
		_remap_refs_in(functions2, copied)
		spr2.set_meta("props", props2)
		spr2.set_meta("functions", functions2)
	cvs._mark()
	cvs.queue_redraw()
	cvs._hint("已粘贴 %d 个实体（Ctrl+Z 撤销）" % cvs._clipboard.size())


func delete_selection() -> void:
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
		return
	var victims: Array = cvs.selected_multi.duplicate()
	if victims.is_empty() and cvs.selected_entity and is_instance_valid(cvs.selected_entity):
		victims.append(cvs.selected_entity)
	if victims.is_empty():
		cvs._hint("先在画布上点选或框选实体，再按 Del 删除")
		return
	cvs._push_undo()
	for v in victims:
		if is_instance_valid(v):
			(v.get_parent() as Node2D).remove_child(v)
			v.free()
	cvs.selected_multi.clear()
	cvs.selected_entity = null
	cvs._mark()
	cvs.queue_redraw()


## 翻转选中实体（单个或框选集合）：每个精灵 toggle flip_h；一个撤销步。
## 返回是否真的翻了（无选中返回 false，快捷键据此决定是否吞键）。
func flip_selected() -> bool:
	var targets := []
	if cvs.selected_multi.size() > 0:
		targets = cvs._valid_multi()
	elif is_instance_valid(cvs.selected_entity):
		targets.append(cvs.selected_entity)
	if targets.is_empty():
		return false
	cvs._push_undo()
	for s in targets:
		(s as Sprite2D).flip_h = not (s as Sprite2D).flip_h
	cvs._mark()
	cvs.queue_redraw()
	return true

## —— 框选区域拖动搬迁（瓦片 / 装饰 / 碰撞三层 + 区域内实体） ——
## 按下时只快照，不立刻搬；松手才「推撤销 → 擦源 → 写目标」。
## 这样拖动中数据没被改过，中途松手/取消都不会留下半截状态。
## 状态字段挂宿主 cvs（本项目控制器一律经 cvs 读写宿主状态）：
## cvs._move_snap / _move_from / _move_grab / _move_cell_delta / _move_active

## 点是否落在已有区域选区里（用来区分「拖走这块」和「重新框选」）
func _in_region_sel(pos: Vector2) -> bool:
	if cvs._region_sel.size.x <= 0 or cvs._region_sel.size.y <= 0:
		return false
	return cvs._region_sel.has_point(cvs._cell_of(pos))

func _snapshot_region(sel: Rect2i) -> Dictionary:
	# 层栈快照：tiles = {层id: [[x,y,atlas,ax,ay]...]}，碰撞/实体照旧（实体带 layer）
	var snap := {"tiles": {}, "collision": [], "ents": [], "size": sel.size}
	for li in cvs.layer_tiles.size():
		var lid: String = cvs.layer_id(li)
		if lid == "":
			continue
		var cells := []
		for y in range(sel.position.y, sel.end.y):
			for x in range(sel.position.x, sel.end.x):
				var c := Vector2i(x, y)
				var tac: Vector2i = (cvs.layer_tiles[li] as TileMapLayer).get_cell_atlas_coords(c)
				if tac != Vector2i(-1, -1):
					cells.append([x, y, (cvs.layer_tiles[li] as TileMapLayer).get_cell_source_id(c), tac.x, tac.y])
		if not cells.is_empty():
			snap["tiles"][lid] = cells
	for y2 in range(sel.position.y, sel.end.y):
		for x2 in range(sel.position.x, sel.end.x):
			var c2 := Vector2i(x2, y2)
			if cvs.collision.get_cell_source_id(c2) != -1:
				var cm = cvs._collision_meta.get(c2, null)
				if cm != null:
					snap["collision"].append([x2, y2, str(cm.get("type", "solid")), str(cm.get("shape", ""))])
				else:
					snap["collision"].append([x2, y2])
	for e in cvs.ents_all():
		var spr := e as Sprite2D
		if spr == null or not spr.has_meta("scene"):
			continue
		if sel.has_point(cvs._cell_of(spr.position)):
			snap["ents"].append(spr)
	return snap

func _begin_region_move(pos: Vector2) -> void:
	if cvs.is_layer_locked(cvs.active_layer):
		cvs._hint("当前图层已锁定：解锁后再移动区域")
		return
	if cvs._any_layer_locked():
		cvs._hint("有图层处于锁定状态：解锁后再移动区域")
		return
	cvs._move_snap = _snapshot_region(cvs._region_sel)
	cvs._move_from = cvs._region_sel.position
	cvs._move_grab = pos
	cvs._move_cell_delta = Vector2i.ZERO
	cvs.begin_gesture(cvs.Gesture.REGION_MOVE, MOUSE_BUTTON_LEFT)


func _move_region_preview(pos: Vector2) -> void:
	var d: Vector2i = cvs._cell_of(pos) - cvs._cell_of(cvs._move_grab)
	if d != cvs._move_cell_delta:
		cvs._move_cell_delta = d
		cvs.queue_redraw()


func _finish_region_move() -> void:
	var active: bool = cvs._move_active
	var snap: Dictionary = cvs._move_snap
	var from: Vector2i = cvs._move_from
	var delta: Vector2i = cvs._move_cell_delta
	cvs._move_snap = {}
	cvs._move_cell_delta = Vector2i.ZERO
	if not active or delta == Vector2i.ZERO:
		return
	cvs._push_undo()
	# 先清源（各层瓦片 + 碰撞），再写目标；实体按位置平移
	for lid in (snap.get("tiles", {}) as Dictionary):
		var li: int = cvs._layer_index_of(str(lid))
		if li < 0:
			continue
		for t in (snap.get("tiles", {})[lid] as Array):
			(cvs.layer_tiles[li] as TileMapLayer).erase_cell(Vector2i(int(t[0]), int(t[1])))
	for t in snap.get("collision", []):
		cvs.set_collision_cell(Vector2i(int(t[0]), int(t[1])), false)
	for lid2 in (snap.get("tiles", {}) as Dictionary):
		var li2: int = cvs._layer_index_of(str(lid2))
		if li2 < 0:
			continue
		for t2 in (snap.get("tiles", {})[lid2] as Array):
			(cvs.layer_tiles[li2] as TileMapLayer).set_cell(
				Vector2i(int(t2[0]), int(t2[1])) + delta, int(t2[2]), Vector2i(int(t2[3]), int(t2[4])))
	for t in snap.get("collision", []):
		var ta := t as Array
		if ta.size() >= 4:
			cvs.set_collision_cell(Vector2i(int(ta[0]), int(ta[1])) + delta, true, str(ta[2]), str(ta[3]))
		else:
			cvs.set_collision_cell(Vector2i(int(ta[0]), int(ta[1])) + delta, true)
	for s in snap.get("ents", []):
		if is_instance_valid(s):
			(s as Sprite2D).position += Vector2(delta) * cvs.tile_px
	# 选区跟着搬到新位置，方便接着拖第二下
	cvs._region_sel.position = from + delta
	cvs._mark()
	cvs.queue_redraw()
	cvs._hint("已移动区域 %dx%d 偏移 (%d,%d)（Ctrl+Z 撤销）" % [
		cvs._region_sel.size.x, cvs._region_sel.size.y, delta.x, delta.y])

func copy_region() -> void:
	if cvs.map_root == null:
		return
	if cvs.place_kind == "entity":
		copy_selection()
		return
	if cvs._region_sel.size.x <= 0:
		cvs._hint("先框选一块区域再复制")
		return
	# 层栈剪贴板：tiles = {层id: [[dx,dy,atlas,ax,ay]...]}，碰撞/实体照旧（实体带 layer）
	cvs._region_clip = {"tiles": {}, "collision": [], "size": cvs._region_sel.size}
	# 层名凭据：粘贴时同图按 id 直配，跨图按层名重映射（谁的名字谁带走）
	var lnames := {}
	for li2 in cvs.layer_count():
		lnames[cvs.layer_id(li2)] = cvs.layer_name(li2)
	cvs._region_clip["layer_names"] = lnames
	for li in cvs.layer_tiles.size():
		var lid: String = cvs.layer_id(li)
		if lid == "":
			continue
		var cells := []
		for y in range(cvs._region_sel.position.y, cvs._region_sel.end.y):
			for x in range(cvs._region_sel.position.x, cvs._region_sel.end.x):
				var d: Vector2i = Vector2i(x, y) - cvs._region_sel.position
	 # 区域剪贴板带 atlas（source_id）——多图集瓦片整块搬运
				var tac: Vector2i = (cvs.layer_tiles[li] as TileMapLayer).get_cell_atlas_coords(Vector2i(x, y))
				if tac != Vector2i(-1, -1):
					var tsid: int = (cvs.layer_tiles[li] as TileMapLayer).get_cell_source_id(Vector2i(x, y))
					cells.append([d.x, d.y, tsid, tac.x, tac.y])
		if not cells.is_empty():
			cvs._region_clip["tiles"][lid] = cells
	for y2 in range(cvs._region_sel.position.y, cvs._region_sel.end.y):
		for x2 in range(cvs._region_sel.position.x, cvs._region_sel.end.x):
			if cvs.collision.get_cell_source_id(Vector2i(x2, y2)) != -1:
	 # 区域剪贴板带碰撞类型/形状
				var cm = cvs._collision_meta.get(Vector2i(x2, y2), null)
				if cm != null:
					cvs._region_clip["collision"].append([x2 - cvs._region_sel.position.x, y2 - cvs._region_sel.position.y, str(cm.get("type", "solid")), str(cm.get("shape", ""))])
				else:
					cvs._region_clip["collision"].append([x2 - cvs._region_sel.position.x, y2 - cvs._region_sel.position.y])
	# 实体也一起复制：区域块含实体，才能整块房间复用（层随实体走）
	var ents_clip := []
	for e in cvs.ents_all():
		var spr := e as Sprite2D
		if spr == null or not spr.has_meta("scene"):
			continue
		var ec: Vector2i = cvs._cell_of(spr.position)
		if cvs._region_sel.has_point(ec):
			ents_clip.append({
				"dx": ec.x - cvs._region_sel.position.x,
				"dy": ec.y - cvs._region_sel.position.y,
				"scene": str(spr.get_meta("scene", "")),
 # 朝向随块复制；code 是引用重映射的前提；layer 是层重映射的前提
				"flip_h": bool(spr.flip_h),
				"code": str(spr.get_meta("code", "")),
				"layer": str(spr.get_meta("layer", "")),
				"functions": (spr.get_meta("functions", []) as Array).duplicate(true),
				"props": (spr.get_meta("props", {}) as Dictionary).duplicate(true),
			})
	cvs._region_clip["ents"] = ents_clip
	cvs._last_copy_region = true
	var tcount := 0
	for lid2 in (cvs._region_clip["tiles"] as Dictionary):
		tcount += ((cvs._region_clip["tiles"] as Dictionary)[lid2] as Array).size()
	cvs._hint("已复制 %dx%d 区域（%d 瓦片 / %d 实体；Ctrl+V 幽灵预览，左键落位/右键或 Esc 取消）" % [
		cvs._region_sel.size.x, cvs._region_sel.size.y, tcount, ents_clip.size()])

## 任一图层锁定即拒绝区域级操作：部分跳过会让剪贴板与实际删除不一致。

## 区域剪切 = 复制区域内各层瓦片 + 碰撞 + 实体，再把源区域清空。整件事一个撤销步。
func cut_region() -> void:
	if cvs.map_root == null:
		return
	if cvs.place_kind == "entity":
		cut_selection()
		return
	if cvs._region_sel.size.x <= 0:
		cvs._hint("先框选一块区域再剪切")
		return
	if cvs._any_layer_locked():
		cvs._hint("有图层处于锁定状态：解锁后再剪切区域")
		return
	copy_region()
	if cvs._region_clip.is_empty():
		return
	cvs._push_undo()
	for y in range(cvs._region_sel.position.y, cvs._region_sel.end.y):
		for x in range(cvs._region_sel.position.x, cvs._region_sel.end.x):
			var c := Vector2i(x, y)
			for tn in cvs.layer_tiles:
				(tn as TileMapLayer).erase_cell(c)
			cvs.set_collision_cell(c, false)
	# 区域内的实体一并移除（它们已经进了剪贴板）
	for e in cvs.ents_all():
		var spr := e as Sprite2D
		if spr == null or not spr.has_meta("scene"):
			continue
		if cvs._region_sel.has_point(cvs._cell_of(spr.position)):
			(spr.get_parent() as Node2D).remove_child(spr)
			spr.free()
	cvs._mark()   # 区域剪切含实体删除，实体索引/实例列表缓存一并失效
	cvs.queue_redraw()
	cvs._hint("已剪切区域 %dx%d（Ctrl+V 粘贴 / Ctrl+Z 撤销）" % [cvs._region_sel.size.x, cvs._region_sel.size.y])


func _paste_region(origin: Vector2i) -> void:
	if cvs.map_root == null or cvs._region_clip.is_empty():
		return
	if cvs._any_layer_locked():
		cvs._hint("有图层处于锁定状态：解锁后再粘贴区域")
		return
	cvs._push_undo()
	# 粘贴按 层id×atlas 维度重建（tiles = {层id: [[dx,dy,atlas,ax,ay]...]}）
	# 层重映射：同图按 id 直配，跨图按层名，都不匹配则落最底层（末尾黄字提示）
	var lnames: Dictionary = cvs._region_clip.get("layer_names", {})
	var missed: Array = []
	for lid in (cvs._region_clip.get("tiles", {}) as Dictionary):
		var li: int = _paste_layer_index(str(lid), lnames, missed)
		for t in (cvs._region_clip.get("tiles", {})[lid] as Array):
			var ta := t as Array
			(cvs.layer_tiles[li] as TileMapLayer).set_cell(
				origin + Vector2i(int(ta[0]), int(ta[1])), int(ta[2]), Vector2i(int(ta[3]), int(ta[4])))
	for t in cvs._region_clip.get("collision", []):
		var cc := origin + Vector2i(int(t[0]), int(t[1]))
		if (t as Array).size() >= 4:
			cvs.set_collision_cell(cc, true, str(t[2]), str(t[3]))
		else:
			cvs.set_collision_cell(cc, true)
	# 实体：按相对格位重建，落回各自的层（找不到同码层落最底层）；引用重映射照旧
	var id_map := {}   # 旧码 → 粘贴后新码
	var pasted: Array = []
	for t in cvs._region_clip.get("ents", []):   # 键统一为 ents（预览也读 ents）
		var spr := Sprite2D.new()
		var scene_id := str(t.get("scene", ""))
		spr.texture = cvs.thumbs.get(scene_id)
		spr.position = Vector2(origin + Vector2i(int(t.get("dx", 0)), int(t.get("dy", 0)))) * cvs.tile_px \
			+ Vector2(cvs.tile_px, cvs.tile_px) * 0.5
		spr.set_meta("scene", scene_id)
 # 恢复朝向；新块给新码，旧码只留作 id_map 的重映射键
		spr.flip_h = bool(t.get("flip_h", false))
		spr.set_meta("props", (t.get("props", {}) as Dictionary).duplicate(true))
		spr.set_meta("functions", (t.get("functions", []) as Array).duplicate(true))
		var ei: int = _paste_layer_index(str(t.get("layer", "")), lnames, missed)
		spr.set_meta("layer", cvs.layer_id(ei))
		(cvs.layer_ents[ei] as Node2D).add_child(spr)
		cvs._fit_sprite(spr, scene_id)
		cvs._ensure_code(spr)
		var old_code := str(t.get("code", ""))
		if old_code != "":
			id_map[old_code] = str(spr.get_meta("code", ""))
		pasted.append(spr)
	# 引用重映射：props/functions 里命中旧 id 的字符串全部换成新 id
	for spr2 in pasted:
		var props2: Dictionary = (spr2.get_meta("props", {}) as Dictionary).duplicate(true)
		var functions2: Array = (spr2.get_meta("functions", []) as Array).duplicate(true)
		var changed := _remap_refs_in(props2, id_map)
		if _remap_refs_in(functions2, id_map):
			changed = true
		if changed:
			spr2.set_meta("props", props2)
		spr2.set_meta("functions", functions2)
	if not missed.is_empty():   # 跨图粘贴按名匹配失败的层：黄字提示哪几层落了底层
		cvs._hint("有 %d 个层按名匹配失败，其内容落在最底层：%s" % [missed.size(), ", ".join(missed)])
	cvs._mark()   # 区域粘贴含实体，保持索引置脏
	cvs._paste_mode = false
	cvs._hint("区域已粘贴")

## 区域粘贴的层重映射：源层 id 在目标图存在则直配；否则按层名匹配；
## 都不匹配则落最底层（index 0），层名记入 missed（调用方末尾黄字提示）。
func _paste_layer_index(src_lid: String, lnames: Dictionary, missed: Array) -> int:
	var li: int = cvs._layer_index_of(src_lid)
	if li >= 0:
		return li
	var nm: String = str(lnames.get(src_lid, ""))
	if nm != "":
		for i in cvs.layer_count():
			if cvs.layer_name(i) == nm:
				return i
	# 名字已知但目标图没有同名层、或名字未知：都算没匹配上，记下来提示
	if not missed.has(nm if nm != "" else src_lid):
		missed.append(nm if nm != "" else src_lid)
	return 0

## 区域粘贴的引用重映射：递归遍历 Dictionary/Array，把命中 id_map 的字符串换成新 id。
## 返回是否发生了替换。props 与 functions 共用（两者都可能有指向实例的字符串）。
func _remap_refs_in(container, id_map: Dictionary) -> bool:
	var changed := false
	var stack: Array = [container]
	while not stack.is_empty():
		var cur = stack.pop_back()
		if cur is Dictionary:
			for k in (cur as Dictionary).keys():
				var v = (cur as Dictionary)[k]
				if v is String and id_map.has(v):
					(cur as Dictionary)[k] = id_map[v]
					changed = true
				elif v is Dictionary or v is Array:
					stack.append(v)
		elif cur is Array:
			var arr := cur as Array
			for i in arr.size():
				var v2 = arr[i]
				if v2 is String and id_map.has(v2):
					arr[i] = id_map[v2]
					changed = true
				elif v2 is Dictionary or v2 is Array:
					stack.append(v2)
	return changed

func _cell_rect(a: Vector2, b: Vector2) -> Rect2i:
	var ca: Vector2i = cvs._cell_of(a)
	var cb: Vector2i = cvs._cell_of(b)
	return Rect2i(Vector2i(mini(ca.x, cb.x), mini(ca.y, cb.y)),
		Vector2i(absi(ca.x - cb.x) + 1, absi(ca.y - cb.y) + 1))
