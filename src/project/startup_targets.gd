extends RefCounted
## Resolves the published resources eligible to start a project.

const Maps := preload("res://src/map/map_store.gd")
const Refs := preload("res://src/project/reference_index.gd")
const Store := preload("res://src/content/content_store.gd")
const Functions := preload("res://src/content/function_decl.gd")

static func options(manifest: Dictionary) -> Array[Dictionary]:
	var startup: Dictionary = manifest.startup
	var result: Array[Dictionary] = []
	if startup.get("maps", false):
		for row in Refs.map_target_options(manifest):
			result.append({"name": "地图 · %s [%s]" % [row.name, row.code], "target": {"map": row.code}})
	if startup.get("screens", false):
		for id in Refs.view_ids(manifest):
			result.append({"name": "屏幕 · " + id, "target": {"view": id}})
	for kind in startup.get("contentTypes", []):
		var declaration := Functions.function_decl(manifest, kind)
		for cid in Store.list_ids(manifest, kind):
			var row := Store.read(manifest, kind, cid)
			if _matches(row, declaration):
				result.append({"name": "%s · %s [%s]" % [declaration.get("name", kind), row.get("name", cid), cid],
					"target": {"function": kind, "content": cid}})
	return result

static func available(manifest: Dictionary, target: Dictionary) -> bool:
	if target.is_empty():
		return true
	var startup: Dictionary = manifest.startup
	if target.has("view"):
		return startup.get("screens", false) and Refs.view_ids(manifest).has(target.view)
	if target.has("map"):
		return startup.get("maps", false) and Refs.resolve_graph_map(Maps.code_index(manifest), target.map).status == "ok"
	var kind: String = target.function
	return kind in startup.get("contentTypes", []) and _matches(
		Store.read(manifest, kind, target.content), Functions.function_decl(manifest, kind))

static func _matches(row: Dictionary, declaration: Dictionary) -> bool:
	return row.get("scope") == "project" and row.get("function") == declaration.get("code") and row.get("fields") is Dictionary
