extends RefCounted
## Map-level links to named flow destinations and reusable rules in the project content library.

const FlowTarget := preload("res://src/content/flow_target.gd")
const OUTPUTS := "flowOutputs"
const CONTENT := "contentSlots"
const SECTIONS := {OUTPUTS: "mapOutputs", CONTENT: "mapContentSlots"}

static func declarations(manifest: Dictionary, section: String) -> Dictionary:
	var value = manifest.get(SECTIONS[section], {})
	return value if value is Dictionary else {}

static func declaration_issues(manifest: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for section in SECTIONS:
		var key: String = SECTIONS[section]
		var rows = manifest.get(key, {})
		if not rows is Dictionary:
			result.append({"path": key, "severity": "error", "message": "must be an object keyed by slot ID"})
			continue
		for id in rows:
			var decl = rows[id]
			var path := "%s.%s" % [key, id]
			if not id is String or id.strip_edges() == "" or not decl is Dictionary or not decl.get("name", id) is String \
					or not FlowTarget.declaration_valid(decl):
				result.append({"path": path, "severity": "error",
					"message": "requires a non-empty ID, optional name and at least one destination domain"})
			elif section == CONTENT and (decl.get("maps", false) or decl.get("screens", false) or not decl.get("arrivalPorts", []).is_empty()):
				result.append({"path": path, "severity": "error", "message": "content slots only accept contentTypes"})
			elif decl.has("contentMapContext") and (decl.contentMapContext not in ["independent", "inherit"] \
					or decl.get("contentTypes", []).is_empty()):
				result.append({"path": path + ".contentMapContext", "severity": "error",
					"message": "must be independent or inherit on a slot that accepts content"})
			elif decl.has("viewMapContext") and (decl.viewMapContext != "inherit" or decl.get("screens") != true):
				result.append({"path": path + ".viewMapContext", "severity": "error",
					"message": "inherit requires an output that accepts screens"})
	return result

static func scoped_content(manifest: Dictionary, data: Dictionary) -> Array[Dictionary]:
	return references(manifest, data).filter(func(ref):
		return ref.decl.get("contentMapContext") == "inherit" and FlowTarget.kind(ref.value) == "content" \
			and FlowTarget.allows(ref.decl, ref.value))

static func targets(data: Dictionary, section: String) -> Dictionary:
	var values = data.get("meta", {}).get(section, {})
	return values if values is Dictionary else {}

static func references(manifest: Dictionary, data: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for section in SECTIONS:
		var decls := declarations(manifest, section)
		var values := targets(data, section)
		var label := "地图出口" if section == OUTPUTS else "地图内容"
		for id in values:
			out.append({"kind": "flow_target", "field": id, "code": label + " · " + id,
				"path": "meta.%s.%s" % [section, id], "value": values[id],
				"decl": decls.get(id, {}), "map_section": section})
	return out
