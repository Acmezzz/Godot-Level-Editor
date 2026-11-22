extends RefCounted
## CellGraph（C4 §7.4）：有限格图——地图 meta.cellGraph 声明的 {cells: [{id, polygon, neighbors}]}。
## 只读参考层：编辑器验证（无重复 id、有效多边形、邻接目标存在）+ 按多边形命中。
## cell_id 引用存公开内容字段（choice source "cell:" 枚举）；第一版不进 v7 整数瓦片坐标。

## 从地图 meta 取格图声明（缺省空图）。
static func graph_of(meta: Dictionary) -> Dictionary:
	var g = meta.get("cellGraph", null)
	return g if g is Dictionary else {}

## 声明校验：返回 issues [{path, message}]（格图坏 = cell_id 引用落空，全部 error）。
static func validate_graph(g: Dictionary) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	var cells = g.get("cells", null)
	if cells == null:
		return issues
	if not (cells is Array):
		issues.append({"path": "meta.cellGraph.cells", "message": "must be an array"})
		return issues
	var ids := {}
	for j in (cells as Array).size():
		var c = (cells as Array)[j]
		var p := "meta.cellGraph.cells[%d]" % j
		if not (c is Dictionary):
			issues.append({"path": p, "message": "must be an object"})
			continue
		var cd: Dictionary = c
		var cid := str(cd.get("id", ""))
		if cid == "" or ids.has(cid):
			issues.append({"path": p + ".id", "message": "must be non-empty and unique (seen: %s)" % cid})
		ids[cid] = true
		var poly = cd.get("polygon", null)
		if not (poly is Array) or (poly as Array).size() < 3:
			issues.append({"path": p + ".polygon", "message": "must be at least 3 [x, y] points"})
		else:
			for pt in (poly as Array):
				var okp: bool = pt is Array and (pt as Array).size() >= 2 and ((pt as Array)[0] is int or (pt as Array)[0] is float) and ((pt as Array)[1] is int or (pt as Array)[1] is float)
				if not okp:
					issues.append({"path": p + ".polygon", "message": "points must be [x, y] number pairs"})
					break
		var nbs = cd.get("neighbors", null)
		if nbs != null and not (nbs is Array):
			issues.append({"path": p + ".neighbors", "message": "must be an array of cell ids"})
	var known := ids
	for j2 in (cells as Array).size():
		var c2 = (cells as Array)[j2]
		if not (c2 is Dictionary):
			continue
		# 第二遍读 neighbors 必须重新判型：上面只报错不停手，坏值（字符串/字典）留在这里，
		# 直接 `as Array` 会得到 null 并在 for 上炸（V4 P1）。
		var nbs2 = (c2 as Dictionary).get("neighbors", null)
		if not (nbs2 is Array):
			continue
		for nb in (nbs2 as Array):
			if not (nb is String or nb is StringName or nb is int or nb is float):
				issues.append({"path": "meta.cellGraph.cells[%d].neighbors" % j2,
					"message": "neighbor entries must be cell id strings (got %s)" % type_string(typeof(nb))})
				continue
			if str(nb) != "" and not known.has(str(nb)):
				issues.append({"path": "meta.cellGraph.cells[%d].neighbors" % j2, "message": "neighbor cell id not declared: %s" % str(nb)})
	return issues
## cell_id 枚举（choice source "cell:" 的候选值）。
static func cell_ids(g: Dictionary) -> Array:
	var out: Array = []
	for c in (g.get("cells", []) as Array):
		if c is Dictionary and str((c as Dictionary).get("id", "")) != "":
			out.append(str((c as Dictionary).get("id", "")))
	return out

## 邻接（含回绕边：邻接就是显式声明，直接查表）。
static func neighbors(g: Dictionary, id: String) -> Array:
	for c in (g.get("cells", []) as Array):
		if c is Dictionary and str((c as Dictionary).get("id", "")) == id:
			var nbs = (c as Dictionary).get("neighbors", [])
			return nbs if nbs is Array else []
	return []

## 按多边形命中（非规则格画布）：返回命中的 cell_id 或 ""。射线法，命中取首个。
static func pick_cell(g: Dictionary, px: Vector2) -> String:
	var best := ""
	for c in (g.get("cells", []) as Array):
		if not (c is Dictionary):
			continue
		var poly := _poly_of(c as Dictionary)
		if poly.size() < 3:
			continue
		if Geometry2D.is_point_in_polygon(px, poly):
			if best == "":
				best = str((c as Dictionary).get("id", ""))
	return best

## 某格的像素多边形（画布高亮用）。缺声明/点不足返回空数组。
static func polygon_of(g: Dictionary, id: String) -> PackedVector2Array:
	for c in (g.get("cells", []) as Array):
		if c is Dictionary and str((c as Dictionary).get("id", "")) == id:
			return _poly_of(c as Dictionary)
	return PackedVector2Array()

## 某格多边形重心（画布「确认后对准这一格」用）。没有多边形返回 Vector2.ZERO。
static func centroid_of(g: Dictionary, id: String) -> Vector2:
	var poly := polygon_of(g, id)
	return _centroid(poly) if poly.size() >= 3 else Vector2.ZERO

## 声明里的 polygon 数组 → PackedVector2Array（脏点跳过，不炸）。
static func _poly_of(c: Dictionary) -> PackedVector2Array:
	var poly := PackedVector2Array()
	for pt in (c.get("polygon", []) as Array):
		if pt is Array and (pt as Array).size() >= 2:
			poly.append(Vector2(float((pt as Array)[0]), float((pt as Array)[1])))
	return poly

## 多边形面积重心（三角扇形加权）；退化（面积 0）退回点均值。
static func _centroid(poly: PackedVector2Array) -> Vector2:
	var a := 0.0
	var acc := Vector2.ZERO
	var n := poly.size()
	for i in n:
		var p0 := poly[i]
		var p1 := poly[(i + 1) % n]
		var cross := p0.x * p1.y - p1.x * p0.y
		a += cross
		acc += (p0 + p1) * cross
	if is_zero_approx(a):
		var sum := Vector2.ZERO
		for p in poly:
			sum += p
		return sum / float(n)
	return acc / (3.0 * a)

