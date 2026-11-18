extends RefCounted
## SelectionOps：从 src/canvas/editor_canvas.gd 拆出的控制器（审查 8.3 表）。宿主状态经 alias 引用。

var cvs   # 宿主引用

func _init(host) -> void:
	cvs = host
## P-11：按实体占位尺寸做外接框命中（旧实现写死 16/20px，大实体边缘点不中/擦不掉）。
## 返回命中的实体（命中多个时取中心距最近者）；无命中返回 null。
func _entity_hit(pos: Vector2) -> Sprite2D:
	var best: Sprite2D = null
	var best_d = INF
	for e in cvs.entities.get_children():
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
	for e in cvs.entities.get_children():
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
func _begin_entity_drag(spr: Sprite2D, pos: Vector2) -> void:
	if cvs.is_layer_locked(cvs._ent_layer_index()):
		cvs._hint("实体层已锁定：解锁后再移动")
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

## 从框内空白处拖动 = 平移整个框选集合（和按住某个成员拖一样，一次撤销步）
func _begin_group_drag(pos: Vector2) -> void:
	if cvs.is_layer_locked(cvs._ent_layer_index()):
		cvs._hint("实体层已锁定：解锁后再移动")
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
			"ent_id": str(spr.get_meta("ent_id", "")),
			"dx": spr.position.x - center.x,
			"dy": spr.position.y - center.y,
			"flip_h": spr.flip_h,
			"def_id": str(spr.get_meta("def_id", "")),
			# deep=true：props 里的 stats 等嵌套字典各副本独立，避免改一个影响全部
			"props": (spr.get_meta("props", {}) as Dictionary).duplicate(true),
		})
	cvs._hint("已复制 %d 个实体（Ctrl+V 粘贴到光标处）" % cvs._clipboard.size())

## 剪切 = 复制 + 删除，但整件事只算一个撤销步。
## （分别调 copy_selection + delete_selection 会推两次撤销，Ctrl+Z 一次撤不回来）

func cut_selection() -> void:
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
		return
	if cvs.is_layer_locked(cvs._ent_layer_index()):
		cvs._hint("实体层已锁定：解锁后再剪切")
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
			cvs.entities.remove_child(s)
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
	var copied_ids := {}
	var paste_ids: Array[String] = []
	var next_id: int = int(cvs.ent_id_counter)
	for t in cvs._clipboard:
		next_id += 1
		var paste_id := "e_%d" % next_id
		paste_ids.append(paste_id)
		var source_id := str(t.get("ent_id", ""))
		if source_id != "":
			copied_ids[source_id] = paste_id
	cvs._push_undo()
	for i in cvs._clipboard.size():
		var t: Dictionary = cvs._clipboard[i]
		var spr := Sprite2D.new()
		var scene_id := str(t.get("scene", ""))
		spr.texture = cvs.thumbs.get(scene_id)
		spr.position = base + Vector2(t.get("dx", 0.0), t.get("dy", 0.0))
		spr.flip_h = bool(t.get("flip_h", false))
		spr.set_meta("scene", scene_id)
		if str(t.get("def_id", "")) != "":
			spr.set_meta("def_id", str(t.get("def_id", "")))
		# 每个副本独立一份数据，并把复制组内部引用改到对应副本。
		var props: Dictionary = (t.get("props", {}) as Dictionary).duplicate(true)
		for edef in cvs.manifest.get("entities", []):
			if str(edef.get("id", "")) != scene_id:
				continue
			for field in edef.get("fields", []):
				var field_id := str(field.get("id", ""))
				var target_id := str(props.get(field_id, ""))
				if str(field.get("type", "")) == "entity_ref" and copied_ids.has(target_id):
					props[field_id] = copied_ids[target_id]
			break
		spr.set_meta("props", props)
		cvs.entities.add_child(spr)
		cvs._fit_sprite(spr, scene_id)
		cvs._assign_id(spr, paste_ids[i])
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
		cvs._hint("先用属性工具点选或框选实体，再按 Del 删除")
		return
	cvs._push_undo()
	for v in victims:
		if is_instance_valid(v):
			cvs.entities.remove_child(v)
			v.free()
	cvs.selected_multi.clear()
	cvs.selected_entity = null
	cvs._mark()
	cvs.queue_redraw()


func align_selection(mode: String) -> void:
	if cvs.map_root == null:
		return
	var targets: Array = cvs._valid_multi()
	if targets.size() < 2:
		cvs._hint("先框选至少 2 个实体再做对齐/分布")
		return
	cvs._push_undo()
	var min_x := INF
	var max_x := -INF
	var min_y := INF
	var max_y := -INF
	for s in targets:
		var p: Vector2 = (s as Sprite2D).position
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_y = minf(min_y, p.y)
		max_y = maxf(max_y, p.y)
	match mode:
		"left":
			for s in targets:
				(s as Sprite2D).position.x = min_x
		"right":
			for s in targets:
				(s as Sprite2D).position.x = max_x
		"top":
			for s in targets:
				(s as Sprite2D).position.y = min_y
		"bottom":
			for s in targets:
				(s as Sprite2D).position.y = max_y
		"center_h":
			var cx := (min_x + max_x) * 0.5
			for s in targets:
				(s as Sprite2D).position.x = cx
		"center_v":
			var cy := (min_y + max_y) * 0.5
			for s in targets:
				(s as Sprite2D).position.y = cy
		"dist_h":
			_distribute(targets, true)
		"dist_v":
			_distribute(targets, false)
		_:
			cvs._hint("未知对齐方式: " + mode)
			return
	# 对齐后吸附格点，保持与保存/加载一致
	for s in targets:
		var spr := s as Sprite2D
		var c: Vector2i = cvs._cell_of(spr.position)
		spr.position = Vector2(c) * cvs.tile_px + Vector2(cvs.tile_px, cvs.tile_px) * 0.5
	cvs._mark()
	cvs.queue_redraw()
	cvs._hint("已对齐/分布 %d 个实体（Ctrl+Z 撤销）" % targets.size())

## 等间距分布：保持首尾，中间实体在两者之间均分

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

func _distribute(targets: Array, horizontal: bool) -> void:
	var sorted := targets.duplicate()
	sorted.sort_custom(func(a, b):
		var pa: Vector2 = (a as Sprite2D).position
		var pb: Vector2 = (b as Sprite2D).position
		return pa.x < pb.x if horizontal else pa.y < pb.y)
	var n := sorted.size()
	if n < 3:
		return
	var first: Vector2 = (sorted[0] as Sprite2D).position
	var last: Vector2 = (sorted[n - 1] as Sprite2D).position
	var step := ((last - first) / float(n - 1))
	for i in range(1, n - 1):
		var p := first + step * float(i)
		if horizontal:
			(sorted[i] as Sprite2D).position.x = p.x
		else:
			(sorted[i] as Sprite2D).position.y = p.y


## T6（批次 12）：批量挂/摘定义——写/清 def_id，一个撤销步（"" = 摘除）
func bulk_set_def(scene_id: String, def_id: String) -> int:
	var targets: Array = cvs._valid_multi()
	var hits := []
	for s in targets:
		if str((s as Sprite2D).get_meta("scene", "")) == scene_id:
			hits.append(s)
	if hits.is_empty():
		cvs._hint("选中里没有 " + scene_id + " 类型的实体")
		return 0
	cvs._push_undo()
	for s in hits:
		var spr := s as Sprite2D
		if def_id == "":
			spr.remove_meta("def_id")
		else:
			spr.set_meta("def_id", def_id)
	cvs._mark()
	cvs.queue_redraw()
	return hits.size()

func bulk_update(scene_id: String, stat_set: Dictionary, stat_clear: Array, props_set: Dictionary) -> int:
	var targets: Array = cvs._valid_multi()
	var hits := []
	for s in targets:
		if str((s as Sprite2D).get_meta("scene", "")) == scene_id:
			hits.append(s)
	if hits.is_empty():
		cvs._hint("选中里没有 " + scene_id + " 类型的实体")
		return 0
	cvs._push_undo()
	for s in hits:
		var spr := s as Sprite2D
		var props: Dictionary = (spr.get_meta("props", {}) as Dictionary).duplicate(true)
		for k in props_set.keys():
			var v = props_set[k]
			if v == null or str(v) == "":
				props.erase(k)
			else:
				props[k] = v
		if not stat_set.is_empty() or not stat_clear.is_empty():
			var stats: Dictionary = props.get("stats", {})
			for k in stat_set.keys():
				stats[k] = stat_set[k]
			for k in stat_clear:
				stats.erase(k)
			if stats.is_empty():
				props.erase("stats")
			else:
				props["stats"] = stats
		spr.set_meta("props", props)
	cvs._mark()
	cvs.queue_redraw()
	cvs._hint("已批量修改 %d 个 %s" % [hits.size(), scene_id])
	return hits.size()


## —— 框选区域拖动搬迁（瓦片 / 装饰 / 碰撞三层 + 区域内实体） ——
## 按下时只快照，不立刻搬；松手才「推撤销 → 擦源 → 写目标」。
## 这样拖动中数据没被改过，中途松手/取消都不会留下半截状态。
## 状态字段挂宿主 cvs（本项目控制器一律经 cvs 读写宿主状态）：
##   cvs._move_snap / _move_from / _move_grab / _move_cell_delta / _move_active

## 点是否落在已有区域选区里（用来区分「拖走这块」和「重新框选」）
func _in_region_sel(pos: Vector2) -> bool:
	if cvs._region_sel.size.x <= 0 or cvs._region_sel.size.y <= 0:
		return false
	return cvs._region_sel.has_point(cvs._cell_of(pos))

func _snapshot_region(sel: Rect2i) -> Dictionary:
	var snap := {"terrain": [], "decor": [], "collision": [], "ents": [], "size": sel.size}
	for y in range(sel.position.y, sel.end.y):
		for x in range(sel.position.x, sel.end.x):
			var c := Vector2i(x, y)
			var tac: Vector2i = cvs.terrain.get_cell_atlas_coords(c)
			if tac != Vector2i(-1, -1):
				snap["terrain"].append([x, y, cvs.terrain.get_cell_source_id(c), tac.x, tac.y])
			var dc: Vector2i = cvs.decor.get_cell_atlas_coords(c)
			if dc != Vector2i(-1, -1):
				snap["decor"].append([x, y, cvs.decor.get_cell_source_id(c), dc.x, dc.y])
			if cvs.collision.get_cell_source_id(c) != -1:
				var cm = cvs._collision_meta.get(c, null)
				if cm != null:
					snap["collision"].append([x, y, str(cm.get("type", "solid")), str(cm.get("shape", ""))])
				else:
					snap["collision"].append([x, y])
	for e in cvs.entities.get_children():
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
	cvs._move_active = true


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
	cvs._move_active = false
	cvs._move_snap = {}
	cvs._move_cell_delta = Vector2i.ZERO
	if not active or delta == Vector2i.ZERO:
		return
	cvs._push_undo()
	# 先清源（三层 + 区域内实体位置回原点后再搬）
	for t in snap.get("terrain", []):
		cvs.terrain.erase_cell(Vector2i(int(t[0]), int(t[1])))
	for t in snap.get("decor", []):
		cvs.decor.erase_cell(Vector2i(int(t[0]), int(t[1])))
	for t in snap.get("collision", []):
		cvs.set_collision_cell(Vector2i(int(t[0]), int(t[1])), false)
	# 再写目标
	for t in snap.get("terrain", []):
		cvs.terrain.set_cell(Vector2i(int(t[0]), int(t[1])) + delta, int(t[2]), Vector2i(int(t[3]), int(t[4])))
	for t in snap.get("decor", []):
		cvs.decor.set_cell(Vector2i(int(t[0]), int(t[1])) + delta, int(t[2]), Vector2i(int(t[3]), int(t[4])))
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
	if cvs._ent_layer_index() == cvs.active_layer:
		copy_selection()
		return
	if cvs._region_sel.size.x <= 0:
		cvs._hint("先用选择工具在瓦片层拖拽框选一块区域")
		return
	cvs._region_clip = {"terrain": [], "decor": [], "collision": [], "size": cvs._region_sel.size}
	for y in range(cvs._region_sel.position.y, cvs._region_sel.end.y):
		for x in range(cvs._region_sel.position.x, cvs._region_sel.end.x):
			var d: Vector2i = Vector2i(x, y) - cvs._region_sel.position
			# 批次 9：区域剪贴板带 atlas（source_id）——多图集瓦片整块搬运
			var tac: Vector2i = cvs.terrain.get_cell_atlas_coords(Vector2i(x, y))
			if tac != Vector2i(-1, -1):
				var tsid: int = cvs.terrain.get_cell_source_id(Vector2i(x, y))
				cvs._region_clip["terrain"].append([d.x, d.y, tsid, tac.x, tac.y])
			var dc: Vector2i = cvs.decor.get_cell_atlas_coords(Vector2i(x, y))
			if dc != Vector2i(-1, -1):
				var dsid: int = cvs.decor.get_cell_source_id(Vector2i(x, y))
				cvs._region_clip["decor"].append([d.x, d.y, dsid, dc.x, dc.y])
			if cvs.collision.get_cell_source_id(Vector2i(x, y)) != -1:
				# 批次 9：区域剪贴板带碰撞类型/形状
				var cm = cvs._collision_meta.get(Vector2i(x, y), null)
				if cm != null:
					cvs._region_clip["collision"].append([d.x, d.y, str(cm.get("type", "solid")), str(cm.get("shape", ""))])
				else:
					cvs._region_clip["collision"].append([d.x, d.y])
	# 实体也一起复制：区域块含实体，才能整块房间复用
	var ents_clip := []
	for e in cvs.entities.get_children():
		var spr := e as Sprite2D
		if spr == null or not spr.has_meta("scene"):
			continue
		var ec: Vector2i = cvs._cell_of(spr.position)
		if cvs._region_sel.has_point(ec):
			ents_clip.append({
				"dx": ec.x - cvs._region_sel.position.x,
				"dy": ec.y - cvs._region_sel.position.y,
				"scene": str(spr.get_meta("scene", "")),
				# A3：朝向与 def 绑定随块复制；ent_id 是引用重映射（C2）的前提
				"flip_h": bool(spr.flip_h),
				"def_id": str(spr.get_meta("def_id", "")),
				"ent_id": str(spr.get_meta("ent_id", "")),
				"props": (spr.get_meta("props", {}) as Dictionary).duplicate(true),
			})
	cvs._region_clip["entities"] = ents_clip
	cvs._last_copy_region = true
	cvs._hint("已复制 %dx%d 区域（%d 瓦片 / %d 实体；Ctrl+V 幽灵预览，左键落位/右键或 Esc 取消）" % [
		cvs._region_sel.size.x, cvs._region_sel.size.y,
		(cvs._region_clip["terrain"] as Array).size() + (cvs._region_clip["decor"] as Array).size() + (cvs._region_clip["collision"] as Array).size(),
		ents_clip.size()])

## 任一图层锁定即拒绝区域级操作（BUG-03）：部分跳过会让剪贴板与实际删除不一致。

func cut_region() -> void:
	if cvs.map_root == null:
		return
	if cvs._ent_layer_index() == cvs.active_layer:
		cut_selection()
		return
	if cvs._region_sel.size.x <= 0:
		cvs._hint("先用选择工具在瓦片层拖拽框选一块区域")
		return
	if cvs._any_layer_locked():
		cvs._hint("有图层处于锁定状态：解锁后再剪切区域")
		return
	copy_region()
	if cvs._region_clip.is_empty():
		return
	cvs._push_undo()
	var ci: int = cvs._collision_layer_index()
	var layers: Array = cvs.manifest.get("layers", [])
	for y in range(cvs._region_sel.position.y, cvs._region_sel.end.y):
		for x in range(cvs._region_sel.position.x, cvs._region_sel.end.x):
			var c := Vector2i(x, y)
			for i in layers.size():
				# 只擦瓦片/装饰层；碰撞层走 cvs.collision 节点，实体层在下面按位置处理
				if i == ci or str(layers[i].get("type", "tiles")) != "tiles":
					continue
				cvs._layer_node(i).erase_cell(c)
			cvs.collision.erase_cell(c)
	# 区域内的实体一并移除（它们已经进了剪贴板）
	for e in cvs.entities.get_children():
		var spr := e as Sprite2D
		if spr == null or not spr.has_meta("scene"):
			continue
		if cvs._region_sel.has_point(cvs._cell_of(spr.position)):
			cvs.entities.remove_child(spr)
			spr.free()
	cvs._mark()
	cvs.queue_redraw()
	cvs._hint("已剪切区域 %dx%d（Ctrl+V 粘贴 / Ctrl+Z 撤销）" % [cvs._region_sel.size.x, cvs._region_sel.size.y])


func _paste_region(origin: Vector2i) -> void:
	if cvs.map_root == null or cvs._region_clip.is_empty():
		return
	if cvs._any_layer_locked():
		cvs._hint("有图层处于锁定状态：解锁后再粘贴区域")
		return
	cvs._push_undo()
	# 批次 9：粘贴按 atlas 维度重建（[dx,dy,atlas,ax,ay] 新 / [dx,dy,ax,ay] 旧）
	for t in cvs._region_clip.get("terrain", []):
		var ta := t as Array
		if ta.size() >= 5:
			cvs.terrain.set_cell(origin + Vector2i(int(ta[0]), int(ta[1])), int(ta[2]), Vector2i(int(ta[3]), int(ta[4])))
		else:
			cvs.terrain.set_cell(origin + Vector2i(int(ta[0]), int(ta[1])), 0, Vector2i(int(ta[2]), int(ta[3])))
	for t in cvs._region_clip.get("decor", []):
		var da := t as Array
		if da.size() >= 5:
			cvs.decor.set_cell(origin + Vector2i(int(da[0]), int(da[1])), int(da[2]), Vector2i(int(da[3]), int(da[4])))
		else:
			cvs.decor.set_cell(origin + Vector2i(int(da[0]), int(da[1])), 0, Vector2i(int(da[2]), int(da[3])))
	for t in cvs._region_clip.get("collision", []):
		var cc := origin + Vector2i(int(t[0]), int(t[1]))
		if (t as Array).size() >= 4:
			cvs.set_collision_cell(cc, true, str(t[2]), str(t[3]))
		else:
			cvs.set_collision_cell(cc, true)
	# 实体：区域内的实体按相对格位重建（引用字段保留，id 重新分配）
	var id_map := {}   # C2（批次 12）：旧 ent_id → 粘贴后新 id
	var pasted: Array = []
	for t in cvs._region_clip.get("entities", []):
		var spr := Sprite2D.new()
		var scene_id := str(t.get("scene", ""))
		spr.texture = cvs.thumbs.get(scene_id)
		spr.position = Vector2(origin + Vector2i(int(t.get("dx", 0)), int(t.get("dy", 0)))) * cvs.tile_px \
			+ Vector2(cvs.tile_px, cvs.tile_px) * 0.5
		spr.set_meta("scene", scene_id)
		# A3：恢复朝向与 def 绑定；ent_id 不复用（新块给新号），留作 C2 重映射的候选数据
		spr.flip_h = bool(t.get("flip_h", false))
		if str(t.get("def_id", "")) != "":
			spr.set_meta("def_id", str(t.get("def_id", "")))
		spr.set_meta("props", (t.get("props", {}) as Dictionary).duplicate(true))
		cvs.entities.add_child(spr)
		cvs._fit_sprite(spr, scene_id)
		cvs._assign_id(spr)
		var old_id := str(t.get("ent_id", ""))
		if old_id != "":
			id_map[old_id] = str(spr.get_meta("ent_id", ""))
		pasted.append(spr)
	# C2：块内引用重映射——props 里的字符串值命中块内旧 id → 指向粘贴出的新实例；块外引用不动
	for spr2 in pasted:
		var props2: Dictionary = (spr2.get_meta("props", {}) as Dictionary).duplicate(true)
		var changed := false
		var stack: Array = [props2]
		while not (stack as Array).is_empty():
			var cur = (stack as Array).pop_back()
			if cur is Dictionary:
				for k in (cur as Dictionary).keys():
					var v = (cur as Dictionary)[k]
					if v is String and id_map.has(v):
						(cur as Dictionary)[k] = id_map[v]
						changed = true
					elif v is Dictionary or v is Array:
						stack.append(v)
		if changed:
			spr2.set_meta("props", props2)
	cvs._mark()
	cvs._paste_mode = false
	cvs._hint("区域已粘贴")

## 取消区域粘贴预览（Esc/右键共用）。键盘入口在 app 级——画布收不到键盘（K9c）。

func _cell_rect(a: Vector2, b: Vector2) -> Rect2i:
	var ca: Vector2i = cvs._cell_of(a)
	var cb: Vector2i = cvs._cell_of(b)
	return Rect2i(Vector2i(mini(ca.x, cb.x), mini(ca.y, cb.y)),
		Vector2i(absi(ca.x - cb.x) + 1, absi(ca.y - cb.y) + 1))
