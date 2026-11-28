extends RefCounted
## Mutates layer declarations and their references in a map document.

const View := preload("res://src/map/map_view_data.gd")
const Graph := preload("res://src/map/cell_graph.gd")

static func move(layers: Array, from: int, to: int, objects := []) -> void:
	if from == to:
		return
	if from == 0 or to == 0:
		for row in objects:
			if row.get("layer", "") == "":
				row["layer"] = View.object_layer(row, layers)
	layers.insert(to, layers.pop_at(from))

static func remove(map: Dictionary, index: int) -> void:
	var layers: Array = map.meta.layers
	var layer: Dictionary = layers[index]
	Graph.detach_layer(Graph.graph_of(map.meta), layer.id, View.layer_transform_of(layer))
	map["objects"] = map.get("objects", []).filter(func(row): return View.object_layer(row, layers) != layer.id)
	map.get("tiles", {}).erase(layer.id)
	layers.remove_at(index)
