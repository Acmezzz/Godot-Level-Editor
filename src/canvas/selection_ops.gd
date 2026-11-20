extends RefCounted
## SelectionOps：从 src/canvas/editor_canvas.gd 拆出的控制器。宿主状态经 cvs 引用。
##
## 操作对象是 EntityNode（场景图片实例与实体实例同形）。命中/框选/拖动/复制
## 全部按节点自己的 rect()/display_size() 口径，不再写死 16px 或依赖 Sprite2D 类型。

const AssetDecl := preload("res://src/assets/asset_decl.gd")

var cvs   # 宿主引用

func _init(host) -> void:
	cvs = host
## 按实例占位矩形做命中（大资产边缘也能点中）。
## 跨层命中：从顶层向下取第一个命中的层，层内取中心距最近者；无命中返回 null。
func _entity_hit(pos: Vector2) -> EntityNode:
	for li in range(cvs.layer_count() - 1, -1, -1):
		if li >= cvs.layer_ents.size():
			continue
		var hit := _entity_hit_in((cvs.layer_ents[li] as Node2D).get_children(), pos)
		if hit != null:
			return hit
	return null

## 单层命中核心：遍历给定容器子节点（tool_ops 擦除与跨层选区共用同一规则）
func _entity_hit_in(children: Array, pos: Vector2) -> EntityNode:
	var best: EntityNode = null
	var best_d = INF
	for e in children:
		var n := e as EntityNode
		if n == null or n.asset == "" or not n.visible_flag:
			continue
		if n.rect().has_point(pos):
			var d = n.position.distance_squared_to(pos)
			if d < best_d:
				best = n
				best_d = d
	return best


func _select_entity_at(pos: Vector2) -> void:
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
		return
	var best: EntityNode = _entity_hit(pos)
	cvs.selected_entity = best
	cvs.selected_multi.clear()
	cvs.entity_selected.emit(best)   # 空点也发 null：右侧检查器要同步清空（擦除路径同语义）
	cvs.queue_redraw()


func _entity_at(pos: Vector2) -> EntityNode:
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
		var n := e as EntityNode
		# 用视觉矩形相交判定：大贴图（背景板）锚点可能在框外，却明显盖住了框
		if n != null and n.asset != "" and r.intersects(n.rect()):
			cvs.selected_multi.append(n)
	cvs.selected_entity = null
	if not cvs.selected_multi.is_empty():
		cvs.selected_entity = cvs.selected_multi[0]
		cvs.entity_selected.emit(cvs.selected_entity)
	cvs._hint("%d 个实例被框选" % cvs.selected_multi.size())
	cvs.queue_redraw()


## 多选集合的外接矩形（按各实例的视觉矩形，不是锚点单点——
## 锚点碰巧落在一起的两个大实例并不相邻）
func _multi_bounds(targets: Array) -> Rect2:
	var r := Rect2()
	var first := true
	for s in targets:
		var nr: Rect2 = (s as EntityNode).rect()
		r = nr if first else r.merge(nr)
		first = false
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

## —— 实例拖拽移动：按下记录起点，移动只改预览，松手吸附并标脏 ——
## 锁检查跟着实例所在层走（实例可属任何栈层）。
func _begin_entity_drag(n: EntityNode, pos: Vector2) -> void:
	if cvs.is_layer_locked(cvs._layer_index_of(n.layer_id)):
		cvs._hint("实例所在图层已锁定：解锁后再移动")
		return
	cvs._drag_entity = n
	cvs._drag_entities = [n]
	cvs._drag_origins = [n.position]
	# 框选集合一起拖动（按住的是集合成员时）
	if cvs.selected_multi.size() > 1 and cvs.selected_multi.has(n):
		cvs._drag_entities = cvs.selected_multi.duplicate()
		cvs._drag_origins.clear()
		for s in cvs._drag_entities:
			cvs._drag_origins.append((s as EntityNode).position)
	cvs._drag_grab = pos
	cvs._drag_moved = false
	cvs.begin_gesture(cvs.Gesture.ENTITY_DRAG, MOUSE_BUTTON_LEFT)

## 从框内空白处拖动 = 平移整个框选集合（和按住某个成员拖一样，一次撤销步）
func _begin_group_drag(pos: Vector2) -> void:
	var targets: Array = cvs._valid_multi()
	if targets.is_empty():
		return
	# 锁检查覆盖全部成员的层（只查首成员时，跨层组的其他成员可能住在锁定层）
	if _selection_touches_locked(targets):
		cvs._hint("有成员所在图层已锁定：解锁后再移动")
		return
	if targets.size() < 2:
		return
	# cvs._drag_entity 指向第一个成员：_finish_entity_drag 靠它判断拖拽是否在进行
	cvs._drag_entity = targets[0] as EntityNode
	cvs._drag_entities = targets.duplicate()
	cvs._drag_origins.clear()
	for s in cvs._drag_entities:
		cvs._drag_origins.append((s as EntityNode).position)
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
		var s := cvs._drag_entities[i] as EntityNode
		if is_instance_valid(s):
			s.position = (cvs._drag_origins[i] as Vector2) + delta
	cvs.queue_redraw()


func _finish_entity_drag() -> void:
	var moved: bool = cvs._drag_moved
	var targets: Array = cvs._drag_entities.duplicate()
	var origins: Array = cvs._drag_origins.duplicate()
	# 记下预览位置（吸附前），用于换算目标位置
	var preview := []
	for s in targets:
		preview.append((s as EntityNode).position if is_instance_valid(s) else Vector2.ZERO)
	cvs._drag_entity = null
	cvs._drag_entities.clear()
	cvs._drag_origins.clear()
	cvs._drag_moved = false
	if not moved or targets.is_empty():
 # 没真正拖动：把预览位移还原
		for i in targets.size():
			if is_instance_valid(targets[i]):
				(targets[i] as EntityNode).position = origins[i]
		return
	# 恢复原位再「撤销 + 吸附放置」，一次拖拽 = 一个撤销步
	for i in targets.size():
		if is_instance_valid(targets[i]):
			(targets[i] as EntityNode).position = origins[i]
	cvs._push_undo()
	for i in targets.size():
		var n := targets[i] as EntityNode
		if not is_instance_valid(n):
			continue
		n.position = cvs.snap_point(preview[i], n)
	cvs._mark()
	cvs.queue_redraw()
	cvs._hint("已移动 %d 个实例（Ctrl+Z 撤销）" % targets.size())


func copy_selection() -> void:
	if cvs.map_root == null:
		return
	var sel := _live_selection()
	if sel.is_empty():
		cvs._hint("先选中实例再复制（Ctrl+C）")
		return
	var center := Vector2.ZERO
	for s in sel:
		center += (s as EntityNode).position
	center /= sel.size()
	cvs._clipboard.clear()
	cvs._last_copy_region = false   # 之后 Ctrl+V 走实例粘贴而不是区域粘贴
	for s in sel:
		var n := s as EntityNode
		cvs._clipboard.append({
			"asset": n.asset,
			"code": n.code,
			"dx": n.position.x - center.x,
			"dy": n.position.y - center.y,
			"layer": n.layer_id,
			"transform": n.data_transform.duplicate(true),
			"functions": n.functions.duplicate(true),
 # deep=true：props 里的嵌套字典各副本独立，避免改一个影响全部
			"props": n.props.duplicate(true),
			"zPolicy": n.z_policy,
			"visible": n.visible_flag,
		})
	cvs._hint("已复制 %d 个实例（Ctrl+V 粘贴到光标处）" % cvs._clipboard.size())

## 剪切 = 复制 + 删除，但整件事只算一个撤销步。
## （分别调 copy_selection + delete_selection 会推两次撤销，Ctrl+Z 一次撤不回来）

func cut_selection() -> void:
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
		return
	if cvs.is_layer_locked(cvs.active_layer):
		cvs._hint("当前图层已锁定：解锁后再剪切")
		return
	var sel := _live_selection()
	if sel.is_empty():
		cvs._hint("先选中实例再剪切（Ctrl+X）")
		return
	# 复用复制逻辑生成剪贴板（它负责算中心与相对偏移）
	copy_selection()
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
	cvs._hint("已剪切 %d 个实例（Ctrl+V 粘贴，Ctrl+Z 撤销）" % n)


func paste_at(pos: Vector2) -> void:
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
		return
	if cvs._clipboard.is_empty():
		cvs._hint("剪贴板为空：先用 Ctrl+C 复制实例")
		return
	var target: int = cvs.active_layer if cvs.active_layer < cvs.layer_count() else 0
	# 目标层锁检查（碰撞元层激活时落到 0 层——0 层也要查）
	if cvs.is_layer_locked(target):
		cvs._hint("目标图层已锁定：解锁后再粘贴")
		return
	cvs._push_undo()
	# 先建副本并给每个 fresh 码；建 旧码→新码 映射，供组内引用重映射
	var copied := {}   # 旧码 → 新码
	var built: Array = []   # [{node, asset, props, functions}]
	for t in cvs._clipboard:
		var aid := str(t.get("asset", ""))
		var n: EntityNode = cvs.make_object(aid)
		n.position = pos + Vector2(t.get("dx", 0.0), t.get("dy", 0.0))
		n.asset = aid
		n.data_transform = (t.get("transform", {}) as Dictionary).duplicate(true)
		n.z_policy = str(t.get("zPolicy", "auto"))
		n.visible_flag = bool(t.get("visible", true))
		n.refresh_visual()
		var code: String = ""
		var src := str(t.get("code", ""))
		if n.is_entity():
			code = cvs._fresh_inst_code()
			n.code = code
			if src != "":
				copied[src] = code
 # 每个副本独立一份数据；组内引用的重映射在下面统一做
		built.append({
			"node": n,
			"asset": aid,
			"props": (t.get("props", {}) as Dictionary).duplicate(true),
			"functions": (t.get("functions", []) as Array).duplicate(true),
		})
		n.layer_id = cvs.layer_id(target)
		(cvs.layer_ents[target] as Node2D).add_child(n)
	# 副本间引用重映射：props 声明驱动（entity_ref fields）+ functions 盲重映射
	for b in built:
		var n2: EntityNode = b.node
		var props2: Dictionary = b.props
		var edef: Dictionary = AssetDecl.by_id(cvs.manifest, str(b.asset))
		for field in edef.get("fields", []):
			if not (field is Dictionary):
				continue
			var field_id := str((field as Dictionary).get("id", ""))
			var target_id := str(props2.get(field_id, ""))
			if str((field as Dictionary).get("type", "")) == "entity_ref" and copied.has(target_id):
				props2[field_id] = copied[target_id]
		var functions2: Array = b.functions
		_remap_refs_in(functions2, copied)
		n2.props = props2
		n2.functions = functions2
		n2.refresh_visual()   # props 就位后按 sizeFields 重算尺寸
		# 吸附：多选粘贴的相对偏移（center 是均值，可为半格）会骑在格线上，
		# 保存再载入整体漂半格。吸附到格（或吸附关闭时保留原像素位）。
		n2.position = cvs.snap_point(n2.position, n2)
	cvs._mark()
	cvs.queue_redraw()
	cvs._hint("已粘贴 %d 个实例（Ctrl+Z 撤销）" % cvs._clipboard.size())


## 选区成员是否踩到锁定层：锁定阻止一切写入（与涂刷/擦除/区域操作同语义）
func _selection_touches_locked(sel: Array) -> bool:
	for s in sel:
		var n := s as EntityNode
		if n != null and is_instance_valid(n):
			if cvs.is_layer_locked(cvs._layer_index_of(n.layer_id)):
				return true
	return false

func delete_selection() -> void:
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
		return
	var victims: Array = cvs.selected_multi.duplicate()
	if victims.is_empty() and cvs.selected_entity and is_instance_valid(cvs.selected_entity):
		victims.append(cvs.selected_entity)
	if victims.is_empty():
		cvs._hint("先在画布上点选或框选实例，再按 Del 删除")
		return
	if _selection_touches_locked(victims):
		cvs._hint("选中实例所在图层已锁定：解锁后再删除")
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


## 翻转选中实例（单个或框选集合）：每个实例 toggle flip_h；一个撤销步。
## 返回是否真的翻了（无选中返回 false，快捷键据此决定是否吞键）。
func flip_selected() -> bool:
	var targets := []
	if cvs.selected_multi.size() > 0:
		targets = cvs._valid_multi()
	elif is_instance_valid(cvs.selected_entity):
		targets.append(cvs.selected_entity)
	if targets.is_empty():
		return false
	if _selection_touches_locked(targets):
		cvs._hint("实例所在图层已锁定：解锁后再翻转")
		return false
	cvs._push_undo()
	for s in targets:
		(s as EntityNode).toggle_flip_h()
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

## 实体的「所在格」判定：由资产的 anchor 统一（top_left 型 = 矩形左上格，
## center 型 = 中心格）。区域复制/剪切/框入/拖动四处共用，防止复制进了剪贴板、
## 剪切却漏删（或反之）的错位。
func _ent_cell(n: EntityNode) -> Vector2i:
	return n.cell()


## 当前有效选区（多选优先，为空则退单选），已滤掉已释放对象。
func _live_selection() -> Array:
	var out: Array = []
	for s in cvs.selected_multi:
		if is_instance_valid(s):
			out.append(s)
	if out.is_empty() and cvs.selected_entity and is_instance_valid(cvs.selected_entity):
		out.append(cvs.selected_entity)
	return out


## 区域快照存**数据**不存活体节点：节点随后被 free 也不会让剪贴板拿到失效引用。
func _snapshot_region(sel: Rect2i) -> Dictionary:
	# 层栈快照：tiles = {层id: [[x,y,资产id,ax,ay]...]}，碰撞/实例同形（实例带 layer）
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
					var aid: String = cvs.asset_of_source((cvs.layer_tiles[li] as TileMapLayer).get_cell_source_id(c))
					if aid == "":
						continue
					cells.append([x, y, aid, tac.x, tac.y])
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
		var n := e as EntityNode
		if n == null or n.asset == "":
			continue
		var ec := _ent_cell(n)
		if sel.has_point(ec):
			snap["ents"].append(_ent_template(n, Vector2(sel.position)))
	return snap

## 一个实例的数据模板（复制/区域快照共用）：相对偏移（格，浮点——保留亚格位置）+ 全部数据字段，
## 不含活体引用。
func _ent_template(n: EntityNode, at: Vector2) -> Dictionary:
	var g: Vector2 = n.grid_of_world(n.position) - at
	return {
		"dx": snappedf(g.x, 0.001),
		"dy": snappedf(g.y, 0.001),
		"asset": n.asset,
		"code": n.code,
		"layer": n.layer_id,
		"transform": n.data_transform.duplicate(true),
		"functions": n.functions.duplicate(true),
		"props": n.props.duplicate(true),
		"zPolicy": n.z_policy,
		"visible": n.visible_flag,
	}

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
	# 先清源（各层瓦片 + 碰撞），再写目标；实例按数据坐标平移（保持浮点位）
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
			var src2: int = cvs.source_of_asset(str((t2 as Array)[2]))
			if src2 < 0:
				continue
			(cvs.layer_tiles[li2] as TileMapLayer).set_cell(
				Vector2i(int((t2 as Array)[0]), int((t2 as Array)[1])) + delta, src2,
				Vector2i(int((t2 as Array)[3]), int((t2 as Array)[4])))
	for t in snap.get("collision", []):
		var ta := t as Array
		if ta.size() >= 4:
			cvs.set_collision_cell(Vector2i(int(ta[0]), int(ta[1])) + delta, true, str(ta[2]), str(ta[3]))
		else:
			cvs.set_collision_cell(Vector2i(int(ta[0]), int(ta[1])) + delta, true)
	# 实例：区块内的实例原地平移（保持身份码与层归属，不重建节点）
	for e in cvs.ents_all():
		var n := e as EntityNode
		if n != null and n.asset != "" and cvs._region_sel.has_point(n.cell()):
			n.position += Vector2(delta) * cvs.tile_px
	# 选区跟着搬到新位置，方便接着拖第二下
	cvs._region_sel.position = from + delta
	cvs._mark()
	cvs.queue_redraw()
	cvs._hint("已移动区域 %dx%d 偏移 (%d,%d)（Ctrl+Z 撤销）" % [
		cvs._region_sel.size.x, cvs._region_sel.size.y, delta.x, delta.y])

## 按模板重建一个实例节点（层按模板里的层码找，找不到落最底层）。
## 区域拖动/区域粘贴共用这一个入口，避免两处各写一遍落层逻辑。
func _instantiate(t: Dictionary, origin: Vector2i) -> EntityNode:
	var aid := str(t.get("asset", ""))
	if aid == "":
		return null
	var n: EntityNode = cvs.make_object(aid)
	if not cvs.is_placeable(aid):
		n.queue_free()   # 目标项目没有这个资产（或不是可摆放类型）：跳过，不落空节点
		return null
	n.layer_id = cvs.layer_id(cvs._layer_index_of(str(t.get("layer", ""))))
	if n.layer_id == "":
		n.layer_id = cvs.layer_id(0)
	n.props = (t.get("props", {}) as Dictionary).duplicate(true)
	n.functions = (t.get("functions", []) as Array).duplicate(true)
	n.data_transform = (t.get("transform", {}) as Dictionary).duplicate(true)
	n.z_policy = str(t.get("zPolicy", "auto"))
	n.visible_flag = bool(t.get("visible", true))
	n.refresh_visual()
	n.apply_grid(origin.x + float(t.get("dx", 0.0)), origin.y + float(t.get("dy", 0.0)))
	var ei: int = cvs._layer_index_of(n.layer_id)
	(cvs.layer_ents[maxi(ei, 0)] as Node2D).add_child(n)
	# 新实例按需发码（场景实例不产码）；旧码只作为引用重映射的键
	if n.is_entity() and n.code == "":
		n.code = cvs._fresh_inst_code()
	return n

func copy_region() -> void:
	if cvs.map_root == null:
		return
	if cvs.place_kind == "object":
		copy_selection()
		return
	if cvs._region_sel.size.x <= 0:
		cvs._hint("先框选一块区域再复制")
		return
	# 层栈剪贴板：tiles = {层id: [[dx,dy,资产id,ax,ay]...]}，碰撞/实体照旧（实体带 layer）
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
				# 区域剪贴板带资产 id——多图集瓦片整块搬运，且清单重排不破坏剪贴板
				var tac: Vector2i = (cvs.layer_tiles[li] as TileMapLayer).get_cell_atlas_coords(Vector2i(x, y))
				if tac != Vector2i(-1, -1):
					var aid: String = cvs.asset_of_source((cvs.layer_tiles[li] as TileMapLayer).get_cell_source_id(Vector2i(x, y)))
					if aid == "":
						continue
					cells.append([d.x, d.y, aid, tac.x, tac.y])
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
	# 实例也一起复制：区域块含实例，才能整块房间复用（层随实例走）
	var ents_clip := []
	for e in cvs.ents_all():
		var n := e as EntityNode
		if n == null or n.asset == "":
			continue
		var ec: Vector2i = _ent_cell(n)
		if cvs._region_sel.has_point(ec):
			ents_clip.append(_ent_template(n, Vector2(cvs._region_sel.position)))
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
	if cvs.place_kind == "object":
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
	# 区域内的实例一并移除（它们已经进了剪贴板）
	for e in cvs.ents_all():
		var n := e as EntityNode
		if n == null or n.asset == "":
			continue
		if cvs._region_sel.has_point(_ent_cell(n)):
			(n.get_parent() as Node2D).remove_child(n)
			n.free()
	# 区域内实例已释放：把选区里的悬挂引用清掉，否则后续复制/框选/绘制
	# 读已释放对象会直接崩（剪掉自己正选着的东西是常态操作）。
	# 只过滤不清空：仍有效的选择保持原样（单选不升格成多选）
	var keep: Array = []
	for s in cvs.selected_multi:
		if is_instance_valid(s):
			keep.append(s)
	cvs.selected_multi = keep
	if cvs.selected_entity != null and not is_instance_valid(cvs.selected_entity):
		cvs.selected_entity = null
		cvs.entity_selected.emit(null)
	cvs._mark()   # 区域剪切含实例删除，实例索引/列表缓存一并失效
	cvs.queue_redraw()
	cvs._hint("已剪切区域 %dx%d（Ctrl+V 粘贴 / Ctrl+Z 撤销）" % [cvs._region_sel.size.x, cvs._region_sel.size.y])


func _paste_region(origin: Vector2i) -> void:
	if cvs.map_root == null or cvs._region_clip.is_empty():
		return
	if cvs._any_layer_locked():
		cvs._hint("有图层处于锁定状态：解锁后再粘贴区域")
		return
	cvs._push_undo()
	# 粘贴按 层id 维度重建（tiles = {层id: [[dx,dy,资产id,ax,ay]...]}）
	# 层重映射：同图按 id 直配，跨图按层名，都不匹配则落最底层（末尾黄字提示）
	var lnames: Dictionary = cvs._region_clip.get("layer_names", {})
	var missed: Array = []
	for lid in (cvs._region_clip.get("tiles", {}) as Dictionary):
		var li: int = _paste_layer_index(str(lid), lnames, missed)
		for t in (cvs._region_clip.get("tiles", {})[lid] as Array):
			var ta := t as Array
			var src: int = cvs.source_of_asset(str(ta[2]))
			if src < 0:
				continue   # 目标项目没有这个资产：跳过，不写坏格子
			(cvs.layer_tiles[li] as TileMapLayer).set_cell(
				origin + Vector2i(int(ta[0]), int(ta[1])), src, Vector2i(int(ta[3]), int(ta[4])))
	for t in cvs._region_clip.get("collision", []):
		var cc := origin + Vector2i(int(t[0]), int(t[1]))
		if (t as Array).size() >= 4:
			cvs.set_collision_cell(cc, true, str(t[2]), str(t[3]))
		else:
			cvs.set_collision_cell(cc, true)
	# 实例：按相对格位重建，落回各自的层（找不到同码层落最底层）；引用重映射照旧
	var id_map := {}   # 旧码 → 粘贴后新码
	var pasted: Array = []
	for t in cvs._region_clip.get("ents", []):   # 键统一为 ents（预览也读 ents）
		var old_code := str(t.get("code", ""))
		var n := _instantiate(t, origin)
		if n == null:
			continue
		# 层重映射失败时 _instantiate 落最底层，但要记下哪几层没匹配上
		var src_lid := str(t.get("layer", ""))
		if src_lid != "" and cvs._layer_index_of(src_lid) < 0:
			var nm: String = str((cvs._region_clip.get("layer_names", {}) as Dictionary).get(src_lid, ""))
			if not missed.has(nm if nm != "" else src_lid):
				missed.append(nm if nm != "" else src_lid)
		if old_code != "" and n.code != "":
			id_map[old_code] = n.code
		pasted.append(n)
	# 引用重映射：props/functions 里命中旧 id 的字符串全部换成新 id
	for n2 in pasted:
		var props2: Dictionary = (n2 as EntityNode).props.duplicate(true)
		var functions2: Array = (n2 as EntityNode).functions.duplicate(true)
		var changed := _remap_refs_in(props2, id_map)
		if _remap_refs_in(functions2, id_map):
			changed = true
		if changed:
			(n2 as EntityNode).props = props2
		(n2 as EntityNode).functions = functions2
		(n2 as EntityNode).refresh_visual()
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
