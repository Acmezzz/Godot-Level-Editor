extends RefCounted
## 清单结构与能力校验：tiles/layers/entities/functions/conditions 的类型与 id/码唯一性、
## 图层限定 terrain/decor/collision、字段 kind 必须显式 input/choice、
## 挂载功能必须已声明、功能引用的条件必须已声明、功能与条件的字段码同空间唯一。

const SUPPORTED_TILE_LAYERS := ["terrain", "decor", "collision"]
const FunctionDecls := preload("res://src/content/function_decl.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")

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
		_validate_entities(data, issues)
	if data.has("functions"):
		_validate_functions(data, issues)
	if data.has("conditions"):
		_validate_conditions(data, issues)
	var tile_size = data.get("tileSize", 16)
	if not (tile_size is int or tile_size is float) or float(tile_size) <= 0.0:
		_add(issues, "error", "tileSize", "must be a positive number")
	return issues

## 功能/字段声明：结构 + 身份码唯一性 + 字段种类合法性。
## 码重复是**错误**：两个声明同码等于静默别名，磁盘上的引用会指向不确定的那个。
## 功能 id 重复同样是**错误**（内容目录按功能 id 分目录；数组写法不查会静默后者覆盖前者）。
static func _validate_functions(data: Dictionary, issues: Array[Dictionary]) -> void:
	var decl = data.get("functions", null)
	if not (decl is Dictionary or decl is Array):
		_add(issues, "error", "functions", "must be an object or an array")
		return
	# 功能 id 查重：dict 写法键天然唯一，array 写法可能重复——重复/空 id 都报错
	# （内容目录按功能 id 分目录，不查的话归一化会静默后者覆盖前者）
	var decl_ids := {}
	if decl is Array:
		for d0 in decl:
			if not (d0 is Dictionary):
				continue
			var fid0 := str((d0 as Dictionary).get("id", ""))
			if fid0 == "" or decl_ids.has(fid0):
				_add(issues, "error", "functions",
					"function ids must be non-empty and unique (array form, seen: %s)" % fid0)
			decl_ids[fid0] = true
	elif decl is Dictionary:
		for k0 in (decl as Dictionary).keys():
			if str(k0) == "":
				_add(issues, "error", "functions", "function ids must be non-empty (dict form)")
	var dup := FunctionDecls.duplicate_codes(data)
	for d in dup:
		_add(issues, "error", "functions", "duplicate code %s (%s)" % [str(d.get("code", "")), str(d.get("scope", ""))])
	var norm: Dictionary = FunctionDecls.functions(data)
	for fid in norm:
		var d: Dictionary = norm[fid]
 # 缺码不是错误：load_from 在 validate 之后调 ensure_codes 补发（新声明补码的正常路径）。
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
 # 零兼容：kind/type 是声明契约的必需键，缺或非法直接报错（UI 侧对应只读兜底）
			if kind != "input" and kind != "choice":
				_add(issues, "error", "functions.%s.fields.%s" % [str(fid), field_id],
					"field kind must be \"input\" or \"choice\"")
			elif kind == "input":
				var typ := str((fd as Dictionary).get("type", ""))
				if not ["string", "int", "float", "bool"].has(typ):
					_add(issues, "error", "functions.%s.fields.%s" % [str(fid), field_id],
						"input type must be string / int / float / bool")
		# 功能引用的条件：同清单内按 id 引用（同挂载模型），引用未声明的条件 = 错误
		var conds = d.get("conditions", [])
		if not (conds is Array):
			_add(issues, "error", "functions.%s.conditions" % str(fid), "must be an array of condition ids")
		else:
			for c0 in conds:
				var c0s := str(c0)
				if c0s == "" or not ConditionDecls.conditions(data).has(c0s):
					_add(issues, "error", "functions.%s.conditions" % str(fid),
						"condition \"%s\" is not declared" % c0s)

## 条件声明：结构 + id 唯一性 + 字段种类合法性（与功能声明同一套规则）。
## 条件按 id 被功能声明引用（清单内人类名，条件无执行码）；字段码与功能字段同空间。
static func _validate_conditions(data: Dictionary, issues: Array[Dictionary]) -> void:
	var decl = data.get("conditions", null)
	if not (decl is Dictionary or decl is Array):
		_add(issues, "error", "conditions", "must be an object or an array")
		return
	# id 查重（数组写法可能重复；dict 写法查空键）
	var cseen := {}
	if decl is Array:
		for item in decl:
			if not (item is Dictionary):
				_add(issues, "error", "conditions", "entries must be objects")
				continue
			var cid0 := str((item as Dictionary).get("id", ""))
			if cid0 == "" or cseen.has(cid0):
				_add(issues, "error", "conditions",
					"condition ids must be non-empty and unique (array form, seen: %s)" % cid0)
			cseen[cid0] = true
	elif decl is Dictionary:
		for k0 in (decl as Dictionary).keys():
			if str(k0) == "":
				_add(issues, "error", "conditions", "condition ids must be non-empty (dict form)")
	# 字段 id / kind / type（归一化视图逐条件查）
	for cid in ConditionDecls.conditions(data):
		var d: Dictionary = ConditionDecls.conditions(data)[cid]
		var fseen := {}
		for fd in d.get("fields", []):
			if not (fd is Dictionary):
				_add(issues, "error", "conditions.%s.fields" % cid, "entries must be objects")
				continue
			var field_id := str((fd as Dictionary).get("id", ""))
			if field_id == "" or fseen.has(field_id):
				_add(issues, "error", "conditions.%s.fields" % cid,
					"field ids must be non-empty and unique (seen: %s)" % field_id)
			fseen[field_id] = true
			var kind := str((fd as Dictionary).get("kind", ""))
			if kind != "input" and kind != "choice":
				_add(issues, "error", "conditions.%s.fields.%s" % [cid, field_id],
					"field kind must be \"input\" or \"choice\"")
			elif kind == "input":
				var typ := str((fd as Dictionary).get("type", ""))
				if not ["string", "int", "float", "bool"].has(typ):
					_add(issues, "error", "conditions.%s.fields.%s" % [cid, field_id],
						"input type must be string / int / float / bool")
	# 字段码跨池查重：条件字段与功能字段共存于同一份内容 fields，同码 = 静默合并
	var fcodes := {}
	for fid in FunctionDecls.functions(data):
		for fd1 in (FunctionDecls.functions(data)[fid] as Dictionary).get("fields", []):
			if fd1 is Dictionary:
				var fc := str((fd1 as Dictionary).get("code", ""))
				if fc != "":
					if fcodes.has(fc):
						_add(issues, "error", "functions.%s.fields" % str(fid),
							"duplicate field code across pools: " + fc)
					fcodes[fc] = true
	for cid2 in ConditionDecls.conditions(data):
		for fd2 in (ConditionDecls.conditions(data)[cid2] as Dictionary).get("fields", []):
			if fd2 is Dictionary:
				var fc2 := str((fd2 as Dictionary).get("code", ""))
				if fc2 != "" and fcodes.has(fc2):
					_add(issues, "error", "conditions.%s.fields" % cid2,
						"duplicate field code across pools: " + fc2)
				if fc2 != "":
					fcodes[fc2] = true

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
 # 多图集已支持（格式 bump）——tiles[] 每项一个图集，索引即地图格的 atlas 维度
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

static func _validate_entities(data: Dictionary, issues: Array[Dictionary]) -> void:
	var entities: Array = data.get("entities", [])
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
 # 自带功能（挂载）：entities[].functions = 已声明功能的 id 数组。
 # 挂载了未声明的功能 = 挂了个空操作，直接报错误（声明池在上层 functions）。
		if entity.has("functions"):
			if not (entity.functions is Array):
				_add(issues, "error", path + ".functions", "must be an array of function ids")
			else:
				var pool := FunctionDecls.functions(data)
				for fid in entity.functions:
					if not (fid is String) or str(fid) == "":
						_add(issues, "error", path + ".functions",
							"mounts must be non-empty function ids")
					elif not pool.has(str(fid)):
						_add(issues, "error", path + ".functions",
							"mounted function is not declared: " + str(fid))
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
