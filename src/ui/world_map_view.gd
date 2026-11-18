extends Control
## 世界地图总览：把所有地图画成节点、跨图 exit 画成有向连线。
## 用于银河城类项目检查整体连通性与孤立区域。
## 纯绘制 + 点击选中，不做 IO；数据由 app 传入。

const Th := preload("res://src/ui/ui_theme.gd")

var nodes: Array = []       # [{map, w, h, area, orders, issues}]
var edges: Array = []       # [{from, to, count, paired}]
var on_select: Callable
var selected := ""
var _rects := {}            # map_name → Rect2
var _hover := ""

const NODE_W := 130.0
const NODE_H := 54.0
const GAP_X := 60.0
const GAP_Y := 52.0
const NODE_PAD := 12.0

func setup(p_nodes: Array, p_edges: Array, current := "") -> void:
	nodes = p_nodes
	edges = p_edges
	if current != "":
		selected = current
	_layout()
	queue_redraw()

## 侧边面板只有约 270px 可用：节点宽度必须跟着实际宽度缩，不能写死 130
func _node_w() -> float:
	return clampf(size.x - 2.0 * NODE_PAD - GAP_X, 96.0, NODE_W)

## 按网格排布：列数随宽度自适应，按 area 分组优先、其次 order
func _layout() -> void:
	_rects.clear()
	if nodes.is_empty():
		custom_minimum_size = Vector2(0, 120)
		return
	var sorted := nodes.duplicate()
	sorted.sort_custom(func(a, b):
		var aa := str((a as Dictionary).get("area", ""))
		var ba := str((b as Dictionary).get("area", ""))
		if aa != ba:
			return aa < ba
		return int((a as Dictionary).get("order", 0)) < int((b as Dictionary).get("order", 0)))
	var nw := _node_w()
	var avail := maxf(size.x, 200.0)
	var cols := maxi(int((avail - 2.0 * NODE_PAD + GAP_X) / (nw + GAP_X)), 1)
	for i in sorted.size():
		var col := i % cols
		var row := int(i / float(cols))
		var pos := Vector2(NODE_PAD + col * (nw + GAP_X), 16.0 + row * (NODE_H + GAP_Y))
		var md: Dictionary = sorted[i]
		_rects[str(md.get("map", ""))] = Rect2(pos, Vector2(nw, NODE_H))
	var rows := int(ceil(float(sorted.size()) / float(cols)))
	# U-20：只回填高度——宽度写进 custom_minimum_size 会形成反馈回路，
	# 窗口变窄时缩不回去（且横向滚动已禁用，宽了就永远裁掉）
	custom_minimum_size = Vector2(0, 32.0 + rows * (NODE_H + GAP_Y))

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and not nodes.is_empty():
		_layout()
		queue_redraw()

func _draw() -> void:
	if nodes.is_empty():
		draw_string(ThemeDB.fallback_font, Vector2(12, 28), "没有地图", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.7, 0.7, 0.7))
		return
	# 连线（先画，压在节点下）
	for ed in edges:
		var from := str(ed.get("from", ""))
		var to := str(ed.get("to", ""))
		if not _rects.has(from) or not _rects.has(to):
			continue
		var a: Rect2 = _rects[from]
		var b: Rect2 = _rects[to]
		# U-21：按相对位置选对边——目标在左/上时不再横穿节点阵
		var ctr_a := a.position + a.size * 0.5
		var ctr_b := b.position + b.size * 0.5
		var dvec := ctr_b - ctr_a
		var p1: Vector2
		var p2: Vector2
		if absf(dvec.x) >= absf(dvec.y):
			p1 = a.position + Vector2(a.size.x if dvec.x > 0 else 0.0, a.size.y * 0.5)
			p2 = b.position + Vector2(0.0 if dvec.x > 0 else b.size.x, b.size.y * 0.5)
		else:
			p1 = a.position + Vector2(a.size.x * 0.5, a.size.y if dvec.y > 0 else 0.0)
			p2 = b.position + Vector2(b.size.x * 0.5, 0.0 if dvec.y > 0 else b.size.y)
		var paired_count := int(ed.get("paired_count", 0))
		var one_way_count := int(ed.get("one_way_count", 0))
		var broken_count := int(ed.get("broken_count", 0))
		var invalid_count := int(ed.get("invalid_count", 0))
		var paired := bool(ed.get("paired", false))
		var col := Th.WM_ERR if broken_count + invalid_count > 0 else (Th.WM_EDGE_PAIRED if paired else Th.WM_EDGE_ONEWAY)
		draw_line(p1, p2, col, 2.0 if paired and broken_count + invalid_count == 0 else 1.5, true)
		# 箭头
		var dir := (p2 - p1).normalized()
		var tip := p2
		var left := tip - dir * 8.0 + dir.orthogonal() * 4.0
		var right := tip - dir * 8.0 - dir.orthogonal() * 4.0
		draw_colored_polygon(PackedVector2Array([tip, left, right]), col)
		var mid := (p1 + p2) * 0.5
		var cnt := int(ed.get("count", 1))
		if cnt > 1:
			var relation_text := ""
			if paired_count > 0:
				relation_text += "↔%d " % paired_count
			if one_way_count > 0:
				relation_text += "→%d " % one_way_count
			if broken_count > 0:
				relation_text += "!%d " % broken_count
			if invalid_count > 0:
				relation_text += "?%d " % invalid_count
			draw_string(ThemeDB.fallback_font, mid + Vector2(2, -3), relation_text.strip_edges(),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)
	# 节点
	for nd in nodes:
		var map_name := str(nd.get("map", ""))
		if not _rects.has(map_name):
			continue
		var r: Rect2 = _rects[map_name]
		var is_sel := map_name == selected
		var is_hover := map_name == _hover
		var bg := Th.WM_NODE_BG
		if is_sel:
			bg = Th.WM_NODE_BG_SEL
		elif is_hover:
			bg = Th.WM_NODE_BG_HOVER
		draw_rect(r, bg, true)
		var border := Th.WM_NODE_BORDER_SEL if is_sel else Th.WM_NODE_BORDER
		draw_rect(r, border, false, 2.0 if is_sel else 1.0)
		# 名称
		draw_string(ThemeDB.fallback_font, r.position + Vector2(9, 21),
			str(nd.get("name", map_name)), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 18, 14, Th.WM_TEXT)
		# 第二行：尺寸 + 实体数
		draw_string(ThemeDB.fallback_font, r.position + Vector2(9, 39),
			"%dx%d · %d 实体" % [int(nd.get("w", 0)), int(nd.get("h", 0)), int(nd.get("ents", 0))],
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 18, 11, Th.WM_TEXT_META)
		# area 标签（右上角，和名称同基线；窄节点时省掉避免压字）
		var area := str(nd.get("area", ""))
		if area != "" and r.size.x >= 150.0:
			draw_string(ThemeDB.fallback_font, r.position + Vector2(r.size.x - 58, 16),
				area, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Th.WM_AREA)
		# 问题标记
		var iss := int(nd.get("issues", 0))
		if iss > 0:
			draw_circle(r.position + Vector2(r.size.x - 10, r.size.y - 10), 5.0, Th.WM_ERR)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var h := _map_at(get_local_mouse_position())
		if h != _hover:
			_hover = h
			queue_redraw()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var map_name := _map_at(get_local_mouse_position())
		if map_name != "":
			selected = map_name
			queue_redraw()
			if on_select.is_valid():
				on_select.call(map_name)

func _map_at(p: Vector2) -> String:
	for map_name in _rects:
		if (_rects[map_name] as Rect2).has_point(p):
			return str(map_name)
	return ""
