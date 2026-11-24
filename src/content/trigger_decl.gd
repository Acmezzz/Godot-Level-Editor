extends RefCounted
## 时机声明域：triggers 池的归一化视图、执行码补发、码表段。
## 声明域只依赖 manifest 字典本身，全部静态函数。
##
## 时机模型（游戏侧契约）：时机 = 游戏侧声明的 {id, name}，
## 只是一个被引用的标签，本身不带字段——参数一律在功能内容里。
## 编辑器只把声明解析成下拉候选并存储时机码，判定归游戏侧功能代码。

const PoolPrint := preload("res://src/content/declaration_pool.gd")

## 归一化结果缓存：指纹 = 项目目录 + triggers 池的递归结构哈希（F1/P03：避免每次访问重扫整池）。
static var _cache: Dictionary = {}
static var _cache_key := ""

static func _key(m: Dictionary) -> String:
	return PoolPrint.fingerprint(m, "triggers")

## 时机池归一化视图 {id: {id, name, code}}。
## 以声明原件为底（未知键保留），只规范化编辑器认识的键。
static func triggers(m: Dictionary) -> Dictionary:
	var key := _key(m)
	if _cache_key == key:
		return _cache
	var out := PoolPrint.named_rows(m.get("triggers"))
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
	var pool := triggers(m)
	for tid in pool:
		if pool[tid].code == code:
			return str(tid)
	return ""

## 补发缺失的时机执行码（池内避开已占用码），就地修改，返回是否有改动。
## 只补空的，不碰重复码——重复由校验报错。
static func ensure_codes(m: Dictionary) -> bool:
	return PoolPrint.ensure_entry_codes(PoolPrint.items(m.get("triggers")))

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
