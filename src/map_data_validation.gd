extends RefCounted
## 地图 JSON 结构校验，与场景树状态无关（纯字典操作，读图必经之路）。

const MapFormat := preload("res://src/map_format.gd")

static func validate(data: Dictionary, manifest := {}) -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	# version：缺失/非数字 = 错误（结构契约没有锚点）；高于当前格式 = 错误（打不开新图）；
	# 低于当前 = 警告（upgrade() 只抬版本号不迁移，结构问题由下面各项各自报出）
	if not data.has("version") or not (data["version"] is int or data["version"] is float):
		_add(issues, "error", "version", "must be a number")
	else:
		var ver := int(data["version"])
		if ver > MapFormat.VERSION:
			_add(issues, "error", "version",
				"map format %d is newer than this editor supports (%d)" % [ver, MapFormat.VERSION])
		elif ver < MapFormat.VERSION:
			_add(issues, "warning", "version", "older map format %d (upgraded in memory)" % ver)
	for key in ["collision", "entities"]:
		if data.has(key) and not (data[key] is Array):
			_add(issues, "error", key, "must be an array")
	var meta = data.get("meta", {})
	var layer_ids := {}
	if not (meta is Dictionary):
		_add(issues, "error", "meta", "must be an object")
	else:
		for key in ["w", "h"]:
			if meta.has(key) and not (meta[key] is int or meta[key] is float):
				_add(issues, "error", "meta." + key, "must be a number")
		layer_ids = _validate_layers(meta, issues)
	var tiles = data.get("tiles", null)
	if tiles != null and not (tiles is Dictionary):
		_add(issues, "error", "tiles", "must be an object keyed by layer id")
	elif tiles is Dictionary and not layer_ids.is_empty():
		for lid in tiles.keys():
			if not layer_ids.has(str(lid)):
				_add(issues, "error", "tiles." + str(lid), "unknown layer id")
			elif not (tiles[lid] is Array):
				_add(issues, "error", "tiles." + str(lid), "must be an array")
			else:
				for j in (tiles[lid] as Array).size():
					var cell = (tiles[lid] as Array)[j]
					if not (cell is Array) or cell.size() != 5 or not _is_number_prefix(cell, 5):
						_add(issues, "error", "tiles.%s[%d]" % [str(lid), j],
							"must contain exactly x, y, atlas, atlas_x, atlas_y")
					elif int(cell[2]) < 0 or int(cell[3]) < 0 or int(cell[4]) < 0:
						_add(issues, "error", "tiles.%s[%d]" % [str(lid), j],
							"atlas index and atlas coords must be >= 0")
	var spawn = data.get("spawn", [2, 2])
	if not (spawn is Array) or spawn.size() != 2 or not _is_number_pair(spawn):
		_add(issues, "error", "spawn", "must contain two numeric coordinates")
	if data.get("entities", null) is Array:
		_validate_entities(data.entities, manifest, layer_ids, issues)
	if data.get("collision", null) is Array:
		for i in data.collision.size():
			var cell = data.collision[i]
			if not (cell is Array) or cell.size() < 2 or cell.size() > 4 or not _is_number_prefix(cell, 2):
				_add(issues, "error", "collision[%d]" % i, "must contain x, y (and optional type/shape)")
	return issues

## meta.layers 用户层栈校验：非空数组、条目 id 非空且唯一、name 非空。
## 返回合法层 id 集（供 tiles 键与 entities.layer 归属校验）；栈本身不合格时返回空集，
## 关联检查（tiles 键 ⊆ 层集、entity.layer ∈ 层集）随之跳过，避免连坐噪音。
static func _validate_layers(meta: Dictionary, issues: Array[Dictionary]) -> Dictionary:
	var ids := {}
	if not meta.has("layers") or not (meta.layers is Array) or (meta.layers as Array).is_empty():
		_add(issues, "error", "meta.layers", "must be a non-empty array of layer objects")
		return ids
	for i in (meta.layers as Array).size():
		var ldef = meta.layers[i]
		var p := "meta.layers[%d]" % i
		if not (ldef is Dictionary):
			_add(issues, "error", p, "must be an object")
			continue
		var lid := str(ldef.get("id", ""))
		if lid == "":
			_add(issues, "error", p + ".id", "must be a non-empty layer id")
		elif ids.has(lid):
			_add(issues, "error", p + ".id", "duplicate layer id: " + lid)
		else:
			ids[lid] = true
		if str(ldef.get("name", "")) == "":
			_add(issues, "error", p + ".name", "must be a non-empty layer name")
		if ldef.has("visible") and not (ldef.visible is bool):
			_add(issues, "error", p + ".visible", "must be a boolean")
	return ids

static func _validate_entities(entities: Array, manifest: Dictionary, layer_ids: Dictionary, issues: Array[Dictionary]) -> void:
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
		var code := str(entity.get("code", ""))
		if code != "" and ids.has(code):
			_add(issues, "error", path + ".code", "duplicate entity code: " + code)
		if code != "":
			ids[code] = true
		for key in ["x", "y"]:
			if entity.has(key) and not (entity[key] is int or entity[key] is float):
				_add(issues, "error", path + "." + key, "must be numeric")
		if not entity.has("scene") or str(entity.get("scene", "")) == "":
			_add(issues, "error", path + ".scene", "must name an entity type")
		elif not known.is_empty() and not known.has(str(entity.scene)):
			_add(issues, "warning", path + ".scene", "entity type is not in the current manifest")
		if entity.has("props") and not (entity.props is Dictionary):
			_add(issues, "error", path + ".props", "must be an object")
		if entity.has("layer") and not layer_ids.is_empty() and not layer_ids.has(str(entity.layer)):
			_add(issues, "error", path + ".layer", "unknown layer id: " + str(entity.layer))
		if entity.has("functions"):
			_validate_functions(entity.get("functions"), path + ".functions", manifest, issues)

## 实例 functions 数组结构校验——[{fn, content, name, order, parallel}]。
## 空 content = 还没绑定内容（内容编辑器里会按需生成），不是错误；未知码只警告，
## 因为项目侧可以先放数据再补声明（清单声明是开发契约，不是硬白名单）。
## fn 在磁盘上一律是功能的执行码，按码查声明，无人类名回退。
static func _validate_functions(raw, path: String, manifest: Dictionary, issues: Array[Dictionary]) -> void:
	if not (raw is Array):
		_add(issues, "error", path, "must be an array")
		return
	var has_manifest := not manifest.is_empty()
	var FunctionDecls := preload("res://src/content/function_decl.gd")
	for i in (raw as Array).size():
		var item = raw[i]
		var p := "%s[%d]" % [path, i]
		if not (item is Dictionary):
			_add(issues, "error", p, "must be an object")
			continue
		var fn_raw := str((item as Dictionary).get("fn", ""))
		if fn_raw == "":
			_add(issues, "error", p + ".fn", "must name a function")
		elif has_manifest and FunctionDecls.fn_id_of(manifest, fn_raw) == "":
			_add(issues, "warning", p + ".fn",
				"function code is not declared in the manifest: " + fn_raw)
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
