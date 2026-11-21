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


## —— 实例尺寸把手（R-04）：选中 sizeFields 实例右下角把手，拖动 = 改 props w/h（格数） ——
## 预览期直接写 props（display_size 实时反映），收尾恢复原值压一个撤销步再写终值。

## 把手命中：仅带 sizeFields 的选中实例有把手（触发区/事件区这类自定尺寸实例）
func _resize_handle_hit(pos: Vector2) -> bool:
	var n = cvs.selected_entity
	if n == null or not is_instance_valid(n) or cvs.place_kind != "object":
		return false
	var sf = (n.decl as Dictionary).get("sizeFields", null)
	if not (sf is Array) or (sf as Array).size() < 2:
		return false
	var r: Rect2 = (n as EntityNode).rect()
	var side = cvs.grid.cell_max() * 0.6
	return Rect2(r.end - Vector2.ONE * side * 0.5, Vector2.ONE * side).has_point(pos)

## 起手：记录目标与原始 w/h（键名从 decl.sizeFields 取）
func _begin_entity_resize(n: EntityNode, pos: Vector2) -> void:
	var sf: Array = (n.decl as Dictionary).get("sizeFields", [])
	if sf.size() < 2:
		return
	if cvs.is_layer_locked(cvs._layer_index_of(n.layer_id)):
		cvs._hint("实例所在图层已锁定：解锁后再调整尺寸")
		return
	cvs._resize_node = n
	cvs._resize_orig = {
		"wf": str(sf[0]), "hf": str(sf[1]),
		"w": int(n.props.get(str(sf[0]), 1)), "h": int(n.props.get(str(sf[1]), 1)),
	}
	cvs._resize_origin = (n as EntityNode).rect().position
	cvs._resize_moved = false
	cvs.begin_gesture(cvs.Gesture.ENTITY_RESIZE, MOUSE_BUTTON_LEFT)

## 拖动预览：props w/h = 鼠标相对 rect 左上角的格数（≥1）；变化才写，回到原值 = 零副作用
func _move_resize_preview(pos: Vector2) -> void:
	if cvs._resize_node == null or not is_instance_valid(cvs._resize_node):
		cvs._resize_node = null
		return
	var n := cvs._resize_node as EntityNode
	var cell := Vector2(cvs.grid.tile)
	var o: Vector2 = cvs._resize_origin
	var nw := maxi(1, roundi(maxf((pos.x - o.x) / maxf(cell.x, 1.0), 0.5)))
	var nh := maxi(1, roundi(maxf((pos.y - o.y) / maxf(cell.y, 1.0), 0.5)))
	var orig: Dictionary = cvs._resize_orig
	if nw == int(orig.w) and nh == int(orig.h):
		return
	n.props[str(orig.wf)] = nw
	n.props[str(orig.hf)] = nh
	cvs._resize_moved = true
	n.refresh_visual()
	cvs.queue_redraw()

## 收尾：动过才压撤销+置脏（恢复原值→压撤销→写回终值 = 一个撤销步）
func _finish_entity_resize() -> void:
	var n = cvs._resize_node
	cvs._resize_node = null
	if n == null or not is_instance_valid(n):
		return
	if not cvs._resize_moved:
		return  # 未动：props 仍是原值，零副作用
	var orig: Dictionary = cvs._resize_orig
	var fw := int(n.props.get(str(orig.wf), 1))
	var fh := int(n.props.get(str(orig.hf), 1))
	# 恢复原值 → 压撤销 → 重写终值（与 _finish_entity_drag 同一纪律）
	n.props[str(orig.wf)] = int(orig.w)
	n.props[str(orig.hf)] = int(orig.h)
	n.refresh_visual()
	cvs._push_undo()
	n.props[str(orig.wf)] = fw
	n.props[str(orig.hf)] = fh
	n.refresh_visual()
	cvs._mark()
	cvs._hint("实例尺寸 %dx%d（Ctrl+Z 撤销）" % [fw, fh])
	cvs.queue_redraw()


## —— 顶点编辑（R-02 几何段）：选中 poly/path 实例的顶点把手 ——
## 预览期直写 props.points，收尾恢复原值压撤销再写终值（与尺寸把手同一纪律）。

## 顶点世界坐标（把手命中/绘制共用）：局部点经 to_global（吃 rotation/scale；
## flip 由点集镜像还原，存取层不掺入）
func _vertex_worlds(n: EntityNode) -> Array:
	var out := []
	for p: Vector2 in (n as EntityNode).points_local():
		out.append((n as EntityNode).to_global(p))
	return out

## 顶点把手命中：返回顶点下标（-1 = 未命中）；半径 = 0.45 格
func _vertex_handle_hit(pos: Vector2) -> int:
	var n = cvs.selected_entity
	if n == null or not is_instance_valid(n) or cvs.place_kind != "object":
		return -1
	var en := n as EntityNode
	if en.visual_type() == "rect":
		return -1
	var r: float = cvs.grid.cell_max() * 0.45
	var best := -1
	var best_d := r
	var i := 0
	for p: Vector2 in en.points_local():
		var d := en.to_global(p).distance_to(pos)
		if d <= best_d:
			best = i
			best_d = d
		i += 1
	return best

## 起手：冻结原点集
func _begin_vertex_drag(n: EntityNode, idx: int) -> void:
	if cvs.is_layer_locked(cvs._layer_index_of(n.layer_id)):
		cvs._hint("实例所在图层已锁定：解锁后再调顶点")
		return
	cvs._vertex_node = n
	cvs._vertex_idx = idx
	cvs._vertex_orig = (n as EntityNode).points_local().duplicate()
	cvs._vertex_moved = false
	cvs.begin_gesture(cvs.Gesture.ENTITY_VERTEX, MOUSE_BUTTON_LEFT)

## 拖动预览：顶点 = 鼠标转局部（吃逆变换），flip 镜像回未翻转局部系再写
func _move_vertex_preview(pos: Vector2) -> void:
	if cvs._vertex_node == null or not is_instance_valid(cvs._vertex_node):
		cvs._vertex_node = null
		return
	var n := cvs._vertex_node as EntityNode
	var pts: Array = n.points_local()
	if cvs._vertex_idx >= pts.size():
		return
	var lp := n.to_local(pos)
	if n.flipped_h():
		lp.x = -lp.x
	if n.flipped_v():
		lp.y = -lp.y
	var orig: Array = cvs._vertex_orig
	if cvs._vertex_idx < orig.size() and lp.is_equal_approx(orig[cvs._vertex_idx]):
		return
	pts[cvs._vertex_idx] = lp
	n.points_write(pts)
	cvs._vertex_moved = true
	cvs.queue_redraw()

## 收尾：动过才压撤销+置脏（恢复原值→压撤销→写终值 = 一个撤销步）
func _finish_vertex_drag() -> void:
	var n = cvs._vertex_node
	cvs._vertex_node = null
	if n == null or not is_instance_valid(n):
		return
	if not cvs._vertex_moved:
		return
	var idx := int(cvs._vertex_idx)
	var orig: Array = cvs._vertex_orig
	var fin: Array = (n as EntityNode).points_local()
	var fp: Vector2 = fin[idx] if idx < fin.size() else Vector2.ZERO
	(n as EntityNode).points_write(orig)
	(n as EntityNode).refresh_visual()
	cvs._push_undo()
	(n as EntityNode).points_write(fin)
	(n as EntityNode).refresh_visual()
	cvs._mark()
	cvs._hint("顶点已移动（Ctrl+Z 撤销）")
	cvs.queue_redraw()

## 双击边加点：最近线段的最近点（超出 0.6 格 = 不算加点意图，返回 false 让位其它交互）。
## 最近点落在既有顶点 0.35 格内 = 复制点，拒绝（让位顶点拖拽）。
func _add_vertex_at(pos: Vector2) -> bool:
	var n = cvs.selected_entity
	if n == null or not is_instance_valid(n):
		return false
	var en := n as EntityNode
	if en.visual_type() == "rect":
		return false
	var pts: Array = en.points_local()
	if pts.size() < 2:
		return false
	var closed: bool = bool(en.decl.get("visual", {}).get("closed", false))
	var best_seg := -1
	var best_lp := Vector2.ZERO
	var best_d := INF
	var segs := pts.size() if closed else pts.size() - 1
	for i in segs:
		var a: Vector2 = en.to_global(pts[i])
		var b: Vector2 = en.to_global(pts[(i + 1) % pts.size()])
		var cp: Vector2 = _closest_on_segment(pos, a, b)
		var d := cp.distance_to(pos)
		if d < best_d:
			best_d = d
			best_seg = i
			best_lp = en.to_local(cp)
	if best_seg < 0 or best_d > cvs.grid.cell_max() * 0.6:
		return false
	if en.flipped_h():
		best_lp.x = -best_lp.x
	if en.flipped_v():
		best_lp.y = -best_lp.y
	for p: Vector2 in pts:
		if (p as Vector2).distance_to(best_lp) < cvs.grid.cell_max() * 0.35:
			return false
	return _vertex_commit(pts, best_seg + 1, best_lp, "已加顶点")

## 右键顶点删点：poly 保底 3 点（closed 时 <3 不成多边形）、path 保底 2 点。
func _delete_vertex_at(pos: Vector2) -> bool:
	var n = cvs.selected_entity
	if n == null or not is_instance_valid(n):
		return false
	var en := n as EntityNode
	if en.visual_type() == "rect":
		return false
	var idx := _vertex_handle_hit(pos)
	if idx < 0:
		return false
	var pts: Array = en.points_local()
	var closed: bool = bool(en.decl.get("visual", {}).get("closed", false))
	var floor_n := 3 if closed else 2
	if pts.size() <= floor_n:
		cvs._hint("%s 至少保留 %d 个顶点" % ["多边形" if closed else "折线", floor_n])
		return true
	# 撤销一步：恢复原值→压快照→写新值（点击类改动同一纪律）
	var orig: Array = pts.duplicate()
	var npts: Array = pts.duplicate()
	npts.remove_at(idx)
	(n as EntityNode).points_write(orig)
	(n as EntityNode).refresh_visual()
	cvs._push_undo()
	(n as EntityNode).points_write(npts)
	(n as EntityNode).refresh_visual()
	cvs._mark()
	cvs._hint("已删顶点（Ctrl+Z 撤销）")
	cvs.queue_redraw()
	return true

## 点击类顶点改动共用：恢复原值→压撤销→按 (idx, lp) 写回新点集
func _vertex_commit(orig: Array, idx: int, lp: Vector2, hint: String) -> bool:
	var n = cvs.selected_entity
	if n == null or not is_instance_valid(n):
		return false
	var en := n as EntityNode
	en.points_write(orig)
	en.refresh_visual()
	cvs._push_undo()
	var npts: Array = orig.duplicate()
	npts.insert(idx, lp)
	en.points_write(npts)
	en.refresh_visual()
	cvs._mark()
	cvs._hint(hint + "（Ctrl+Z 撤销）")
	cvs.queue_redraw()
	return true

## 线段最近点
func _closest_on_segment(p: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var ab := b - a
	var t := 0.0
	if ab.length_squared() > 0.0001:
		t = clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return a + ab * t


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


## R 键：旋转选中实例 90°（单个或框选集合）；一个撤销步。返回是否吞键。
func rotate_selected_90() -> bool:
	var targets := []
	if cvs.selected_multi.size() > 0:
		targets = cvs._valid_multi()
	elif is_instance_valid(cvs.selected_entity):
		targets.append(cvs.selected_entity)
	if targets.is_empty():
		return false
	if _selection_touches_locked(targets):
		cvs._hint("实例所在图层已锁定：解锁后再旋转")
		return false
	cvs._push_undo()
	for s in targets:
		(s as EntityNode).rotate_90()
	cvs._mark()
	cvs.queue_redraw()
	return true

## [ ] 键：等比缩放选中实例（单个或框选集合）；一个撤销步。返回是否吞键。
func scale_selected(d: float) -> bool:
	var targets := []
	if cvs.selected_multi.size() > 0:
		targets = cvs._valid_multi()
	elif is_instance_valid(cvs.selected_entity):
		targets.append(cvs.selected_entity)
	if targets.is_empty():
		return false
	if _selection_touches_locked(targets):
		cvs._hint("实例所在图层已锁定：解锁后再缩放")
		return false
	cvs._push_undo()
	for s in targets:
		(s as EntityNode).scale_step(d)
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
