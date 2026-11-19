class_name EditorManifest
## 游戏项目清单读取器：编辑器的唯一项目入口。
## 清单 = <游戏项目>/editor/editor_manifest.json，定义图层/瓦片/实体/试玩命令。

const BAD_NAME_CHARS := ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
const Validation := preload("res://src/manifest_validation.gd")

## 变量替换：%mapfile% 当前地图文件；%projectpath% 游戏项目根目录
## 路径含空格且模板未自行加引号时自动补引号，避免经 cmd /c 后被拆成多个参数。
static func substitute_vars(cmd: String, map_file: String, project_path: String) -> String:
	return _substitute_one(_substitute_one(cmd, "%mapfile%", map_file), "%projectpath%", project_path)

static func _substitute_one(cmd: String, token: String, value: String) -> String:
	var idx := cmd.find(token)
	while idx >= 0:
		var quoted := idx > 0 and idx + token.length() < cmd.length() \
			and cmd[idx - 1] == "\"" and cmd[idx + token.length()] == "\""
		var repl := value
		if not quoted and value.contains(" "):
			repl = "\"" + value + "\""
		cmd = cmd.substr(0, idx) + repl + cmd.substr(idx + token.length())
		idx = cmd.find(token, idx + repl.length())
	return cmd

## 地图名是否安全：必须是纯文件名，不能包含分隔符、盘符或 ..，也不能是保留名
static func is_valid_map_name(name: String) -> bool:
	if name == "" or name != name.strip_edges():
		return false
	if name.contains("..") or name.begins_with("."):
		return false
	for ch in BAD_NAME_CHARS:
		if name.contains(ch):
			return false
	# Windows 文件名不能以点或空格结尾
	if name.ends_with("."):
		return false
	var stem := name.to_lower()
	for reserved in ["con", "prn", "aux", "nul"]:
		if stem == reserved or stem.begins_with(reserved + "."):
			return false
	return true

## 从项目文件夹读清单；失败返回带 _error 的字典
static func validate(data: Dictionary) -> Array[Dictionary]:
	return Validation.validate(data, str(data.get("_dir", "")))

static func load_from(project_dir: String) -> Dictionary:
	var p := project_dir.path_join("editor/editor_manifest.json")
	if not FileAccess.file_exists(p):
		return {"_error": "没找到 " + p}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {"_error": "无法读取 " + p}
	var text := f.get_as_text()
	f.close()
	var data = JSON.parse_string(text)
	if not (data is Dictionary):
		return {"_error": "清单 JSON 解析失败: " + p}
	data["_dir"] = project_dir
	# K22（批次 12）：清单 version——缺省补 1，结构演进时有迁移锚点
	if not data.has("version") or not (data["version"] is int):
		data["version"] = 1
	var issues := validate(data)
	var errors: Array[String] = []
	var warnings: Array[String] = []
	for issue in issues:
		var msg := "%s: %s" % [str(issue.path), str(issue.message)]
		if str(issue.severity) == "error":
			errors.append(msg)
		else:
			warnings.append(msg)
	if not errors.is_empty():
		return {"_error": "清单结构无效: " + "; ".join(errors), "_warnings": warnings}
	# 相对路径 → 绝对路径
	var base: String = project_dir
	for t in data.get("tiles", []):
		if str(t.get("atlas", "")) != "":
			t["atlas_abs"] = base.path_join(str(t.atlas))
	data["_maps_dir"] = base.path_join("maps")
	data["_warnings"] = warnings
	# 内置种类（如 trigger_zone）由编辑器提供，不需要游戏工程声明
	preload("res://src/content/builtin_kinds.gd").merge_into(data)
	# 分层身份码：实体段。老清单实体没有就补发（保存清单时随 entities 写回）
	for e in data.get("entities", []):
		if e is Dictionary and str(e.get("code", "")) == "":
			e["code"] = preload("res://src/content/content_id.gd").new_entity_code()
	# 功能段 / 字段段：同样补发（保存清单时随 functions 写回）。
	# 磁盘上的执行引用一律用码，人类名只负责显示与内容目录名，改名不破数据。
	ensure_codes(data)
	return data

## 试玩命令 = 模板 + 变量替换；清单可选 godotExe（支持 %projectpath%）覆盖可执行文件，
## 便于换机器/多人协作时不必改 playCommand。
static func resolved_play_command(m: Dictionary, map_file: String) -> String:
	var cmd := substitute_vars(m.get("playCommand", ""), map_file, m.get("_dir", ""))
	var exe_rel := str(m.get("godotExe", ""))
	if exe_rel == "":
		return cmd
	var exe := substitute_vars(exe_rel, map_file, m.get("_dir", ""))
	# 替换命令开头那段可执行文件（保留后续参数）
	var first := ""
	var rest := cmd
	var s := cmd.strip_edges()
	if s.begins_with("\""):
		var end := s.find("\"", 1)
		first = s.substr(1, end - 1) if end > 0 else ""
		rest = s.substr(end + 1) if end > 0 else ""
	else:
		var sp := s.find(" ")
		first = s if sp < 0 else s.substr(0, sp)
		rest = "" if sp < 0 else s.substr(sp)
	if first == "":
		return cmd
	return "\"" + exe + "\"" + rest

## 地图文件路径：<项目>/maps/<名>.json；名称非法或路径逃出 maps 目录时返回 ""
static func map_path(m: Dictionary, name: String) -> String:
	if not is_valid_map_name(name):
		return ""
	var maps_dir := str(m.get("_maps_dir", ""))
	if maps_dir == "":
		return ""
	var path := maps_dir.path_join(name + ".json").simplify_path()
	var root := maps_dir.simplify_path()
	if not path.begins_with(root + "/") and not path.begins_with(root + "\\"):
		return ""
	return path

## ---- 角色声明（实体-内容模型阶段 1） ----
## role = 编辑器连接语义标签；清单实体条目可声明 role: portal/exit/landing/trigger，
## 缺省按 scene id 回退识别（旧清单零改动兼容），声明优先于回退。
## 连接工具（配对/校验/选点/可达性）一律按 role 识别，不再硬编码 scene id。

const FALLBACK_ROLES := {
	"portal": "portal",
	"exit": "exit",
	"spawn_point": "landing",
	"trigger_zone": "trigger",
}

## 实体类型的连接语义；无声明且 id 不匹配连接原语时返回空串（普通实体）
static func role_of(m: Dictionary, sid: String) -> String:
	for ed in m.get("entities", []):
		if ed is Dictionary and str(ed.get("id", "")) == sid:
			return str(ed.get("role", FALLBACK_ROLES.get(sid, "")))
	return str(FALLBACK_ROLES.get(sid, ""))

## 该实体类型是否具有给定连接语义（普通实体恒 false）
static func has_role(m: Dictionary, sid: String, role: String) -> bool:
	return role_of(m, sid) == role

## 某个实体类型在编辑器画布上的占位尺寸（像素）。
## 优先级：清单 editorSize → prefab 碰撞形状 → 0（= 用缩略图原始尺寸）
static func entity_editor_size(m: Dictionary, edef: Dictionary) -> Vector2:
	var es = edef.get("editorSize", null)
	if es is Array and (es as Array).size() >= 2:
		return Vector2(float(es[0]), float(es[1]))
	var prefab := str(edef.get("prefab", ""))
	if prefab == "":
		return Vector2.ZERO
	return prefab_collision_size(m.get("_dir", ""), prefab)

## 把图像裁到不透明内容的最小外接框（四周透明留白削掉）。
## 预览图多是 96×96 画布 + 中间十几像素的小图，不裁的话在画布上就是个点。
## 留 1px 余量，避免裁得过紧导致相邻像素被过滤掉。全透明图原样返回。
static func trim_alpha(img: Image) -> Image:
	if img == null:
		return null
	var used := img.get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0:
		return img
	var pad := 1
	var x0 := maxi(used.position.x - pad, 0)
	var y0 := maxi(used.position.y - pad, 0)
	var x1 := mini(used.position.x + used.size.x + pad, img.get_width())
	var y1 := mini(used.position.y + used.size.y + pad, img.get_height())
	var rect := Rect2i(x0, y0, x1 - x0, y1 - y0)
	if rect.position == Vector2i.ZERO and rect.size == img.get_size():
		return img
	var out := Image.create(rect.size.x, rect.size.y, false, img.get_format())
	out.blit_rect(img, rect, Vector2i.ZERO)
	return out

## 从 .tscn 里读第一个 CollisionShape2D / RectangleShape2D 的尺寸（像素）。
## 找不到或解析失败返回 Vector2.ZERO。不做完整场景解析，只按行扫描关键字段。
static func prefab_collision_size(project_dir: String, prefab_rel: String) -> Vector2:
	var p: String = project_dir.path_join(prefab_rel) if project_dir != "" else prefab_rel
	if p == "" or not FileAccess.file_exists(p):
		return Vector2.ZERO
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return Vector2.ZERO
	var text := f.get_as_text()
	f.close()
	# 收集形状尺寸：Rectangle 用 size，Circle 用 radius*2，Capsule 用 radius*2 + height
	var sizes := {}
	var cur_id := ""
	var cur_kind := ""
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("[sub_resource type="):
			var idpos := line.find("id=\"")
			cur_id = ""
			cur_kind = ""
			if idpos >= 0:
				var rest := line.substr(idpos + 4)
				cur_id = rest.substr(0, rest.find("\""))
			if line.contains("RectangleShape2D"):
				cur_kind = "rect"
			elif line.contains("CircleShape2D"):
				cur_kind = "circle"
			elif line.contains("CapsuleShape2D"):
				cur_kind = "capsule"
			continue
		if cur_id == "" or cur_kind == "":
			continue
		if line.begins_with("size = Vector2("):
			var inner := line.trim_prefix("size = Vector2(").trim_suffix(")")
			var parts := inner.split(",")
			if parts.size() == 2:
				sizes[cur_id] = Vector2(parts[0].strip_edges().to_float(), parts[1].strip_edges().to_float())
		elif line.begins_with("radius = ") and cur_kind == "circle":
			var r := line.trim_prefix("radius = ").to_float()
			sizes[cur_id] = Vector2(r * 2.0, r * 2.0)
		elif line.begins_with("radius = ") and cur_kind == "capsule":
			sizes[cur_id + "_r"] = Vector2(line.trim_prefix("radius = ").to_float(), 0)
		elif line.begins_with("height = ") and cur_kind == "capsule":
			var h := line.trim_prefix("height = ").to_float()
			var rv: Vector2 = sizes.get(cur_id + "_r", Vector2(0, 0))
			sizes[cur_id] = Vector2(rv.x * 2.0, h)
		elif line.begins_with("[") and not line.begins_with("[sub_resource"):
			cur_id = ""
			cur_kind = ""
	# 找到第一个 CollisionShape2D 节点引用的 shape，取其 size
	for raw2 in text.split("\n"):
		var line2 := raw2.strip_edges()
		if line2.begins_with("[node") and line2.contains("CollisionShape2D"):
			# 在同一节点块内找 shape = SubResource("...")
			var idx := text.find(line2)
			if idx < 0:
				continue
			var block := text.substr(idx, 400)
			var spos := block.find("shape = SubResource(\"")
			if spos >= 0:
				var rest2 := block.substr(spos + 20)
				var sid := rest2.substr(0, rest2.find("\""))
				if sizes.has(sid):
					return sizes[sid]
	# 没有 CollisionShape2D：退回第一个矩形尺寸
	for k in sizes:
		return sizes[k]
	return Vector2.ZERO

## ---- 功能声明读取（批次 B） ----
## 顶层 functions 可为 {fnId: {name, fields, ...}} 或 [{id, ...}]。
## 两种写法归一成 {fnId: {id, code, name, fields}}；声明缺失返回空字典，不报错。
##
## 身份码规则（与实体 code 同款）：id 是人类名，只负责显示与内容目录名；
## code 是 4 位执行码，才是磁盘上的引用（地图 functions[].fn、内容 fields 的键）。
## 缺码的声明由 load_from 补发并随清单写回，所以改名永远不破数据。
## P2-10：归一化结果按「项目目录 + 清单指纹」缓存——content_editor 重建右栏时逐字段调用，
## function_decl/function_fields/function_name 每次都全量重扫是纯浪费。
## 指纹 = functions 声明的 JSON 串（清单保存后内容必变，天然失效）。
static var _fn_cache: Dictionary = {}
static var _fn_cache_key := ""

static func _fn_key(m: Dictionary) -> String:
	return str(m.get("_dir", "")) + "\u0001" + JSON.stringify(m.get("functions", null))

## 把两种写法统一成 [{id, body}] 对，便于就地补码。
## 只读视图：不往 body 里写 id（dict 形式本来就不存 id，凭空加键会让「加载+保存」多出噪音）。
static func _decl_items(decl) -> Array:
	var out: Array = []
	if decl is Dictionary:
		for key in (decl as Dictionary):
			var body = (decl as Dictionary)[key]
			if body is Dictionary:
				out.append({"id": str(key), "body": body})
	elif decl is Array:
		for item in (decl as Array):
			if item is Dictionary:
				out.append({"id": str((item as Dictionary).get("id", "")), "body": item})
	return out

## 补发缺失的功能码 / 字段码。就地修改清单，返回是否有改动。
## 只补「空」的，**不碰重复码**——重复是真实错误（两个声明同码 = 静默别名），
## 由校验报出来让人决定改哪个；这里替用户改一个反而会悄悄改变既有引用指向。
static func ensure_codes(m: Dictionary) -> bool:
	var Decls := preload("res://src/content/content_id.gd")
	var changed := false
	var seen := {}
	# 第一遍收集已占用的码，第二遍只给空的分配，避免新码撞上后面的既有码
	for pair in _decl_items(m.get("functions", null)):
		var d0: Dictionary = pair.body
		var c0 := str(d0.get("code", ""))
		if c0 != "":
			seen[c0] = true
		for fd0 in d0.get("fields", []) if d0.get("fields", []) is Array else []:
			var fc0 := str((fd0 as Dictionary).get("code", "")) if fd0 is Dictionary else ""
			if fc0 != "":
				seen[fc0] = true
	for pair in _decl_items(m.get("functions", null)):
		var d: Dictionary = pair.body
		if str(d.get("code", "")) == "":
			var code := Decls.new_fn_code()
			while seen.has(code):
				code = Decls.new_fn_code()
			d["code"] = code
			seen[code] = true
			changed = true
		for fd in d.get("fields", []) if d.get("fields", []) is Array else []:
			if not (fd is Dictionary):
				continue
			if str((fd as Dictionary).get("code", "")) == "":
				var fcode := Decls.new_fn_code()
				while seen.has(fcode):
					fcode = Decls.new_fn_code()
				(fd as Dictionary)["code"] = fcode
				seen[fcode] = true
				changed = true
	return changed

## 重复的功能码 / 字段码（校验用，不改数据）：[{scope, code}]
static func duplicate_codes(m: Dictionary) -> Array:
	var out: Array = []
	var seen := {}
	for pair in _decl_items(m.get("functions", null)):
		var d: Dictionary = pair.body
		var code := str(d.get("code", ""))
		if code != "":
			if seen.has(code):
				out.append({"scope": str(pair.id), "code": code})
			seen[code] = true
		var fseen := {}
		for fd in d.get("fields", []) if d.get("fields", []) is Array else []:
			if not (fd is Dictionary):
				continue
			var fcode := str((fd as Dictionary).get("code", ""))
			if fcode == "":
				continue
			if fseen.has(fcode):
				out.append({"scope": str(pair.id) + "." + str((fd as Dictionary).get("id", "")), "code": fcode})
			fseen[fcode] = true
	return out

static func functions(m: Dictionary) -> Dictionary:
	var key := _fn_key(m)
	if _fn_cache_key == key:
		return _fn_cache
	var out := {}
	var decl = m.get("functions", null)
	if decl is Dictionary:
		for fid_key in (decl as Dictionary):
			var fid := str(fid_key)
			if fid == "":
				continue
			var body = (decl as Dictionary)[fid_key]
			var src: Dictionary = body if body is Dictionary else {}
			out[fid] = {
				"id": fid,
				"code": str(src.get("code", "")),
				"name": str(src.get("name", fid)) if str(src.get("name", "")) != "" else fid,
				"fields": src.get("fields", []) if src.get("fields", []) is Array else [],
			}
	elif decl is Array:
		for item in (decl as Array):
			if not (item is Dictionary):
				continue
			var src2: Dictionary = item
			var fid2 := str(src2.get("id", ""))
			if fid2 == "":
				continue
			out[fid2] = {
				"id": fid2,
				"code": str(src2.get("code", "")),
				"name": str(src2.get("name", fid2)) if str(src2.get("name", "")) != "" else fid2,
				"fields": src2.get("fields", []) if src2.get("fields", []) is Array else [],
			}
	_fn_cache = out
	_fn_cache_key = key
	return out

## 单个功能声明；缺失时返回空字典。
static func function_decl(m: Dictionary, fn_id: String) -> Dictionary:
	var all := functions(m)
	return all.get(fn_id, {}) if all.get(fn_id, {}) is Dictionary else {}

## 功能字段声明数组（与实体 stats/fields 同构）；缺失时返回空数组。
static func function_fields(m: Dictionary, fn_id: String) -> Array:
	return function_decl(m, fn_id).get("fields", [])

## 功能显示名；缺省用 fn_id。
static func function_name(m: Dictionary, fn_id: String) -> String:
	return str(function_decl(m, fn_id).get("name", fn_id))

## 功能 id（人类名）→ 执行码；缺失返回空串。
static func fn_code(m: Dictionary, fn_id: String) -> String:
	return str(function_decl(m, fn_id).get("code", ""))

## 执行码 → 功能 id；未知码返回空串（调用方据此上报漂移）。
static func fn_id_of(m: Dictionary, code: String) -> String:
	if code == "":
		return ""
	for fid in functions(m):
		if str((functions(m)[fid] as Dictionary).get("code", "")) == code:
			return str(fid)
	return ""

## 字段 id（人类名）→ 字段码；缺失返回空串。
static func field_code(m: Dictionary, fn_id: String, field_id: String) -> String:
	for fd in function_fields(m, fn_id):
		if fd is Dictionary and str((fd as Dictionary).get("id", "")) == field_id:
			return str((fd as Dictionary).get("code", ""))
	return ""

## 字段码 → 字段声明；未知码返回空字典。
static func field_decl_by_code(m: Dictionary, fn_id: String, code: String) -> Dictionary:
	if code == "":
		return {}
	for fd in function_fields(m, fn_id):
		if fd is Dictionary and str((fd as Dictionary).get("code", "")) == code:
			return fd
	return {}

## 解析磁盘上的功能引用（可能是码，也可能是旧数据的裸人类名）。
## 返回 {id, code, known}；known=false 表示清单里查不到（数据漂移，调用方上报）。
## 兼容顺序：先按码查；查不到再按人类名查（旧地图/旧内容文件）；都不中则原样回填。
static func resolve_fn(m: Dictionary, raw: String) -> Dictionary:
	if raw == "":
		return {"id": "", "code": "", "known": false}
	var by_code := fn_id_of(m, raw)
	if by_code != "":
		return {"id": by_code, "code": raw, "known": true}
	var decl := function_decl(m, raw)
	if not decl.is_empty():
		return {"id": raw, "code": str(decl.get("code", "")), "known": true}
	return {"id": raw, "code": raw, "known": false}

## 解析内容文件里的字段键：新数据是字段码，旧数据是字段 id。
## 返回对应声明；两边都不中返回空字典（= 未声明字段，保留原值但不上 UI）。
static func resolve_field(m: Dictionary, fn_id: String, raw_key: String) -> Dictionary:
	var by_code := field_decl_by_code(m, fn_id, raw_key)
	if not by_code.is_empty():
		return by_code
	for fd in function_fields(m, fn_id):
		if fd is Dictionary and str((fd as Dictionary).get("id", "")) == raw_key:
			return fd
	return {}

## 人类名 ↔ 执行码对照表（Markdown），保存清单时写到 editor/CODES.md。
## 游戏侧启动时读清单即可重建同样的运行时映射；本表是给人看的快照 + git diff 友好。
## 另一用途：游戏侧改码后 diff 这张表就能看清「改了名没改码」还是「换了码」。
static func codes_doc(m: Dictionary) -> String:
	var L: Array[String] = []
	L.append("# 码表")
	L.append("")
	L.append("人类名 ↔ 执行码对照，编辑器在保存清单时自动生成（勿手改）。")
	L.append("磁盘执行引用（地图 functions[].fn、内容 \"function\"、内容 fields 的键）写码；")
	L.append("人类 id 只负责显示与内容目录名。游戏侧启动时读清单重建同样的映射。")
	L.append("")
	var all := functions(m)
	if all.is_empty():
		# 无功能声明：只留说明，避免空表让游戏侧误以为码表缺失
		L.append("（清单未声明功能。）")
		return "\n".join(L)
	L.append("## 功能")
	L.append("")
	L.append("| 码 | 人类 id | 显示名 |")
	L.append("|----|---------|--------|")
	for fid in all:
		var d: Dictionary = all[fid]
		L.append("| %s | %s | %s |" % [str(d.get("code", "")), str(fid), str(d.get("name", fid))])
	L.append("")
	L.append("## 字段")
	for fid in all:
		var fields: Array = (all[fid] as Dictionary).get("fields", [])
		if fields.is_empty():
			continue
		L.append("")
		L.append("### %s" % str(fid))
		L.append("")
		L.append("| 码 | 人类 id | kind | type |")
		L.append("|----|---------|------|------|")
		for fd in fields:
			if not (fd is Dictionary):
				continue
			var d2: Dictionary = fd
			L.append("| %s | %s | %s | %s |" % [
				str(d2.get("code", "")), str(d2.get("id", "")),
				str(d2.get("kind", "")), str(d2.get("type", ""))])
	return "\n".join(L)
