extends RefCounted
## 条件声明域：conditions 池的归一化视图、字段码补发（与功能字段共用一个码空间）、
## 条件↔字段查询。声明域只依赖 manifest 字典本身，全部静态函数。
##
## 条件库模型（游戏侧契约）：条件 = 一段游戏侧代码 + 暴露的可调字段（接口）。
## 功能声明用 `conditions: [条件 id, ...]` 引用条件（同清单内按 id 引用，同挂载模型）；
## 固定条件参数写进内容 fields；可配置条件组每行有自己的 fields。两者都用字段码做键，
## 编辑器负责填参和引用，条件判定由游戏执行。

const ContentId := preload("res://src/content/content_id.gd")
const PoolPrint := preload("res://src/core/pool_fingerprint.gd")

## 归一化结果缓存：指纹 = 项目目录 + conditions 池的递归结构哈希（F1/P03：避免每次访问重扫整池）。
static var _cache: Dictionary = {}
static var _cache_key := ""

static func _key(m: Dictionary) -> String:
	return PoolPrint.of(m, "conditions")

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

## 条件池归一化视图 {id: {id, name, fields}}。
## **以声明原件为底**（未知键原样保留），只规范化编辑器认识的键。
static func conditions(m: Dictionary) -> Dictionary:
	var key := _key(m)
	if _cache_key == key:
		return _cache
	var out := {}
	for pair in _decl_items(m.get("conditions", null)):
		var cid := str(pair.id)
		if cid == "":
			continue
		var src: Dictionary = pair.body
		var d: Dictionary = src.duplicate(true)
		d["id"] = cid
		d["name"] = str(src.get("name", cid)) if str(src.get("name", "")) != "" else cid
		d["fields"] = src.get("fields", []) if src.get("fields", []) is Array else []
		out[cid] = d
	_cache = out
	_cache_key = key
	return out

## 单个条件声明；缺失时返回空字典。
static func condition_decl(m: Dictionary, cond_id: String) -> Dictionary:
	var all := conditions(m)
	return all.get(cond_id, {}) if all.get(cond_id, {}) is Dictionary else {}

## 条件字段声明数组；缺失时返回空数组。
static func condition_fields(m: Dictionary, cond_id: String) -> Array:
	return condition_decl(m, cond_id).get("fields", [])

## 条件行保存人类 ID，与固定条件的 declarations.conditions 使用同一身份。
static func allowed_rows(m: Dictionary, field: Dictionary) -> Array:
	var allowed = field.get("allowedConditions")
	if not allowed is Array:
		return []
	var all := conditions(m)
	var rows: Array = []
	for id in allowed:
		if id is String and all.has(id):
			rows.append(all[id])
	return rows

static func row_schema(m: Dictionary, field: Dictionary, row: Dictionary) -> Dictionary:
	var id = row.get("condition")
	var allowed = field.get("allowedConditions")
	if not id is String or not allowed is Array or not allowed.has(id):
		return {}
	return condition_decl(m, id)

## 已占用字段码集合（三池同空间：功能+条件+步骤——步骤池后加，条件补码同样要避开它）。
## 条件字段与功能字段共存于同一份内容 fields（键=字段码），码必须同空间唯一。
static func taken_field_codes(m: Dictionary) -> Dictionary:
	return ContentId.field_codes(m)

## 补发条件字段缺失码（避开功能与条件字段已占用的码），就地修改，返回是否有改动。
## 只补「空」的，不碰重复码（与 function_decl.ensure_codes 同一纪律——重复由校验报错）。
## 只在 FunctionDecl.ensure_codes 之后调用：功能字段码已定，条件字段避开它们。
static func ensure_codes(m: Dictionary) -> bool:
	var changed := false
	var seen := taken_field_codes(m)
	for pair in _decl_items(m.get("conditions", null)):
		var d: Dictionary = pair.body
		for fd in d.get("fields", []) if d.get("fields", []) is Array else []:
			if not (fd is Dictionary):
				continue
			if str((fd as Dictionary).get("code", "")) == "":
				var fcode := ContentId.new_fn_code()
				while seen.has(fcode):
					fcode = ContentId.new_fn_code()
				(fd as Dictionary)["code"] = fcode
				seen[fcode] = true
				changed = true
	return changed

## 条件池的码表段（Markdown）；无条件声明时返回空串，由调用方拼在功能码表之后。
static func codes_doc(m: Dictionary) -> String:
	var conds := conditions(m)
	if conds.is_empty():
		return ""
	var L: Array[String] = []
	L.append("## 条件")
	L.append("")
	L.append("条件按 id 被功能声明引用（清单内人类名，条件本身无执行码）；")
	L.append("条件字段与功能字段共用一个码空间。固定条件使用内容 fields，可配置条件组使用各行的 fields。")
	L.append("")
	for cid in conds:
		var d: Dictionary = conds[cid]
		L.append("### %s（%s）" % [str(cid), str(d.get("name", cid))])
		L.append("")
		var fields: Array = d.get("fields", [])
		if fields.is_empty():
			L.append("（无可调字段。）")
			L.append("")
			continue
		L.append("| 码 | 人类 id | kind | type |")
		L.append("|----|---------|------|------|")
		for fd in fields:
			if not (fd is Dictionary):
				continue
			L.append("| %s | %s | %s | %s |" % [
				str((fd as Dictionary).get("code", "")), str((fd as Dictionary).get("id", "")),
				str((fd as Dictionary).get("kind", "")), str((fd as Dictionary).get("type", ""))])
		L.append("")
	return "\n".join(L)
