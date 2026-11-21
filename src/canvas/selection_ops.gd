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
		var hit := _entity_hit_in(cvs._layer_entities(li), pos)
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
	if (a - b).length() < cvs.grid.cell_max() * 0.5:
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
	return cvs.grid.cell_max() * (cvs.K.GROUP_HOT + (0.5 if cvs.select_mode else 0.0))

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
		cvs._place_in_layer(n, target)
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


## —— 拆到 src/canvas/region_ops.gd（调用点保持不变） ——

func _live_selection() -> Array:
	return cvs._region_ops_ctrl._live_selection()

func _instantiate(t: Dictionary, origin: Vector2i) -> EntityNode:
	return cvs._region_ops_ctrl._instantiate(t, origin)
func _remap_refs_in(container, id_map: Dictionary) -> bool:
	return cvs._region_ops_ctrl._remap_refs_in(container, id_map)
