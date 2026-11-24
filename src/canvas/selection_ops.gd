extends RefCounted
## SelectionOps：从 src/canvas/editor_canvas.gd 拆出的控制器。宿主状态经 cvs 引用。
##
## 操作对象是 EntityNode（场景图片实例与实体实例同形）。命中/框选/拖动/复制
## 全部按节点自己的 rect()/display_size() 口径，不再写死 16px 或依赖 Sprite2D 类型。

const AssetDecl := preload("res://src/assets/asset_decl.gd")
const ClonePlan := preload("res://src/content/clone_plan.gd")
const Geometry := preload("res://src/map/object_geometry.gd")
const RefFields := preload("res://src/content/ref_fields.gd")

var cvs   # 宿主引用

func _init(host) -> void:
	cvs = host
## 按实例占位矩形做命中（大资产边缘也能点中）。
## 跨层命中：从顶层向下取第一个命中的层，层内取中心距最近者；无命中返回 null。
## 隐藏层整层跳过（E06）：隐藏内容不能点中，否则「看不见的东西被选中/删掉」。
func _entity_hit(pos: Vector2) -> EntityNode:
	for li in range(cvs.layer_count() - 1, -1, -1):
		if not cvs.is_layer_visible(li):
			continue
		var hit := _entity_hit_in(cvs._layer_entities(li), pos, li)
		if hit != null:
			return hit
	return null

## 单层命中核心：遍历给定容器子节点（tool_ops 擦除与跨层选区共用同一规则）。
## 层局部坐标（E02）：pos 是世界坐标，先逆变换到该层容器空间，再与实例 rect() 比。
## 实例 rect()/position 都在层局部空间（层容器承担 offset/scale/parallax）。
## 多个命中时取**绘制顺序最靠上**的那个（不是中心距最近）：below/YSort/above 三段
## 依次靠上；ySort 层内按 y 越大越靠上，否则按子节点顺序（V4 P1）。
func _entity_hit_in(children: Array, pos: Vector2, layer_i := -1) -> EntityNode:
	var lp: Vector2 = pos if layer_i < 0 else cvs.to_layer_local(layer_i, pos)
	var best: EntityNode = null
	var best_rank := -INF
	for e in children:
		var n := e as EntityNode
		if n == null or n.asset == "" or not cvs.is_entity_shown(n):
			continue
		if not n.contains_point(lp):
			continue
		var rank := _draw_rank(n)
		if rank > best_rank:
			best = n
			best_rank = rank
	return best

## 实例在层内的绘制先后近似值（越大越靠上）：
## 段容器 Below < YSort < Above；ySort 开着时用 y 坐标（Godot 同层 y 越大越后画），
## 否则用子节点顺序。只用于命中择一，不参与渲染。
func _draw_rank(n: EntityNode) -> float:
	var parent := n.get_parent() as Node2D
	var bucket := 1.0
	if parent != null:
		match str(parent.name):
			"Below": bucket = 0.0
			"Above": bucket = 2.0
			_: bucket = 1.0
	var rank := bucket * 1000000.0
	if parent != null and parent.y_sort_enabled:
		# y 越大越靠上；同一 y 时子节点顺序靠后者在上
		rank += n.position.y * 10.0 + float(n.get_index()) * 0.001
	else:
		rank += float(n.get_index())
	return rank


func _select_entity_at(pos: Vector2) -> void:
	if cvs.map_root == null:
		cvs._hint("无地图：先新建或打开一张地图")
		return
	var best: EntityNode = _entity_hit(pos)
	# 空点也发 null：右侧检查器要同步清空（擦除路径同语义）。走统一提交入口（E09）。
	cvs.commit_selection(best)


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
	# 逐层判定（E02/E06）：世界框逆变换到层局部再与实例 rect 相交；
	# 隐藏层整层跳过——框选不能把看不见的实例带进来。
	for li in cvs.layer_count():
		if not cvs.is_layer_visible(li):
			continue
		var inv: Transform2D = cvs.layer_xform(li).affine_inverse()
		var rl: Rect2 = inv * r
		for e in cvs._layer_entities(li):
			var n := e as EntityNode
			if n != null and n.asset != "" and cvs.is_entity_shown(n) and rl.intersects(n.aabb()):
				cvs.selected_multi.append(n)
	# 统一走选择提交入口（E09）：单选=首成员、多选=整组、信息条同步
	cvs.commit_multi(cvs.selected_multi)
	cvs._hint("%d 个实例被框选" % cvs.selected_multi.size())


## 多选集合的外接矩形（按各实例的视觉矩形，不是锚点单点——
## 锚点碰巧落在一起的两个大实例并不相邻）。
## 跨层成员先在各自层局部算 rect，再变换到世界坐标合并。
func _multi_bounds(targets: Array) -> Rect2:
	var r := Rect2()
	var first := true
	for s in targets:
		var n := s as EntityNode
		if n == null or not is_instance_valid(n):
			continue
		var li: int = cvs._layer_index_of(n.layer_id)
		var nr: Rect2 = n.aabb()
		if li >= 0:
			nr = cvs.layer_xform(li) * nr
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
## 锁检查跟着实例所在层走（实例可属任何栈层）。整组拖动时**所有成员**的层都要查
## （E04：先选锁定与未锁定对象再从其中拖动，锁定成员不得跟随）。
func _begin_entity_drag(n: EntityNode, pos: Vector2) -> void:
	if cvs.is_layer_locked(cvs._layer_index_of(n.layer_id)):
		cvs._hint("实例所在图层已锁定：解锁后再移动")
		return
	cvs._drag_entity = n
	cvs._drag_entities = [n]
	cvs._drag_origins = [n.position]
	# 框选集合一起拖动（按住的是集合成员时）
	if cvs.selected_multi.size() > 1 and cvs.selected_multi.has(n):
		var group: Array = cvs._valid_multi()
		if _selection_touches_locked(group):
			cvs._hint("组内有成员所在图层已锁定：解锁后再移动")
			return
		cvs._drag_entities = group
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
	# 世界位移 → 逐成员所在层的局部位移（E02）：层有偏移/缩放/旋转时，
	# 直接加世界位移会让成员漂离光标。起始位置在起手时已冻结（相机后来移动不影响落点）。
	var delta: Vector2 = pos - cvs._drag_grab
	if delta.length() > 1.0:
		cvs._drag_moved = true
	for i in cvs._drag_entities.size():
		var s := cvs._drag_entities[i] as EntityNode
		if is_instance_valid(s):
			var li: int = cvs._layer_index_of(s.layer_id)
			var dl: Vector2 = delta if li < 0 else cvs.world_delta_local(li, delta)
			s.position = (cvs._drag_origins[i] as Vector2) + dl
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
	# 恢复原位再「记录 + 吸附放置」，一次拖拽 = 一个撤销步
	for i in targets.size():
		if is_instance_valid(targets[i]):
			(targets[i] as EntityNode).position = origins[i]
	# §7.5 阶段二：位置改动走 InstanceKey 差量（只记这几个实例）。
	var pre: Dictionary = cvs._undo_history_ctrl.inst_rows(targets)
	var via_delta := bool(pre.get("ok", false))
	if not via_delta:
		cvs.push_undo()   # 场景图片没有实例码：退回整图快照
	for i in targets.size():
		var n := targets[i] as EntityNode
		if not is_instance_valid(n):
			continue
		n.position = cvs.snap_point(preview[i], n)
	if via_delta:
		cvs._undo_history_ctrl.inst_commit(pre.get("rows", {}))
	cvs._mark_ents()
	cvs.queue_redraw()
	cvs._hint("已移动 %d 个实例（Ctrl+Z 撤销）" % targets.size())


## —— 实例尺寸把手（R-04）：选中 sizeFields 实例右下角把手，拖动 = 改 props w/h（格数） ——
## 预览期直接写 props（display_size 实时反映），收尾恢复原值压一个撤销步再写终值。

## 把手命中：仅带 sizeFields 的选中实例有把手（触发区/事件区这类自定尺寸实例）。
## 把手画在世界空间（层变换已作用），命中也在世界空间比（E02）。
func _resize_handle_hit(pos: Vector2) -> bool:
	var n = cvs.selected_entity
	if n == null or not is_instance_valid(n) or cvs.place_kind != "object":
		return false
	var sf = (n.decl as Dictionary).get("sizeFields", null)
	if not (sf is Array) or (sf as Array).size() < 2:
		return false
	var li: int = cvs._layer_index_of((n as EntityNode).layer_id)
	var r: Rect2 = (n as EntityNode).rect()
	if li >= 0:
		r = cvs.layer_xform(li) * r
	var side = cvs.grid.cell_max() * 0.6
	return Rect2(r.end - Vector2.ONE * side * 0.5, Vector2.ONE * side).has_point(pos)

## 起手：记录目标与原始 w/h（键名从 decl.sizeFields 取）
func _begin_entity_resize(n: EntityNode) -> void:
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

## 拖动预览：props w/h = 鼠标相对 rect 左上角的格数（≥1）；变化才写，回到原值 = 零副作用。
## 世界鼠标 → 实例所在层局部（E02），与起手快照同一空间。
func _move_resize_preview(pos: Vector2) -> void:
	if cvs._resize_node == null or not is_instance_valid(cvs._resize_node):
		cvs._resize_node = null
		return
	var n := cvs._resize_node as EntityNode
	var li: int = cvs._layer_index_of(n.layer_id)
	var lp: Vector2 = pos if li < 0 else cvs.to_layer_local(li, pos)
	var cell := Vector2(cvs.grid.tile)
	var o: Vector2 = cvs._resize_origin
	var nw := maxi(1, roundi(maxf((lp.x - o.x) / maxf(cell.x, 1.0), 0.5)))
	var nh := maxi(1, roundi(maxf((lp.y - o.y) / maxf(cell.y, 1.0), 0.5)))
	var orig: Dictionary = cvs._resize_orig
	if nw == int(orig.w) and nh == int(orig.h):
		# 拖回起点（E10）：必须把 props 写回原值，否则停留时显示的是上一次预览尺寸，
		# 收尾也会把那个旧预览值当终值提交。
		n.props[str(orig.wf)] = int(orig.w)
		n.props[str(orig.hf)] = int(orig.h)
		cvs._resize_moved = false
		n.refresh_visual()
		cvs.queue_redraw()
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
	# 恢复原值 → 记录差量 → 重写终值（与 _finish_entity_drag 同一纪律）
	n.props[str(orig.wf)] = int(orig.w)
	n.props[str(orig.hf)] = int(orig.h)
	n.refresh_visual()
	var pre: Dictionary = cvs._undo_history_ctrl.inst_rows([n])
	var via_delta := bool(pre.get("ok", false))
	if not via_delta:
		cvs.push_undo()
	n.props[str(orig.wf)] = fw
	n.props[str(orig.hf)] = fh
	n.refresh_visual()
	if via_delta:
		cvs._undo_history_ctrl.inst_commit(pre.get("rows", {}))
	cvs._mark_ents()
	cvs._hint("实例尺寸 %dx%d（Ctrl+Z 撤销）" % [fw, fh])
	cvs.queue_redraw()


## —— E2 空间连线：选中实例的 entity_ref 端点把手 ——
## 每条本图引用从源实例画到落点；落点实例上/源实例上空引用处各给一个把手。
## 拖动把手 = 换落点——松手时经 RefOps 同一写入口落地（C1 配对清空规则、撤销一致）。
## 数据真相仍是 props 里的引用字段；画布从不自造字段。

## 选中实例的连线把手：[{fd, value, from: Vector2, at: Vector2, has_target}]（世界坐标）。
## from 永远画在源实例锚点；at 落在目标锚点。空引用没有落点：把手放在锚点右上方的
## 短线段末端（与绘制同一偏移）——压在锚点正中会和「拖动实例」抢同一处点击。
func _link_handles() -> Array:
	var n = cvs.selected_entity
	if n == null or not is_instance_valid(n) or cvs.place_kind != "object":
		return []
	if cvs._ref_ops_ctrl == null:
		return []
	var out: Array = []
	var src: Vector2 = cvs._w_for(n as EntityNode)
	var stub: Vector2 = Vector2(maxf(cvs.grid.cell_max() * 0.56, 10.0), -maxf(cvs.grid.cell_max() * 0.56, 10.0))
	for r in cvs._ref_ops_ctrl.local_refs(n as EntityNode):
		var rd: Dictionary = r
		var tgt := rd.get("target") as EntityNode
		var is_port: bool = rd.fd.get("type") == "port_ref"
		var from: Vector2 = cvs.port_position(n, rd.source_port) if is_port and not rd.source_port.is_empty() else src
		var has_target := is_instance_valid(tgt) and (not is_port or tgt.is_visible_in_tree())
		var handle: Vector2 = from + stub
		if is_port:
			handle.y -= float(out.size()) * cvs.grid.cell_max() * 0.75
		elif has_target:
			handle = cvs._w_for(tgt)
		var at: Vector2 = cvs.port_position(tgt, rd.target_port) if is_port and has_target else handle
		out.append({"fd": rd.fd, "from": from, "at": at, "handle": handle,
			"has_target": has_target, "bound": rd.get("bound", has_target)})
	return out

## 把手命中：返回 {fd, ...} 或空字典。半径与顶点把手一致（0.45 格）。
## 只有选中的实例才有把手——连线是「当前实例的引用」，不是全图常驻装饰。
func _link_handle_hit(pos: Vector2) -> Dictionary:
	var r: float = cvs.grid.cell_max() * 0.45
	var best := {}
	var best_d := r
	for h in _link_handles():
		var hd: Dictionary = h
		var d: float = (hd.handle as Vector2).distance_to(pos)
		# 有目标的把手画在目标上：远处实例不可见时点不到，先让相机跟过去（focus）。无目标落在源上。
		if d <= best_d:
			best = hd
			best_d = d
	return best

## 起手：只记身份，不改数据（松手才写）。
## 从「有落点的目标把手」拖到空白 = 断开引用（RefOps 清空，复用 C1 规则）；
## 从空引用把手拖到空白 = 取消（本来就是空的）。
func _begin_link_drag(h: Dictionary) -> void:
	var n = cvs.selected_entity
	if n == null or not is_instance_valid(n):
		return
	if _selection_touches_locked([n]):
		cvs._hint("实例所在图层已锁定：解锁后再改引用")
		return
	cvs._link_node = n
	cvs._link_fd = (h.get("fd", {}) as Dictionary).duplicate(true)
	cvs._link_origin = h.from
	cvs._link_handle = h.handle
	cvs._link_fd_types = RefFields.describe(cvs._link_fd).filter.get("types", [])
	cvs._link_hover = ""
	cvs._link_can_clear = bool(h.bound)
	cvs.begin_gesture(cvs.Gesture.LINK_DRAG, MOUSE_BUTTON_LEFT)
	cvs._hint("拖动「%s」到目标%s松手%s" % [str(h.fd.get("name", h.fd.id)),
		"端口" if h.fd.type == "port_ref" else "实例",
		"；松在空白 = 断开引用" if cvs._link_can_clear else "；松在空白 = 取消"])

## 拖动预览：只记光标下的候选（绘制层画高亮），不写数据。
## 候选必须满足声明的 of 白名单——不满足时高亮为空并当场说明（不让人拖到无效目标上）。
func _move_link_preview(pos: Vector2) -> void:
	cvs._link_hover = _link_candidate(pos, cvs._link_fd)
	cvs.queue_redraw()

func _link_candidate(pos: Vector2, fd: Dictionary) -> String:
	if fd.type == "port_ref":
		return cvs.port_candidate_at(pos, cvs._link_fd_types)
	var node: EntityNode = cvs._entity_at(pos)
	if is_instance_valid(node) and node.is_entity() and cvs._ref_ops_ctrl.accepts(fd, node):
		return node.code
	return ""

## 松手：候选有效且不是源实例自己才写；空白/自连按起手来源决定「断开」还是「取消」。
## 写入走 RefOps——与内容表单下拉、画布选点同一规则（含配对地图改动的确认与清空）。
func _finish_link_drag(pos: Vector2) -> void:
	var n = cvs._link_node
	var fd: Dictionary = cvs._link_fd
	var can_clear: bool = cvs._link_can_clear
	var is_port: bool = fd.get("type") == "port_ref"
	var released_on_handle: bool = is_port and (cvs._link_handle as Vector2).distance_to(pos) <= cvs.grid.cell_max() * 0.45
	var code := "" if fd.is_empty() else _link_candidate(pos, fd)
	cvs.clear_link_drag()
	if not is_instance_valid(n) or fd.is_empty() or released_on_handle or _selection_touches_locked([n]):
		return
	if is_port and code.is_empty() and (cvs.port_candidate_at(pos, []) != "" or cvs._entity_at(pos) != null):
		cvs._hint("此处没有兼容的端口，原引用未变更")
		return
	if code == "":
		if can_clear:
			var rc: Dictionary = await cvs._ref_ops_ctrl.set_entity_ref(n as EntityNode, fd, "")
			if str(rc.get("status", "")) != "ok":
				cvs._hint("断开未生效（已取消）")
		else:
			cvs._hint("已取消连线（没有落在其它实例上）")
		cvs.queue_redraw()
		return
	if code == (n as EntityNode).code:
		cvs._hint("已取消：实例不能引用自己")
		cvs.queue_redraw()
		return
	var value = JSON.parse_string(code) if is_port else code
	var res: Dictionary = await cvs._ref_ops_ctrl.set_entity_ref(n as EntityNode, fd, value)
	if str(res.get("status", "")) != "ok":
		cvs._hint("连线未生效：%s" % ("取消了配对地图改动" if str(res.get("status", "")) == "cancelled" else "写入失败"))
	cvs.queue_redraw()


## 按部件依次展开：每个部件先外环，再列内环。
func _geometry_rings(n: EntityNode) -> Array:
	if not Geometry.closed(n.decl.get("visual", {})):
		return [n.points_local()]
	var rings := []
	for part in n.geometry_parts():
		rings.append(part.points)
		rings.append_array(part.holes)
	return rings

func _vertex_world_rings(n: EntityNode) -> Array:
	var worlds := []
	for ring in _geometry_rings(n):
		worlds.append(ring.map(n.geometry_point_to_world))
	return worlds

func _vertex_handle_hit(pos: Vector2) -> Vector2i:
	var en: EntityNode = cvs.selected_entity
	if not is_instance_valid(en) or cvs.place_kind != "object" or en.visual_type() == "rect":
		return Vector2i(-1, -1)
	var best := Vector2i(-1, -1)
	var distance: float = _handle_radius()
	var worlds := _vertex_world_rings(en)
	for ring in worlds.size():
		for vertex in worlds[ring].size():
			var d: float = worlds[ring][vertex].distance_to(pos)
			if d < distance:
				best = Vector2i(ring, vertex)
				distance = d
	return best

func _handle_radius() -> float:
	return 8.0 / maxf(cvs.zoom, 0.01)

func _geometry_editable(en: EntityNode) -> bool:
	if not is_instance_valid(en) or not en.is_visible_in_tree() or cvs.doc_busy:
		return false
	var li: int = cvs._layer_index_of(en.layer_id)
	return li >= 0 and cvs.is_layer_visible(li) and not cvs.is_layer_locked(li)

func _begin_vertex_drag(n: EntityNode, key: Vector2i) -> void:
	if not _geometry_editable(n):
		cvs._hint("当前实例不可编辑：请检查图层是否可见并已解锁。")
		return
	cvs.begin_gesture(cvs.Gesture.ENTITY_VERTEX, MOUSE_BUTTON_LEFT)
	cvs._vertex_node = n
	cvs._vertex_key = key
	cvs._vertex_orig = n.props.duplicate(true)
	cvs._vertex_rings = _geometry_rings(n)

func _move_vertex_preview(pos: Vector2) -> void:
	var n: EntityNode = cvs._vertex_node
	if not _geometry_editable(n):
		return
	var key: Vector2i = cvs._vertex_key
	var original: Array = cvs._vertex_rings[key.x]
	var lp := n.geometry_point_from_world(pos)
	if not lp.is_finite():
		return
	var precision := Vector2(0.01, 0.01)
	if lp.snapped(precision).is_equal_approx((original[key.y] as Vector2).snapped(precision)):
		n.props = cvs._vertex_orig.duplicate(true)
	else:
		var rings: Array = cvs._vertex_rings.duplicate(true)
		rings[key.x][key.y] = lp
		_write_ring(n, rings, key.x)
	n.refresh_visual()
	cvs.queue_redraw()

func _finish_vertex_drag() -> void:
	var n: EntityNode = cvs._vertex_node
	if not is_instance_valid(n):
		_cancel_vertex_drag()
		return
	var key: Vector2i = cvs._vertex_key
	var candidate := _geometry_rings(n)
	var unchanged: bool = n.props == cvs._vertex_orig
	_cancel_vertex_drag()
	if not unchanged and _geometry_editable(n):
		_commit_ring(n, candidate, key.x, "顶点已移动")

func _cancel_vertex_drag() -> void:
	var n: EntityNode = cvs._vertex_node
	if is_instance_valid(n):
		n.props = cvs._vertex_orig
		n.refresh_visual()
	cvs._vertex_node = null
	cvs._vertex_orig = {}
	cvs._vertex_rings = []
	cvs.queue_redraw()

func _add_vertex_at(pos: Vector2) -> bool:
	var en: EntityNode = cvs.selected_entity
	if not is_instance_valid(en) or en.visual_type() == "rect":
		return false
	if not _geometry_editable(en):
		return false
	# A click near an existing handle belongs to vertex dragging, not edge insertion.
	if _vertex_handle_hit(pos).x >= 0:
		return false
	var rings := _geometry_rings(en)
	var worlds := _vertex_world_rings(en)
	var closed := Geometry.closed(en.decl.get("visual", {}))
	var best := Vector2i(-1, -1)
	var best_pos := Vector2.ZERO
	var distance: float = 10.0 / maxf(cvs.zoom, 0.01)
	for ring in worlds.size():
		var contour: Array = worlds[ring]
		var count := contour.size() if closed else contour.size() - 1
		if contour.size() < 2:
			continue
		for i in count:
			var nearest := Geometry2D.get_closest_point_to_segment(pos, contour[i], contour[(i + 1) % contour.size()])
			var d := nearest.distance_to(pos)
			if d < distance:
				best = Vector2i(ring, i + 1)
				best_pos = nearest
				distance = d
	if best.x < 0:
		return false
	rings[best.x].insert(best.y, en.geometry_point_from_world(best_pos))
	_commit_ring(en, rings, best.x, "已加顶点")
	return true

func _delete_vertex_at(pos: Vector2) -> bool:
	var en: EntityNode = cvs.selected_entity
	var key := _vertex_handle_hit(pos)
	if key.x < 0:
		return false
	if not _geometry_editable(en):
		cvs._hint("当前实例不可编辑。")
		return true
	var rings := _geometry_rings(en)
	var minimum := Geometry.minimum(en.decl.get("visual", {}))
	if rings[key.x].size() <= minimum:
		cvs._hint("此轮廓至少保留 %d 个顶点。" % minimum)
		return true
	rings[key.x].remove_at(key.y)
	_commit_ring(en, rings, key.x, "已删顶点")
	return true

func _write_ring(en: EntityNode, rings: Array, index: int) -> void:
	if not Geometry.closed(en.decl.get("visual", {})):
		en.points_write(rings[0])
	else:
		var parts := en.geometry_parts()
		var cursor := 0
		for part in parts:
			if index == cursor:
				part.points = rings[index]
				break
			var hole_index := index - cursor - 1
			if hole_index >= 0 and hole_index < part.holes.size():
				part.holes[hole_index] = rings[index]
				break
			cursor += 1 + part.holes.size()
		en.geometry_parts_write(parts)

func _geometry_problem(en: EntityNode, rings: Array) -> String:
	var visual: Dictionary = en.decl.get("visual", {})
	if not Geometry.closed(visual):
		return Geometry.problem(rings[0], visual)
	var parts := en.geometry_parts()
	var cursor := 0
	for part in parts:
		var hole_count: int = part.holes.size()
		part.points = rings[cursor]
		part.holes = rings.slice(cursor + 1, cursor + 1 + hole_count)
		cursor += 1 + hole_count
	return Geometry.parts_problem(parts)

func _commit_ring(en: EntityNode, rings: Array, index: int, hint: String) -> void:
	var issue := _geometry_problem(en, rings)
	# Keep imported invalid outlines editable so authors can repair them in stages.
	if not issue.is_empty() and _geometry_problem(en, _geometry_rings(en)).is_empty():
		cvs._hint(issue)
		return
	var before: Dictionary = cvs._undo_history_ctrl.inst_rows([en])
	if not before.get("ok", false):
		cvs.push_undo()
	_write_ring(en, rings, index)
	en.refresh_visual()
	if before.get("ok", false):
		cvs._undo_history_ctrl.inst_commit(before.rows)
	cvs._mark_ents()
	cvs._hint(hint + "（Ctrl+Z 撤销）")
	cvs.queue_redraw()


func copy_selection() -> bool:
	if cvs.map_root == null:
		return false
	var sel := _live_selection()
	if sel.is_empty():
		cvs._hint("先选中实例再复制（Ctrl+C）")
		return false
	var source: Dictionary = cvs.copy_content_source()
	if source.is_empty():
		return false
	cvs._clipboard_source = source
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
			# 完整对象负载（E12）：sortAnchor 与游戏侧自定义键随复制走
			"raw": n.raw.duplicate(true),
		})
	cvs._hint("已复制 %d 个实例（Ctrl+V 粘贴到光标处）" % cvs._clipboard.size())
	return true

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
	# 锁检查覆盖整条选区所在层（E04）：剪切会删掉全部成员，只查活动层会连带删掉锁定层内容
	if _selection_touches_locked(sel):
		cvs._hint("选中实例所在图层已锁定：解锁后再剪切")
		return
	# 复用复制逻辑生成剪贴板（它负责算中心与相对偏移）
	if not copy_selection():
		return
	var pre: Dictionary = cvs._undo_history_ctrl.inst_rows(sel)
	var via_delta := bool(pre.get("ok", false))
	if not via_delta:
		cvs.push_undo()
	var n := 0
	for s in sel:
		if is_instance_valid(s):
			(s.get_parent() as Node2D).remove_child(s)
			s.free()
			n += 1
	if via_delta:
		cvs._undo_history_ctrl.inst_commit(pre.get("rows", {}))
	cvs.selected_multi.clear()
	cvs.selected_entity = null
	cvs._mark_ents()
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
	# C2：复制走统一计划——实例码与附属内容 ID 一起预留，组内引用重映射、组外保留，
	# 附属内容生成独立文件（此前所有副本共享同一内容 ID，改一个台词全部变）。
	var rows: Array = []
	for t in cvs._clipboard:
		rows.append({
			"asset": str(t.get("asset", "")),
			"code": str(t.get("code", "")),
			"props": (t.get("props", {}) as Dictionary).duplicate(true),
			"functions": (t.get("functions", []) as Array).duplicate(true),
		})
	var source: Dictionary = cvs._clipboard_source
	var plan: Dictionary = ClonePlan.build(
		{"data": {"objects": rows, "meta": source.get("meta", {})}, "manifest": cvs.manifest},
		{"data": cvs.map_data, "manifest": cvs.manifest},
		PackedStringArray(), false, source.get("staged", {}))
	if str(plan.get("status", "")) != "ok":
		cvs._hint("粘贴已取消：" + ClonePlan.conflicts_text(plan.get("conflicts", [])))
		return
	# R12：粘贴内容改暂存——不再当场写盘，新内容随正式提交（Ctrl+S/试玩）落盘；
	# 撤销恢复地图后绑定消失，暂存复核就地丢弃，不再留下孤儿内容文件。
	# ent 取拥有该内容的副本实例码（R02 复核用）；行与剪贴板条目一一对应。
	var remapped: Array = (plan.get("map_patch", {}) as Dictionary).get("objects", [])
	var ce = null
	if cvs.app_host != null and cvs.app_host.project_shell != null \
			and cvs.app_host.project_shell.content_editor != null:
		ce = cvs.app_host.project_shell.content_editor
	for pc in (plan.get("pending_contents", []) as Array):
		var pd: Dictionary = pc
		var owner := ""
		for row in remapped:
			var rf: Dictionary = row
			for f in (rf.get("functions", []) as Array):
				if f is Dictionary and str((f as Dictionary).get("content", "")) == str(pd.get("id", "")):
					owner = str(rf.get("code", ""))
		if ce != null:
			ce.stage_clone(str(pd.get("fn_id", "")), str(pd.get("id", "")),
				pd.get("data", {}) as Dictionary, owner)
	# §7.5 阶段二：粘贴是纯新增——先建节点再按 InstanceKey 记一条差量；
	# 有场景图片（无实例码）就退回整图快照（必须在动手前压）。
	var can_delta := true
	for t3 in cvs._clipboard:
		if not AssetDecl.is_entity(cvs.manifest, str((t3 as Dictionary).get("asset", ""))):
			can_delta = false
			break
	if not can_delta:
		cvs.push_undo()
	# 建副本：数据取自重映射后的行；位置/变换/显隐取剪贴板原模板
	var built: Array = []
	for i in cvs._clipboard.size():
		var t2: Dictionary = cvs._clipboard[i]
		var row: Dictionary = remapped[i] if i < remapped.size() else {}
		var aid := str(t2.get("asset", ""))
		var n: EntityNode = cvs.make_object(aid)
		n.position = pos + Vector2(t2.get("dx", 0.0), t2.get("dy", 0.0))
		n.asset = aid
		n.data_transform = (t2.get("transform", {}) as Dictionary).duplicate(true)
		n.z_policy = str(t2.get("zPolicy", "auto"))
		n.visible_flag = bool(t2.get("visible", true))
		# 完整对象负载（E12）：sortAnchor/未知键随剪贴板走，身份键以重映射行为准
		var raw: Dictionary = (t2.get("raw", {}) as Dictionary).duplicate(true) \
			if t2.get("raw", null) is Dictionary else {}
		if str(row.get("code", "")) != "":
			raw["code"] = str(row.get("code", ""))
		n.raw = raw
		n.code = str(row.get("code", ""))
		n.layer_id = cvs.layer_id(target)
		cvs._place_in_layer(n, target)
		built.append({
			"node": n,
			"props": row.get("props", {}) if row.get("props", null) is Dictionary else (t2.get("props", {}) as Dictionary).duplicate(true),
			"functions": row.get("functions", []) if row.get("functions", null) is Array else (t2.get("functions", []) as Array).duplicate(true),
		})
	for b in built:
		var n2: EntityNode = b.node
		n2.props = b.props
		n2.functions = b.functions
		n2.refresh_visual()   # props 就位后按 sizeFields 重算尺寸
		if n2.code == "" and n2.is_entity():
			cvs._ensure_code(n2)   # 场景图片实例不产码；实体缺码时兜底补发
		# 吸附：多选粘贴的相对偏移（center 是均值，可为半格）会骑在格线上，
		# 保存再载入整体漂半格。吸附到格（或吸附关闭时保留原像素位）。
		n2.position = cvs.snap_point(n2.position, n2)
	if can_delta:
		var added: Array = []
		for b2 in built:
			added.append(b2.node)
		cvs._undo_history_ctrl.inst_commit_add(added)
	cvs._mark_ents()
	cvs.queue_redraw()
	var n_contents: int = (plan.get("pending_contents", []) as Array).size()
	cvs._hint("已粘贴 %d 个实例%s（Ctrl+Z 撤销）" % [
		cvs._clipboard.size(), ("，复制内容 %d 条（随保存落盘）" % n_contents) if n_contents > 0 else ""])


## 选区是否触碰锁定层（按**层码**判定，E04：重排后下标变了也挡得住）；
## 隐藏层同样算不可触碰（看不见的内容不该被批量改写）。
func _selection_touches_locked(sel: Array) -> bool:
	for s in sel:
		var n := s as EntityNode
		if n != null and is_instance_valid(n):
			var li: int = cvs._layer_index_of(n.layer_id)
			if li >= 0 and (cvs.is_layer_locked(li) or not cvs.is_layer_visible(li)):
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
	delete_instances(victims)

func delete_instances(victims: Array) -> bool:
	if _selection_touches_locked(victims):
		cvs._hint("实例所在图层已锁定或隐藏：解锁并显示后再删除")
		return false
	# §7.5 阶段二：删除走 InstanceKey 差量；只要有一个场景图片（无码）就整体退回快照。
	var pre: Dictionary = cvs._undo_history_ctrl.inst_rows(victims)
	var via_delta := bool(pre.get("ok", false))
	if not via_delta:
		cvs.push_undo()
	for v in victims:
		if is_instance_valid(v):
			if cvs.selected_entity == v:
				cvs.selected_entity = null
			cvs.selected_multi.erase(v)
			(v.get_parent() as Node2D).remove_child(v)
			v.free()
	if via_delta:
		cvs._undo_history_ctrl.record_instance_removal(pre.rows)
	cvs._mark_ents()
	cvs.commit_selection(cvs.selected_entity, cvs.selected_multi)
	return true


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
	return transform_instances(targets, false)

func transform_instances(targets: Array, rotate: bool) -> bool:
	if _selection_touches_locked(targets):
		cvs._hint("实例所在图层已锁定或隐藏：解锁并显示后再调整")
		return false
	var pre: Dictionary = cvs._undo_history_ctrl.inst_rows(targets)
	var via_delta := bool(pre.get("ok", false))
	if not via_delta:
		cvs.push_undo()
	for s in targets:
		var node := s as EntityNode
		if rotate:
			node.rotate_90()
		else:
			node.toggle_flip_h()
	if via_delta:
		cvs._undo_history_ctrl.inst_commit(pre.get("rows", {}))
	cvs._mark_ents()
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
	return transform_instances(targets, true)

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
	var pre: Dictionary = cvs._undo_history_ctrl.inst_rows(targets)
	var via_delta := bool(pre.get("ok", false))
	if not via_delta:
		cvs.push_undo()
	for s in targets:
		(s as EntityNode).scale_step(d)
	if via_delta:
		cvs._undo_history_ctrl.inst_commit(pre.get("rows", {}))
	cvs._mark_ents()
	cvs.queue_redraw()
	return true


## —— 拆到 src/canvas/region_ops.gd（调用点保持不变） ——

func _live_selection() -> Array:
	return cvs._region_ops_ctrl._live_selection()
