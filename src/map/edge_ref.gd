extends RefCounted
## EdgeRef（§7.4 格边引用）：格拓扑里「一条边」的稳定身份。
##
## 身份完全由编辑器从格拓扑推导，不需要游戏侧声明键：
##   一条边 = 两个共边格 (a, b)；无向边取**排序后的代表边**——
##   两端点按 (y, x) 字典序排好，写成 "x1,y1|x2,y2"。edge(a,b) == edge(b,a)。
## 因此同一格对永远得到同一串，与作者点的是哪一端、格号怎么遍历无关。
##
## 字段值（公开内容字段，game 侧直读）：
##   {map: 地图码, cell: [x, y]（规范格号）, edge: "x1,y1|x2,y2"}
## map 空 = 本图（与 port_ref 的 map 分量同语义）。

## 两端点规范化排序后的边 ID（无向共享边取唯一代表）。
static func canonical_edge(a: Vector2i, b: Vector2i) -> String:
	var p := a
	var q := b
	if q.y < p.y or (q.y == p.y and q.x < p.x):
		p = b
		q = a
	return "%d,%d|%d,%d" % [p.x, p.y, q.x, q.y]

## 边 ID → 两端点 [[x, y], [x, y]]；格式不合法返回空数组。
static func parse_edge(s: String) -> Array:
	var parts := s.split("|", false)
	if parts.size() != 2:
		return []
	var out: Array = []
	for part in parts:
		var xy := str(part).split(",", false)
		if xy.size() != 2:
			return []
		if not _is_int(xy[0]) or not _is_int(xy[1]):
			return []
		out.append([int(xy[0]), int(xy[1])])
	return out

static func _is_int(s: String) -> bool:
	var t := s.strip_edges()
	if t == "":
		return false
	if t.begins_with("-"):
		t = t.substr(1)
	return t.is_valid_int()

## 字段值：{map: 地图码（空 = 本图）, cell: [x, y] 规范格号, edge: 规范边 ID}。
## cell 取规范边排序后的**第一个端点**——与 edge 永远自洽，不存两套口径。
static func value_of(map_code: String, a: Vector2i, b: Vector2i) -> Dictionary:
	var e := canonical_edge(a, b)
	var ends := parse_edge(e)
	var head: Array = ends[0] if ends.size() == 2 else [a.x, a.y]
	return {"map": map_code, "cell": [int(head[0]), int(head[1])], "edge": e}

## 读字段值里的边 ID（非字典/坏值返回 ""）。
static func edge_of(v) -> String:
	if not (v is Dictionary):
		return ""
	return str((v as Dictionary).get("edge", ""))

## 该边是否确实是格 a 的一条共边（b ∈ neighbors(a)）。调用方给邻接表，
## 本模块不持有格几何（拓扑口径归 GridSpace）。
static func is_real_edge(edge: String, a: Vector2i, neighbors: Array) -> bool:
	var ends := parse_edge(edge)
	if ends.size() != 2:
		return false
	var p0 := Vector2i(int(ends[0][0]), int(ends[0][1]))
	var p1 := Vector2i(int(ends[1][0]), int(ends[1][1]))
	# 规范边排序后 p0 在前；实际邻接方向可能是 p1 → p0，两种都要认
	if p0 == a:
		return neighbors.has(p1)
	if p1 == a:
		return neighbors.has(p0)
	return false

## 持久化的格边身份只依赖地图范围与拓扑，不依赖可变的瓦片占用。
static func segment(grid: GridSpace, a: Vector2i, b: Vector2i, w: int, h: int) -> PackedVector2Array:
	if grid == null or not grid.cell_in_map(a, w, h) or not grid.cell_in_map(b, w, h):
		return PackedVector2Array()
	return grid.edge_between(a, b)

## Maps a whole edge through a region paste. Partial or non-adjacent results
## keep their original reference; an edge is never inferred from one endpoint.
static func region_mapper(source: GridSpace, source_size: Vector2i, source_frame: Transform2D,
		area: Rect2, target: GridSpace, target_size: Vector2i, target_frame: Transform2D,
		origin: Vector2) -> Callable:
	var to_target := target_frame.affine_inverse()
	return func(value: Dictionary, map_code: String) -> Dictionary:
		var ends := parse_edge(edge_of(value))
		if ends.size() != 2:
			return {}
		var a := Vector2i(ends[0][0], ends[0][1])
		var b := Vector2i(ends[1][0], ends[1][1])
		var wa := source_frame * source.cell_center_px(a)
		var wb := source_frame * source.cell_center_px(b)
		if not area.has_point(wa) or not area.has_point(wb) or segment(source, a, b, source_size.x, source_size.y).is_empty():
			return {}
		var dst_a := target.pick_cell(to_target * (origin + wa - area.position))
		var dst_b := target.pick_cell(to_target * (origin + wb - area.position))
		if segment(target, dst_a, dst_b, target_size.x, target_size.y).is_empty():
			return {}
		return value_of(map_code, dst_a, dst_b)
