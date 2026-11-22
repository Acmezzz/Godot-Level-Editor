extends RefCounted
## 音频声明域：audio 池的归一化视图、执行码补发、码表段。
## 声明域只依赖 manifest 字典本身，全部静态函数。
##
## 音频模型（游戏侧契约）：音频资产 = 游戏侧声明的 {id, name, path}，
## 路径解释权在游戏侧——编辑器只把 `audio:` 来源渲染成下拉、值存音频码，
## 不加载、不播放音频，也不解释语义。BGM/音效的播放时机归功能代码。

const ContentId := preload("res://src/content/content_id.gd")
const PoolPrint := preload("res://src/core/pool_fingerprint.gd")

## 归一化结果缓存：指纹 = 项目目录 + audio 池的递归结构哈希（F1/P03：避免每次访问重扫整池）。
static var _cache: Dictionary = {}
static var _cache_key := ""

static func _key(m: Dictionary) -> String:
	return PoolPrint.of(m, "audio")

## 把两种写法统一成 [{id, body}] 对，便于就地补码（与 function_decl 同构）。
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

## 音频池归一化视图 {id: {id, name, path, code}}。
## **以声明原件为底**（未知键原样保留），只规范化编辑器认识的键。
static func audio(m: Dictionary) -> Dictionary:
	var key := _key(m)
	if _cache_key == key:
		return _cache
	var out := {}
	for pair in _decl_items(m.get("audio", null)):
		var aid := str(pair.id)
		if aid == "":
			continue
		var src: Dictionary = pair.body
		var d: Dictionary = src.duplicate(true)
		d["id"] = aid
		d["name"] = str(src.get("name", aid)) if str(src.get("name", "")) != "" else aid
		d["path"] = str(src.get("path", ""))
		d["code"] = str(src.get("code", ""))
		out[aid] = d
	_cache = out
	_cache_key = key
	return out

## 单个音频声明；缺失时返回空字典。
static func audio_decl(m: Dictionary, aid: String) -> Dictionary:
	var all := audio(m)
	return all.get(aid, {}) if all.get(aid, {}) is Dictionary else {}

## 补发音频条目缺失的执行码（池内避开已占用码），就地修改，返回是否有改动。
## 只补「空」的，不碰重复码——重复由校验报错（与 function_decl 同一纪律）。
static func ensure_codes(m: Dictionary) -> bool:
	var changed := false
	var seen := {}
	for pair in _decl_items(m.get("audio", null)):
		var d: Dictionary = pair.body
		var have := str(d.get("code", ""))
		if have != "":
			seen[have] = true
	for pair in _decl_items(m.get("audio", null)):
		var d2: Dictionary = pair.body
		if str(d2.get("code", "")) != "":
			continue
		var acode := ContentId.new_fn_code()
		while seen.has(acode):
			acode = ContentId.new_fn_code()
		d2["code"] = acode
		seen[acode] = true
		changed = true
	return changed

## 音频池的码表段（Markdown）；无音频声明时返回空串，由调用方拼在码表末尾。
static func codes_doc(m: Dictionary) -> String:
	var all := audio(m)
	if all.is_empty():
		return ""
	var L: Array[String] = []
	L.append("## 音频")
	L.append("")
	L.append("音频资产由游戏工程声明（path 解释权在游戏侧）；编辑器把 `audio:` 来源渲染成")
	L.append("下拉，内容 fields 里存音频码，编辑器不加载、不播放音频。")
	L.append("")
	L.append("| 码 | 人类 id | 名称 | 路径 |")
	L.append("|----|---------|------|------|")
	for aid in all:
		var d: Dictionary = all[aid]
		L.append("| %s | %s | %s | %s |" % [
			str(d.get("code", "")), str(aid), str(d.get("name", aid)), str(d.get("path", ""))])
	L.append("")
	return "\n".join(L)
