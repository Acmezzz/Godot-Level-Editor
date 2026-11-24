extends RefCounted
## 步骤声明域：steps 池的归一化视图、字段码补发、码表段。
## 声明域只依赖 manifest 字典本身，全部静态函数。
##
## 步骤模型（游戏侧契约）：演出功能（声明 `"steps": true`）的内容里带步骤数组
## `steps: [{step: <步骤码>, fields: {<字段码>: 值}}]`，每步引用步骤池条目；
## 步骤字段与功能/条件字段共用一个码空间。运行时游戏侧按序解释执行。

const PoolPrint := preload("res://src/content/declaration_pool.gd")

## 归一化结果缓存：指纹 = 项目目录 + steps 池的递归结构哈希（F1/P03：避免每次访问重扫整池）。
static var _cache: Dictionary = {}
static var _cache_key := ""

static func _key(m: Dictionary) -> String:
	return PoolPrint.fingerprint(m, "steps")

## 步骤池归一化视图 {id: {id, code, name, fields}}。
## **以声明原件为底**（未知键原样保留），只规范化编辑器认识的键。
static func steps(m: Dictionary) -> Dictionary:
	var key := _key(m)
	if _cache_key == key:
		return _cache
	var out := {}
	for pair in PoolPrint.items(m.get("steps", null)):
		var sid := str(pair.id)
		if sid == "":
			continue
		var src: Dictionary = pair.body
		var d: Dictionary = src.duplicate(true)
		d["id"] = sid
		d["code"] = str(src.get("code", ""))
		d["name"] = str(src.get("name", sid)) if str(src.get("name", "")) != "" else sid
		d["fields"] = src.get("fields", []) if src.get("fields", []) is Array else []
		out[sid] = d
	_cache = out
	_cache_key = key
	return out

## 单个步骤声明；缺失时返回空字典。
static func step_decl(m: Dictionary, sid: String) -> Dictionary:
	var all := steps(m)
	return all.get(sid, {}) if all.get(sid, {}) is Dictionary else {}

## 步骤显示名；缺省用 sid。
static func step_name(m: Dictionary, sid: String) -> String:
	return str(step_decl(m, sid).get("name", sid))

## 执行码 → 步骤声明（内容 steps[].step 存码）；未知码返回空字典。
static func step_by_code(m: Dictionary, code: String) -> Dictionary:
	if code == "":
		return {}
	for sid in steps(m):
		var d: Dictionary = steps(m)[sid]
		if str((d as Dictionary).get("code", "")) == code:
			return d
	return {}

## 补发步骤字段缺失码：避开功能、条件与步骤池已占用的码（三池共用一个码空间），
## 就地修改，返回是否有改动。只补「空」的，不碰重复码（重复由校验报错）。
## 在 FunctionDecl / ConditionDecl 的 ensure_codes 之后调用。
static func ensure_codes(m: Dictionary) -> bool:
	var rows := PoolPrint.items(m.get("steps"))
	var entries_changed := PoolPrint.ensure_entry_codes(rows)
	return PoolPrint.ensure_field_codes(m, rows) or entries_changed
