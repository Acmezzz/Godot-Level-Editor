extends RefCounted
## Runtime-safe chunk overlay. This file can be used in a game without the editor.

const GRID := "gridDelta"
const CONTENT := "contentDelta"
const LAYER_FRAME := ["offset", "scale", "parallax", "tileGrid"]
const LAYER_OVERRIDES := ["name", "visible", "ySort", "blend"] + LAYER_FRAME
const FLOW_SECTIONS := ["flowOutputs", "contentSlots"]

const SOURCE_KEY := "generatorSource"

static func origin(map: Dictionary) -> Dictionary:
	var meta: Dictionary = map.get("meta", {})
	var row = meta.get(SOURCE_KEY)
	if not row is Dictionary or row.get("version") != 1 or row.get("owner") != meta.get("code") \
			or not row.get("base") is Dictionary or not row.base.get("meta") is Dictionary \
			or row.base.meta.get("code") != meta.get("code"):
		return {}
	return row

static func attach(map: Dictionary, generator: String, parameters: Dictionary, generated := {}) -> void:
	var base: Dictionary = (map if generated.is_empty() else generated).duplicate(true)
	base.meta.erase(SOURCE_KEY)
	map.meta[SOURCE_KEY] = {"version": 1, "owner": map.meta.code, "generator": generator,
		"parameters": parameters.duplicate(true), "base": base}

static func compatibility_problem(a: Dictionary, b: Dictionary, authored_stack := false) -> String:
	for field in ["w", "h", "gridProjection", "gridTopology", "gridBasis"]:
		if not _same(a.get(field), b.get(field)):
			return "网格配置不一致：%s。" % field
	var left = a.get("layers")
	var right = b.get("layers")
	if not left is Array or not right is Array or left.is_empty() or right.is_empty():
		return "图层结构不一致。"
	var before := _layer_index(left)
	var after := _layer_index(right)
	if before.is_empty() or after.is_empty():
		return "图层声明无效。"
	if before.keys()[0] != after.keys()[0] or (not authored_stack and before.keys() != after.keys()):
		return "首层或生成图层顺序不一致。"
	if authored_stack:
		return ""
	for id in before:
		for field in LAYER_FRAME:
			if not _same(before[id].get(field), after[id].get(field)):
				return "图层 %s 的空间变换或格系不一致。" % id
	return ""

static func _layer_index(layers: Array) -> Dictionary:
	var indexed := {}
	for layer in layers:
		if not layer is Dictionary or not layer.get("id") is String or layer.id.is_empty() or indexed.has(layer.id):
			return {}
		indexed[layer.id] = layer
	return indexed

static func compile(authored: Dictionary, mode: String) -> Dictionary:
	if mode not in [GRID, CONTENT]:
		return {"error": "未知差量模式。"}
	var meta: Dictionary = authored.get("meta", {}) if authored.get("meta", {}) is Dictionary else {}
	var source := origin(authored)
	if source.is_empty():
		return {"error": "差量需要本图自己的生成基线。"}
	var base: Dictionary = source.base
	var problem := compatibility_problem(base.meta, meta, mode == CONTENT)
	if problem != "":
		return {"error": problem}
	var grid := _compile_grid(base, authored, meta.layers)
	if grid.is_empty():
		return {"error": "瓦片或碰撞格位无效或重复。"}
	var result := {"error": "", "mode": mode, "meta": meta, "grid": grid, "objects": {}}
	if mode == CONTENT:
		var baseline_layers := _layer_index(base.meta.layers)
		var authored_layers := _layer_index(meta.layers)
		result["baseline_meta"] = base.meta
		var removed_layers := {}
		for id in baseline_layers:
			if not authored_layers.has(id):
				var removed = _grid_index(base.get("tiles", {}).get(id, []), true)
				if removed == null:
					return {"error": "移除图层 %s 的基线瓦片无效。" % id}
				removed_layers[id] = removed
		result["removed_layers"] = removed_layers
		var before := _object_index(base.get("objects", []))
		var after := _object_index(authored.get("objects", []))
		if not before.ok or not after.ok:
			return {"error": "摆放物列表或实例码无效，无法计算差量。"}
		var changes := {}
		for code in before.coded:
			var old: Dictionary = before.coded[code]
			if not after.coded.has(code):
				changes[code] = {"op": "remove", "base": old}
			elif not _same(old, after.coded[code]):
				if old.get("asset") != after.coded[code].get("asset"):
					return {"error": "实例 %s 更换了资产：保留旧码会改变其身份，请删除后重新摆放。" % code}
				changes[code] = {"op": "update", "base": old, "value": after.coded[code]}
		for code in after.coded:
			if not before.coded.has(code):
				changes[code] = {"op": "add", "value": after.coded[code]}
		result.objects = changes
		var default_layer: String = meta.layers[0].id
		result["decor_remove"] = _unmatched_decor(before.anonymous, after.anonymous, default_layer)
		result["decor_add"] = _unmatched_decor(after.anonymous, before.anonymous, default_layer)
		var original_spawn = base.get("spawn", [2, 2])
		var new_spawn = authored.get("spawn", [2, 2])
		if not _same(original_spawn, new_spawn):
			result["spawn"] = new_spawn
		var overrides := {}
		var grid_replacements := {}
		for id in authored_layers:
			if not baseline_layers.has(id):
				continue
			var original: Dictionary = baseline_layers[id]
			var layer: Dictionary = authored_layers[id]
			var edits := {}
			for key in LAYER_OVERRIDES:
				if not _same(original.get(key), layer.get(key)):
					edits[key] = layer.get(key)
			if not edits.is_empty():
				overrides[id] = edits
			if edits.has("tileGrid"):
				# The keys of the two tile tables belong to different spaces.
				grid_replacements[id] = {"base": _grid_index(base.get("tiles", {}).get(id, []), true),
					"rows": authored.get("tiles", {}).get(id, [])}
		result["layer_overrides"] = overrides
		result["grid_replacements"] = grid_replacements
		var topology := _compile_graph(base.meta.get("cellGraph", {}), meta.get("cellGraph", {}), meta.layers)
		if topology.has("error"):
			return topology
		result["cell_graph"] = topology
		result["flow_slots"] = _compile_flow_slots(base.meta, meta)
	return result

## Computes a new map. A conflict never mutates or partly patches the runtime map.
static func apply(runtime: Dictionary, plan: Dictionary) -> Dictionary:
	if plan.get("error", "") != "" or not plan.has("mode"):
		return {"error": str(plan.get("error", "差量计划无效。"))}
	var meta = runtime.get("meta", {})
	if not meta is Dictionary:
		return {"error": "运行时地图元数据无效。"}
	var problem := compatibility_problem(meta, plan.get("baseline_meta", plan.meta))
	if problem != "":
		return {"error": problem}
	var objects: Array = []
	if plan.mode == CONTENT:
		var current := _object_index(runtime.get("objects", []))
		if not current.ok:
			return {"error": "运行时分块的摆放物列表或实例码无效。"}
		var updated := {}
		for code in plan.objects:
			var change: Dictionary = plan.objects[code]
			var row: Dictionary = current.coded.get(code, {})
			if change.op == "add":
				if not row.is_empty():
					return {"error": "新增实例 %s 与运行时分块重码。" % code}
				continue
			if row.is_empty() and change.op == "remove":
				continue
			if row.is_empty() or row.get("asset") != change.base.get("asset"):
				return {"error": "运行时实例 %s 缺失或资产身份不一致。" % code}
			if change.op == "update":
				updated[code] = _overlay_dict(row, change.base, change.value)
		var default_layer: String = meta.layers[0].id
		var removals := _decor_counts(plan.get("decor_remove", []), default_layer)
		for row in runtime.get("objects", []):
			var code := str(row.get("code", ""))
			if code.is_empty() and not removals.is_empty():
				var key := _decor_key(row, default_layer)
				if _consume(removals, key):
					continue
			if plan.objects.get(code, {}).get("op") != "remove":
				objects.append(updated.get(code, row))
		if not removals.is_empty():
			return {"error": "当前种子缺少要移除的原始无码摆放物，无法可靠识别位置；分块差量未应用。"}
		for code in plan.objects:
			if plan.objects[code].op == "add":
				objects.append(plan.objects[code].value)
		objects.append_array(plan.get("decor_add", []))
	var out := runtime.duplicate()
	if plan.mode == CONTENT:
		var runtime_layers := _layer_index(meta.layers)
		var layers: Array = []
		var overrides: Dictionary = plan.get("layer_overrides", {})
		for authored_layer: Dictionary in plan.meta.layers:
			var layer: Dictionary = runtime_layers.get(authored_layer.id, authored_layer).duplicate(true)
			for key in overrides.get(layer.id, {}):
				var value = overrides[layer.id][key]
				if value == null:
					layer.erase(key)
				else:
					layer[key] = value
			layers.append(layer)
		var removed_layers: Dictionary = plan.get("removed_layers", {})
		for row: Dictionary in objects:
			if removed_layers.has(row.get("layer")):
				return {"error": "移除的图层 %s 仍有当前种子的摆放物。" % row.layer}
		out["objects"] = objects.duplicate(true)
		if plan.has("spawn"):
			out["spawn"] = plan.spawn.duplicate()
		out["meta"] = meta.duplicate()
		out.meta.layers = layers
		_apply_flow_slots(out.meta, plan.get("flow_slots", {}))
		var topology: Dictionary = plan.get("cell_graph", {})
		if not topology.is_empty():
			var patched_graph := _apply_graph(meta.get("cellGraph", {}), topology, layers)
			if patched_graph.has("error"):
				return patched_graph
			out.meta["cellGraph"] = patched_graph.graph
		elif not removed_layers.is_empty():
			var index := _graph_index(meta.get("cellGraph", {}))
			if index.is_empty():
				return {"error": "当前种子的有限格图无效。"}
			problem = _graph_links_problem(index, layers)
			if problem != "":
				return {"error": problem}
	var collision = _apply_grid(runtime.get("collision", []), plan.grid.collision, false)
	if collision == null or not runtime.get("tiles", {}) is Dictionary:
		return {"error": "运行时格位无效或重复。"}
	out["collision"] = collision
	var tiles: Dictionary = runtime.get("tiles", {}).duplicate()
	var removed: Dictionary = plan.get("removed_layers", {})
	var replacements: Dictionary = plan.get("grid_replacements", {})
	for id in removed:
		if not _same(_grid_index(tiles.get(id, []), true), removed[id]):
			return {"error": "移除的图层 %s 含有不同于基线的种子瓦片。" % id}
		tiles.erase(id)
	for layer in out.meta.layers:
		var id: String = layer.id
		if replacements.has(id):
			var migration: Dictionary = replacements[id]
			if not _same(_grid_index(tiles.get(id, []), true), migration.base):
				return {"error": "图层 %s 已更换格系，但当前种子的瓦片不同于基线。请保留原层并新增独立格系图层。" % id}
			tiles[id] = migration.rows.duplicate(true)
			continue
		var patched = _apply_grid(tiles.get(id, []), plan.grid.tiles[id], true)
		if patched == null:
			return {"error": "运行时瓦片格位无效或重复：%s。" % id}
		tiles[id] = patched
	out["tiles"] = tiles
	return {"error": "", "map": out}

static func _compile_flow_slots(base: Dictionary, authored: Dictionary) -> Dictionary:
	var result := {}
	for section in FLOW_SECTIONS:
		var before: Dictionary = base.get(section, {})
		var after: Dictionary = authored.get(section, {})
		var edits := {}
		for id in before:
			if not after.has(id):
				edits[id] = null
		for id in after:
			if not _same(before.get(id), after[id]):
				edits[id] = after[id]
		if not edits.is_empty():
			result[section] = edits
	return result

static func _apply_flow_slots(meta: Dictionary, changes: Dictionary) -> void:
	for section in changes:
		var slots: Dictionary = meta.get(section, {}).duplicate(true)
		for id in changes[section]:
			var target = changes[section][id]
			if target == null:
				slots.erase(id)
			else:
				slots[id] = target.duplicate(true)
		if slots.is_empty():
			meta.erase(section)
		else:
			meta[section] = slots

static func _compile_graph(base: Variant, authored: Variant, layers: Array) -> Dictionary:
	if _same(base, authored):
		return {}
	var before := _graph_index(base)
	var after := _graph_index(authored)
	if before.is_empty() or after.is_empty():
		return {"error": "基线或作者格图的格、边或空间无效。"}
	var problem := _graph_links_problem(after, layers)
	if not problem.is_empty():
		return {"error": problem}
	var groups := {}
	for group in ["spaces", "cells", "edges"]:
		var edits := {}
		for id in before[group]:
			if not after[group].has(id):
				edits[id] = {"op": "remove"}
			elif not _same(before[group][id], after[group][id]):
				edits[id] = {"op": "update", "base": before[group][id], "value": after[group][id]}
		for id in after[group]:
			if not before[group].has(id):
				edits[id] = {"op": "add", "value": after[group][id]}
		groups[group] = edits
	return {"groups": groups, "base": before.extra, "value": after.extra}

static func _apply_graph(runtime: Variant, plan: Dictionary, layers: Array) -> Dictionary:
	var live := _graph_index(runtime)
	if live.is_empty():
		return {"error": "当前种子的有限格图无效。"}
	for group in plan.groups:
		var rows: Dictionary = live[group]
		for id in plan.groups[group]:
			var edit: Dictionary = plan.groups[group][id]
			match edit.op:
				"remove":
					rows.erase(id)
				"add":
					if rows.has(id):
						return {"error": "格图 %s/%s 与当前种子重码。" % [group, id]}
					rows[id] = edit.value
				"update":
					if not rows.has(id):
						return {"error": "当前种子缺少要修改的格图条目 %s/%s。" % [group, id]}
					var row := _overlay_dict(rows[id], edit.base, edit.value)
					if group == "cells" and not _same(edit.base.get("neighbors", []), edit.value.get("neighbors", [])):
						row["neighbors"] = _overlay_neighbors(rows[id].get("neighbors", []),
							edit.base.get("neighbors", []), edit.value.get("neighbors", []))
					rows[id] = row
	var problem := _graph_links_problem(live, layers)
	if not problem.is_empty():
		return {"error": problem}
	var graph := _overlay_dict(live.extra, plan.base, plan.value)
	graph["cells"] = live.cells.values()
	if not live.spaces.is_empty() or runtime.has("spaces"):
		graph["spaces"] = live.spaces
	if not live.edges.is_empty() or runtime.has("edges"):
		graph["edges"] = live.edges.values()
	return {"graph": graph.duplicate(true)}

static func _graph_index(graph: Variant) -> Dictionary:
	if not graph is Dictionary or not graph.get("spaces", {}) is Dictionary:
		return {}
	var result := {"spaces": graph.get("spaces", {}).duplicate(), "extra": graph.duplicate()}
	for row in result.spaces.values():
		if not row is Dictionary:
			return {}
	for group in ["cells", "edges"]:
		var rows := {}
		var values = graph.get(group, [])
		if not values is Array:
			return {}
		for row in values:
			if not row is Dictionary or not row.get("id") is String or row.id.is_empty() or rows.has(row.id):
				return {}
			if group == "cells" and not row.get("neighbors", []) is Array:
				return {}
			rows[row.id] = row
		result[group] = rows
	for key in ["cells", "edges", "spaces"]:
		result.extra.erase(key)
	return result

static func _overlay_neighbors(runtime: Array, base: Array, authored: Array) -> Array:
	var original := {}
	var ranks := {}
	for id in base:
		original[id] = true
	for i in authored.size():
		ranks[authored[i]] = i
	var result := runtime.filter(func(id): return not original.has(id) or ranks.has(id))
	var retained := {}
	for id in result:
		retained[id] = true
	for id in authored:
		if not original.has(id) and not retained.has(id):
			result.append(id)
			retained[id] = true
	# Preserve seed order unless the author reordered existing destinations.
	var before := base.filter(func(id): return ranks.has(id))
	var after := authored.filter(func(id): return original.has(id))
	if not _same(before, after):
		var ordered := result.filter(func(id): return ranks.has(id))
		ordered.sort_custom(func(a, b): return ranks[a] < ranks[b])
		var cursor := 0
		for i in result.size():
			if ranks.has(result[i]):
				result[i] = ordered[cursor]
				cursor += 1
	return result

static func _graph_links_problem(graph: Dictionary, layers: Array) -> String:
	var layer_ids := {}
	for layer: Dictionary in layers:
		layer_ids[layer.id] = true
	for id in graph.spaces:
		var row: Dictionary = graph.spaces[id]
		var layer = row.get("layer", "")
		if layer != "" and not layer_ids.has(layer):
			return "格图空间 %s 找不到图层 %s。" % [id, layer]
		var x := _graph_point(row.get("axisX", [1, 0]))
		var y := _graph_point(row.get("axisY", [0, 1]))
		var space_origin := _graph_point(row.get("origin", [0, 0]))
		var frame := Transform2D(x, y, space_origin)
		if (not frame.is_finite() or absf(x.normalized().cross(y.normalized())) < 0.000001
				or not frame.affine_inverse().is_finite()):
			return "格图空间 %s 的合并坐标轴不可逆。" % id
	for id in graph.cells:
		var row: Dictionary = graph.cells[id]
		var space = row.get("space", "")
		if space != "" and not graph.spaces.has(space):
			return "格 %s 找不到空间 %s。" % [id, space]
		for neighbor in row.get("neighbors", []):
			if not graph.cells.has(neighbor):
				return "格 %s 的邻接目标 %s 已不存在。" % [id, neighbor]
	for id in graph.edges:
		var edge: Dictionary = graph.edges[id]
		if not graph.cells.has(edge.get("from")) or (edge.get("toMap", "") == "" and not graph.cells.has(edge.get("to"))):
			return "格图边 %s 的本地端点已不存在。" % id
	return ""

static func _graph_point(pair: Variant) -> Vector2:
	if not pair is Array or pair.size() != 2:
		return Vector2(NAN, NAN)
	for value in pair:
		if not (value is int or value is float):
			return Vector2(NAN, NAN)
	return Vector2(pair[0], pair[1])

static func _object_index(rows: Variant) -> Dictionary:
	var coded := {}
	var anonymous: Array = []
	if not rows is Array:
		return {"ok": false}
	for row in rows:
		if not row is Dictionary or not row.get("code", "") is String:
			return {"ok": false}
		var code: String = row.get("code", "")
		if code == "":
			anonymous.append(row)
		elif coded.has(code):
			return {"ok": false}
		else:
			coded[code] = row
	return {"ok": true, "coded": coded, "anonymous": anonymous}

## With no stable identity, an edit is removal of an exact baseline placement
## plus an addition. Counts distinguish intentional duplicates from row order.
static func _unmatched_decor(rows: Array, other: Array, default_layer: String) -> Array:
	var counts := _decor_counts(other, default_layer)
	var result: Array = []
	for row: Dictionary in rows:
		if not _consume(counts, _decor_key(row, default_layer)):
			result.append(row)
	return result

static func _decor_counts(rows: Array, default_layer: String) -> Dictionary:
	var counts := {}
	for row: Dictionary in rows:
		var key := _decor_key(row, default_layer)
		counts[key] = int(counts.get(key, 0)) + 1
	return counts

static func _consume(counts: Dictionary, key: String) -> bool:
	var count := int(counts.get(key, 0))
	if count == 0:
		return false
	if count == 1:
		counts.erase(key)
	else:
		counts[key] = count - 1
	return true

static func _decor_key(row: Dictionary, default_layer: String) -> String:
	var value := row.duplicate()
	value.erase("code")
	value["layer"] = row.get("layer", default_layer)
	for key in ["props", "transform", "functions"]:
		if row.get(key) in [null, {}, []]:
			value.erase(key)
	if row.get("visible", true):
		value.erase("visible")
	if row.get("zPolicy", "auto") in ["", "auto"]:
		value.erase("zPolicy")
	return JSON.stringify(_normalized_numbers(value), "", true, true)

static func _normalized_numbers(value: Variant) -> Variant:
	if value is int or value is float:
		return 0.0 if value == 0 else float(value)
	if value is Array:
		return value.map(_normalized_numbers)
	if value is Dictionary:
		var result := {}
		for key in value:
			result[key] = _normalized_numbers(value[key])
		return result
	return value

static func _overlay_dict(runtime: Dictionary, base: Dictionary, authored: Dictionary) -> Dictionary:
	var out := runtime.duplicate()
	for key in base:
		if not authored.has(key):
			if base[key] is Dictionary and runtime.get(key) is Dictionary:
				var retained := _overlay_dict(runtime[key], base[key], {})
				if not retained.is_empty():
					out[key] = retained
					continue
			out.erase(key)
	for key in authored:
		var value = authored[key]
		if base.has(key) and _same(base[key], value):
			continue
		if value is Dictionary and runtime.get(key) is Dictionary \
				and (not base.has(key) or base[key] is Dictionary):
			out[key] = _overlay_dict(runtime[key], base.get(key, {}), value)
		else:
			out[key] = value
	return out

static func _compile_grid(base: Dictionary, authored: Dictionary, layers: Array) -> Dictionary:
	if not base.get("tiles", {}) is Dictionary or not authored.get("tiles", {}) is Dictionary:
		return {}
	var collision := _compile_grid_rows(base.get("collision", []), authored.get("collision", []), false)
	if collision.is_empty():
		return {}
	var tiles := {}
	for row in layers:
		if not row.get("id") is String or str(row.id) == "" or tiles.has(row.id):
			return {}
		var id: String = row.id
		var changes := _compile_grid_rows(base.get("tiles", {}).get(id, []), authored.get("tiles", {}).get(id, []), true)
		if changes.is_empty():
			return {}
		tiles[id] = changes
	return {"collision": collision, "tiles": tiles}

static func _compile_grid_rows(base: Variant, authored: Variant, tile: bool) -> Dictionary:
	var before = _grid_index(base, tile)
	var after = _grid_index(authored, tile)
	if before == null or after == null:
		return {}
	var edits := {}
	for key in before:
		if not after.has(key):
			edits[key] = null
	for key in after:
		if not before.has(key) or not _same(before[key], after[key]):
			edits[key] = after[key]
	return {"edits": edits}

static func _apply_grid(runtime: Variant, patch: Dictionary, tile: bool) -> Variant:
	var result = _grid_index(runtime, tile)
	if result == null:
		return null
	for key in patch.edits:
		if patch.edits[key] == null:
			result.erase(key)
		else:
			result[key] = patch.edits[key]
	return result.values().duplicate(true)

static func _grid_index(rows: Variant, tile: bool) -> Variant:
	if not rows is Array:
		return null
	var cells := {}
	for row in rows:
		if (tile and not (row is Array and row.size() == 6)) or (not tile and not row is Dictionary):
			return null
		var x = row[0] if tile else row.get("x")
		var y = row[1] if tile else row.get("y")
		if not _integer(x) or not _integer(y):
			return null
		var key := Vector2i(int(row[0]), int(row[1])) if tile else Vector2i(int(row.x), int(row.y))
		if cells.has(key):
			return null
		cells[key] = row
	return cells

static func _integer(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and floorf(float(value)) == value and absi(int(value)) <= 2147483647

static func _same(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		return a == b
	if typeof(a) != typeof(b):
		return false
	if a is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _same(a[i], b[i]):
				return false
		return true
	if a is Dictionary:
		if a.size() != b.size():
			return false
		for key in a:
			if not b.has(key) or not _same(a[key], b[key]):
				return false
		return true
	return a == b
