extends RefCounted
## Plan a finite graph extension from one tile layer without mutating authored rows.

const GENERATED_KEY := "generatedFromTile"

static func plan(graph: Dictionary, grid: GridSpace, layer: String, space: String,
		cells: Array[Vector2i], connect_existing := false, has_tile := Callable()) -> Dictionary:
	if cells.is_empty():
		return {"error": "所选图层或范围内没有瓦片。"}
	var spaces: Dictionary = graph.get("spaces", {})
	var existing = spaces.get(space, {})
	if spaces.has(space) and (not existing is Dictionary or existing.get("layer", "") != layer
			or existing.has("origin") or existing.has("axisX") or existing.has("axisY")):
		return {"error": "同名空间未绑定到此图层，或已有局部变换。请使用新的空间 ID。"}
	var taken := {}
	var previous: Array = graph.get("cells", [])
	for i in previous.size():
		var row = previous[i]
		if row is Dictionary:
			taken[row.get("id", "")] = i
	var ids := {}
	var seen := {}
	var skipped := 0
	var frame := grid.geometry_key()
	var ordered := cells.duplicate()
	ordered.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y or (a.y == b.y and a.x < b.x))
	for cell in ordered:
		if seen.has(cell):
			return {"error": "输入包含重复瓦片格。"}
		seen[cell] = true
		var id := _id(space, cell)
		if taken.has(id):
			if not _is_generated(previous[taken[id]], space):
				return {"error": "格 ID 已被其他格占用：%s。现有多边形和连边未改动。" % id}
			skipped += 1
			continue
		ids[cell] = id
	var rows: Array[Dictionary] = []
	var joins := {}
	for cell in ordered:
		if not ids.has(cell):
			continue
		var points: Array = []
		for point in grid.cell_polygon(cell):
			points.append([point.x, point.y])
		var neighbors: Array[String] = []
		for neighbor in grid.neighbors_any(cell):
			if ids.has(neighbor):
				neighbors.append(ids[neighbor])
				continue
			if not connect_existing or (not seen.has(neighbor)
					and (not has_tile.is_valid() or not has_tile.call(neighbor))):
				continue
			var target := _id(space, neighbor)
			var index: int = taken.get(target, -1)
			if index < 0 or not _is_generated(previous[index], space) or previous[index][GENERATED_KEY] != frame:
				continue
			var old_neighbors = previous[index].get("neighbors", [])
			if not old_neighbors is Array:
				return {"error": "已有格 %s 的邻接无效，请先修正。" % target}
			if not joins.has(index):
				joins[index] = old_neighbors.duplicate()
			neighbors.append(target)
			if not joins[index].has(ids[cell]):
				joins[index].append(ids[cell])
		var row := {"id": ids[cell], "space": space, "polygon": points, "neighbors": neighbors}
		row[GENERATED_KEY] = frame
		rows.append(row)
	return {"rows": rows, "joins": joins, "skipped": skipped}

static func _id(space: String, cell: Vector2i) -> String:
	return "%s:%d,%d" % [space, cell.x, cell.y]

static func _is_generated(row: Dictionary, space: String) -> bool:
	return row.get(GENERATED_KEY) is String and row.get("space", "") == space
