extends RefCounted
## Named flow outlets shared by all maps in a game; the game decides when to follow each target.

const FlowTarget := preload("res://src/content/flow_target.gd")
const KEY := "flowOutputs"

static func declarations(manifest: Dictionary) -> Dictionary:
	return manifest.get("mapOutputs", {})

static func declaration_issues(manifest: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var outputs = manifest.get("mapOutputs", {})
	if not outputs is Dictionary:
		return [{"path": "mapOutputs", "severity": "error", "message": "must be an object keyed by outlet ID"}]
	for id in outputs:
		var decl = outputs[id]
		if id.strip_edges() == "" or not decl is Dictionary or not decl.get("name", id) is String \
				or not FlowTarget.declaration_valid(decl):
			result.append({"path": "mapOutputs." + id, "severity": "error",
				"message": "requires a non-empty ID, optional name and at least one destination domain"})
	return result

static func targets(data: Dictionary) -> Dictionary:
	var values = data.get("meta", {}).get(KEY, {})
	return values if values is Dictionary else {}

static func references(manifest: Dictionary, data: Dictionary) -> Array[Dictionary]:
	var decls := declarations(manifest)
	var values := targets(data)
	var out: Array[Dictionary] = []
	for id in values:
		out.append({"kind": "flow_target", "field": id, "code": "地图出口 · " + id,
			"path": "meta." + KEY + "." + id, "value": values[id], "decl": decls.get(id, {}), "map_outlet": true})
	return out
