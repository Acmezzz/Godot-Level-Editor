extends RefCounted
## 有限格图可将多边形存于独立的仿射空间；空 space 表示地图根像素坐标。
## cells[].neighbors 是简单邻接；
## edges 是可独立重接的有向边，可并行且可按项目声明填写属性。

const EDGE_TYPES_KEY := "cellGraphEdgeTypes"
const SCALAR_TYPES := ["string", "int", "float", "range", "bool"]

## 从地图 meta 取格图声明（缺省空图）。
static func graph_of(meta: Dictionary) -> Dictionary:
	var g = meta.get("cellGraph", null)
	return g if g is Dictionary else {}

## 校验结构和已声明的值。声明变动产生警告，保留旧值，允许作者打开地图修复。
static func validate_graph(g: Dictionary, manifest := {}, layer_frames: Variant = null) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	var cells = g.get("cells", null)
	if g.is_empty():
		return issues
	if not (cells is Array):
		issues.append({"path": "meta.cellGraph.cells", "message": "must be an array"})
		return issues
	var ids := {}
	var spaces := _validate_spaces(g, issues, layer_frames)
	for j in (cells as Array).size():
		var c = (cells as Array)[j]
		var p := "meta.cellGraph.cells[%d]" % j
		if not (c is Dictionary):
			issues.append({"path": p, "message": "must be an object"})
			continue
		var cd: Dictionary = c
		var cid := str(cd.get("id", ""))
		if not cd.get("id") is String or cid.strip_edges() == "" or ids.has(cid):
			issues.append({"path": p + ".id", "message": "must be non-empty and unique (seen: %s)" % cid})
		ids[cid] = true
		var space = cd.get("space", "")
		if not space is String or (space != "" and not spaces.has(space)):
			_issue(issues, p + ".space", "must be empty or name a space in this graph")
		var poly = cd.get("polygon", null)
		if not (poly is Array) or (poly as Array).size() < 3:
			issues.append({"path": p + ".polygon", "message": "must be at least 3 [x, y] points"})
		else:
			for pt in (poly as Array):
				var okp: bool = _valid_point(pt)
				if not okp:
					issues.append({"path": p + ".polygon", "message": "points must be [x, y] number pairs"})
					break
			var points := points_of(cd)
			if points.size() == poly.size() and Geometry2D.triangulate_polygon(points).is_empty():
				issues.append({"path": p + ".polygon", "message": "polygon must enclose a valid area"})
		var nbs = cd.get("neighbors", null)
		if cd.has("neighbors") and not nbs is Array:
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
			if not nb is String or nb == "":
				issues.append({"path": "meta.cellGraph.cells[%d].neighbors" % j2,
					"message": "neighbor entries must be cell id strings (got %s)" % type_string(typeof(nb))})
				continue
			if not known.has(nb):
				issues.append({"path": "meta.cellGraph.cells[%d].neighbors" % j2, "message": "neighbor cell id not declared: %s" % str(nb)})
	_validate_edges(g, manifest, known, issues)
	return issues

static func _validate_spaces(g: Dictionary, issues: Array[Dictionary], layer_frames: Variant) -> Dictionary:
	var raw = g.get("spaces", {})
	if not raw is Dictionary:
		_issue(issues, "meta.cellGraph.spaces", "must be an object keyed by space id")
		return {}
	for id in raw:
		var row = raw[id]
		var path := "meta.cellGraph.spaces." + str(id)
		if not id is String or id.strip_edges() == "" or id != id.strip_edges() or not row is Dictionary:
			_issue(issues, path, "space must have a non-empty id and an object declaration")
			continue
		if row.has("name") and not row.name is String:
			_issue(issues, path + ".name", "must be a string")
		var lid = row.get("layer", "")
		if not lid is String or lid != lid.strip_edges():
			_issue(issues, path + ".layer", "must be empty or a layer id")
		elif lid != "" and layer_frames is Dictionary and not layer_frames.has(lid):
			_issue(issues, path + ".layer", "bound layer is no longer declared: " + lid, "warning")
		var valid := true
		for key in ["origin", "axisX", "axisY"]:
			if row.has(key) and not _valid_point(row[key]):
				_issue(issues, path + "." + key, "must be a finite [x, y] pair")
				valid = false
		if valid:
			var xf := space_transform(g, id)
			if not invertible(xf):
				_issue(issues, path, "space axes must form an invertible 2D basis")
			elif layer_frames is Dictionary and lid is String and layer_frames.has(lid) \
					and not invertible(layer_frames[lid] * xf):
				_issue(issues, path, "the composed layer and space transform must be invertible")
	return raw

## Local-to-root map pixel transform. Omitted parts form the identity.
static func space_transform(g: Dictionary, id: String, layer_frames := {}) -> Transform2D:
	var spaces = g.get("spaces")
	if id == "" or not spaces is Dictionary or not spaces.get(id) is Dictionary:
		return Transform2D.IDENTITY
	var row: Dictionary = spaces[id]
	var local := Transform2D(_point_or(row.get("axisX"), Vector2.RIGHT),
		_point_or(row.get("axisY"), Vector2.DOWN), _point_or(row.get("origin"), Vector2.ZERO))
	var layer: Transform2D = layer_frames.get(row.get("layer", ""), Transform2D.IDENTITY)
	return layer * local

## Bake the removed layer's static placement into its spaces without changing
## their ids, vertex data or edges. The caller owns the whole-map undo snapshot.
static func detach_layer(g: Dictionary, layer_id: String, layer_frame: Transform2D) -> void:
	var spaces = g.get("spaces")
	if layer_id == "" or not spaces is Dictionary:
		return
	for id in spaces:
		var row = spaces[id]
		if not row is Dictionary or row.get("layer") != layer_id:
			continue
		var xf := layer_frame * space_transform(g, str(id))
		row["origin"] = [xf.origin.x, xf.origin.y]
		row["axisX"] = [xf.x.x, xf.x.y]
		row["axisY"] = [xf.y.x, xf.y.y]
		row.erase("layer")

static func invertible(xf: Transform2D) -> bool:
	var det := xf.determinant()
	return xf.is_finite() and is_finite(det) and det != 0.0 \
		and absf(xf.x.normalized().cross(xf.y.normalized())) >= 0.000001 \
		and xf.affine_inverse().is_finite()

static func _point_or(raw: Variant, fallback: Vector2) -> Vector2:
	return Vector2(float(raw[0]), float(raw[1])) if _valid_point(raw) else fallback

static func map_points(g: Dictionary, cell: Dictionary, layer_frames := {}) -> PackedVector2Array:
	return space_transform(g, str(cell.get("space", "")), layer_frames) * points_of(cell)

static func bound_layers(g: Dictionary) -> Dictionary:
	var out := {}
	var spaces = g.get("spaces")
	if spaces is Dictionary:
		for row in spaces.values():
			if row is Dictionary and row.get("layer", "") != "":
				out[str(row.layer)] = true
	return out

static func layer_of_cell(g: Dictionary, id: String) -> String:
	var spaces = g.get("spaces")
	if not spaces is Dictionary:
		return ""
	for cell in g.get("cells", []):
		if cell is Dictionary and cell.get("id") == id:
			var row = spaces.get(cell.get("space", ""))
			return str(row.get("layer", "")) if row is Dictionary else ""
	return ""

static func cell_source_space(decl: Dictionary) -> Variant:
	var source := str(decl.get("source", ""))
	if source.begins_with("cell:") and source.length() > 5:
		return source.substr(5)
	return null

static func cell_options(g: Dictionary, space_filter: Variant = null) -> Array:
	var out: Array = []
	var spaces = g.get("spaces", {})
	var cells = g.get("cells", [])
	for cell in cells if cells is Array else []:
		if not cell is Dictionary or not cell.get("id") is String or cell.id == "":
			continue
		var sid: String = str(cell.get("space", ""))
		if space_filter != null and sid != space_filter:
			continue
		var name := sid
		if spaces is Dictionary and spaces.get(sid) is Dictionary:
			name = str(spaces[sid].get("name", sid))
		out.append({"v": cell.id, "t": cell.id if name == "" else "%s · %s" % [cell.id, name]})
	return out

static func edge_types(manifest: Dictionary) -> Dictionary:
	var types = manifest.get(EDGE_TYPES_KEY)
	return types if types is Dictionary else {}

static func edge_fields(types: Dictionary, kind: String) -> Array:
	var decl = types.get(kind)
	var fields = decl.get("fields") if decl is Dictionary else null
	return fields if fields is Array else []

static func edge_defaults(types: Dictionary, kind: String) -> Dictionary:
	var props := {}
	for field in edge_fields(types, kind):
		if field is Dictionary and field.get("id") is String and field.has("default"):
			props[field.id] = field.default
	return props

static func validate_edge_types(manifest: Dictionary) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	if manifest.has(EDGE_TYPES_KEY) and not manifest[EDGE_TYPES_KEY] is Dictionary:
		_issue(issues, EDGE_TYPES_KEY, "must be an object keyed by edge type")
	for id in edge_types(manifest):
		var d = manifest[EDGE_TYPES_KEY][id]
		var path := EDGE_TYPES_KEY + "." + str(id)
		if not id is String or id.strip_edges() == "" or id != id.strip_edges() or not d is Dictionary:
			_issue(issues, path, "type must have a non-empty id and an object declaration")
			continue
		var fields = d.get("fields", [])
		if not fields is Array:
			_issue(issues, path + ".fields", "must be an array")
			continue
		var seen := {}
		for i in fields.size():
			var fd = fields[i]
			var fp := "%s.fields[%d]" % [path, i]
			if not fd is Dictionary or not fd.get("id") is String or fd.id.strip_edges() == "" or seen.has(fd.id):
				_issue(issues, fp, "field id must be non-empty and unique within this type")
				continue
			seen[fd.id] = true
			if fd.get("kind") == "choice":
				var options = fd.get("options")
				if fd.has("source") or not options is Array or options.is_empty() \
						or options.any(func(o): return not o is String or o == ""):
					_issue(issues, fp, "choice requires non-empty local string options")
			elif fd.get("kind") != "input" or not SCALAR_TYPES.has(fd.get("type")):
				_issue(issues, fp, "use a scalar input or a local choice")
			elif fd.get("type") in ["int", "float", "range"]:
				for limit in ["min", "max"]:
					if fd.has(limit) and (not _number(fd[limit]) or (fd.type == "int" and fmod(float(fd[limit]), 1.0) != 0.0)):
						_issue(issues, fp + "." + limit, "must be a finite bound compatible with the input type")
				if _number(fd.get("min")) and _number(fd.get("max")) and fd.min > fd.max:
					_issue(issues, fp, "min must not exceed max")
			if fd.has("default") and not _valid_value(fd, fd.default):
				_issue(issues, fp + ".default", "does not match the declared field")
	return issues

static func _validate_edges(g: Dictionary, manifest: Dictionary, cells: Dictionary,
		issues: Array[Dictionary]) -> void:
	var edges = g.get("edges", [])
	if not edges is Array:
		_issue(issues, "meta.cellGraph.edges", "must be an array")
		return
	var ids := {}
	var types := edge_types(manifest)
	for i in edges.size():
		var row = edges[i]
		var path := "meta.cellGraph.edges[%d]" % i
		if not row is Dictionary:
			_issue(issues, path, "must be an object")
			continue
		var id = row.get("id")
		if not id is String or id.strip_edges() == "" or ids.has(id):
			_issue(issues, path + ".id", "must be non-empty and unique")
		else:
			ids[id] = true
		var to_map = row.get("toMap", "")
		if not to_map is String or to_map != to_map.strip_edges():
			_issue(issues, path + ".toMap", "must be empty or a target map code")
		if not row.get("from") is String or not cells.has(row.from):
			_issue(issues, path + ".from", "must name a cell in this graph")
		if not row.get("to") is String or row.to.strip_edges() == "":
			_issue(issues, path + ".to", "must be a non-empty destination cell id")
		elif to_map is String and to_map == "" and not cells.has(row.to):
			_issue(issues, path + ".to", "must name a cell in this graph")
		var kind = row.get("type", "")
		var props = row.get("props", {})
		if not kind is String:
			_issue(issues, path + ".type", "must be a string")
		elif not manifest.is_empty() and kind != "" and not types.has(kind):
			_issue(issues, path + ".type", "edge type is no longer declared: " + kind, "warning")
		if not props is Dictionary:
			_issue(issues, path + ".props", "must be an object")
		elif kind is String and types.get(kind) is Dictionary:
			var fields = types[kind].get("fields", [])
			for fd in fields if fields is Array else []:
				if fd is Dictionary and fd.get("id") is String and props.has(fd.id) and not _valid_value(fd, props[fd.id]):
					_issue(issues, path + ".props." + fd.id, "does not match the declared field", "warning")

static func _issue(issues: Array[Dictionary], path: String, message: String, severity := "error") -> void:
	issues.append({"path": path, "message": message, "severity": severity})

static func _number(v: Variant) -> bool:
	return (v is int or v is float) and is_finite(float(v))

static func _valid_value(fd: Dictionary, value: Variant) -> bool:
	if fd.get("kind") == "choice":
		var options = fd.get("options")
		if not options is Array:
			return false
		if fd.get("multiple", false):
			return value is Array and value.all(func(v): return v is String and options.has(v))
		return value is String and options.has(value)
	match fd.get("type"):
		"string": return value is String
		"bool": return value is bool
		"int", "float", "range":
			return _number(value) and (fd.type != "int" or fmod(float(value), 1.0) == 0.0) \
				and (not _number(fd.get("min")) or value >= fd.min) \
				and (not _number(fd.get("max")) or value <= fd.max)
	return false
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

## Remove one row and its connections in place. Explicit targets in other maps are separate identities.
static func remove_cell(cells: Array, edges: Array, index: int, map_code: String) -> void:
	var row = cells[index]
	var id: String = str(row.get("id", "")) if row is Dictionary else ""
	cells.remove_at(index)
	if id.is_empty():
		return
	for i in range(edges.size() - 1, -1, -1):
		var edge = edges[i]
		if edge is Dictionary and (edge.get("from") == id or
				(edge.get("to") == id and edge.get("toMap", "") in ["", map_code])):
			edges.remove_at(i)
	for cell in cells:
		if cell is Dictionary and cell.get("neighbors") is Array and cell.neighbors.has(id):
			cell.neighbors = cell.neighbors.filter(func(neighbor): return neighbor != id)

## 按多边形命中（非规则格画布）：返回命中的 cell_id 或 ""。射线法，命中取首个。
static func pick_cell(g: Dictionary, px: Vector2, space_filter: Variant = null, layer_frames := {}) -> String:
	for c in (g.get("cells", []) as Array):
		if not (c is Dictionary):
			continue
		if space_filter is String and c.get("space", "") != space_filter:
			continue
		var poly := map_points(g, c, layer_frames)
		if poly.size() < 3:
			continue
		if Geometry2D.is_point_in_polygon(px, poly):
			var id := str(c.get("id", ""))
			if id != "":
				return id
	return ""

## 某格的像素多边形（画布高亮用）。缺声明/点不足返回空数组。
static func polygon_of(g: Dictionary, id: String, layer_frames := {}) -> PackedVector2Array:
	for c in (g.get("cells", []) as Array):
		if c is Dictionary and str((c as Dictionary).get("id", "")) == id:
			return map_points(g, c, layer_frames)
	return PackedVector2Array()

## 某格多边形重心（画布「确认后对准这一格」用）。没有多边形返回 Vector2.ZERO。
static func centroid_of(g: Dictionary, id: String, layer_frames := {}) -> Vector2:
	var poly := polygon_of(g, id, layer_frames)
	return _centroid(poly) if poly.size() >= 3 else Vector2.ZERO

## 声明里的 polygon 数组 → PackedVector2Array（脏点跳过，不炸）。
static func points_of(c: Dictionary) -> PackedVector2Array:
	var poly := PackedVector2Array()
	var points = c.get("polygon", [])
	if not points is Array:
		return poly
	for pt in points:
		if _valid_point(pt):
			poly.append(Vector2(float((pt as Array)[0]), float((pt as Array)[1])))
	return poly

static func _valid_point(pt: Variant) -> bool:
	if not pt is Array or pt.size() != 2:
		return false
	for value in pt:
		if not (value is int or value is float) or not is_finite(float(value)):
			return false
	return true

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

