extends RefCounted
## 时机声明域：triggers 池的归一化视图、执行码补发、码表段。
## 声明域只依赖 manifest 字典本身，全部静态函数。
##
## 时机模型（游戏侧契约）：时机 = 游戏侧声明的 {id, name}，
## 只是一个被引用的标签，本身不带字段——参数一律在功能内容里。
## 编辑器只把声明解析成下拉候选并存储时机码，判定归游戏侧功能代码。

const ContentId := preload("res://src/content/content_id.gd")

## 归一化结果缓存：指纹 = 项目目录 + triggers 声明的 JSON 串（清单保存后必变，天然失效）。
static var _cache: Dictionary = {}
static var _cache_key := ""

static func _key(m: Dictionary) -> String:
	return str(m.get("_dir", "")) + "\u0001" + JSON.stringify(m.get("triggers", null))

## 两种写法统一成 [{id, body}]，便于就地补码（与 audio_decl 同构）。
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

## 时机池归一化视图 {id: {id, name, code}}。
## 以声明原件为底（未知键保留），只规范化编辑器认识的键。
static func triggers(m: Dictionary) -> Dictionary:
	var key := _key(m)
	if _cache_key == key:
		return _cache
	var out := {}
	for pair in _decl_items(m.get("triggers", null)):
		var tid := str(pair.id)
		if tid == "":
			continue
		var src: Dictionary = pair.body
		var d: Dictionary = src.duplicate(true)
		d["id"] = tid
		d["name"] = str(src.get("name", tid)) if str(src.get("name", "")) != "" else tid
		d["code"] = str(src.get("code", ""))
		out[tid] = d
	_cache = out
	_cache_key = key
	return out

static func trigger_decl(m: Dictionary, tid: String) -> Dictionary:
	var all := triggers(m)
	return all.get(tid, {}) if all.get(tid, {}) is Dictionary else {}

## 执行码 → 时机 id；未知码返回空串（调用方据此上报漂移）。
static func trigger_id_of(m: Dictionary, code: String) -> String:
	if code == "":
		return ""
	for tid in triggers(m):
		if str((triggers(m)[tid] as Dictionary).get("code", "")) == code:
			return str(tid)
	return ""

## 补发缺失的时机执行码（池内避开已占用码），就地修改，返回是否有改动。
## 只补空的，不碰重复码——重复由校验报错。
static func ensure_codes(m: Dictionary) -> bool:
	var changed := false
	var seen := {}
	for pair in _decl_items(m.get("triggers", null)):
		var have := str((pair.body as Dictionary).get("code", ""))
		if have != "":
			seen[have] = true
	for pair in _decl_items(m.get("triggers", null)):
		var d: Dictionary = pair.body
		if str(d.get("code", "")) != "":
			continue
		var code := ContentId.new_fn_code()
		while seen.has(code):
			code = ContentId.new_fn_code()
		d["code"] = code
		seen[code] = true
		changed = true
	return changed

## 时机的码表段（Markdown）；无声明时返回空串。
static func codes_doc(m: Dictionary) -> String:
	var all := triggers(m)
	if all.is_empty():
		return ""
	var L: Array[String] = []
	L.append("## 时机")
	L.append("")
	L.append("时机由游戏工程声明（判定归功能代码）；功能按 id 引用，绑定写时机码。")
	L.append("")
	L.append("| 码 | 人类 id | 名称 |")
	L.append("|----|---------|------|")
	for tid in all:
		var d: Dictionary = all[tid]
		L.append("| %s | %s | %s |" % [
			str(d.get("code", "")), str(tid), str(d.get("name", tid))])
	L.append("")
	return "\n".join(L)
