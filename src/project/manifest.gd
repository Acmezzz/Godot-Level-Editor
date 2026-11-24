class_name EditorManifest
## 游戏项目清单读取器：编辑器的唯一项目入口。
## 清单 = <游戏项目>/editor/editor_manifest.json，是**声明池**：资产（图集/图片/实体）、
## 功能/条件/步骤/音频/时机声明、碰撞类型池、试玩配置。**图层不在清单里**——每张地图自带 meta.layers。
## 加载链：校验（manifest_validation）→ 补发缺失的分层身份码（ensure_codes）→ 并入内置种类
## （trigger_zone）→ 派生路径（_dir/_maps_dir、atlas_abs）→ 实体占位尺寸解析
## （editorSize → 1 格）。地图名/路径安全校验也在这里（is_valid_map_name）。
## 写盘前剥内部键（`_` 前缀、atlas_abs、内置种类）——清单是游戏侧读的公共契约，不留编辑器私有状态。

const DeclarationPool := preload("res://src/content/declaration_pool.gd")
const BAD_NAME_CHARS := ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
const Validation := preload("res://src/project/manifest_validation.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const AudioDecls := preload("res://src/content/audio_decl.gd")
const TriggerDecls := preload("res://src/content/trigger_decl.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")

## 参数数组用的替换：原样内联，不加引号（A6）。
## OS.create_process 直接收 argv，引号会变成值的一部分；路径含空格正是数组分段的价值所在。
static func substitute_vars_raw(arg: String, map_file: String, project_path: String) -> String:
	return arg.replace("%mapfile%", map_file).replace("%projectpath%", project_path)

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
	# C-20：记录加载时的 mtime——保存前对比，磁盘被外部改过先确认再覆盖
	# V4 P0-1：mtime 在粗粒度文件系统上可能同秒不变（改了两份不同内容仍是同一个数），
	# 摘要才是准的基线；mtime 只在摘要不可得时兜底。
	data["_manifest_mtime"] = FileAccess.get_modified_time(p)
	data["_manifest_digest"] = text.sha256_text()
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
	# V4 P0-2：补码前的码快照——装载结束后与补码后的差集 = 本次会话临时发码。
	var codes_before := issued_codes(data)
	# 功能段 / 字段段：同样补发（保存清单时随 functions写回）。
	# 磁盘上的执行引用一律用码，人类名零兼容、无回退——查不到就是数据漂移。
	var issued := false
	var taken := {}
	for a in data.get("assets", []):
		if not a is Dictionary or a.get("kind") != "entity":
			continue
		var code := str(a.get("code", ""))
		if code == "":
			continue
		if taken.has(code):
			return {"_error": "资产身份码冲突：%s 与 %s 都使用 %s" % [
				taken[code], a.get("id", ""), code], "_warnings": warnings}
		taken[code] = a.get("id", "")
	for a in data.get("assets", []):
		if not a is Dictionary or a.get("kind") != "entity" or str(a.get("code", "")) != "":
			continue
		var code := preload("res://src/content/content_id.gd").new_entity_code()
		while taken.has(code):
			code = preload("res://src/content/content_id.gd").new_entity_code()
		a["code"] = code
		taken[code] = a.get("id", "")
		issued = true
	issued = FunctionDecls.ensure_codes(data) or issued
	# 条件字段码：与功能字段共用一个码空间，避开功能字段已占用的码补发。
	issued = ConditionDecls.ensure_codes(data) or issued
	# 步骤池：条目码 + 步骤字段码补发（字段码避开功能/条件已占用）。
	issued = StepDecls.ensure_codes(data) or issued
	# 音频码：音频池条目补发执行码（保存清单时随 audio 写回）。
	issued = AudioDecls.ensure_codes(data) or issued
	# 时机码：triggers 池条目补发执行码（时机不带字段，不进字段码空间）。
	issued = TriggerDecls.ensure_codes(data) or issued
	# 资产零登记扫描（2026-11-21 用户模型）：约定目录自动补条目/发码/改名重链。
	# 新增/重链/停用改了数据 → 随下次清单保存落盘（_codes_issued 同一标记位）。
	# A4：changes 覆盖「补指纹 / 标停用 / 歧义待确认」，不只是 added/renamed。
	var scan: Dictionary = preload("res://src/project/asset_scan.gd").sync(data)
	issued = bool(scan.get("changes", false)) or issued
	if not (scan.get("retired", []) as Array).is_empty() or not (scan.get("ambiguous", []) as Array).is_empty():
		push_warning("资产扫描：%d 个资产停用、%d 个改名待确认（资产页可处理）" % [
			(scan.get("retired", []) as Array).size(), (scan.get("ambiguous", []) as Array).size()])
	# 补码只改内存：内容文件马上就会带着新码落盘，清单却要等下一次显式保存。
	# 留标记让「内容视图 Ctrl+S」顺手把清单也写回（D6），否则新码在磁盘上无对应对照。
	if issued:
		data["_codes_issued"] = true
		# V4 P0-2：记录本次会话补发的码键（装载前 → 装载后差集）。草稿恢复只在
		# 磁盘本来没有该码时才允许覆盖；分不清「磁盘原有」与「临时补发」，
		# 旧草稿的预留码就永远合不回来。
		var after := issued_codes(data)
		var fresh := {}
		for k in after:
			if str(codes_before.get(k, "")) != str(after[k]):
				fresh[k] = true
		data["_codes_issued_now"] = fresh
	return data

## 本次会话已发出的声明身份（id → code）：草稿保存它，重启恢复时按基线合并，
## 避免「清单未落盘 → 重启重发新码 → 草稿里的旧引用悬空」（R07）。
## scope 前缀区分池：fn/cond/step/audio/trigger/asset。
static func issued_codes(m: Dictionary) -> Dictionary:
	var out := {}
	for fid in FunctionDecls.functions(m):
		var c := str((FunctionDecls.functions(m)[fid] as Dictionary).get("code", ""))
		if c != "":
			out["fn:" + str(fid)] = c
	for cid in ConditionDecls.conditions(m):
		var c2 := str((ConditionDecls.conditions(m)[cid] as Dictionary).get("code", ""))
		if c2 != "":
			out["cond:" + str(cid)] = c2
	for sid in StepDecls.steps(m):
		var c3 := str((StepDecls.steps(m)[sid] as Dictionary).get("code", ""))
		if c3 != "":
			out["step:" + str(sid)] = c3
	for aid in AudioDecls.audio(m):
		var c4 := str((AudioDecls.audio(m)[aid] as Dictionary).get("code", ""))
		if c4 != "":
			out["audio:" + str(aid)] = c4
	for tid in TriggerDecls.triggers(m):
		var c5 := str((TriggerDecls.triggers(m)[tid] as Dictionary).get("code", ""))
		if c5 != "":
			out["trigger:" + str(tid)] = c5
	# V4 P0-2：字段码也是执行引用（内容 fields 的键、步骤值键）。只记池条目码会让
	# 草稿恢复后字段键对不上：旧草稿里按旧字段码存的值全部变成未知键。
	for fid2 in FunctionDecls.functions(m):
		var fd2: Dictionary = FunctionDecls.functions(m)[fid2]
		for f in (fd2.get("fields", []) as Array):
			if f is Dictionary and str((f as Dictionary).get("code", "")) != "":
				out["fnf:" + str(fid2) + ":" + str((f as Dictionary).get("id", ""))] = str((f as Dictionary).get("code", ""))
	for cid3 in ConditionDecls.conditions(m):
		var cd3: Dictionary = ConditionDecls.conditions(m)[cid3]
		for f2 in (cd3.get("fields", []) as Array):
			if f2 is Dictionary and str((f2 as Dictionary).get("code", "")) != "":
				out["condf:" + str(cid3) + ":" + str((f2 as Dictionary).get("id", ""))] = str((f2 as Dictionary).get("code", ""))
	for sid2 in StepDecls.steps(m):
		var sd2: Dictionary = StepDecls.steps(m)[sid2]
		for f3 in (sd2.get("fields", []) as Array):
			if f3 is Dictionary and str((f3 as Dictionary).get("code", "")) != "":
				out["stepf:" + str(sid2) + ":" + str((f3 as Dictionary).get("id", ""))] = str((f3 as Dictionary).get("code", ""))
	for a in (m.get("assets", []) as Array):
		if a is Dictionary and str((a as Dictionary).get("kind", "")) == "entity":
			var aid2 := str((a as Dictionary).get("id", ""))
			var c6 := str((a as Dictionary).get("code", ""))
			if aid2 != "" and c6 != "":
				out["asset:" + aid2] = c6
	return out

## 草稿恢复：把草稿记录的已发码合并回内存清单（只补空码，不覆盖现有声明）。
## 返回补回的条数；草稿来自另一个项目形态时会静默跳过不存在的声明。
## 直接改清单原始结构（dict/array 两种写法），不走归一化视图——那是缓存副本。
## V4 P0-2：restore_reserved=true 时允许覆盖「本次会话刚补发」的码。
## 原因：启动装载先给缺码声明发了新码，草稿里保存的是上次会话的预留码；
## 只填空码的规则会把新码当成既有身份，草稿里的引用（内容字段键/步骤键/实例绑定）
## 全部对不上。`_codes_issued_now` 精确记录本次会话补发的键，磁盘上原有的码不动。
static func merge_issued_codes(m: Dictionary, codes: Dictionary, restore_reserved := false) -> int:
	if codes.is_empty():
		return 0
	var n := 0
	var issued_now: Dictionary = m.get("_codes_issued_now", {}) if m.get("_codes_issued_now", null) is Dictionary else {}
	for key in codes:
		var k := str(key)
		var code := str(codes[key])
		if code == "":
			continue
		var parts := k.split(":", false)
		if parts.size() < 2:
			continue
		var scope := str(parts[0])
		var id := str(parts[1])
		# 字段码作用域：键 = 作用域:池条目 id:字段 id（三段的池条目码是两段，分开放行）
		if scope in ["fnf", "condf", "stepf"]:
			if parts.size() != 3:
				continue
			var owner := str(parts[1])
			var field_id := str(parts[2])
			var items: Array = []
			match scope:
				"fnf": items = DeclarationPool.items(m.get("functions", null))
				"condf": items = DeclarationPool.items(m.get("conditions", null))
				"stepf": items = DeclarationPool.items(m.get("steps", null))
			for pair in items:
				if str((pair.body as Dictionary).get("id", "")) != owner:
					continue
				for fd in ((pair.body as Dictionary).get("fields", []) as Array):
					if fd is Dictionary and str((fd as Dictionary).get("id", "")) == field_id:
						var cur := str((fd as Dictionary).get("code", ""))
						if cur == "" or (restore_reserved and issued_now.has(k)):
							(fd as Dictionary)["code"] = code
							n += 1
			continue
		if parts.size() != 2:
			continue
		if scope == "asset":
			for ae in (m.get("assets", []) as Array):
				if ae is Dictionary and str((ae as Dictionary).get("id", "")) == id \
						and str((ae as Dictionary).get("kind", "")) == "entity" \
						and (str((ae as Dictionary).get("code", "")) == "" \
							or (restore_reserved and issued_now.has(k))):
					(ae as Dictionary)["code"] = code
					n += 1
			continue
		var pool_key := ""
		match scope:
			"fn": pool_key = "functions"
			"cond": pool_key = "conditions"
			"step": pool_key = "steps"
			"audio": pool_key = "audio"
			"trigger": pool_key = "triggers"
		if pool_key == "":
			continue
		var decl = m.get(pool_key, null)
		if decl is Dictionary:
			var body = (decl as Dictionary).get(id, null)
			if body is Dictionary and (str((body as Dictionary).get("code", "")) == "" \
					or (restore_reserved and issued_now.has(k))) \
					and str((body as Dictionary).get("id", id)) == id:
				(body as Dictionary)["code"] = code
				n += 1
		elif decl is Array:
			for item in (decl as Array):
				if item is Dictionary and str((item as Dictionary).get("id", "")) == id \
						and (str((item as Dictionary).get("code", "")) == "" \
							or (restore_reserved and issued_now.has(k))):
					(item as Dictionary)["code"] = code
					n += 1
					break
	if n > 0:
		m["_codes_issued"] = true
	return n

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
## 优先级：清单 editorSize → 0（消费方按 1 格兜底）
static func entity_editor_size(_m: Dictionary, edef: Dictionary) -> Vector2:
	var es = edef.get("editorSize", null)
	if es is Array and (es as Array).size() >= 2:
		return Vector2(float(es[0]), float(es[1]))
	return Vector2.ZERO
