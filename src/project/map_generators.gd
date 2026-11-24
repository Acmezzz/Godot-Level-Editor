extends RefCounted
## Optional game-owned map generators. Parameters use a small subset of the field schema.

const TYPES := ["int", "float", "bool", "string"]

static func issues(manifest: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not manifest.has("mapGenerators"):
		return out
	var pool = manifest.mapGenerators
	if not pool is Dictionary:
		return [_issue("mapGenerators", "must be an object keyed by generator ID")]
	for id in pool:
		var path := "mapGenerators." + str(id)
		var row = pool[id]
		if not id is String or id.strip_edges().is_empty() or not row is Dictionary \
				or not row.get("name", id) is String or not row.get("fields", []) is Array:
			out.append(_issue(path, "requires a non-empty ID, optional name and fields array"))
			continue
		var ids := {}
		var fields: Array = row.get("fields", [])
		for i in fields.size():
			var field = fields[i]
			if not field is Dictionary or not valid_field(field) or ids.has(field.id):
				out.append(_issue("%s.fields[%d]" % [path, i], "requires a unique field ID and a valid input type, default and range"))
				continue
			ids[field.id] = true
	return out

static func valid_field(field: Dictionary) -> bool:
	var id = field.get("id")
	var type = field.get("type", "")
	if not id is String or id.strip_edges().is_empty() or not field.get("name", id) is String \
			or field.get("kind") != "input" or not type in TYPES:
		return false
	var value = default_value(field)
	match type:
		"bool": return value is bool
		"string": return value is String
		_:
			var lo = field.get("min", -999999)
			var hi = field.get("max", 999999)
			return _number(lo, type) and _number(hi, type) and _number(value, type) \
				and lo <= value and value <= hi and absf(lo) <= 1e9 and absf(hi) <= 1e9

static func _number(value: Variant, type: String) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and (type != "int" or value == floorf(value))

static func default_value(field: Dictionary) -> Variant:
	if field.has("default"):
		return field.default
	match field.get("type"):
		"bool": return false
		"string": return ""
		_:
			var lo = field.get("min", -999999)
			var hi = field.get("max", 999999)
			if _number(lo, "float") and _number(hi, "float") and lo <= hi:
				return clampf(0, lo, hi)
			return 0

static func _issue(path: String, message: String) -> Dictionary:
	return {"severity": "warning", "path": path, "message": message}
