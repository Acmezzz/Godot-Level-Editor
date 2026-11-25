extends RefCounted
## Shared drawing documents and event bindings, keyed by stable layer IDs.

const KEY := "eventLayers"
const Triggers := preload("res://src/content/trigger_decl.gd")
const FlowTarget := preload("res://src/content/flow_target.gd")

static func drawing_codes(manifest: Dictionary) -> Array[String]:
	var codes: Array[String] = []
	for layer in manifest.get(KEY, {}).values():
		var code: String = layer.get("drawingMap", "")
		if code != "" and not codes.has(code):
			codes.append(code)
	return codes

static func applies_to(layer: Dictionary, map_code: String) -> bool:
	return map_code != "" and (not layer.has("maps") or map_code in layer.maps)

## Bottom to top, with the empty ID marking the base map at order zero.
static func drawing_stack(layers: Dictionary) -> Array[String]:
	var stack: Array[String] = []
	stack.assign(layers.keys())
	stack.append("")
	stack.sort_custom(func(a: String, b: String) -> bool:
		var first := 0 if a == "" else int(layers[a].get("drawOrder", 1))
		var second := 0 if b == "" else int(layers[b].get("drawOrder", 1))
		return a < b if first == second else first < second)
	return stack

static func drawings_for_map(manifest: Dictionary, map_code: String) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var layers: Dictionary = manifest.get(KEY, {})
	if map_code == "" or map_code in drawing_codes(manifest):
		return rows
	for id in drawing_stack(layers):
		if id == "":
			continue
		var layer: Dictionary = layers[id]
		var code: String = layer.get("drawingMap", "")
		if code != "" and applies_to(layer, map_code):
			rows.append({"layer": id, "map": code, "drawOrder": int(layer.get("drawOrder", 1))})
	return rows

static func types(manifest: Dictionary) -> Dictionary:
	var result := {}
	for trigger in Triggers.triggers(manifest).values():
		if trigger.get("eventTargets") is Dictionary and FlowTarget.declaration_valid(trigger.eventTargets):
			result[trigger.code] = trigger
	return result

static func issues(manifest: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var layers = manifest.get(KEY, {})
	if not layers is Dictionary:
		return [_issue(KEY, "must be an object keyed by layer ID")]
	for id in layers:
		var path := KEY + "." + str(id)
		var row = layers[id]
		if str(id).strip_edges() == "" or not row is Dictionary or not row.get("events", {}) is Dictionary:
			out.append(_issue(path, "requires a stable layer ID and an events object"))
			continue
		if row.has("drawingMap") and (not row.drawingMap is String or row.drawingMap.is_empty()):
			out.append(_issue(path + ".drawingMap", "must be a map code"))
		var order = row.get("drawOrder", 1)
		if not (order is int or (order is float and is_finite(order) and order == floor(order))) or order == 0:
			out.append(_issue(path + ".drawOrder", "must be a nonzero integer; zero is the base map"))
		var maps = row.get("maps", [])
		var seen := {}
		if not maps is Array or not maps.all(func(code):
			if not code is String or code.is_empty() or seen.has(code):
				return false
			seen[code] = true
			return true):
			out.append(_issue(path + ".maps", "must contain unique map codes"))
		for code in row.get("events", {}):
			if str(code).strip_edges() == "" or FlowTarget.kind(row.events[code]) == "":
				out.append(_issue(path + ".events." + str(code), "requires a trigger code and a destination ID"))
	return out

static func _issue(path: String, message: String) -> Dictionary:
	return {"severity": "error", "path": path, "message": message}

static func references(manifest: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var declarations := types(manifest)
	for id in manifest.get(KEY, {}):
		var layer: Dictionary = manifest[KEY][id]
		for code in layer.get("events", {}):
			var trigger: Dictionary = declarations.get(code, {})
			out.append({"layer": id, "code": code, "target": layer.events[code],
				"name": "%s · %s" % [layer.get("name", id), trigger.get("name", code)],
				"domains": trigger.get("eventTargets", {})})
	return out
