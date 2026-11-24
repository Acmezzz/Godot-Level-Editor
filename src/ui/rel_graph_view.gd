extends Control
## RelGraphView：内容关系图的**绘制层**（E2）。数据由 rel_graph.gd 提供（纯数据）。
##
## 布局 = 简单分层：入度为 0 的节点放左列，其余按 BFS 深度向右；
## 每列上下居中排开。不做力导向（规模小、可读性优先）。
## 点击节点 → 回调宿主（跳去那条内容）；点击边 → 回调宿主（定位或编辑字段）。
## 循环引用合法（游戏允许），BFS 用已访问集截断，不会无限展开。

const RelGraph := preload("res://src/content/rel_graph.gd")

var data := {}
var on_pick: Callable = Callable()   # Callable(key)
var on_edge: Callable = Callable()   # Callable(edge Dictionary)
var highlighted := ""
var expand_layout := false  # 项目图允许滚动，保证远列与长列可达

var _pos := {}        # key -> 中心点（局部坐标）
var _segs: Array = [] # [{path, edge}]：边段缓存（绘制与命中共用）
var _radius := 26.0
var _hover := ""
var _hover_edge := -1

func _ready() -> void:
	# 尺寸变化后重新分层（列宽由控件高度决定居中位置）
	resized.connect(func():
		_layout()
		queue_redraw())

func set_data(d: Dictionary) -> void:
	data = d
	_layout()
	queue_redraw()

func _layout() -> void:
	_pos.clear()
	_segs.clear()   # 空图/换数据时必须清段缓存：留着旧段 = 看不见的边还能被点中（V4 P1）
	_hover_edge = -1
	var nodes: Array = data.get("nodes", [])
	if nodes.is_empty():
		if expand_layout:
			custom_minimum_size = Vector2.ZERO
		return
	var edges: Array = data.get("edges", [])
	var indeg := {}
	var outg := {}
	for n in nodes:
		indeg[str((n as Dictionary).get("key", ""))] = 0
		outg[str((n as Dictionary).get("key", ""))] = []
	for e in edges:
		var ed: Dictionary = e
		var f := str(ed.get("from", ""))
		if outg.has(f):
			(outg[f] as Array).append(str(ed.get("to", "")))
		if indeg.has(str(ed.get("to", ""))):
			indeg[str(ed.get("to", ""))] += 1
	# BFS 分层：roots = 入度 0（全图都有入边时取第一个，避免空列）
	var layer := {}
	var roots: Array = []
	for n in nodes:
		var k := str((n as Dictionary).get("key", ""))
		if int(indeg.get(k, 0)) == 0:
			roots.append(k)
	if roots.is_empty():
		roots.append(str((nodes[0] as Dictionary).get("key", "")))
	var q: Array = roots.duplicate()
	for r in roots:
		layer[r] = 0
	var cursor := 0
	while cursor < q.size():
		var k2 := str(q[cursor])
		cursor += 1
		var d0 := int(layer.get(k2, 0))
		for t in (outg.get(k2, []) as Array):
			var tk := str(t)
			if layer.has(tk):
				continue   # 已访问：循环在图上表现为回边，不再展开
			layer[tk] = d0 + 1
			q.append(tk)
	# 未连通的节点放第 0 层
	for n in nodes:
		var k3 := str((n as Dictionary).get("key", ""))
		if not layer.has(k3):
			layer[k3] = 0
	var cols := {}
	for n in nodes:
		var k4 := str((n as Dictionary).get("key", ""))
		if not cols.has(int(layer[k4])):
			cols[int(layer[k4])] = []
		(cols[int(layer[k4])] as Array).append(k4)
	var col_w := _radius * 3.4
	var step := _radius * 2.6
	var height := size.y
	if expand_layout:
		var max_rows := 0
		for column in cols.values():
			max_rows = maxi(max_rows, column.size())
		var min_size := Vector2(col_w * cols.size() + _radius, step * max_rows + _radius * 1.6)
		custom_minimum_size = min_size
		height = maxf(height, min_size.y)
	for c in cols:
		var arr: Array = cols[c]
		var h := step * maxf(0.0, float(arr.size() - 1))
		for i in arr.size():
			_pos[str(arr[i])] = Vector2(col_w * int(c) + _radius, height * 0.5 - h * 0.5 + step * i)
	# 边段缓存（绘制与点击命中共用）：多行管道 → 目标列靠左的单行下移 14px 错开
	_segs.clear()
	var lanes := {}
	for e in edges:
		var ed2: Dictionary = e
		var a2 = _pos.get(str(ed2.get("from", "")), null)
		var b2 = _pos.get(str(ed2.get("to", "")), null)
		if a2 == null or b2 == null:
			continue
		var pair := "%s>%s" % [str(ed2.get("from", "")), str(ed2.get("to", ""))]
		var lane := int(lanes.get(pair, 0))
		lanes[pair] = lane + 1
		_segs.append({"path": _edge_path(a2, b2, lane), "edge": ed2})

func _draw() -> void:
	var nodes: Array = data.get("nodes", [])
	if nodes.is_empty():
		return
	var font: Font = ThemeDB.fallback_font
	# 边先画（节点压在上面）；同起终多行时按 lane 错开
	for si in _segs.size():
		var seg: Dictionary = _segs[si]
		var path: PackedVector2Array = seg.path
		var ed: Dictionary = seg.get("edge", {})
		var hot: bool = si == _hover_edge
		var col := Color(1.0, 0.85, 0.3, 0.9) if hot else Color(0.4, 0.85, 0.95, 0.55)
		draw_polyline(path, col, 2.4 if hot else 1.4, true)
		var tip := path[path.size() - 1]
		var dir := (tip - path[path.size() - 2]).normalized()
		if path.size() == 2:
			tip -= dir * _radius
		var left := tip - dir.rotated(0.45) * 8.0
		var right := tip - dir.rotated(-0.45) * 8.0
		draw_colored_polygon(PackedVector2Array([tip, left, right]), Color(col, 0.9))
		# 字段名标在边中点
		var mid := (path[0] + path[1]) * 0.5 if path.size() == 2 else (path[1] + path[2]) * 0.5
		draw_string(font, mid + Vector2(-12, -4), str(ed.get("label", "")),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
			Color(1.0, 0.85, 0.3, 0.95) if hot else Color(0.55, 0.9, 1.0, 0.75))
	for n in nodes:
		var nd: Dictionary = n
		var k := str(nd.get("key", ""))
		var p = _pos.get(k, null)
		if p == null:
			continue
		var at: Vector2 = p
		var is_hot: bool = k == highlighted or k == _hover
		var col := Color(1.0, 0.85, 0.3, 0.95) if is_hot else Color(0.30, 0.45, 0.58, 0.95)
		if nd.get("fn_id") == RelGraph.VIEW_KIND:
			if not is_hot:
				col = Color("#4d6654")
			var extent := Vector2.ONE * _radius
			draw_rect(Rect2(at - extent, extent * 2), col)
			draw_rect(Rect2(at - extent, extent * 2), Color(1, 1, 1, 0.85), false, 1.4)
		else:
			draw_circle(at, _radius, col)
			draw_circle(at, _radius, Color(1, 1, 1, 0.85), false, 1.4, true)
		# 名称（过长截断）+ 内容 ID 尾段（4 位随机码足够辨认）
		var nm := str(nd.get("name", ""))
		if nm.length() > 7:
			nm = nm.substr(0, 6) + "…"
		draw_string(font, at + Vector2(-_radius + 4, 2), nm,
			HORIZONTAL_ALIGNMENT_LEFT, _radius * 2 - 8, 11,
			Color(0.95, 0.97, 1.0, 0.95) if is_hot else Color(0.85, 0.9, 0.95, 0.95))
		var tail := str(nd.get("cid", ""))
		if tail.length() > 4:
			tail = tail.substr(tail.length() - 4)
		draw_string(font, at + Vector2(-_radius + 4, 14), tail,
			HORIZONTAL_ALIGNMENT_LEFT, _radius * 2 - 8, 9, Color(0.7, 0.8, 0.86, 0.8))

## 命中：光标最近的节点（半径内）；没命中返回空串。
func _node_at(p: Vector2) -> String:
	for k in _pos:
		if p.distance_to(_pos[k] as Vector2) <= _radius:
			return str(k)
	return ""

func _edge_path(a: Vector2, b: Vector2, lane: int) -> PackedVector2Array:
	if a == b:
		var outer := _radius * 1.45 + lane * 10.0
		return PackedVector2Array([a + Vector2(0, -_radius), a + Vector2(0, -outer),
			a + Vector2(outer, -outer), a + Vector2(outer, 0), a + Vector2(_radius, 0)])
	var offset := Vector2(0, 14.0 * lane)
	return PackedVector2Array([a + offset, b + offset])

## 命中：光标最近的边段（距离 ≤ 6px）。调用方先处理节点命中。
func _edge_at(p: Vector2) -> int:
	var best := -1
	var best_d := 6.0
	for i in _segs.size():
		var path: PackedVector2Array = _segs[i].path
		for j in range(1, path.size()):
			var q := Geometry2D.get_closest_point_to_segment(p, path[j - 1], path[j])
			var d := p.distance_to(q)
			if d < best_d:
				best_d = d
				best = i
	return best

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var m := event as InputEventMouseMotion
		var h := _node_at(m.position)
		var he := _edge_at(m.position) if h == "" else -1
		if h != _hover or he != _hover_edge:
			_hover = h
			_hover_edge = he
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if (h != "" or he >= 0) else Control.CURSOR_ARROW
			queue_redraw()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var k2 := _node_at(mb.position)
			if k2 != "":
				if on_pick is Callable and (on_pick as Callable).is_valid():
					(on_pick as Callable).call(k2)
				return
			var ei := _edge_at(mb.position)
			if ei >= 0 and on_edge is Callable and (on_edge as Callable).is_valid():
				(on_edge as Callable).call((_segs[ei] as Dictionary).get("edge", {}))
