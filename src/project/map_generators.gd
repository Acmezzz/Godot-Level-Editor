extends RefCounted
## Optional game-owned map generators. Parameters are independent of the current map.

const TYPES := ["int", "float", "bool", "string", "asset_ref", "array"]
const CHOICE_SOURCES := ["map", "view:", "audio:"]

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
		_check_fields(row.get("fields", []), path, out, 0)
	return out

static func _check_fields(fields: Array, path: String, out: Array[Dictionary], depth: int) -> void:
	var ids := {}
	for i in fields.size():
		var field = fields[i]
		var at := "%s.fields[%d]" % [path, i]
		if not field is Dictionary or not field.get("id") is String or field.id.strip_edges().is_empty() \
				or not field.get("name", field.id) is String or ids.has(field.id) or not _shape(field, depth) \
				or not valid_value(field, default_value(field)):
			out.append(_issue(at, "requires a unique field ID and a supported generator parameter with a valid default"))
			continue
		ids[field.id] = true
		if field.get("type") == "array" and field.get("of") == "record":
			_check_fields(field.fields, at, out, depth + 1)

static func _shape(field: Dictionary, depth: int) -> bool:
	if field.get("kind") == "choice":
		var source: String = str(field.get("source", ""))
		return field.get("options") is Array or source in CHOICE_SOURCES \
			or source.begins_with("content:") or source.begins_with("asset:") or source.begins_with("entity:")
	var type: String = str(field.get("type", ""))
	if field.get("kind") != "input" or type not in TYPES:
		return false
	if type != "array":
		return true
	if field.get("of") == "record":
		return depth < 4 and field.get("fields") is Array and not field.fields.is_empty()
	return _shape(_array_element(field), depth + 1) if field.get("of") != "array" else false

static func valid_value(field: Dictionary, value: Variant) -> bool:
	if field.get("kind") == "choice":
		if field.get("multiple") == true:
			return value is Array and value.all(func(item): return item is String)
		return value is String
	match field.get("type"):
		"bool": return value is bool
		"string", "asset_ref": return value is String
		"array":
			var element := _array_element(field)
			return value is Array and value.all(func(item): return valid_value(element, item))
		"record":
			return value is Dictionary and field.fields.all(func(sub):
				return sub is Dictionary and valid_value(sub, value.get(sub.get("id", ""), default_value(sub))))
		"int", "float":
			var type: String = field.type
			var lo = field.get("min", -999999)
			var hi = field.get("max", 999999)
			return _number(lo, type) and _number(hi, type) and _number(value, type) \
				and lo <= value and value <= hi and absf(lo) <= 1e9 and absf(hi) <= 1e9
	return false

static func _array_element(field: Dictionary) -> Dictionary:
	# The shared field helper depends on the manifest through the reference index.
	return load("res://src/content/ref_fields.gd").array_element_decl(field)

static func _number(value: Variant, type: String) -> bool:
	return (value is int or value is float) and is_finite(float(value)) \
		and (type != "int" or value == floorf(value))

static func default_value(field: Dictionary) -> Variant:
	if field.has("default"):
		return field.default
	if field.get("kind") == "choice":
		return [] if field.get("multiple") == true else ""
	match field.get("type"):
		"bool": return false
		"string", "asset_ref": return ""
		"array": return []
		"record": return {}
		_:
			var lo = field.get("min", -999999)
			var hi = field.get("max", 999999)
			if _number(lo, "float") and _number(hi, "float") and lo <= hi:
				return clampf(0, lo, hi)
			return 0

static func _issue(path: String, message: String) -> Dictionary:
	return {"severity": "warning", "path": path, "message": message}
