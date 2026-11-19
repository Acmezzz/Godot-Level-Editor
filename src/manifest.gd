class_name EditorManifest
## 游戏项目清单读取器：编辑器的唯一项目入口。
## 清单 = <游戏项目>/editor/editor_manifest.json，定义图层/瓦片/实体/试玩命令。

const BAD_NAME_CHARS := ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
const Validation := preload("res://src/manifest_validation.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")

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
	# 磁盘上的执行引用一律用码，人类名零兼容、无回退——查不到就是数据漂移。
	FunctionDecls.ensure_codes(data)
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
