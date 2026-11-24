extends RefCounted
## 音频声明域：audio 池的归一化视图、执行码补发、码表段。
## 声明域只依赖 manifest 字典本身，全部静态函数。
##
## 音频模型（游戏侧契约）：音频资产 = 游戏侧声明的 {id, name, path}，
## 内容字段存音频码；编辑器可用项目内 path / previewPath 试听。
## 游戏里的素材加载和播放时机仍归功能代码。

const PoolPrint := preload("res://src/content/declaration_pool.gd")

## 归一化结果缓存：指纹 = 项目目录 + audio 池的递归结构哈希（F1/P03：避免每次访问重扫整池）。
static var _cache: Dictionary = {}
static var _cache_key := ""

static func _key(m: Dictionary) -> String:
	return PoolPrint.fingerprint(m, "audio")

## 音频池归一化视图 {id: {id, name, path, code}}。
## **以声明原件为底**（未知键原样保留），只规范化编辑器认识的键。
static func audio(m: Dictionary) -> Dictionary:
	var key := _key(m)
	if _cache_key == key:
		return _cache
	var out := PoolPrint.named_rows(m.get("audio"))
	for row in out.values():
		row["path"] = str(row.get("path", ""))
	_cache = out
	_cache_key = key
	return out

## 试听路径只读项目内源文件；游戏的运行时路径可以使用自己的资源键。
static func preview_relative_path(value: String) -> String:
	var rel := value.strip_edges().replace("\\", "/")
	if rel.begins_with("res://"):
		rel = rel.substr(6)
	return "" if rel.is_absolute_path() or ":" in rel or ".." in rel.split("/") else rel

## 音频引用只按执行码解析。
static func by_code(m: Dictionary, code: String) -> Dictionary:
	if code == "":
		return {}
	var all := audio(m)
	var matched := {}
	for row in all.values():
		if row.code == code:
			if not matched.is_empty():
				return {}
			matched = row
	return matched

## 补发音频条目缺失的执行码（池内避开已占用码），就地修改，返回是否有改动。
## 只补「空」的，不碰重复码——重复由校验报错（与 function_decl 同一纪律）。
static func ensure_codes(m: Dictionary) -> bool:
	return PoolPrint.ensure_entry_codes(PoolPrint.items(m.get("audio")))

## 音频池的码表段（Markdown）；无音频声明时返回空串，由调用方拼在码表末尾。
static func codes_doc(m: Dictionary) -> String:
	var all := audio(m)
	if all.is_empty():
		return ""
	var L: Array[String] = []
	L.append("## 音频")
	L.append("")
	L.append("音频资产由游戏工程声明（path 解释权在游戏侧）；编辑器把 `audio:` 来源渲染成")
	L.append("下拉，内容 fields 里存音频码，时间轴可试听项目内的参考音频。")
	L.append("")
	L.append("| 码 | 人类 id | 名称 | 路径 |")
	L.append("|----|---------|------|------|")
	for aid in all:
		var d: Dictionary = all[aid]
		L.append("| %s | %s | %s | %s |" % [
			str(d.get("code", "")), str(aid), str(d.get("name", aid)), str(d.get("path", ""))])
	L.append("")
	return "\n".join(L)
