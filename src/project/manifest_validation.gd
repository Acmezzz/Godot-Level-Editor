extends RefCounted
## 检查编辑器读取和保存所依赖的清单结构、身份及引用。

const FunctionDecls := preload("res://src/content/function_decl.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const TriggerDecls := preload("res://src/content/trigger_decl.gd")
const CollisionTypes := preload("res://src/assets/collision_types.gd")
const BuiltinKinds := preload("res://src/assets/builtin_kinds.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const CellGraph := preload("res://src/map/cell_graph.gd")
const ScreenLayout := preload("res://src/project/screen_layout.gd")
const GamePreview := preload("res://src/project/game_preview.gd")
const WorldLayout := preload("res://src/project/world_layout.gd")
const MapGenerators := preload("res://src/project/map_generators.gd")
const MapFlow := preload("res://src/map/map_flow.gd")
const ProjectSlots := preload("res://src/project/project_content_slots.gd")
const EventLayers := preload("res://src/project/event_layers.gd")

## input 字段类型白名单（与 field_widgets 一一对应）：新增类型必须同时有控件分支。
const Keyframes := preload("res://src/content/keyframe_curve.gd")
const FlowTarget := preload("res://src/content/flow_target.gd")
const INPUT_TYPES := ["string", "int", "float", "bool", "color", "vector2", "range", "asset_ref", "array", "port_ref", "viewport_ref", "edge_ref", "curve", "flow_target"]

## 资产 id 同时用作地图瓦片条目的第 3 位（磁盘引用）——必须存在且唯一。
static func validate(data: Dictionary, project_dir := "") -> Array[Dictionary]:
	var issues: Array[Dictionary] = []
	# 旧键零兼容：tiles[] / entities[] 已并入 assets[]，见到就报错（迁移脚本负责搬家）
	for old in ["tiles", "entities"]:
		if data.has(old):
			_add(issues, "error", old, "retired: declare this in assets[] with kind/shape (run tools/migrate_project.gd)")
	if data.has("assets"):
		if not (data["assets"] is Array):
			_add(issues, "error", "assets", "must be an array")
		else:
			_validate_assets(data, project_dir, issues)
	_validate_declarations(data, issues)
	_validate_content_field_shapes(data, issues)
	if data.has("collisionTypes"):
		_validate_collision_types(data, issues)
	_validate_playtest(data, issues)
	issues.append_array(GamePreview.declaration_issues(data))
	issues.append_array(WorldLayout.issues(data))
	issues.append_array(MapGenerators.issues(data))
	issues.append_array(MapFlow.declaration_issues(data))
	issues.append_array(ProjectSlots.declaration_issues(data))
	issues.append_array(EventLayers.issues(data))
	# tileSize：正整数像素（正方形格）或 [w,h] 两正整数（矩形格，B1：拒绝零/负/非整数）
	var tile_size = data.get("tileSize", 16)
	if tile_size is Array:
		var bad := (tile_size as Array).size() != 2
		for v in (tile_size as Array):
			if not _is_positive_integer(v):
				bad = true
		if bad:
			_add(issues, "error", "tileSize", "must be a positive integer or [w, h] of two positive integers")
	elif not _is_positive_integer(tile_size):
		_add(issues, "error", "tileSize", "must be a positive integer or [w, h] of two positive integers")
	_validate_top_level(data, issues)
	for issue in CellGraph.validate_edge_types(data):
		_add(issues, "error", issue.path, issue.message)
	return issues

## 顶层可选键结构校验（缺键走缺省，存在即校验形态）。
static func _validate_top_level(data: Dictionary, issues: Array[Dictionary]) -> void:
	if data.has("contentDir") and not data.contentDir is String:
		_add(issues, "error", "contentDir", "must be a string")
	elif data.has("contentDir"):
		var cd := str(data["contentDir"])
		if cd != "" and (cd.begins_with("/") or cd.begins_with("\\") or cd.contains("..")):
			_add(issues, "error", "contentDir", "must be a relative path without '..'")
	for capability in ["directViewTargets", "directMapTargets"]:
		if data.has(capability) and not data[capability] is bool:
			_add(issues, "error", capability, "must be a boolean")
	_validate_viewports(data, issues)
	_validate_views(data, issues)
	_validate_screen_modules(data, issues)
	_validate_startup(data, issues)
	if data.has("screenSize"):
		var ss = data["screenSize"]
		if not (ss is Array) or (ss as Array).size() != 2 \
				or not ((ss as Array)[0] is int or (ss as Array)[0] is float) \
				or not ((ss as Array)[1] is int or (ss as Array)[1] is float):
			_add(issues, "error", "screenSize", "must be [w, h] numbers")

static func _validate_startup(data: Dictionary, issues: Array[Dictionary]) -> void:
	if not data.has("startup"):
		return
	var startup = data.startup
	if not startup is Dictionary:
		_add(issues, "error", "startup", "must be an object")
		return
	for kind in ["screens", "maps"]:
		if startup.has(kind) and not startup[kind] is bool:
			_add(issues, "error", "startup." + kind, "must be a boolean")
	var ports = startup.get("arrivalPorts", [])
	if not ports is Array or not ports.all(func(id): return id is String and id != ""):
		_add(issues, "error", "startup.arrivalPorts", "must be an array of non-empty port types")
		return
	var kinds = startup.get("contentTypes", [])
	if not kinds is Array:
		_add(issues, "error", "startup.contentTypes", "must be an array of declared function IDs")
		return
	var declarations := FunctionDecls.functions(data)
	var seen := {}
	for kind in kinds:
		if not kind is String or not declarations.has(kind) or seen.has(kind):
			_add(issues, "error", "startup.contentTypes", "must name unique declared function IDs")
		else:
			seen[kind] = true
	if startup.has("contentMapContext") and (startup.contentMapContext != "paired" or kinds.is_empty()):
		_add(issues, "error", "startup.contentMapContext", "paired requires at least one permitted content type")
	if startup.has("contentMap") and (startup.get("contentMapContext") != "paired" \
			or FlowTarget.kind(startup.get("target")) != "content" \
			or not startup.contentMap is String or startup.contentMap.is_empty()):
		_add(issues, "error", "startup.contentMap", "must be a non-empty map code on a paired content entry")
	if not startup.has("target"):
		return
	var target = startup.target
	if FlowTarget.allows(startup, target) and (not target.has("content") or ContentStore.is_valid_id(target.content)):
		return
	_add(issues, "error", "startup.target", "must select a permitted {function, content}, {view}, {map} or {map, inst, port}")

## 功能/字段声明：结构 + 身份码唯一性 + 字段种类合法性。
## 码重复是**错误**：两个声明同码等于静默别名，磁盘上的引用会指向不确定的那个。
## 功能 id 重复同样是**错误**（内容目录按功能 id 分目录；数组写法不查会静默后者覆盖前者）。
## 声明条目按池查 ID 与执行码；功能、条件和步骤的字段码共享一个空间。
static func _validate_declarations(data: Dictionary, issues: Array[Dictionary]) -> void:
	var references := {"conditions": ConditionDecls.conditions(data), "triggers": TriggerDecls.triggers(data)}
	var field_codes := {}
	for section in ["functions", "conditions", "steps", "audio", "triggers"]:
		var decl = data.get(section, {})
		if not (decl is Dictionary or decl is Array):
			_add(issues, "error", section, "must be an object or an array")
			continue
		var ids := {}
		var codes := {}
		for item in decl:
			var row = decl[item] if decl is Dictionary else item
			if not row is Dictionary:
				_add(issues, "error", section, "entries must be objects")
				continue
			var id := str(item if decl is Dictionary else row.get("id", ""))
			var path := "%s.%s" % [section, id]
			if id.strip_edges().is_empty() or ids.has(id):
				_add(issues, "error", path, "id must be non-empty and unique")
			ids[id] = true
			var code := str(row.get("code", ""))
			if section != "conditions" and code != "":
				if codes.has(code):
					_add(issues, "error", path + ".code", "duplicate code: " + code)
				codes[code] = true
			if section in ["functions", "conditions", "steps"]:
				var fields = row.get("fields", [])
				if not fields is Array:
					_add(issues, "error", path + ".fields", "must be an array")
				else:
					_validate_fields(fields, path + ".fields", issues, section == "functions")
					for field in fields:
						if not field is Dictionary:
							continue
						var field_code := str(field.get("code", ""))
						if field_code == "":
							continue
						if field_codes.has(field_code):
							_add(issues, "error", path + ".fields", "duplicate field code: " + field_code)
						field_codes[field_code] = true
			if section == "functions":
				if not ContentStore.is_valid_kind(id):
					_add(issues, "error", path, "function id must be a valid content folder name")
				for key in references:
					var refs = row.get(key, [])
					if not refs is Array:
						_add(issues, "error", path + "." + key, "must be an array of ids")
						continue
					for ref in refs:
						if not references[key].has(str(ref)):
							_add(issues, "error", path + "." + key, "undeclared id: " + str(ref))


## 碰撞类型池：形状枚举 + 颜色形态；id 非空唯一（数组写法）。
static func _validate_collision_types(data: Dictionary, issues: Array[Dictionary]) -> void:
	var decl = data.get("collisionTypes", null)
	if not (decl is Dictionary or decl is Array):
		_add(issues, "error", "collisionTypes", "must be an object or an array")
		return
	var ids := {}
	for pair in CollisionTypes._decl_items(decl):
		var tid := str(pair.id)
		if tid == "" or ids.has(tid):
			_add(issues, "error", "collisionTypes",
				"collision type ids must be non-empty and unique (seen: %s)" % tid)
		ids[tid] = true
		var body: Dictionary = pair.body
		var shape := str(body.get("shape", ""))
		if shape != "" and not ["rect", "triangle_r", "triangle_l", "circle", "polygon"].has(shape):
			_add(issues, "error", "collisionTypes", "invalid shape: " + shape)
		if body.has("color") and (not body.color is String or body.color.length() != 7 \
				or not body.color.begins_with("#") or not Color.html_is_valid(body.color)):
			_add(issues, "error", "collisionTypes", "color must be a #rrggbb string")

## 试玩声明（v7）：清单 playtest.flags/params 驱动试玩面板（替代写死的 dash/glide/hp）。
## flags = {id, name, arg}（arg 为启动时原样追加的 CLI 参数）；params = {id, name, arg(含 %d), def, min, max}。
## 未声明 playtest = 面板空态提示；结构错报 error——和其它 error 一样会拦住清单载入
## （manifest.gd 只会对 warning 放行；试玩面板本身在无声明时也能用）。
static func _validate_playtest(data: Dictionary, issues: Array[Dictionary]) -> void:
	if not data.has("playtest"):
		return
	var pt = data.get("playtest", null)
	if not (pt is Dictionary):
		_add(issues, "error", "playtest", "must be an object")
		return
	var pt2: Dictionary = pt
	for kind in ["flags", "params"]:
		var arr = pt2.get(kind, null)
		if arr == null:
			continue
		if not (arr is Array):
			_add(issues, "error", "playtest." + kind, "must be an array")
			continue
		var ids := {}
		for it in (arr as Array):
			if not (it is Dictionary):
				_add(issues, "error", "playtest." + kind, "entries must be objects")
				continue
			var d: Dictionary = it
			var fid := str(d.get("id", ""))
			if fid == "" or ids.has(fid):
				_add(issues, "error", "playtest." + kind,
					"ids must be non-empty and unique (seen: %s)" % fid)
			ids[fid] = true
			if str(d.get("name", "")) == "":
				_add(issues, "error", "playtest." + kind + "." + fid, "must have a name")
			if kind == "flags" and str(d.get("arg", "")) == "":
				_add(issues, "error", "playtest.flags." + fid, "must have an arg")
			if kind == "params" and not str(d.get("arg", "")).contains("%d"):
				_add(issues, "error", "playtest.params." + fid, "arg must contain %d for the number")
	# 结构化启动（A6）：executable 为路径字符串，args 为参数数组；两者都可选。
	var exe = pt2.get("executable", null)
	if exe != null and not (exe is String):
		_add(issues, "error", "playtest.executable", "must be a path string")
	elif exe is String and (exe as String).strip_edges() == "" and pt2.has("executable"):
		_add(issues, "warning", "playtest.executable", "empty executable: playtest is disabled")
	for feature in ["report", "projectEntry", "mapEntry", "viewEntry", "viewDraft", "contentEntryMap", "captureFrames"]:
		if not pt2.has(feature):
			continue
		if not pt2[feature] is bool:
			_add(issues, "error", "playtest." + feature, "must be a boolean")
		elif pt2[feature] and (not exe is String or str(exe).strip_edges() == ""):
			_add(issues, "error", "playtest." + feature, "requires a structured executable launch")
	if pt2.get("viewDraft") == true and pt2.get("report") != true:
		_add(issues, "error", "playtest.viewDraft", "requires report: true to verify the loaded draft")
	if pt2.get("captureFrames") == true and pt2.get("report") != true:
		_add(issues, "error", "playtest.captureFrames", "requires report: true to identify the running session")
	if pt2.has("mapEntryPorts"):
		var types = pt2.mapEntryPorts
		if pt2.get("mapEntry") != true or not types is Array or types.is_empty() \
				or not types.all(func(id): return id is String and not id.strip_edges().is_empty()):
			_add(issues, "error", "playtest.mapEntryPorts", "requires mapEntry: true and a non-empty array of port types")
	if pt2.get("contentEntryMap") == true and (pt2.get("projectEntry") != true \
			or not pt2.get("entryFunctions") is Array or pt2.entryFunctions.is_empty()):
		_add(issues, "error", "playtest.contentEntryMap", "requires projectEntry and at least one entryFunctions ID")
	if pt2.has("entryFunctions"):
		var entries = pt2.entryFunctions
		if pt2.get("projectEntry") != true:
			_add(issues, "error", "playtest.entryFunctions", "requires projectEntry: true")
		if not entries is Array:
			_add(issues, "error", "playtest.entryFunctions", "must be an array of function IDs")
		else:
			var declared := FunctionDecls.functions(data)
			var seen := {}
			for i in entries.size():
				var id = entries[i]
				if not id is String or not declared.has(id) or seen.has(id):
					_add(issues, "error", "playtest.entryFunctions[%d]" % i, "must be a unique declared function ID")
				else:
					seen[id] = true
	var args = pt2.get("args", null)
	if args != null:
		if not (args is Array):
			_add(issues, "error", "playtest.args", "must be an array of strings")
		else:
			for i in (args as Array).size():
				if not ((args as Array)[i] is String):
					_add(issues, "error", "playtest.args[%d]" % i, "must be a string")

## 步骤池：id 非空唯一（array 写法查重）、条目码池内唯一、字段 id/kind/type 合法、
## 步骤字段码与功能/条件字段同空间查重（跨池同码 = 静默合并，报错）。
## 资产表：kind/shape 合法、id 唯一、scene 的图集或图片二选一、entity 的呈现二选一、
## 挂载功能必须已声明、palette 条目结构。
static func _validate_assets(data: Dictionary, project_dir: String, issues: Array[Dictionary]) -> void:
	var assets: Array = data.get("assets", [])
	var needs_builtin := not assets.any(func(asset): return asset is Dictionary and asset.get("id") == BuiltinKinds.TRIGGER_ID)
	var ids := {}
	var codes := {}
	var atlas_sizes := {}
	var tile_size := preload("res://src/canvas/grid_space.gd").tile_size_of(data)
	for i in assets.size():
		var a = assets[i]
		var path := "assets[%d]" % i
		if not (a is Dictionary):
			_add(issues, "error", path, "must be an object")
			continue
		var ad: Dictionary = a
		var id := str(ad.get("id", ""))
		if id == "" or ids.has(id):
			_add(issues, "error", path + ".id", "must be non-empty and unique")
		ids[id] = true
		var kind := str(ad.get("kind", ""))
		if kind != "scene" and kind != "entity":
			_add(issues, "error", path + ".kind", "must be \"scene\" or \"entity\"")
			continue
		if kind == "scene":
			for key in ["code", "functions", "ports"]:
				if ad.has(key):
					_add(issues, "error", path + "." + key, "only entity assets can declare " + key)
			_validate_scene_asset(ad, path, project_dir, issues, tile_size, atlas_sizes)
		else:
			if needs_builtin and ad.get("code") == BuiltinKinds.TRIGGER_CODE:
				_add(issues, "error", path + ".code", "TZ99 is reserved for the built-in trigger_zone")
			_validate_ports(ad, path, issues)
			_validate_port_sources(ad, path, issues)
			_validate_entity_asset(data, ad, path, codes, issues)

static func _positive_int(value: Variant) -> bool:
	return (value is int or value is float) and value > 0 and float(value) == floorf(float(value))

static func _validate_scene_asset(ad: Dictionary, path: String, project_dir: String, issues: Array[Dictionary],
		tile_size: Vector2i, atlas_sizes: Dictionary) -> void:
	var shape := str(ad.get("shape", "tile"))
	if shape != "tile" and shape != "image":
		_add(issues, "error", path + ".shape", "scene shape must be \"tile\" or \"image\"")
		return
	var atlas := str(ad.get("atlas", ""))
	var texture := str(ad.get("texture", ""))
	if shape == "tile":
		var cell = ad.get("cell")
		if ad.has("cell") and not ((cell is Dictionary and _positive_int(cell.get("w")) and _positive_int(cell.get("h"))) \
				or (cell is Array and cell.size() == 2 and cell.all(_positive_int))):
			_add(issues, "warning", path + ".cell", "use positive integers in {w, h}; invalid values fall back to tileSize")
		if atlas == "":
			_add(issues, "error", path + ".atlas", "tile shape needs an atlas")
		elif project_dir != "" and atlas.contains(".."):
			_add(issues, "error", path + ".atlas", "path cannot traverse outside the project")
		elif project_dir != "" and not FileAccess.file_exists(project_dir.path_join(atlas)):
			_add(issues, "warning", path + ".atlas", "atlas file not found on disk")
		elif project_dir != "":
			var file := project_dir.path_join(atlas).simplify_path()
			if not atlas_sizes.has(file):
				var img := Image.new()
				atlas_sizes[file] = img.get_size() if img.load(file) == OK else Vector2i.ZERO
			var size: Vector2i = atlas_sizes[file]
			var slicing := preload("res://src/assets/asset_decl.gd").declared_cell_size(cell, tile_size)
			if size != Vector2i.ZERO and (slicing.x > size.x or slicing.y > size.y):
				_add(issues, "warning", path + ".cell", "slice %s is larger than atlas %s" % [slicing, size])
		if ad.has("palette"):
			if not (ad.palette is Array):
				_add(issues, "error", path + ".palette", "must be an array")
			else:
				for j in (ad.palette as Array).size():
					var entry = (ad.palette as Array)[j]
					if not (entry is Dictionary):
						_add(issues, "error", "%s.palette[%d]" % [path, j], "must be an object")
					elif not ((entry as Dictionary).get("cell", null) is Array) \
							or ((entry as Dictionary).cell as Array).size() < 2:
						_add(issues, "error", "%s.palette[%d].cell" % [path, j], "must contain atlas x and y")
	else:
		if texture == "":
			_add(issues, "error", path + ".texture", "image shape needs a texture")
		elif project_dir != "" and texture.contains(".."):
			_add(issues, "error", path + ".texture", "path cannot traverse outside the project")
		elif project_dir != "" and not FileAccess.file_exists(project_dir.path_join(texture)):
			_add(issues, "warning", path + ".texture", "texture file not found on disk")
	if atlas != "" and texture != "":
		_add(issues, "error", path, "scene asset must declare exactly one of atlas / texture")
	# 资产投影用于推断缺省地图投影。
	var gp := str(ad.get("gridProjection", "orthogonal"))
	if gp != "orthogonal" and gp != "isometric" and gp != "hexagonal":
		_add(issues, "error", path + ".gridProjection", "must be \"orthogonal\" or \"isometric\" or \"hexagonal\"")

static func _validate_entity_asset(data: Dictionary, ad: Dictionary, path: String,
		codes: Dictionary, issues: Array[Dictionary]) -> void:
	if ad.has("shape"):
		_add(issues, "error", path + ".shape", "only scene assets have a shape")
	# 呈现二选一：prefab（游戏侧场景）或 visual（编辑器自画）。都没有 = 放上画布是空白，
	# 这正是「实体声明了却看不见」的老坑。
	var prefab := str(ad.get("prefab", ""))
	var visual = ad.get("visual", null)
	if prefab == "" and not (visual is Dictionary):
		_add(issues, "error", path, "entity asset needs prefab or visual")
	if visual != null and not (visual is Dictionary):
		_add(issues, "error", path + ".visual", "must be an object")
	elif visual is Dictionary and str((visual as Dictionary).get("type", "rect")) not in ["rect", "poly", "path"]:
		_add(issues, "error", path + ".visual.type", "must be rect / poly / path")
	if ad.has("editorSize"):
		var es = ad.editorSize
		if not (es is Array) or (es as Array).size() < 2:
			_add(issues, "error", path + ".editorSize", "must be [w, h]")
	# 码：entity 可以有；同池唯一
	var code := str(ad.get("code", ""))
	if code != "":
		if codes.has(code):
			_add(issues, "error", path + ".code", "duplicate asset code %s" % code)
		codes[code] = true
	if ad.has("fields") and not (ad.fields is Array):
		_add(issues, "error", path + ".fields", "must be an array")
	# 自带功能（挂载）：asset.functions = 已声明功能的 id 数组。
	# 挂载了未声明的功能 = 挂了个空操作，直接报错误（声明池在上层 functions）。
	if ad.has("functions"):
		if not (ad.functions is Array):
			_add(issues, "error", path + ".functions", "must be an array of function ids")
		else:
			var pool := FunctionDecls.functions(data)
			var seen_mounts := {}
			for fid in ad.functions:
				if not (fid is String) or str(fid) == "":
					_add(issues, "error", path + ".functions", "mounts must be non-empty function ids")
				elif not pool.has(str(fid)):
					_add(issues, "error", path + ".functions",
						"mounted function is not declared: " + str(fid))
				elif seen_mounts.has(str(fid)):
					# C09：同功能重复挂载会让实例补出两条同码绑定，「唯一继承行」无处可认
					_add(issues, "error", path + ".functions", "duplicate mount: " + str(fid))
				else:
					seen_mounts[str(fid)] = true
	if ad.has("frames") and not (ad.frames is Array):
		_add(issues, "error", path + ".frames", "must be an array of texture paths")
	if ad.get("fields", []) is Array:
		_validate_fields(ad.get("fields", []), path + ".fields", issues, true, "asset")

## 正整数像素尺寸（B1）：int 直接判，float 必须有限且恰为整数（JSON 20.0 合法、20.5 拒绝）。
static func _is_positive_integer(v) -> bool:
	if v is int:
		return v > 0
	if not (v is float):
		return false
	var f: float = v
	return is_finite(f) and f > 0.0 and f == floorf(f)

static func _add(issues: Array[Dictionary], severity: String, path: String, message: String) -> void:
	issues.append({"severity": severity, "path": path, "message": message})

## 可配置条件使用已声明的叶条件池；不允许条件声明递归引用自己。
static func _validate_content_field_shapes(data: Dictionary, issues: Array[Dictionary]) -> void:
	var conditions := ConditionDecls.conditions(data)
	var assets = data.get("assets", [])
	for i in (assets as Array).size() if assets is Array else 0:
		var asset = assets[i]
		if asset is Dictionary and asset.get("kind") == "entity":
			_check_condition_fields(asset.get("fields"), "assets[%d].fields" % i, conditions, true, issues)
	for section in ["functions", "steps", "conditions"]:
		var pool: Dictionary
		match section:
			"functions": pool = FunctionDecls.functions(data)
			"steps": pool = StepDecls.steps(data)
			_: pool = conditions
		for id in pool:
			_check_condition_fields(pool[id].get("fields"), "%s.%s.fields" % [section, id],
				conditions, section != "conditions", issues)

static func _check_condition_fields(fields: Variant, path: String, conditions: Dictionary,
		allow_rows: bool, issues: Array[Dictionary], depth := 0) -> void:
	if not fields is Array or depth > 4:
		return
	for fd in fields:
		if not fd is Dictionary:
			continue
		var child := path + "." + str(fd.get("id", "?"))
		var flow_list: bool = fd.get("type") == "array" and fd.get("of") == "flow_target"
		if fd.get("kind") == "input" and (fd.get("type") == "flow_target" or flow_list):
			if not FlowTarget.declaration_valid(fd):
				_add(issues, "error", child, "flow_target requires at least one domain: maps, screens, contentTypes or arrivalPorts")
			elif flow_list and fd.has("default") and (not fd.default is Array or not fd.default.all(func(target):
					return (target is Dictionary and target.is_empty()) or FlowTarget.allows(fd, target))):
				_add(issues, "error", child + ".default", "must be an array of permitted flow targets")
			elif not flow_list and fd.has("default") and not (fd.default is Dictionary and fd.default.is_empty()) and not FlowTarget.allows(fd, fd.default):
				_add(issues, "error", child + ".default", "flow target is not in the declared domains")
		if fd.get("kind") == "input" and fd.get("type") == "curve" and fd.has("default") and not Keyframes.valid(fd.default):
			_add(issues, "error", child + ".default", "curve keys require increasing nonnegative times, finite values and a supported mode")
		if fd.has("pickSpace"):
			var point: bool = fd.get("type") == "vector2" or (fd.get("type") == "array" and fd.get("of") == "vector2")
			if fd.pickSpace not in ["map", "layer"] or fd.get("kind") != "input" or not point or fd.get("dims", 2) != 2:
				_add(issues, "error", child + ".pickSpace", "map or layer picking requires a two-dimensional vector2 or array of vector2")
			elif fd.pickSpace == "layer":
				var layer_field := str(fd.get("layerField", ""))
				if layer_field == "" or not fields.any(func(sibling):
					return sibling is Dictionary and sibling.get("id") == layer_field \
						and sibling.get("kind") == "choice" and sibling.get("type") != "array" \
						and sibling.get("source") == "layer:" and not bool(sibling.get("multiple", false)) \
						and sibling.get("mapField", "") == fd.get("mapField", "")):
					_add(issues, "error", child + ".layerField", "must name a single layer: choice in the same row with the same mapField")
		if fd.has("viewMapContext") and (fd.viewMapContext != "inherit" or fd.get("screens") != true \
				or fd.get("kind") != "input" or (fd.get("type") != "flow_target" and not flow_list)):
			_add(issues, "error", child + ".viewMapContext", "inherit requires a flow_target that permits screens")
		if fd.has("contentMapContext"):
			var mode = fd.contentMapContext
			var at := child + ".contentMapContext"
			if not mode is String or str(mode) not in ["independent", "inherit", "paired"]:
				_add(issues, "error", at, "must be independent, inherit or paired")
			elif not str(fd.get("source", "")).begins_with("content:") and not (
					fd.get("kind") == "input" and (fd.get("type") == "flow_target" or flow_list)
					and fd.get("contentTypes") is Array and not fd.contentTypes.is_empty()):
				_add(issues, "error", at, "requires a content: choice or a flow_target that permits content")
			elif mode == "paired":
				var pair := str(fd.get("mapField", ""))
				if pair == "" or not fields.any(func(sibling):
					return sibling is Dictionary and str(sibling.get("id", "")) == pair \
						and (sibling.get("type") == "map_ref" or sibling.get("source") == "map") \
						and not bool(sibling.get("multiple", false)) and sibling.get("type") != "array"):
					_add(issues, "error", at, "paired requires mapField naming a single map choice in the same row")
		if fd.get("type") != "array":
			continue
		if fd.get("of") == "record":
			_check_condition_fields(fd.get("fields"), child, conditions, allow_rows, issues, depth + 1)
		elif fd.get("of") == "condition":
			var allowed = fd.get("allowedConditions")
			if not allow_rows:
				_add(issues, "error", child, "condition declarations must not contain condition arrays")
			elif fd.get("kind") != "input" or not allowed is Array or allowed.is_empty():
				_add(issues, "error", child, "array of condition requires input kind and non-empty allowedConditions")
			else:
				var seen := {}
				for id in allowed:
					if not id is String or not conditions.has(id) or seen.has(id):
						_add(issues, "error", child + ".allowedConditions", "unknown or duplicate condition: " + str(id))
					else:
						seen[id] = true

static func _validate_fields(fields: Array, path: String, issues: Array[Dictionary],
		records := true, domain := "", depth := 0) -> void:
	var ids := {}
	for field in fields:
		if not field is Dictionary:
			_add(issues, "error", path, "entries must be objects")
			continue
		var id := str(field.get("id", ""))
		if id.is_empty() or ids.has(id) or (domain == "module" and (not field.get("id") is String or id.strip_edges().is_empty())):
			_add(issues, "error", path, "field ids must be non-empty and unique (seen: %s)" % id)
		ids[id] = true
		var at := path + "." + id
		var kind := str(field.get("kind", ""))
		if kind != "input":
			if kind != "choice" and domain != "asset":
				_add(issues, "error", at, "field kind must be \"input\" or \"choice\"")
			continue
		var type := str(field.get("type", ""))
		if domain == "asset" and type in ["entity_ref", "map_ref"]:
			continue
		if not INPUT_TYPES.has(type):
			_add(issues, "error", at, "input type must be one of: " + ", ".join(INPUT_TYPES))
		elif records and type == "array" and field.get("of") == "record":
			var children = field.get("fields")
			if depth >= 5:
				_add(issues, "error", at, "record nesting too deep (max 5)")
			elif not children is Array or children.is_empty():
				_add(issues, "error", at, "of: record requires a non-empty fields array")
			else:
				_validate_fields(children, at + ".fields", issues, true, "", depth + 1)

## C3（§7.4）：assets[].ports 校验。端口 = {id, x, y, type?}：id 非空唯一、x/y 为数字
## （锚点局部像素）、type 可选字符串。不校验其它未知键（游戏侧自定义原样保留）。
static func _validate_ports(ad: Dictionary, path: String, issues: Array[Dictionary]) -> void:
	var ps = ad.get("ports", null)
	if ps == null:
		return
	if not (ps is Array):
		_add(issues, "error", path + ".ports", "must be an array of {id, x, y, type?}")
		return
	var seen := {}
	for j in (ps as Array).size():
		var e = (ps as Array)[j]
		var p := "%s.ports[%d]" % [path, j]
		if not (e is Dictionary):
			_add(issues, "error", p, "must be an object")
			continue
		var pid := str((e as Dictionary).get("id", ""))
		if pid == "" or seen.has(pid):
			_add(issues, "error", p + ".id", "must be non-empty and unique (seen: %s)" % pid)
		seen[pid] = true
		for k in ["x", "y"]:
			var v = (e as Dictionary).get(k, null)
			if not (v is int or v is float):
				_add(issues, "error", p + "." + k, "must be a number (anchor local px)")
		var pt = (e as Dictionary).get("type", null)
		if pt != null and not (pt is String):
			_add(issues, "error", p + ".type", "must be a string")

static func _validate_port_sources(asset: Dictionary, path: String, issues: Array[Dictionary]) -> void:
	var ports = asset.get("ports", [])
	var fields = asset.get("fields", [])
	if not fields is Array:
		return
	for field in fields:
		if not field is Dictionary or not field.has("sourcePort"):
			continue
		var id = field.sourcePort
		if field.get("type") != "port_ref" or not id is String or id.is_empty() or not ports is Array or not ports.any(
				func(port): return port is Dictionary and port.get("id") == id):
			_add(issues, "error", "%s.fields.%s.sourcePort" % [path, field.get("id", "?")],
				"must name a declared port on this asset and belong to a port_ref field")

## C5（§7.4）：具名参考画幅 viewports（[{id, w, h}]）：id 非空唯一、w/h 必填正数。
static func _validate_viewports(data: Dictionary, issues: Array[Dictionary]) -> void:
	var vs = data.get("viewports", null)
	if vs == null:
		return
	if not (vs is Array):
		_add(issues, "error", "viewports", "must be an array of {id, w, h}")
		return
	var seen := {}
	for j in (vs as Array).size():
		var e = (vs as Array)[j]
		var p := "viewports[%d]" % j
		if not (e is Dictionary):
			_add(issues, "error", p, "must be an object")
			continue
		var vid := str((e as Dictionary).get("id", ""))
		if vid == "" or seen.has(vid):
			_add(issues, "error", p + ".id", "must be non-empty and unique (seen: %s)" % vid)
		seen[vid] = true
		for k in ["w", "h"]:
			var v = (e as Dictionary).get(k, null)
			if v == null or not (v is int or v is float):
				_add(issues, "error", p + "." + k, "must be a positive number")
			elif v <= 0:
				_add(issues, "error", p + "." + k, "must be a positive number")
static func _validate_screen_modules(data: Dictionary, issues: Array[Dictionary]) -> void:
	var raw = data.get("screenModules", {})
	if not raw is Dictionary:
		_add(issues, "error", "screenModules", "must be an object keyed by module ID")
		return
	var conditions := ConditionDecls.conditions(data)
	for id in raw:
		var path := "screenModules." + str(id)
		var decl = raw[id]
		if not id is String or id.strip_edges().is_empty() or not decl is Dictionary:
			_add(issues, "error", path, "must have a non-empty ID and an object declaration")
			continue
		var outputs = decl.get("outputs", {})
		if not outputs is Dictionary:
			_add(issues, "error", path + ".outputs", "must be an object of output IDs and labels")
		else:
			for output in outputs:
				var spec = outputs[output]
				var valid: bool = not spec.strip_edges().is_empty() if spec is String else (
					spec is Dictionary and spec.get("name", "") is String and FlowTarget.declaration_valid(spec))
				if not output is String or output.strip_edges().is_empty() or not valid:
					_add(issues, "error", path + ".outputs." + str(output), "requires an output ID and a label or destination domains")
		var fields = decl.get("fields", [])
		if not fields is Array:
			_add(issues, "error", path + ".fields", "must be an array")
			continue
		if outputs is Dictionary:
			for output in outputs:
				var spec = outputs[output]
				if not spec is Dictionary:
					continue
				var at := path + ".outputs." + str(output)
				if spec.has("contentMapContext") or spec.has("mapField"):
					var mode = spec.get("contentMapContext")
					if mode not in ["inherit", "paired"] or not spec.get("contentTypes") is Array \
							or spec.contentTypes.is_empty() or (mode == "paired" and not _module_map_field(fields, spec.get("mapField"))) \
							or (mode == "inherit" and spec.has("mapField")):
						_add(issues, "error", path + ".outputs." + str(output),
							"inherit or paired requires contentTypes; paired also needs a single map choice in mapField")
				if spec.has("viewMapContext") and (spec.viewMapContext != "inherit" or spec.get("screens") != true):
					_add(issues, "error", at + ".viewMapContext", "inherit requires an output that accepts screens")
		_validate_fields(fields, path + ".fields", issues, true, "module")
		_check_condition_fields(fields, path + ".fields", conditions, true, issues)
		_check_module_map_pairs(fields, path + ".fields", issues)

static func _check_module_map_pairs(fields: Array, path: String, issues: Array[Dictionary], depth := 0) -> void:
	if depth > 4:
		return
	for field in fields:
		if not field is Dictionary:
			continue
		var at := path + "." + str(field.get("id", "?"))
		if field.has("mapField"):
			var pair = field.mapField
			if not _module_map_field(fields, pair):
				_add(issues, "error", at + ".mapField", "must name a single map choice in the same row")
		if field.get("type") == "array" and field.get("of") == "record" and field.get("fields") is Array:
			_check_module_map_pairs(field.fields, at + ".fields", issues, depth + 1)

static func _module_map_field(fields: Array, id: Variant) -> bool:
	return id is String and not id.is_empty() and fields.any(func(field):
		return field is Dictionary and field.get("id") == id and field.get("kind") == "choice" \
			and field.get("source") == "map" and not bool(field.get("multiple", false)))

## C5：项目参考 views（[{view_id, image, pixel_size, hotspots}]）：view_id 非空唯一、
## image/pixel_size/hotspots 可选但类型必对（image 字符串、pixel_size 正数、hotspots 数组）。
## hotspot = {rect: [nx, ny, nw, nh] 全部 0..1, target: 对象（目标身份，编辑器不解释）}。
static func _validate_views(data: Dictionary, issues: Array[Dictionary]) -> void:
	var vs = data.get("views", null)
	if vs == null:
		return
	if not (vs is Array):
		_add(issues, "error", "views", "must be an array of {view_id, image, pixel_size, hotspots}")
		return
	var seen := {}
	var viewports := ScreenLayout.sizes(data)
	for j in (vs as Array).size():
		var e = (vs as Array)[j]
		var p := "views[%d]" % j
		if not (e is Dictionary):
			_add(issues, "error", p, "must be an object")
			continue
		var vid := str((e as Dictionary).get("view_id", ""))
		if vid == "" or seen.has(vid):
			_add(issues, "error", p + ".view_id", "must be non-empty and unique (seen: %s)" % vid)
		seen[vid] = true
		if e.has("layout"):
			ScreenLayout.validate(e.layout, viewports, p + ".layout", issues, ScreenLayout.modules(data), data.get("directViewTargets") == true, data.get("directMapTargets") == true)
		var img = (e as Dictionary).get("image", null)
		if img != null and not (img is String):
			_add(issues, "error", p + ".image", "must be a string")
		var psz = (e as Dictionary).get("pixel_size", null)
		if psz != null and ((not (psz is int or psz is float)) or psz <= 0):
			_add(issues, "error", p + ".pixel_size", "must be a positive number")
		var hs = (e as Dictionary).get("hotspots", null)
		if hs != null and not (hs is Array):
			_add(issues, "error", p + ".hotspots", "must be an array")
			continue
		for h in (hs as Array) if hs is Array else []:
			if not (h is Dictionary):
				_add(issues, "error", p + ".hotspots", "must be objects")
				continue
			var r = (h as Dictionary).get("rect", null)
			var rok: bool = r is Array and (r as Array).size() == 4 and ((r as Array)[0] is int or (r as Array)[0] is float) and ((r as Array)[1] is int or (r as Array)[1] is float) and ((r as Array)[2] is int or (r as Array)[2] is float) and ((r as Array)[3] is int or (r as Array)[3] is float)
			if not rok:
				_add(issues, "error", p + ".hotspots", "hotspot rect must be 4 numbers in 0..1")
				continue
			var r0: float = float((r as Array)[0])
			var r1: float = float((r as Array)[1])
			var r2: float = float((r as Array)[2])
			var r3: float = float((r as Array)[3])
			if r0 < 0.0 or r0 > 1.0 or r1 < 0.0 or r1 > 1.0 or r2 < 0.0 or r2 > 1.0 or r3 < 0.0 or r3 > 1.0:
				_add(issues, "error", p + ".hotspots", "hotspot rect must be normalized 0..1")
			var tgt = (h as Dictionary).get("target", null)
			if tgt != null and not (tgt is Dictionary):
				_add(issues, "error", p + ".hotspots", "hotspot target must be an object")
	return
