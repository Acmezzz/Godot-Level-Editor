extends RefCounted
## Plans a copy of one tile layer. Cell collisions and out-of-range targets block the batch.

static func plan(rows: Array, source: GridSpace, target: GridSpace,
		size: Vector2i, by_center: bool) -> Dictionary:
	var result := {"rows": [], "moved": 0, "outside": 0, "collisions": 0, "examples": []}
	var assigned := {}
	for row in rows:
		var from := Vector2i(int(row[0]), int(row[1]))
		var to := target.pick_cell(source.cell_center_px(from)) if by_center else from
		if not target.cell_in_map(to, size.x, size.y):
			result.outside += 1
			_example(result, "%s → %s：越界" % [from, to])
			continue
		if assigned.has(to):
			result.collisions += 1
			_example(result, "%s 与 %s 同时落到 %s" % [assigned[to], from, to])
			continue
		assigned[to] = from
		var output: Array = row.duplicate(true)
		output[0] = to.x
		output[1] = to.y
		result.rows.append(output)
		if from != to:
			result.moved += 1
	return result

static func _example(result: Dictionary, line: String) -> void:
	if result.examples.size() < 6:
		result.examples.append(line)
