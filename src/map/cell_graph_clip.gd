extends RefCounted
## Copies the induced subgraph. Selection and storage use canvas pixels; paste
## converts back into the destination graph spaces without changing their IDs.

const Graph := preload("res://src/map/cell_graph.gd")
const Tiles := preload("res://src/map/cell_graph_tiles.gd")

static func capture(graph: Dictionary, world: Transform2D, frames: Dictionary, layers: Dictionary,
		area: Rect2, map_name: String, map_code: String) -> Dictionary:
	var cells := []
	var selected := {}
	var spaces := {}
	var source_spaces: Dictionary = graph.get("spaces", {})
	for row in graph.get("cells", []):
		var sid: String = row.get("space", "")
		var space: Dictionary = source_spaces.get(sid, {})
		var lid: String = space.get("layer", "")
		if lid != "" and not layers.has(lid):
			continue
		var poly := world * Graph.map_points(graph, row, frames)
		if poly.size() < 3 or not area.has_point(Graph._centroid(poly)):
			continue
		var copy: Dictionary = row.duplicate(true)
		copy.erase(Tiles.GENERATED_KEY)
		copy.polygon = Array(poly).map(func(p: Vector2): return p - area.position)
		cells.append(copy)
		selected[row.id] = true
		if sid != "":
			spaces[sid] = space.duplicate(true)
	for row in cells:
		if row.has("neighbors"):
			row.neighbors = row.neighbors.filter(func(id): return selected.has(id))
	var edges := []
	for row in graph.get("edges", []):
		var dest: String = row.get("toMap", "")
		if not selected.has(row.from) or not selected.has(row.to) or dest not in ["", map_name, map_code]:
			continue
		var copy: Dictionary = row.duplicate(true)
		copy.erase("toMap")
		edges.append(copy)
	return {"cells": cells, "edges": edges, "spaces": spaces}

static func merge_spaces(clip: Dictionary, graph: Dictionary, layers: Dictionary) -> Dictionary:
	var spaces: Dictionary = graph.get("spaces", {}).duplicate()
	for sid in clip.spaces:
		var space: Dictionary = clip.spaces[sid].duplicate(true)
		var lid: String = space.get("layer", "")
		if lid != "":
			space.layer = layers[lid]
		if spaces.has(sid):
			if spaces[sid].get("layer", "") != space.get("layer", ""):
				return {"error": "目标格图空间「%s」绑定到不同图层。" % sid}
		else:
			spaces[sid] = space
	return {"spaces": spaces}

static func paste(clip: Dictionary, graph: Dictionary, spaces: Dictionary, origin: Vector2,
		world: Transform2D, frames: Dictionary) -> Dictionary:
	var out := graph.duplicate(true)
	if not spaces.is_empty():
		out.spaces = spaces
	var cells: Array = out.get_or_add("cells", [])
	var edges: Array = out.get("edges", [])
	var used := {}
	for row in cells:
		used[row.id] = true
	var ids := {}
	for row in clip.cells:
		ids[row.id] = _copy_id(row.id, used)
	var inverse := {}
	for row in clip.cells:
		var copy: Dictionary = row.duplicate(true)
		copy.id = ids[row.id]
		var sid: String = row.get("space", "")
		if not inverse.has(sid):
			var xf := world * Graph.space_transform(out, sid, frames)
			inverse[sid] = xf.affine_inverse()
		var local: Transform2D = inverse[sid]
		copy.polygon = row.polygon.map(func(offset: Vector2):
			var point := local * (origin + offset)
			return [point.x, point.y])
		if row.has("neighbors"):
			copy.neighbors = row.neighbors.map(func(id): return ids[id])
		cells.append(copy)
	used.clear()
	for row in edges:
		used[row.id] = true
	for row in clip.edges:
		var copy: Dictionary = row.duplicate(true)
		copy.id = _copy_id(row.id, used)
		copy.from = ids[row.from]
		copy.to = ids[row.to]
		edges.append(copy)
	if not edges.is_empty():
		out.edges = edges
	return {"graph": out, "ids": ids}

static func _copy_id(id: String, used: Dictionary) -> String:
	var result := id + "-copy"
	var n := 2
	while used.has(result):
		result = "%s-copy-%d" % [id, n]
		n += 1
	used[result] = true
	return result
