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
const CellGraph := preload("res://src/map/cell_graph.gd")
const ScreenLayout := preload("res://src/project/screen_layout.gd")
const GamePreview := preload("res://src/project/game_preview.gd")
const WorldLayout := preload("res://src/project/world_layout.gd")
const MapGenerators := preload("res://src/project/map_generators.gd")

## input 字段类型白名单（与 field_widgets 一一对应）：新增类型必须同时有控件分支。
const INPUT_TYPES := ["string", "int", "float", "bool", "color", "vector2", "range", "asset_ref", "array", "port_ref", "viewport_ref", "edge_ref"]

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
	_validate_content_field_shapes(data, issues)
	if data.has("audio"):
		_validate_audio(data, issues)
	if data.has("triggers"):
		_validate_triggers(data, issues)
	if data.has("collisionTypes"):
		_validate_collision_types(data, issues)
	_validate_playtest(data, issues)
	issues.append_array(GamePreview.declaration_issues(data))
	issues.append_array(WorldLayout.issues(data))
	issues.append_array(MapGenerators.issues(data))
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
	# C-15 混投影：画布口径是「任一 tile 资产声明非正交投影即整图按它」，混用会静默错位——警告。
	# B1：指名具体资产与投影，否则「混了」这句话无从下手。
	var projs := {}
	var proj_assets := {}
	var assets_arr = data.get("assets", null)
	if assets_arr is Array:
		for a in (assets_arr as Array):
			if not (a is Dictionary) or str((a as Dictionary).get("kind", "")) != "scene" \
					or str((a as Dictionary).get("shape", "")) != "tile":
				continue
			var p := str((a as Dictionary).get("gridProjection", "orthogonal"))
			projs[p] = true
			if not proj_assets.has(p):
				proj_assets[p] = []
			(proj_assets[p] as Array).append(str((a as Dictionary).get("id", "")))
	if projs.size() > 1:
		var detail: Array[String] = []
		for p in proj_assets:
			detail.append("%s: %s" % [str(p), ", ".join(PackedStringArray(proj_assets[p]))])
		_add(issues, "warning", "assets",
			"mixed gridProjection: canvas renders isometric if ANY tile asset declares it; orthogonal assets will misalign (" + "; ".join(detail) + ")")
	_validate_top_level(data, issues)
	for issue in CellGraph.validate_edge_types(data):
		_add(issues, "error", issue.path, issue.message)
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
	_validate_viewports(data, issues)
	_validate_views(data, issues)
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
	# 功能 id 同时是内容目录名与内容 ID 第四段——字符集必须过**目录名**规则（C07：
	# 与 ContentStore.is_valid_kind 同一条权威规则）。`dlg.one` 这类带点的 id 会被
	# 内容目录校验拒绝，若这里放行就是「声明能载入、第一次编辑才失败」。
	for fid2 in FunctionDecls.functions(data):
		if not ContentStore.is_valid_kind(fid2):
			_add(issues, "error", "functions.%s" % str(fid2),
				"function id must be a valid content folder name: letters/digits/_/- (no dot, no leading/trailing dash)")
	var dup := FunctionDecls.duplicate_codes(data)
	for d in dup:
		_add(issues, "error", "functions", "duplicate code %s (%s)" % [str(d.get("code", "")), str(d.get("scope", ""))])
	var norm: Dictionary = FunctionDecls.functions(data)
	for fid in norm:
		var d: Dictionary = norm[fid]
		if d.has("repeatable") and not d.repeatable is bool:
			_add(issues, "error", "functions.%s.repeatable" % fid, "must be a boolean")
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
				elif typ == "array":
					_validate_array_field("functions.%s.fields.%s" % [fid, field_id], fd, issues)
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
		_validate_time_preview(data, d, str(fid), issues)
## timePreview 声明校验（D2）：引用必须指向本功能已声明的字段 ID / 已声明的步骤 ID；
## subdivisionsPerBeat 必须是正整数。缺声明项不算错误（预览退化为原单位编辑），
## 但**写错引用**（引用了不存在的字段/步骤）必须报出来——那是配置错误不是缺省。
static func _validate_time_preview(data: Dictionary, fn_decl: Dictionary, fid: String,
		issues: Array[Dictionary]) -> void:
	var tp = fn_decl.get("timePreview", null)
	if tp == null:
		return
	if not (tp is Dictionary):
		_add(issues, "error", "functions.%s.timePreview" % fid, "must be an object")
		return
	var tpd: Dictionary = tp
	var fids := {}
	for fd in (fn_decl.get("fields", []) as Array) if fn_decl.get("fields", []) is Array else []:
		if fd is Dictionary:
			fids[str((fd as Dictionary).get("id", ""))] = true
	for key in ["fpsField", "audioField", "offsetField", "frameAssetField"]:
		if not tpd.has(key):
			continue
		var val := str(tpd.get(key, ""))
		if val == "":
			continue
		if not fids.has(val):
			_add(issues, "error", "functions.%s.timePreview.%s" % [fid, key],
				"field \"%s\" is not declared on this function" % val)
	var tempo_step := str(tpd.get("tempoStep", ""))
	if tempo_step != "":
		var StepDecls := preload("res://src/content/step_decl.gd")
		var sd: Dictionary = StepDecls.step_decl(data, tempo_step)
		if sd.is_empty():
			_add(issues, "error", "functions.%s.timePreview.tempoStep" % fid,
				"step \"%s\" is not declared" % tempo_step)
		else:
			var bpm_field := str(tpd.get("bpmField", ""))
			if bpm_field != "":
				var sids := {}
				for fd2 in (sd.get("fields", []) as Array) if sd.get("fields", []) is Array else []:
					if fd2 is Dictionary:
						sids[str((fd2 as Dictionary).get("id", ""))] = true
				if not sids.has(bpm_field):
					_add(issues, "error", "functions.%s.timePreview.bpmField" % fid,
						"field \"%s\" is not declared on step \"%s\"" % [bpm_field, tempo_step])
	if tpd.has("subdivisionsPerBeat"):
		var spb = tpd.get("subdivisionsPerBeat")
		if not _is_positive_integer(spb):
			_add(issues, "error", "functions.%s.timePreview.subdivisionsPerBeat" % fid,
				"must be a positive integer")

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
		if body.has("previewPath") and (not body.previewPath is String
				or AudioDecls.preview_relative_path(body.previewPath) == ""):
			_add(issues, "error", "audio.%s.previewPath" % aid, "must be a non-empty project-relative audio path")

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
		_add(issues, "warning", "playtest.executable", "empty executable: falls back to playCommand")
	for feature in ["report", "projectEntry"]:
		if not pt2.has(feature):
			continue
		if not pt2[feature] is bool:
			_add(issues, "error", "playtest." + feature, "must be a boolean")
		elif pt2[feature] and (not exe is String or str(exe).strip_edges() == ""):
			_add(issues, "error", "playtest." + feature, "requires a structured executable launch")
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
		_validate_ports(ad, path, issues)
		_validate_port_sources(ad, path, issues)
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
	var fields := {}
	for field in ad.get("fields", []) if ad.get("fields", []) is Array else []:
		if not (field is Dictionary):
			_add(issues, "error", path + ".fields", "entries must be objects")
			continue
		var fid2 := str((field as Dictionary).get("id", ""))
		if fid2 == "" or fields.has(fid2):
			_add(issues, "error", path + ".fields", "field ids must be non-empty and unique")
		fields[fid2] = true
		if field.get("kind") == "input" and not field.get("type", "") in ["entity_ref", "map_ref"]:
			var typ := str(field.get("type", ""))
			var field_path := "%s.fields.%s" % [path, fid2]
			if not INPUT_TYPES.has(typ):
				_add(issues, "error", field_path, "input type must be one of: " + ", ".join(INPUT_TYPES))
			elif typ == "array":
				_validate_array_field(field_path, field, issues)

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
		if fd.has("contentMapContext"):
			var mode = fd.contentMapContext
			var at := child + ".contentMapContext"
			if not mode is String or str(mode) not in ["independent", "inherit", "paired"]:
				_add(issues, "error", at, "must be independent, inherit or paired")
			elif not str(fd.get("source", "")).begins_with("content:"):
				_add(issues, "error", at, "requires a content: choice source")
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

## C1（§7.4）：array 字段声明校验。of: record 要求 fields 数组：子字段对象、id 非空唯一、
## kind=input/choice、type 合法（input 的 type 走 INPUT_TYPES 白名单）；嵌套 record 递归（限深 4）。
## 已有标量数组（of 缺省或标量/choice）不受影响——只新增 record 形的报错，不改旧声明语义。
static func _validate_array_field(path: String, fd: Dictionary,
		issues: Array[Dictionary], depth := 0) -> void:
	if depth > 4:
		_add(issues, "error", path,
			"record nesting too deep (max 4)")
		return
	var of := str(fd.get("of", ""))
	if of != "record":
		return
	var fl = fd.get("fields", null)
	if not (fl is Array) or (fl as Array).is_empty():
		_add(issues, "error", path,
			"of: record requires a non-empty fields array")
		return
	var seen := {}
	for sub in (fl as Array):
		if not (sub is Dictionary):
			_add(issues, "error", path,
				"record fields entries must be objects")
			continue
		var sid := str((sub as Dictionary).get("id", ""))
		if sid == "" or seen.has(sid):
			_add(issues, "error", path,
				"record sub-field ids must be non-empty and unique (seen: %s)" % sid)
		seen[sid] = true
		var skind := str((sub as Dictionary).get("kind", ""))
		if skind != "input" and skind != "choice":
			_add(issues, "error", path,
				"record sub-field kind must be input or choice (seen: %s)" % skind)
		elif skind == "input":
			var styp := str((sub as Dictionary).get("type", ""))
			if styp == "array":
				_validate_array_field(path + ".fields." + sid, sub as Dictionary, issues, depth + 1)
			elif not INPUT_TYPES.has(styp):
				_add(issues, "error", path,
					"record sub-field type must be one of: " + ", ".join(INPUT_TYPES))
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
			ScreenLayout.validate(e.layout, viewports, p + ".layout", issues)
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
