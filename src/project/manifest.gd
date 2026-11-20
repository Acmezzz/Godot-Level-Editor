class_name EditorManifest
## 游戏项目清单读取器：编辑器的唯一项目入口。
## 清单 = <游戏项目>/editor/editor_manifest.json，定义图层/瓦片/实体/功能声明/试玩命令。
## 加载链里还负责：补发缺失的分层身份码、并入内置种类、实体占位尺寸解析
## （editorSize → prefab 碰撞形状）、地图名/路径安全校验。

const BAD_NAME_CHARS := ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
const Validation := preload("res://src/project/manifest_validation.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const AudioDecls := preload("res://src/content/audio_decl.gd")
const TriggerDecls := preload("res://src/content/trigger_decl.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const ImageProbe := preload("res://src/assets/image_probe.gd")

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
	# 保留名不带扩展名（CON.json 同样是 Windows 保留设备名），COM/LPT 覆盖 1-9
	for reserved in ["con", "prn", "aux", "nul",
			"com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
			"lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"]:
		if stem == reserved or stem.begins_with(reserved + "."):
			return false
	return true

static func validate(data: Dictionary) -> Array[Dictionary]:
	return Validation.validate(data, str(data.get("_dir", "")))

## 读 <项目>/editor/editor_manifest.json；失败返回 {"_error": 消息}
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
	# 清单 version——缺省补 1，结构演进时有迁移锚点。
	# JSON 把数字解析成 float，不能按 `is int` 判断：那样每次加载都会把版本重置成 1。
	if not data.has("version") or not (data["version"] is int or data["version"] is float):
		data["version"] = 1
	else:
		data["version"] = int(data["version"])
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
	# 相对路径 → 绝对路径（assets[] 的图集绝对路径在图鉴归一化里算）
	data["_maps_dir"] = project_dir.path_join("maps")
	data["_warnings"] = warnings
	# 内置种类（如 trigger_zone）由编辑器提供，不需要游戏工程声明
	preload("res://src/assets/builtin_kinds.gd").merge_into(data)
	# 分层身份码：资产段。老清单资产没有就补发（保存清单时随 assets 写回）
	for a in data.get("assets", []):
		if a is Dictionary and str((a as Dictionary).get("kind", "")) == "entity" \
				and str((a as Dictionary).get("code", "")) == "":
			(a as Dictionary)["code"] = preload("res://src/content/content_id.gd").new_entity_code()
	# 功能段 / 字段段：同样补发（保存清单时随 functions 写回）。
	# 磁盘上的执行引用一律用码，人类名零兼容、无回退——查不到就是数据漂移。
	var issued := false
	issued = FunctionDecls.ensure_codes(data) or issued
	# 条件字段码：与功能字段共用一个码空间，避开功能字段已占用的码补发。
	issued = ConditionDecls.ensure_codes(data) or issued
	# 步骤池：条目码 + 步骤字段码补发（字段码避开功能/条件已占用）。
	issued = StepDecls.ensure_codes(data) or issued
	# 音频码：音频池条目补发执行码（保存清单时随 audio 写回）。
	issued = AudioDecls.ensure_codes(data) or issued
	# 时机码：triggers 池条目补发执行码（时机不带字段，不进字段码空间）。
	issued = TriggerDecls.ensure_codes(data) or issued
	# 补码只改内存：内容文件马上就会带着新码落盘，清单却要等下一次显式保存。
	# 留标记让「内容视图 Ctrl+S」顺手把清单也写回（D6），否则新码在磁盘上无对应对照。
	if issued:
		data["_codes_issued"] = true
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

## ---- 角色声明 ----
## role = 编辑器连接语义标签（画布标记用）；清单资产条目声明 role: portal/exit/landing/trigger。
## 零兼容：只认清单声明，不按资产 id 猜——没声明 role 的资产就是普通资产。

## 实体类型的连接语义；未声明返回空串（普通资产）
static func role_of(m: Dictionary, sid: String) -> String:
	return AssetDecl.role_of(m, sid)

## 该资产类型是否具有给定连接语义（普通资产恒 false）
static func has_role(m: Dictionary, sid: String, role: String) -> bool:
	return AssetDecl.has_role(m, sid, role)

## 某个资产在编辑器画布上的占位尺寸（像素）。
## 优先级：清单 editorSize → prefab 碰撞形状 → 0（消费方按 1 格兜底）
static func entity_editor_size(m: Dictionary, edef: Dictionary) -> Vector2:
	var es = edef.get("editorSize", null)
	if es is Array and (es as Array).size() >= 2:
		return Vector2(float(es[0]), float(es[1]))
	var prefab := str(edef.get("prefab", ""))
	if prefab == "":
		return Vector2.ZERO
	return ImageProbe.prefab_collision_size(m.get("_dir", ""), prefab)
