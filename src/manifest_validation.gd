extends RefCounted
## Manifest structural and supported-capability validation.

const SUPPORTED_TILE_LAYERS := ["terrain", "decor", "collision"]

static func validate(data: Dictionary, project_dir := "") -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	for key in ["tiles", "layers", "entities"]:
		if data.has(key) and not (data[key] is Array):
			_add(issues, "error", key, "must be an array")
	if data.get("tiles", null) is Array:
		_validate_tiles(data.tiles, project_dir, issues)
	if data.get("layers", null) is Array:
		_validate_layers(data.layers, issues)
	if data.get("entities", null) is Array:
		_validate_entities(data.entities, issues)
	if data.has("functions"):
		_validate_functions(data, issues)
	var tile_size = data.get("tileSize", 16)
	if not (tile_size is int or tile_size is float) or float(tile_size) <= 0.0:
		_add(issues, "error", "tileSize", "must be a positive number")
	return issues

## 功能/字段声明：结构 + 身份码唯一性 + 字段种类合法性。
## 码重复是**错误**：两个声明同码等于静默别名，磁盘上的引用会指向不确定的那个。
## id 重复同样错误（内容和目录按 id 分目录）。
static func _validate_functions(data: Dictionary, issues: Array[Dictionary]) -> void:
	var ManifestScript := preload("res://src/manifest.gd")
	var decl = data.get("functions", null)
	if not (decl is Dictionary or decl is Array):
		_add(issues, "error", "functions", "must be an object or an array")
		return
	var dup := ManifestScript.duplicate_codes(data)
	for d in dup:
		_add(issues, "error", "functions", "duplicate code %s (%s)" % [str(d.get("code", "")), str(d.get("scope", ""))])
	var norm: Dictionary = ManifestScript.functions(data)
	for fid in norm:
		var d: Dictionary = norm[fid]
		# 缺码不是错误：load_from 在 validate 之后调 ensure_codes 自动补发（兼容老清单）。
		# 只有「重复」是错误——上面 duplicate_codes 已报。
		var fseen := {}
		for fd in d.get("fields", []):
			if not (fd is Dictionary):
				_add(issues, "error", "functions.%s.fields" % str(fid), "entries must be objects")
				continue
			var field_id := str((fd as Dictionary).get("id", ""))
			if field_id == "" or fseen.has(field_id):
				_add(issues, "error", "functions.%s.fields" % str(fid),
					"field ids must be non-empty and unique (by id, seen: %s)" % field_id)
			fseen[field_id] = true
			var kind := str((fd as Dictionary).get("kind", ""))
			if kind != "" and kind != "input" and kind != "choice":
				_add(issues, "error", "functions.%s.fields.%s" % [str(fid), field_id],
					"unsupported field kind: " + kind)

static func _validate_tiles(tiles: Array, project_dir: String, issues: Array[Dictionary]) -> void:
	var ids := {}
	for i in tiles.size():
		var tile = tiles[i]
		var path := "tiles[%d]" % i
		if not (tile is Dictionary):
			_add(issues, "error", path, "must be an object")
			continue
		var id := str(tile.get("id", ""))
		if id == "" or ids.has(id):
			_add(issues, "error", path + ".id", "must be non-empty and unique")
		ids[id] = true
		var atlas := str(tile.get("atlas", ""))
		if atlas == "":
			_add(issues, "error", path + ".atlas", "must name an atlas")
		# T21：多图集已支持（批次 9 格式 bump）——tiles[] 每项一个图集，索引即地图格的 atlas 维度
		if project_dir != "" and atlas.contains(".."):
			_add(issues, "error", path + ".atlas", "path cannot traverse outside the project")
		if tile.has("palette"):
			if not (tile.palette is Array):
				_add(issues, "error", path + ".palette", "must be an array")
			else:
				for j in tile.palette.size():
					var entry = tile.palette[j]
					if not (entry is Dictionary):
						_add(issues, "error", "%s.palette[%d]" % [path, j], "must be an object")
					elif not (entry.get("cell", null) is Array) or entry.cell.size() < 2:
						_add(issues, "error", "%s.palette[%d].cell" % [path, j], "must contain atlas x and y")

static func _validate_layers(layers: Array, issues: Array[Dictionary]) -> void:
	var ids := {}
	for i in layers.size():
		var layer = layers[i]
		var path := "layers[%d]" % i
		if not (layer is Dictionary):
			_add(issues, "error", path, "must be an object")
			continue
		var id := str(layer.get("id", ""))
		if id == "" or ids.has(id):
			_add(issues, "error", path + ".id", "must be non-empty and unique")
		elif not SUPPORTED_TILE_LAYERS.has(id):
			_add(issues, "error", path + ".id", "unsupported map layer: " + id)
		ids[id] = true
	for required in ["terrain", "decor", "collision"]:
		if not ids.has(required):
			_add(issues, "warning", "layers", "recommended layer is missing: " + required)

static func _validate_entities(entities: Array, issues: Array[Dictionary]) -> void:
	var ids := {}
	for i in entities.size():
		var entity = entities[i]
		var path := "entities[%d]" % i
		if not (entity is Dictionary):
			_add(issues, "error", path, "must be an object")
			continue
		var id := str(entity.get("id", ""))
		if id == "" or ids.has(id):
			_add(issues, "error", path + ".id", "must be non-empty and unique")
		ids[id] = true
		if entity.has("fields") and not (entity.fields is Array):
			_add(issues, "error", path + ".fields", "must be an array")
		if entity.has("stats") and not (entity.stats is Array):
			_add(issues, "error", path + ".stats", "must be an array")
		var fields := {}
		for field in entity.get("fields", []) if entity.get("fields", []) is Array else []:
			if not (field is Dictionary):
				_add(issues, "error", path + ".fields", "entries must be objects")
				continue
			var fid := str(field.get("id", ""))
			if fid == "" or fields.has(fid):
				_add(issues, "error", path + ".fields", "field ids must be non-empty and unique")
			fields[fid] = true

static func _add(issues: Array[Dictionary], severity: String, path: String, message: String) -> void:
	issues.append({"severity": severity, "path": path, "message": message})
