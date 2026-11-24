extends RefCounted
## Validation for the point list consumed by the asset's declared visual.

const MAX_POINTS := 512
const MAX_HOLES := 32
const MAX_PARTS := 32
const POLY := {"type": "poly"}

static func closed(visual: Dictionary) -> bool:
	return visual.get("type") == "poly" and visual.get("closed", true) == true

static func minimum(visual: Dictionary) -> int:
	return 3 if closed(visual) else 2

static func problem(points: Array, visual: Dictionary) -> String:
	var floor_count := minimum(visual)
	if points.size() < floor_count or points.size() > MAX_POINTS:
		return "需要 %d 至 %d 个顶点。" % [floor_count, MAX_POINTS]
	var path := PackedVector2Array()
	for value in points:
		var p: Vector2
		if value is Vector2:
			p = value
		elif value is Array and value.size() == 2 and _number(value[0]) and _number(value[1]):
			p = Vector2(value[0], value[1])
		else:
			return "顶点必须是有限的二维坐标。"
		if not p.is_finite():
			return "顶点必须是有限的二维坐标。"
		p = p.snapped(Vector2(0.01, 0.01))
		if not path.is_empty() and path[-1] == p:
			return "相邻顶点不能重合。"
		path.append(p)
	if not closed(visual):
		return ""
	var seen := {}
	for p in path:
		if seen.has(p):
			return "闭合轮廓不能重复顶点（末点会自动接回起点）。"
		seen[p] = true
	var count := path.size()
	for i in count:
		var a := path[i]
		var b := path[(i + 1) % count]
		var prev := path[posmod(i - 1, count)]
		if is_zero_approx((prev - a).cross(b - a)) and (prev - a).dot(b - a) > 0.0:
			return "闭合轮廓不能沿同一条边折返。"
		for j in range(i + 2, count if i != 0 else count - 1):
			if _intersects(a, b, path[j], path[(j + 1) % count]):
				return "闭合轮廓不能自交。"
	if Geometry2D.triangulate_polygon(path).is_empty():
		return "闭合轮廓必须能围出面积。"
	return ""

static func _intersects(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> bool:
	if Geometry2D.segment_intersects_segment(a, b, c, d) != null:
		return true
	# Parallel overlaps or an endpoint on a non-adjacent edge also invalidate a ring.
	return _on_segment(a, c, d) or _on_segment(b, c, d) or _on_segment(c, a, b) or _on_segment(d, a, b)

static func _on_segment(p: Vector2, a: Vector2, b: Vector2) -> bool:
	return p.distance_squared_to(Geometry2D.get_closest_point_to_segment(p, a, b)) <= 0.00000001

static func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))

static func holes_problem(outer: Array, holes: Variant) -> String:
	if not holes is Array or holes.size() > MAX_HOLES:
		return "孔洞必须是数组，最多 %d 个。" % MAX_HOLES
	if holes.is_empty():
		return ""
	if problem(outer, POLY) != "":
		return "添加孔洞前须有有效的外轮廓。"
	var exterior := _ring(outer)
	var accepted: Array[PackedVector2Array] = []
	var total := outer.size()
	for i in holes.size():
		var raw = holes[i]
		if not raw is Array:
			return "孔洞 %d 必须是顶点数组。" % (i + 1)
		total += raw.size()
		if total > MAX_POINTS:
			return "外轮廓与孔洞共计最多 %d 个顶点。" % MAX_POINTS
		var issue := problem(raw, POLY)
		if issue != "":
			return "孔洞 %d：%s" % [i + 1, issue]
		var ring := _ring(raw)
		if not Geometry2D.is_point_in_polygon(ring[0], exterior) or _rings_touch(exterior, ring):
			return "孔洞 %d 必须完全位于外轮廓内，不能接触边界。" % (i + 1)
		for other in accepted:
			if _rings_touch(other, ring) or Geometry2D.is_point_in_polygon(ring[0], other) \
					or Geometry2D.is_point_in_polygon(other[0], ring):
				return "孔洞 %d 与已有孔洞相交、相切或互相包含。" % (i + 1)
		accepted.append(ring)
	return ""

static func _ring(raw: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for row in raw:
		var p := row as Vector2 if row is Vector2 else Vector2(row[0], row[1])
		out.append(p.snapped(Vector2(0.01, 0.01)))
	return out

static func parts_problem(parts: Array) -> String:
	if parts.size() > MAX_PARTS:
		return "最多 %d 个外轮廓。" % MAX_PARTS
	var total := 0
	var exteriors: Array[PackedVector2Array] = []
	for i in parts.size():
		var part = parts[i]
		if not part is Dictionary or not part.get("points") is Array:
			return "轮廓 %d 缺少顶点数组。" % (i + 1)
		var issue := problem(part.points, POLY)
		if not issue.is_empty():
			return "轮廓 %d：%s" % [i + 1, issue]
		var holes = part.get("holes", [])
		issue = holes_problem(part.points, holes)
		if not issue.is_empty():
			return "轮廓 %d：%s" % [i + 1, issue]
		total += part.points.size()
		for hole in holes:
			total += hole.size()
		if total > MAX_POINTS:
			return "所有轮廓与孔洞共计最多 %d 个顶点。" % MAX_POINTS
		var ring := _ring(part.points)
		for other in exteriors:
			if _rings_touch(other, ring) or Geometry2D.is_point_in_polygon(ring[0], other) \
					or Geometry2D.is_point_in_polygon(other[0], ring):
				return "外轮廓之间不可相交、接触或嵌套。"
		exteriors.append(ring)
	return ""

static func _rings_touch(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	for i in a.size():
		for j in b.size():
			if _intersects(a[i], a[(i + 1) % a.size()], b[j], b[(j + 1) % b.size()]):
				return true
	return false

## Even-odd fill between consecutive vertex heights. Valid boundaries cannot
## cross inside a strip, so each pair of adjacent crossings makes a trapezoid.
static func fill_strips(rings: Array[PackedVector2Array]) -> Array[PackedVector2Array]:
	var ys := {}
	var edges: Array[Vector4] = []
	var count := 0
	for ring in rings:
		count += ring.size()
		if count > MAX_POINTS:
			return []
		for i in ring.size():
			var a := ring[i]
			var b := ring[(i + 1) % ring.size()]
			ys[a.y] = true
			if a.y < b.y:
				edges.append(Vector4(a.x, a.y, b.x, b.y))
			elif a.y > b.y:
				edges.append(Vector4(b.x, b.y, a.x, a.y))
	var heights := ys.keys()
	heights.sort()
	var out: Array[PackedVector2Array] = []
	for i in range(heights.size() - 1):
		var lo: float = heights[i]
		var hi: float = heights[i + 1]
		var active: Array[Vector2] = []
		for edge in edges:
			if edge.y <= lo and edge.w >= hi:
				var slope := (edge.z - edge.x) / (edge.w - edge.y)
				active.append(Vector2(edge.x + (lo - edge.y) * slope, edge.x + (hi - edge.y) * slope))
		active.sort_custom(func(a: Vector2, b: Vector2): return a.x + a.y < b.x + b.y)
		for j in range(0, active.size() - 1, 2):
			var a := active[j]
			var b := active[j + 1]
			var shape := PackedVector2Array([Vector2(a.x, lo)])
			if not is_equal_approx(a.x, b.x):
				shape.append(Vector2(b.x, lo))
			shape.append(Vector2(b.y, hi))
			if not is_equal_approx(a.y, b.y):
				shape.append(Vector2(a.y, hi))
			if shape.size() >= 3:
				out.append(shape)
	return out
