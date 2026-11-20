extends RefCounted
class_name FunctionDecl
## 功能/字段声明域（从 manifest.gd 拆出）：functions 归一化视图、码补发/查重、
## 码↔名双向查找、CODES.md 生成。声明域只依赖 manifest 字典本身，全部静态函数。

## 归一化结果缓存：content_editor 重建右栏时逐字段调用 function_fields 等，
## 全量重扫是纯浪费。指纹 = 项目目录 + functions 声明的 JSON 串（清单保存后必变，天然失效）。
static var _cache: Dictionary = {}
static var _cache_key := ""

static func _key(m: Dictionary) -> String:
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
	# 占用表 = 三池字段码全量 + 本池条目码。字段码是全局码空间（校验跨池同码报错），
	# 功能是首池——补码不避条件/步骤已占码，造出的坏码会随清单落盘、下次启动校验拒载
	var seen := Decls.field_codes(m)
	var seen_fn := {}   # 条目码查重是池内的（steps/audio 各自池内查重）
	for pair in _decl_items(m.get("functions", null)):
		var c0 := str((pair.body as Dictionary).get("code", ""))
		if c0 != "":
			seen_fn[c0] = true
	for pair in _decl_items(m.get("functions", null)):
		var d: Dictionary = pair.body
		if str(d.get("code", "")) == "":
			var code := Decls.new_fn_code()
			while seen_fn.has(code):
				code = Decls.new_fn_code()
			d["code"] = code
			seen_fn[code] = true
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
	var fseen := {}   # 字段码跨功能查重：字段码是一个全局码空间，A 功能占了 B 功能就不能再占
	for pair in _decl_items(m.get("functions", null)):
		var d: Dictionary = pair.body
		var code := str(d.get("code", ""))
		if code != "":
			if seen.has(code):
				out.append({"scope": str(pair.id), "code": code})
			seen[code] = true
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
	var key := _key(m)
	if _cache_key == key:
		return _cache
	var out := {}
	var decl = m.get("functions", null)
	if decl is Dictionary:
		for fid_key in (decl as Dictionary):
			var fid := str(fid_key)
			if fid == "":
				continue
			var body = (decl as Dictionary)[fid_key]
			var src: Dictionary = body if body is Dictionary else {}
			out[fid] = _normalize_fn(fid, src)
	elif decl is Array:
		for item in (decl as Array):
			if not (item is Dictionary):
				continue
			var src2: Dictionary = item
			var fid2 := str(src2.get("id", ""))
			if fid2 == "":
				continue
			out[fid2] = _normalize_fn(fid2, src2)
	_cache = out
	_cache_key = key
	return out

## 归一化单个功能声明：**以声明原件为底**（未知键原样保留，游戏侧写什么编辑器都不丢），
## 只规范化编辑器认识的键。此前是白名单重建，`triggers`/`timing`/`view` 等键进不了视图，
## UI 连"看得见"都做不到。
static func _normalize_fn(fid: String, src: Dictionary) -> Dictionary:
	var d: Dictionary = src.duplicate(true)
	d["id"] = fid
	d["code"] = str(src.get("code", ""))
	d["name"] = str(src.get("name", fid)) if str(src.get("name", "")) != "" else fid
	d["fields"] = src.get("fields", []) if src.get("fields", []) is Array else []
	d["conditions"] = src.get("conditions", []) if src.get("conditions", []) is Array else []
	d["steps"] = bool(src.get("steps", false))
	return d

## 单个功能声明；缺失时返回空字典。
static func function_decl(m: Dictionary, fn_id: String) -> Dictionary:
	var all := functions(m)
	return all.get(fn_id, {}) if all.get(fn_id, {}) is Dictionary else {}

## 功能字段声明数组；缺失时返回空数组。
static func function_fields(m: Dictionary, fn_id: String) -> Array:
	return function_decl(m, fn_id).get("fields", [])

## 功能显示名；缺省用 fn_id。
static func function_name(m: Dictionary, fn_id: String) -> String:
	return str(function_decl(m, fn_id).get("name", fn_id))

## 该功能声明是否为演出功能（声明 "steps": true）——内容表单据此渲染演出子面板入口。
static func fn_has_steps(m: Dictionary, fn_id: String) -> bool:
	return bool(function_decl(m, fn_id).get("steps", false))

## 该功能声明的时机 id 白名单（数组，未声明 = 空）。
static func fn_triggers(m: Dictionary, fn_id: String) -> Array:
	var t = function_decl(m, fn_id).get("triggers", [])
	return t if t is Array else []

## 该功能声明的时机提示对象（{mode}，缺省空字典）。
static func fn_timing(m: Dictionary, fn_id: String) -> Dictionary:
	var t = function_decl(m, fn_id).get("timing", null)
	return t if t is Dictionary else {}

## 该功能的呈现提示对象（{group, icon, color}，缺省空字典）。
static func fn_view(m: Dictionary, fn_id: String) -> Dictionary:
	var v = function_decl(m, fn_id).get("view", null)
	return v if v is Dictionary else {}

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

## 资产类型的自带功能（挂载）：清单 assets[].functions = 功能 id 数组，声明顺序即默认执行顺序。
## 返回 [{id, code}]；挂载了未声明功能的 id 被过滤（校验层报错误），保证返回的都可用。
static func entity_mounts(m: Dictionary, sid: String) -> Array:
	var out: Array = []
	for ed in m.get("assets", []):
		if not (ed is Dictionary) or str((ed as Dictionary).get("id", "")) != sid:
			continue
		var mounts = (ed as Dictionary).get("functions", [])
		if not (mounts is Array):
			continue
		for fid in mounts:
			var fids := str(fid)
			var code := fn_code(m, fids)
			if fids != "" and code != "":
				out.append({"id": fids, "code": code})
	return out

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
