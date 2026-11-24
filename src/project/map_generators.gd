extends RefCounted
## Editor contract for parameters sent to game-owned map generators.

const Functions := preload("res://src/content/function_decl.gd")
const Store := preload("res://src/content/content_store.gd")

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
		if row.has("contentType") and (not row.contentType is String or row.has("fields")
				or Functions.function_decl(manifest, row.contentType).is_empty()):
			out.append(_issue(path + ".contentType", "requires a declared function ID in place of fields"))
			continue
		var fields = _parameter_fields(manifest, row)
		if fields == null:
			out.append(_issue(path + ".parameterFields", "requires contentType and a list of unique IDs declared by that function"))
			continue
		_check_fields(fields, path, out, 0)
	return out

static func fields_for(manifest: Dictionary, generator_id: String) -> Array:
	return _parameter_fields(manifest, manifest.mapGenerators[generator_id])

static func _parameter_fields(manifest: Dictionary, generator: Dictionary) -> Variant:
	if not generator.has("contentType"):
		return null if generator.has("parameterFields") else generator.get("fields", [])
	var fields := Functions.function_fields(manifest, generator.contentType)
	if not generator.has("parameterFields"):
		return fields
	var ids = generator.parameterFields
	if not ids is Array:
		return null
	var by_id := {}
	for field in fields:
		if field is Dictionary and field.get("id") is String:
			by_id[field.id] = field
	var selected := []
	for id in ids:
		if not id is String or not by_id.has(id):
			return null
		selected.append(by_id[id])
		by_id.erase(id)
	return selected

## Read published presets and translate their execution keys into request parameter IDs.
static func presets(manifest: Dictionary, generator_id: String) -> Array[Dictionary]:
	var kind: String = manifest.mapGenerators[generator_id].get("contentType", "")
	var out: Array[Dictionary] = []
	if kind.is_empty():
		return out
	var fn := Functions.function_decl(manifest, kind)
	var fields := fields_for(manifest, generator_id)
	var rows := Store.read_all(manifest, kind)
	for cid in rows:
		var row: Dictionary = rows[cid]
		if row.get("scope") != "project" or row.get("function") != fn.code or not row.get("fields") is Dictionary:
			continue
		var params := _parameter_ids(fields, row.fields, true)
		if fields.all(func(field): return valid_value(field, params[field.id])):
			out.append({"id": cid, "name": row.get("name", cid), "parameters": params})
	return out

static func _parameter_ids(fields: Array, values: Dictionary, fill_defaults: bool) -> Dictionary:
	var out := {}
	for field in fields:
		var key: String = field.get("code", field.id)
		if key.is_empty():
			key = field.id
		if not values.has(key) and not fill_defaults:
			continue
		var value = values.get(key, default_value(field))
		if field.get("type") == "array" and field.get("of") == "record" and value is Array:
			value = value.map(func(row): return _parameter_ids(field.fields, row, false) if row is Dictionary else row)
		out[field.id] = value
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
