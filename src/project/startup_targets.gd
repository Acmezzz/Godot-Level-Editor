extends RefCounted
## Resolves the published resources eligible to start a project.

const Maps := preload("res://src/map/map_store.gd")
const Refs := preload("res://src/project/reference_index.gd")
const Store := preload("res://src/content/content_store.gd")
const Functions := preload("res://src/content/function_decl.gd")
const FlowTarget := preload("res://src/content/flow_target.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")

static func options(manifest: Dictionary) -> Array[Dictionary]:
	return destination_options(manifest, manifest.startup)

static func destination_options(manifest: Dictionary, domains: Dictionary, working_map := {}) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if domains.get("maps") == true:
		var live: Dictionary = working_map.get("meta", {})
		var live_code: String = live.get("code", "")
		for row in Refs.map_target_options(manifest):
			if row.code != live_code:
				result.append({"name": "地图 · %s [%s]" % [row.name, row.code], "target": {"map": row.code}})
		if not live_code.is_empty():
			result.append({"name": "当前地图 · %s [%s]" % [live.name, live_code], "target": {"map": live_code}})
	result.append_array(arrival_options(manifest, domains, "", working_map))
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

static func arrival_options(manifest: Dictionary, domains: Dictionary, map_code := "", working_map := {}) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var types: Array = domains.get("arrivalPorts", [])
	if types.is_empty():
		return result
	var meta: Dictionary = working_map.get("meta", {})
	var live_code: String = meta.get("code", "")
	for row in Refs.map_target_options(manifest):
		if row.code == live_code or (map_code != "" and row.code != map_code):
			continue
		var map := Maps.read(manifest, row.name)
		_append_arrivals(result, manifest, row.name, row.code, map, types)
	if live_code != "" and (map_code == "" or map_code == live_code):
		_append_arrivals(result, manifest, meta.get("name", "") + "（当前地图）", live_code, working_map, types)
	return result

static func _append_arrivals(result: Array[Dictionary], manifest: Dictionary, name: String,
		code: String, map: Dictionary, types: Array) -> void:
	for port in RefFields.port_options(manifest, code, map.get("objects", []), types):
		result.append({"name": "入场 · %s · %s" % [name, port.t], "target": JSON.parse_string(port.v)})

static func available(manifest: Dictionary, target: Dictionary) -> bool:
	if target.is_empty():
		return true
	return destination_available(manifest, manifest.startup, target)

static func needs_content_map(startup: Dictionary, target: Variant) -> bool:
	return startup.get("contentMapContext") == "paired" and FlowTarget.kind(target) == "content"

static func content_map_available(manifest: Dictionary, code: String) -> bool:
	return code != "" and Refs.resolve_graph_map(Maps.code_index(manifest), code).status == "ok"

static func destination_available(manifest: Dictionary, domains: Dictionary, target: Variant, maps := {}) -> bool:
	if not FlowTarget.allows(domains, target):
		return false
	if target.has("view"):
		return Refs.view_ids(manifest).has(target.view)
	if target.has("map"):
		if maps.has(target.map):
			return _map_destination_available(manifest, domains, target, maps[target.map])
		var resolved := Refs.resolve_graph_map(Maps.code_index(manifest), target.map)
		if resolved.status != "ok":
			return false
		if not target.has("port"):
			return true
		return _map_destination_available(manifest, domains, target, Maps.read(manifest, resolved.key))
	var kind: String = target.function
	return is_project_destination(Store.read(manifest, kind, target.content), Functions.fn_code(manifest, kind))

static func _map_destination_available(manifest: Dictionary, domains: Dictionary, target: Dictionary, map: Dictionary) -> bool:
	if map.get("meta", {}).get("code") != target.map:
		return false
	if not target.has("port"):
		return true
	for row in map.get("objects", []):
		if row.get("code") != target.inst:
			continue
		var asset := AssetDecl.by_id(manifest, row.get("asset", ""))
		return RefFields.ports_of(asset).any(func(port):
			return port.get("id") == target.port and port.get("type", "") in domains.arrivalPorts)
	return false

static func is_project_destination(row: Dictionary, code: Variant) -> bool:
	return row.get("scope") == "project" and row.get("function") == code and row.get("fields") is Dictionary
