extends RefCounted
class_name FunctionDecl
## 功能/字段声明域（从 manifest.gd 拆出）：functions 归一化视图、码补发、
## 执行码与声明 ID 互查。声明域只依赖 manifest 字典本身，全部静态函数。

## 归一化结果缓存：content_editor 重建右栏时逐字段调用 function_fields 等，
## 全量重扫是纯浪费。指纹 = 项目目录 + functions 池的递归结构哈希（F1/P03：
## 原先 JSON.stringify 整池是每次访问的成本，池越大越慢；见 declaration_pool.gd）。
const ContentId := preload("res://src/content/content_id.gd")
const PoolPrint := preload("res://src/content/declaration_pool.gd")
const Triggers := preload("res://src/content/trigger_decl.gd")

static var _cache: Dictionary = {}
static var _cache_key := ""
static var _by_code := {}

static func _key(m: Dictionary) -> String:
	return PoolPrint.fingerprint(m, "functions")

## 补发缺失的功能码 / 字段码。就地修改清单，返回是否有改动。
## 只补「空」的，**不碰重复码**——重复是真实错误（两个声明同码 = 静默别名），
## 由校验报出来让人决定改哪个；这里替用户改一个反而会悄悄改变既有引用指向。
static func ensure_codes(m: Dictionary) -> bool:
	var rows := PoolPrint.items(m.get("functions"))
	var entries_changed := PoolPrint.ensure_entry_codes(rows)
	return PoolPrint.ensure_field_codes(m, rows) or entries_changed

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
	_by_code = {}
	for id in out:
		var code := str(out[id].get("code", ""))
		if code != "" and not _by_code.has(code):
			_by_code[code] = id
	_cache_key = key
	return out

## 归一化单个功能声明：**以声明原件为底**（未知键原样保留，游戏侧写什么编辑器都不丢），
## 只规范化编辑器认识的键。此前是白名单重建，`triggers`/`timing`/`view` 等键进不了视图，
## UI 连"看得见"都做不到。
## conditions 非数组时**不归一成空数组**（C07）：那会把坏声明静默洗白，校验也就查不到了。
static func _normalize_fn(fid: String, src: Dictionary) -> Dictionary:
	var d: Dictionary = src.duplicate(true)
	d["id"] = fid
	d["code"] = str(src.get("code", ""))
	d["name"] = str(src.get("name", fid)) if str(src.get("name", "")) != "" else fid
	d["fields"] = src.get("fields", []) if src.get("fields", []) is Array else []
	if d.get("conditions", null) == null:
		d["conditions"] = []
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

static func trigger_options(m: Dictionary, fn_id: String) -> Dictionary:
	var choices := {}
	for id in fn_triggers(m, fn_id):
		var row := Triggers.trigger_decl(m, str(id))
		var code := str(row.get("code", ""))
		if code != "":
			choices[code] = str(row.get("name", id))
	return choices

static func allows_trigger(m: Dictionary, fn_id: String, value: Variant) -> bool:
	return value is String and (value == "" or trigger_options(m, fn_id).has(value))

## 功能 id（人类名）→ 执行码；缺失返回空串。
static func fn_code(m: Dictionary, fn_id: String) -> String:
	return str(function_decl(m, fn_id).get("code", ""))

## 执行码 → 功能 id；未知码返回空串（调用方据此上报漂移）。
static func fn_id_of(m: Dictionary, code: String) -> String:
	if code == "":
		return ""
	functions(m)
	return str(_by_code.get(code, ""))

## A repeatable function executes once per binding row; absence retains the single-row authoring policy.
static func is_repeatable(m: Dictionary, fn_id: String) -> bool:
	var value = function_decl(m, fn_id).get("repeatable")
	return value is bool and value

static func renumber_bindings(rows: Array) -> void:
	for i in rows.size():
		if rows[i] is Dictionary:
			rows[i]["order"] = i + 1

## IDs are unique within an instance, so cloning a map or entity can preserve them.
static func new_binding_id(rows: Array) -> String:
	var used := {}
	for row in rows:
		if row is Dictionary and row.get("bindingId") is String:
			used[row.bindingId] = true
	var id := ContentId.new_inst_code() + ContentId.new_inst_code()
	while used.has(id):
		id = ContentId.new_inst_code() + ContentId.new_inst_code()
	return id

## -1 = absent, -2 = ambiguous. A single legacy unmarked row is the inherited binding.
static func mounted_index(rows: Array, execution_code: String) -> int:
	var matched := -1
	var marked := -1
	var count := 0
	for i in rows.size():
		var row = rows[i]
		if not row is Dictionary or str(row.get("fn", "")) != execution_code:
			continue
		matched = i
		count += 1
		if row.get("mounted") is bool and row.mounted:
			if marked >= 0:
				return -2
			marked = i
	if marked >= 0:
		return marked
	return (-2 if count > 1 else matched)

## 资产类型的自带功能（挂载）：清单 assets[].functions = 功能 id 数组，声明顺序即默认执行顺序。
## 返回 [{id, code}]；挂载了未声明功能的 id 被过滤（校验层报错误），保证返回的都可用。
## 重复挂载的同功能只保留第一条（C09）：同码两条会让实例补出两条同码绑定，
## 「唯一继承行」无从辨认；校验层已把重复挂载报为错误，这里做运行期去重兜底。
static func entity_mounts(m: Dictionary, sid: String) -> Array:
	var out: Array = []
	var seen := {}
	for ed in m.get("assets", []):
		if not (ed is Dictionary) or str((ed as Dictionary).get("id", "")) != sid:
			continue
		var mounts = (ed as Dictionary).get("functions", [])
		if not (mounts is Array):
			continue
		for fid in mounts:
			var fids := str(fid)
			var code := fn_code(m, fids)
			if fids == "" or code == "" or seen.has(code):
				continue
			seen[code] = true
			out.append({"id": fids, "code": code})
	return out

## 给一行实例绑定补齐类型挂载（C09）：放置和载图时在**工作副本**上调用，
## 与选中事件彻底解耦——没被点开过的实例也补齐。
## 只在「该功能码一条绑定都没有」时追加唯一继承行 `mounted: true`；
## 同码多条且标记不唯一时不猜继承行（返回 ambiguous）。
## 返回 {functions, changed, ambiguous}；functions 与传入数组不共享引用。
static func fill_bindings(m: Dictionary, asset_id: String, fns: Array) -> Dictionary:
	return fill_mounts(functions(m), entity_mounts(m, asset_id), fns)

static func fill_mounts(pool: Dictionary, mounts: Array, fns: Array) -> Dictionary:
	var out: Array = fns.duplicate(true)
	if mounts.is_empty():
		return {"functions": out, "changed": false, "ambiguous": []}
	var changed := false
	var ambiguous: Array = []
	for mt in mounts:
		var code := str(mt.code)
		var i := mounted_index(out, code)
		if i == -2:
			ambiguous.append(code)
		elif i == -1:
			var row := {"fn": code, "content": "", "name": "", "order": 0,
				"parallel": false, "mounted": true}
			if pool.get(mt.id, {}).get("repeatable") == true:
				row["bindingId"] = new_binding_id(out)
			out.append(row)
			changed = true
	if not changed:
		return {"functions": out, "changed": false, "ambiguous": ambiguous}
	renumber_bindings(out)
	return {"functions": out, "changed": true, "ambiguous": ambiguous}
