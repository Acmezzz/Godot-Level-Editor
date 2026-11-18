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
	var tile_size = data.get("tileSize", 16)
	if not (tile_size is int or tile_size is float) or float(tile_size) <= 0.0:
		_add(issues, "error", "tileSize", "must be a positive number")
	return issues

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
