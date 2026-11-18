extends RefCounted
## Structural validation for map JSON, independent of scene-tree state.

static func validate(data: Dictionary, manifest := {}) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	for key in ["terrain", "decor", "collision", "entities"]:
		if data.has(key) and not (data[key] is Array):
			_add(issues, "error", key, "must be an array")
	var meta = data.get("meta", {})
	if not (meta is Dictionary):
		_add(issues, "error", "meta", "must be an object")
	else:
		for key in ["w", "h"]:
			if meta.has(key) and not (meta[key] is int or meta[key] is float):
				_add(issues, "error", "meta." + key, "must be a number")
	var spawn = data.get("spawn", [2, 2])
	if not (spawn is Array) or spawn.size() < 2 or not _is_number_pair(spawn):
		_add(issues, "error", "spawn", "must contain two numeric coordinates")
	if data.get("entities", null) is Array:
		_validate_entities(data.entities, manifest, issues)
	for key in ["terrain", "decor"]:
		if data.get(key, null) is Array:
			for i in data[key].size():
				var cell = data[key][i]
				if not (cell is Array) or cell.size() < 4 or not _is_number_prefix(cell, 4):
					_add(issues, "error", "%s[%d]" % [key, i], "must contain x, y, atlas_x, atlas_y")
	if data.get("collision", null) is Array:
		for i in data.collision.size():
			var cell = data.collision[i]
			if not (cell is Array) or cell.size() < 2 or not _is_number_prefix(cell, 2):
				_add(issues, "error", "collision[%d]" % i, "must contain x and y")
	return issues

static func _validate_entities(entities: Array, manifest: Dictionary, issues: Array[Dictionary]) -> void:
	var known := {}
	for definition in manifest.get("entities", []):
		if definition is Dictionary:
			known[str(definition.get("id", ""))] = definition
	var ids := {}
	for i in entities.size():
		var entity = entities[i]
		var path := "entities[%d]" % i
		if not (entity is Dictionary):
			_add(issues, "error", path, "must be an object")
			continue
		var id := str(entity.get("id", ""))
		if id != "" and ids.has(id):
			_add(issues, "error", path + ".id", "duplicate entity id: " + id)
		if id != "":
			ids[id] = true
		for key in ["x", "y"]:
			if entity.has(key) and not (entity[key] is int or entity[key] is float):
				_add(issues, "error", path + "." + key, "must be numeric")
		if not entity.has("scene") or str(entity.get("scene", "")) == "":
			_add(issues, "error", path + ".scene", "must name an entity type")
		elif not known.is_empty() and not known.has(str(entity.scene)):
			_add(issues, "warning", path + ".scene", "entity type is not in the current manifest")
		if entity.has("props") and not (entity.props is Dictionary):
			_add(issues, "error", path + ".props", "must be an object")
		if entity.has("functions"):
			_validate_functions(entity.get("functions"), path + ".functions", manifest, issues)

## v2 §5.3：实例 functions 数组结构校验——[{fn, content, name, order, parallel}]。
## 空 content = 还没填（内容编辑器里显示「未填」），不是错误；未知 fn 只警告，
## 因为项目侧可以先放数据再补实现（清单声明是开发契约，不是硬白名单）。
static func _validate_functions(raw, path: String, manifest: Dictionary, issues: Array[Dictionary]) -> void:
	if not (raw is Array):
		_add(issues, "error", path, "must be an array")
		return
	var declared := {}
	var decl = manifest.get("functions", null)
	if decl is Dictionary:
		for key in (decl as Dictionary):
			declared[str(key)] = true
	elif decl is Array:
		for item in (decl as Array):
			if item is Dictionary:
				declared[str((item as Dictionary).get("id", ""))] = true
	for i in (raw as Array).size():
		var item = raw[i]
		var p := "%s[%d]" % [path, i]
		if not (item is Dictionary):
			_add(issues, "error", p, "must be an object")
			continue
		var fn_id := str((item as Dictionary).get("fn", ""))
		if fn_id == "":
			_add(issues, "error", p + ".fn", "must name a function")
		elif not declared.is_empty() and not declared.has(fn_id):
			_add(issues, "warning", p + ".fn", "function is not declared in the manifest: " + fn_id)
		for key in ["content", "name"]:
			if (item as Dictionary).has(key) and not ((item as Dictionary)[key] is String):
				_add(issues, "error", p + "." + key, "must be a string")
		if (item as Dictionary).has("order") and not ((item as Dictionary).order is int or (item as Dictionary).order is float):
			_add(issues, "error", p + ".order", "must be numeric")
		if (item as Dictionary).has("parallel") and not ((item as Dictionary).parallel is bool):
			_add(issues, "error", p + ".parallel", "must be a boolean")

static func _is_number_pair(values: Array) -> bool:
	return _is_number_prefix(values, 2)

static func _is_number_prefix(values: Array, count: int) -> bool:
	if values.size() < count:
		return false
	for i in count:
		if not (values[i] is int or values[i] is float):
			return false
	return true

static func _add(issues: Array[Dictionary], severity: String, path: String, message: String) -> void:
	issues.append({"severity": severity, "path": path, "message": message})
