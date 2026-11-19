extends RefCounted
## 条件声明域：conditions 池的归一化视图、字段码补发（与功能字段共用一个码空间）、
## 条件↔字段查询。声明域只依赖 manifest 字典本身，全部静态函数。
##
## 条件库模型（游戏侧契约）：条件 = 一段游戏侧代码 + 暴露的可调字段（接口）。
## 功能声明用 `conditions: [条件 id, ...]` 引用条件（同清单内按 id 引用，同挂载模型）；
## 条件参数与功能参数共存于同一份内容 fields（键=字段码），编辑器只渲染填参，不解释语义。

const FunctionDecls := preload("res://src/content/function_decl.gd")
const ContentId := preload("res://src/content/content_id.gd")

## 归一化结果缓存：指纹 = 项目目录 + conditions 声明的 JSON 串（清单保存后必变，天然失效）。
static var _cache: Dictionary = {}
static var _cache_key := ""

static func _key(m: Dictionary) -> String:
	return str(m.get("_dir", "")) + "\u0001" + JSON.stringify(m.get("conditions", null))

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
		out[cid] = {
			"id": cid,
			"name": str(src.get("name", cid)) if str(src.get("name", "")) != "" else cid,
			"fields": src.get("fields", []) if src.get("fields", []) is Array else [],
		}
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

## 条件显示名；缺省用 cond_id。
static func condition_name(m: Dictionary, cond_id: String) -> String:
	return str(condition_decl(m, cond_id).get("name", cond_id))

## 已占用字段码集合（功能池 + 条件池）——条件字段与功能字段共存于同一份内容
## fields（键=字段码），两个池的码必须同空间唯一。
static func taken_field_codes(m: Dictionary) -> Dictionary:
	var seen := {}
	for fid in FunctionDecls.functions(m):
		for fd in (FunctionDecls.functions(m)[fid] as Dictionary).get("fields", []):
			if fd is Dictionary:
				seen[str((fd as Dictionary).get("code", ""))] = true
	for pair in _decl_items(m.get("conditions", null)):
		var body: Dictionary = pair.body
		for fd0 in body.get("fields", []) if body.get("fields", []) is Array else []:
			if fd0 is Dictionary:
				seen[str((fd0 as Dictionary).get("code", ""))] = true
	return seen

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
	L.append("条件字段与功能字段共用一个码空间，值都存在同一份内容 fields 里。")
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
