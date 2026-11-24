extends RefCounted
## Resolves the published resources eligible to start a project.

const Maps := preload("res://src/map/map_store.gd")
const Refs := preload("res://src/project/reference_index.gd")
const Store := preload("res://src/content/content_store.gd")
const Functions := preload("res://src/content/function_decl.gd")
const FlowTarget := preload("res://src/content/flow_target.gd")
const RefFields := preload("res://src/content/ref_fields.gd")

static func options(manifest: Dictionary) -> Array[Dictionary]:
	return destination_options(manifest, manifest.startup)

static func destination_options(manifest: Dictionary, domains: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if domains.get("maps") == true:
		for row in Refs.map_target_options(manifest):
			result.append({"name": "地图 · %s [%s]" % [row.name, row.code], "target": {"map": row.code}})
	result.append_array(arrival_options(manifest, domains))
	if domains.get("screens") == true:
		for id in Refs.view_ids(manifest):
			result.append({"name": "屏幕 · " + id, "target": {"view": id}})
	for kind in domains.get("contentTypes", []):
		var declaration := Functions.function_decl(manifest, kind)
		for cid in Store.list_ids(manifest, kind):
			var row := Store.read(manifest, kind, cid)
			if is_project_destination(row, declaration.get("code")):
				result.append({"name": "%s · %s [%s]" % [declaration.get("name", kind), row.get("name", cid), cid],
					"target": {"function": kind, "content": cid}})
	return result

static func arrival_options(manifest: Dictionary, domains: Dictionary, map_code := "") -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var types: Array = domains.get("arrivalPorts", [])
	if types.is_empty():
		return result
	for row in Refs.map_target_options(manifest):
		if map_code != "" and row.code != map_code:
			continue
		var map := Maps.read(manifest, row.name)
		for port in RefFields.port_options(manifest, row.code, map.get("objects", []), types):
			result.append({"name": "入场 · %s · %s" % [row.name, port.t], "target": JSON.parse_string(port.v)})
	return result

static func available(manifest: Dictionary, target: Dictionary) -> bool:
	if target.is_empty():
		return true
	return destination_available(manifest, manifest.startup, target)

static func destination_available(manifest: Dictionary, domains: Dictionary, target: Variant) -> bool:
	if not FlowTarget.allows(domains, target):
		return false
	if target.has("view"):
		return Refs.view_ids(manifest).has(target.view)
	if target.has("map"):
		var resolved := Refs.resolve_graph_map(Maps.code_index(manifest), target.map)
		if resolved.status != "ok":
			return false
		if not target.has("port"):
			return true
		var map := Maps.read(manifest, resolved.key)
		return RefFields.port_options(manifest, target.map, map.get("objects", []), domains.arrivalPorts).any(
			func(port): return JSON.parse_string(port.v) == target)
	var kind: String = target.function
	return is_project_destination(Store.read(manifest, kind, target.content), Functions.fn_code(manifest, kind))

static func is_project_destination(row: Dictionary, code: Variant) -> bool:
	return row.get("scope") == "project" and row.get("function") == code and row.get("fields") is Dictionary
