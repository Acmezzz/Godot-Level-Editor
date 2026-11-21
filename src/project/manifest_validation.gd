extends RefCounted
## 清单结构与能力校验：assets/functions/conditions/steps/audio 的类型与
## id/码唯一性（图层已退役为地图 meta.layers，归 map_data_validation 校验）、
## 字段 kind 必须显式 input/choice、挂载功能必须已声明、功能引用的条件必须已声明、
## 功能/条件/步骤字段码同空间唯一、步骤码与音频码池内唯一。

const FunctionDecls := preload("res://src/content/function_decl.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const AudioDecls := preload("res://src/content/audio_decl.gd")
const TriggerDecls := preload("res://src/content/trigger_decl.gd")
const CollisionTypes := preload("res://src/assets/collision_types.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")

## input 字段类型白名单（与 field_widgets 一一对应）：新增类型必须同时有控件分支。
const INPUT_TYPES := ["string", "int", "float", "bool", "color", "vector2", "range", "asset_ref", "array"]

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
	if data.has("functions"):
		_validate_functions(data, issues)
	if data.has("conditions"):
		_validate_conditions(data, issues)
	if data.has("steps"):
		_validate_steps(data, issues)
	if data.has("audio"):
		_validate_audio(data, issues)
	if data.has("triggers"):
		_validate_triggers(data, issues)
	if data.has("collisionTypes"):
		_validate_collision_types(data, issues)
	_validate_playtest(data, issues)
	# tileSize：正数（正方形格）或 [w,h] 两正数（矩形格，R-01 批 1c）
	var tile_size = data.get("tileSize", 16)
	if tile_size is Array:
		var bad := (tile_size as Array).size() != 2
		for v in (tile_size as Array):
			if not (v is int or v is float) or float(v) <= 0.0:
				bad = true
		if bad:
			_add(issues, "error", "tileSize", "must be a positive number or [w, h] of two positive numbers")
	elif not (tile_size is int or tile_size is float) or float(tile_size) <= 0.0:
		_add(issues, "error", "tileSize", "must be a positive number or [w, h] of two positive numbers")
	# C-15 混投影：画布口径是「任一 tile 资产声明非正交投影即整图按它」，混用会静默错位——警告
	var projs := {}
	var assets_arr = data.get("assets", null)
	if assets_arr is Array:
		for a in (assets_arr as Array):
			if not (a is Dictionary) or str((a as Dictionary).get("kind", "")) != "scene" \
					or str((a as Dictionary).get("shape", "")) != "tile":
				continue
			projs[str((a as Dictionary).get("gridProjection", "orthogonal"))] = true
	if projs.size() > 1:
		_add(issues, "warning", "assets",
			"mixed gridProjection: canvas renders isometric if ANY tile asset declares it; orthogonal assets will misalign")
	_validate_top_level(data, issues)
	return issues

## 顶层可选键结构校验（缺键走缺省，存在即校验形态）。
static func _validate_top_level(data: Dictionary, issues: Array[Dictionary]) -> void:
	for k in ["playCommand", "godotExe", "contentDir"]:
		if data.has(k) and not (data[k] is String):
			_add(issues, "error", k, "must be a string")
	if data.has("contentDir"):
		var cd := str(data["contentDir"])
		if cd != "" and (cd.begins_with("/") or cd.begins_with("\\") or cd.contains("..")):
			_add(issues, "error", "contentDir", "must be a relative path without '..'")
	if data.has("screenSize"):
		var ss = data["screenSize"]
		if not (ss is Array) or (ss as Array).size() != 2 \
				or not ((ss as Array)[0] is int or (ss as Array)[0] is float) \
				or not ((ss as Array)[1] is int or (ss as Array)[1] is float):
			_add(issues, "error", "screenSize", "must be [w, h] numbers")

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
	# 功能 id 同时是内容目录名与内容 ID 第四段——字符集受限（ContentStore 同一规则），
	# 非法字符集的声明能过结构校验但内容读写全废，必须在加载期就报出来
	for fid2 in FunctionDecls.functions(data):
		if not ContentStore.is_valid_id(fid2):
			_add(issues, "error", "functions.%s" % str(fid2),
				"function id may only contain letters/digits/_/./- (content dir + id segment)")
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
				if not INPUT_TYPES.has(typ):
					_add(issues, "error", "functions.%s.fields.%s" % [str(fid), field_id],
						"input type must be one of: " + ", ".join(INPUT_TYPES))
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
		# 功能声明的 triggers 是时机 id 白名单；按 id 引用时机池，未声明 = 错误。
		var trs = d.get("triggers", [])
		if not (trs is Array):
			_add(issues, "error", "functions.%s.triggers" % str(fid), "must be an array of trigger ids")
		else:
			for t0 in trs:
				var t0s := str(t0)
				if t0s == "" or not TriggerDecls.triggers(data).has(t0s):
					_add(issues, "error", "functions.%s.triggers" % str(fid),
						"trigger \"%s\" is not declared" % t0s)
		var timing = d.get("timing", null)
		if timing != null:
			if not (timing is Dictionary):
				_add(issues, "error", "functions.%s.timing" % str(fid), "must be an object")
			elif str((timing as Dictionary).get("mode", "")) != "" \
					and not ["instant", "duration", "continuous"].has(str((timing as Dictionary).get("mode"))):
				_add(issues, "error", "functions.%s.timing.mode" % str(fid),
					"must be instant / duration / continuous")
		# R-10 时间基：seconds（缺省）/ frames / beats——时间轴刻度/吸附单位随声明
		var tb := str(d.get("timebase", "seconds"))
		if str(d.get("timebase", null)) != "" and d.get("timebase", null) != null \
				and not ["seconds", "frames", "beats"].has(tb):
			_add(issues, "error", "functions.%s.timebase" % str(fid),
				"must be seconds / frames / beats")
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
				if not INPUT_TYPES.has(typ):
					_add(issues, "error", "conditions.%s.fields.%s" % [cid, field_id],
						"input type must be one of: " + ", ".join(INPUT_TYPES))
	# 字段码跨池查重：条件字段与功能字段共存于同一份内容 fields，同码 = 静默合并。
	# 功能池内部的字段码重复由 duplicate_codes（本文件上方）已报过——这里只收集不重报
	var fcodes := {}
	for fid in FunctionDecls.functions(data):
		for fd1 in (FunctionDecls.functions(data)[fid] as Dictionary).get("fields", []):
			if fd1 is Dictionary:
				var fc := str((fd1 as Dictionary).get("code", ""))
				if fc != "":
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

## 音频池：id 非空唯一（array 写法查重）、码池内唯一（重复=静默别名，报错）、
## path 缺失只警告（条目占位合法，播放归游戏侧）。
static func _validate_audio(data: Dictionary, issues: Array[Dictionary]) -> void:
	var decl = data.get("audio", null)
	if not (decl is Dictionary or decl is Array):
		_add(issues, "error", "audio", "must be an object or an array")
		return
	var ids := {}
	var codes := {}
	for pair in AudioDecls._decl_items(decl):
		var aid := str(pair.id)
		if aid == "" or ids.has(aid):
			_add(issues, "error", "audio",
				"audio ids must be non-empty and unique (seen: %s)" % aid)
		ids[aid] = true
		var body: Dictionary = pair.body
		var c := str(body.get("code", ""))
		if c != "" and codes.has(c):
			_add(issues, "error", "audio", "duplicate code %s (%s)" % [c, aid])
		codes[c] = true
		if str(body.get("path", "")) == "":
			_add(issues, "warning", "audio.%s" % aid, "audio path is empty")

## 时机池：id 非空唯一（array 写法查重）、码池内唯一（重复 = 静默别名，报错）。
## 时机不含字段，字段码空间完全不碰它。
static func _validate_triggers(data: Dictionary, issues: Array[Dictionary]) -> void:
	var decl = data.get("triggers", null)
	if not (decl is Dictionary or decl is Array):
		_add(issues, "error", "triggers", "must be an object or an array")
		return
	var ids := {}
	var codes := {}
	for pair in TriggerDecls._decl_items(decl):
		var tid := str(pair.id)
		if tid == "" or ids.has(tid):
			_add(issues, "error", "triggers",
				"trigger ids must be non-empty and unique (seen: %s)" % tid)
		ids[tid] = true
		var body: Dictionary = pair.body
		var c := str(body.get("code", ""))
		if c != "" and codes.has(c):
			_add(issues, "error", "triggers", "duplicate code %s (%s)" % [c, tid])
		codes[c] = true

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
		if body.has("color") and not (body.color is String):
			_add(issues, "error", "collisionTypes", "color must be a #rrggbb string")

## 试玩声明（v7）：清单 playtest.flags/params 驱动试玩面板（替代写死的 dash/glide/hp）。
## flags = {id, name, arg}（arg 为启动时原样追加的 CLI 参数）；params = {id, name, arg(含 %d), def, min, max}。
## 未声明 playtest = 面板空态提示；结构错报 error，不拦载入（试玩是编辑期功能）。
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

## 步骤池：id 非空唯一（array 写法查重）、条目码池内唯一、字段 id/kind/type 合法、
## 步骤字段码与功能/条件字段同空间查重（跨池同码 = 静默合并，报错）。
static func _validate_steps(data: Dictionary, issues: Array[Dictionary]) -> void:
	var decl = data.get("steps", null)
	if not (decl is Dictionary or decl is Array):
		_add(issues, "error", "steps", "must be an object or an array")
		return
	var sseen := {}
	if decl is Array:
		for item in decl:
			if not (item is Dictionary):
				_add(issues, "error", "steps", "entries must be objects")
				continue
			var sid0 := str((item as Dictionary).get("id", ""))
			if sid0 == "" or sseen.has(sid0):
				_add(issues, "error", "steps",
					"step ids must be non-empty and unique (array form, seen: %s)" % sid0)
			sseen[sid0] = true
	elif decl is Dictionary:
		for k0 in (decl as Dictionary).keys():
			if str(k0) == "":
				_add(issues, "error", "steps", "step ids must be non-empty (dict form)")
			elif not ((decl as Dictionary)[k0] is Dictionary):
				_add(issues, "error", "steps", "step entries must be objects (dict form, key: %s)" % str(k0))
	# 条目码池内唯一（内容 steps[].step 存码，重复 = 静默别名）
	var ecodes := {}
	for pair in StepDecls._decl_items(decl):
		var ec := str((pair.body as Dictionary).get("code", ""))
		if ec != "":
			if ecodes.has(ec):
				_add(issues, "error", "steps", "duplicate step code %s (%s)" % [ec, str(pair.id)])
			ecodes[ec] = true
	# 字段 id / kind / type（归一化视图逐步骤查）
	for sid in StepDecls.steps(data):
		var d: Dictionary = StepDecls.steps(data)[sid]
		var fseen := {}
		for fd in d.get("fields", []):
			if not (fd is Dictionary):
				_add(issues, "error", "steps.%s.fields" % sid, "entries must be objects")
				continue
			var field_id := str((fd as Dictionary).get("id", ""))
			if field_id == "" or fseen.has(field_id):
				_add(issues, "error", "steps.%s.fields" % sid,
					"field ids must be non-empty and unique (seen: %s)" % field_id)
			fseen[field_id] = true
			var kind := str((fd as Dictionary).get("kind", ""))
			if kind != "input" and kind != "choice":
				_add(issues, "error", "steps.%s.fields.%s" % [sid, field_id],
					"field kind must be \"input\" or \"choice\"")
			elif kind == "input":
				var typ := str((fd as Dictionary).get("type", ""))
				if not INPUT_TYPES.has(typ):
					_add(issues, "error", "steps.%s.fields.%s" % [sid, field_id],
						"input type must be one of: " + ", ".join(INPUT_TYPES))
	# 步骤字段码跨池查重：避开功能 + 条件已占用的码
	var fcodes := {}
	for fid in FunctionDecls.functions(data):
		for fd1 in (FunctionDecls.functions(data)[fid] as Dictionary).get("fields", []):
			if fd1 is Dictionary and str((fd1 as Dictionary).get("code", "")) != "":
				fcodes[str((fd1 as Dictionary).get("code", ""))] = true
	for cid2 in ConditionDecls.conditions(data):
		for fd2 in (ConditionDecls.conditions(data)[cid2] as Dictionary).get("fields", []):
			if fd2 is Dictionary and str((fd2 as Dictionary).get("code", "")) != "":
				fcodes[str((fd2 as Dictionary).get("code", ""))] = true
	for sid3 in StepDecls.steps(data):
		for fd3 in (StepDecls.steps(data)[sid3] as Dictionary).get("fields", []):
			if not (fd3 is Dictionary):
				continue
			var fc3 := str((fd3 as Dictionary).get("code", ""))
			if fc3 != "" and fcodes.has(fc3):
				_add(issues, "error", "steps.%s.fields" % sid3,
					"duplicate field code across pools: " + fc3)
			if fc3 != "":
				fcodes[fc3] = true

## 资产表：kind/shape 合法、id 唯一、scene 的图集或图片二选一、entity 的呈现二选一、
## 挂载功能必须已声明、palette 条目结构。
static func _validate_assets(data: Dictionary, project_dir: String, issues: Array[Dictionary]) -> void:
	var assets: Array = data.get("assets", [])
	var ids := {}
	var codes := {}
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
			_validate_scene_asset(ad, path, project_dir, issues)
		else:
			_validate_entity_asset(data, ad, path, codes, issues)

static func _validate_scene_asset(ad: Dictionary, path: String, project_dir: String, issues: Array[Dictionary]) -> void:
	var shape := str(ad.get("shape", "tile"))
	if shape != "tile" and shape != "image":
		_add(issues, "error", path + ".shape", "scene shape must be \"tile\" or \"image\"")
		return
	var atlas := str(ad.get("atlas", ""))
	var texture := str(ad.get("texture", ""))
	if shape == "tile":
		if atlas == "":
			_add(issues, "error", path + ".atlas", "tile shape needs an atlas")
		elif project_dir != "" and atlas.contains(".."):
			_add(issues, "error", path + ".atlas", "path cannot traverse outside the project")
		elif project_dir != "" and not FileAccess.file_exists(project_dir.path_join(atlas)):
			_add(issues, "warning", path + ".atlas", "atlas file not found on disk")
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
	# 网格投影枚举校验；混投影（不同投影混用）在 validate() 尾部统一给警告
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
			for fid in ad.functions:
				if not (fid is String) or str(fid) == "":
					_add(issues, "error", path + ".functions", "mounts must be non-empty function ids")
				elif not pool.has(str(fid)):
					_add(issues, "error", path + ".functions",
						"mounted function is not declared: " + str(fid))
	if ad.has("frames") and not (ad.frames is Array):
		_add(issues, "error", path + ".frames", "must be an array of texture paths")
	var fields := {}
	for field in ad.get("fields", []) if ad.get("fields", []) is Array else []:
		if not (field is Dictionary):
			_add(issues, "error", path + ".fields", "entries must be objects")
			continue
		var fid2 := str((field as Dictionary).get("id", ""))
		if fid2 == "" or fields.has(fid2):
			_add(issues, "error", path + ".fields", "field ids must be non-empty and unique")
		fields[fid2] = true

static func _add(issues: Array[Dictionary], severity: String, path: String, message: String) -> void:
	issues.append({"severity": severity, "path": path, "message": message})
