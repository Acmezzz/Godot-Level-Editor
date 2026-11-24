extends RefCounted
## Shared event bindings; the game decides when the declared trigger fires.

const KEY := "eventLayers"
const Triggers := preload("res://src/content/trigger_decl.gd")
const FlowTarget := preload("res://src/content/flow_target.gd")

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
