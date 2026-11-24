extends RefCounted
## Named references assigned by the author and read by the game independently of its entry point.

const Functions := preload("res://src/content/function_decl.gd")
const Store := preload("res://src/content/content_store.gd")
const FlowTarget := preload("res://src/content/flow_target.gd")
const KEY := "projectContentSlots"

static func declarations(manifest: Dictionary) -> Dictionary:
	var rows = manifest.get(KEY, {})
	return rows if rows is Dictionary else {}

static func declaration_issues(manifest: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not manifest.get(KEY, {}) is Dictionary:
		return [_issue(KEY, "must be an object keyed by slot ID")]
	var slots := declarations(manifest)
	if slots.is_empty():
		return out
	var functions := Functions.functions(manifest)
	for id in slots:
		var path := "%s.%s" % [KEY, id]
		var slot = slots[id]
		if not id is String or id.strip_edges().is_empty() or not slot is Dictionary or not slot.get("name", id) is String:
			out.append(_issue(path, "requires a non-empty ID and an optional name"))
			continue
		var kinds = slot.get("contentTypes", [])
		if not kinds is Array or kinds.is_empty() or not kinds.all(func(kind): return kind is String and functions.has(kind)):
			out.append(_issue(path + ".contentTypes", "must list declared function IDs"))
			continue
		if slot.has("target"):
			var target = slot.target
			if FlowTarget.kind(target) != "content" or target.function not in kinds or not Store.is_valid_id(target.content):
				out.append(_issue(path + ".target", "must select a permitted {function, content}"))
	return out

static func references(manifest: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var slots := declarations(manifest)
	for id in slots:
		var slot = slots[id]
		if slot is Dictionary and FlowTarget.kind(slot.get("target")) == "content":
			out.append({"id": id, "name": slot.get("name", id), "target": slot.target,
				"domains": {"contentTypes": slot.get("contentTypes", [])}, "path": "%s.%s.target" % [KEY, id]})
	return out

static func _issue(path: String, message: String) -> Dictionary:
	return {"path": path, "severity": "error", "message": message}
