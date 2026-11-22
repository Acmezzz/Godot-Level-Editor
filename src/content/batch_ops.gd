extends RefCounted
## BatchOps：按功能声明的批量改值（E2）。只做**数据判定与预览计划**，不碰 UI、不写盘。
##
## 触发入口给一组候选 (实例, 内容 ID)；本模块按同一功能声明的**同码同类型**字段
## 过滤出真正能一起改的条目，产出计划：
##   {field, code, type, old_values: {cid: 旧值}, targets: [cid], skipped: [{cid, why}],
##    conflicts: [{cid, why}], files: [绝对路径]}
## 调用方（内容编辑器）先显示「命中 / 跳过 / 冲突」，确认后逐条写内容文件；
## 每条的写入仍走 ContentStore 既有路径（.history 备份随之保留）。

const ContentStore := preload("res://src/content/content_store.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const MapStore := preload("res://src/map/map_store.gd")

## 内容文件里的字段键：字段声明的码优先，缺码退回人类 id（与 FieldWidgets/内容表单一致）。
static func field_key(fd: Dictionary) -> String:
	var c := str(fd.get("code", ""))
	return c if c != "" else str(fd.get("id", ""))

## 该字段否能安全批量写：只有 input/choice 两种 kind（与 field_widgets 的可写集合一致）。
## 认不出的种类不参与批量——不提供能写坏数据的入口。
static func is_batchable(fd: Dictionary) -> bool:
	var k := str(fd.get("kind", ""))
	return k == "input" or k == "choice"

## 批量改值的计划。
## manifest / fn_id：功能声明（字段集合以它为准，同功能的实例才共用同一份声明）；
## rows：候选 [{node, code, cid}]（cid = 该实例在这一功能上的内容 ID，空 = 跳过）；
## fcode：字段码（field_key）；new_value：目标值。
## 返回见文件头。冲突判据：
##   ① 内容文件读不出来 / 缺失（不猜、不新建——批量只改已有内容）；
##   ② 旧值类型与声明不符（int/float/bool/vector2/color 等严格口径，与控件同一规则）。
static func plan_field(manifest: Dictionary, fn_id: String, rows: Array,
		fcode: String, new_value) -> Dictionary:
	var fields: Array = FunctionDecls.function_fields(manifest, fn_id)
	var fd := _field_by_key(fields, fcode)
	if fd.is_empty():
		return {"status": "error", "error": "功能声明里没有字段 %s" % fcode,
			"targets": [], "skipped": [], "conflicts": [], "old_values": {}, "files": []}
	if not is_batchable(fd):
		return {"status": "error", "error": "字段「%s」不是可批量写入的种类" % _fname(fd),
			"targets": [], "skipped": [], "conflicts": [], "old_values": {}, "files": []}
	var typ := str(fd.get("type", ""))
	var old_values := {}
	var targets: Array = []
	var skipped: Array = []
	var conflicts: Array = []
	var files: Array = []
	var seen := {}
	for r in rows:
		var row: Dictionary = r
		var cid := str(row.get("cid", ""))
		if cid == "":
			skipped.append({"cid": str(row.get("code", "")), "why": "该实例还没有内容"})
			continue
		if seen.has(cid):
			continue   # 同一内容被两个实例共用（C2 之后不应出现）：只改一次
		seen[cid] = true
		var path := ContentStore.path_for(manifest, fn_id, cid)
		var data: Dictionary = ContentStore.read(manifest, fn_id, cid)
		if data.is_empty():
			conflicts.append({"cid": cid, "why": "内容文件读不出来或缺失（%s）" % path})
			continue
		var fv: Dictionary = data.get("fields", {}) if data.get("fields", {}) is Dictionary else {}
		var cur = fv.get(fcode, null)
		if not _value_ok(typ, cur):
			conflicts.append({"cid": cid, "why": "现有值「%s」与声明类型 %s 不符" % [str(cur), typ]})
			continue
		old_values[cid] = cur
		targets.append(cid)
		files.append(path)
	return {"status": "ok", "field": fd, "code": fcode, "type": typ,
		"targets": targets, "skipped": skipped, "conflicts": conflicts,
		"old_values": old_values, "files": files,
		"old": old_values.duplicate(), "new": new_value}

## 应用计划：逐条写内容文件。
## read_fn / write_fn 可选（内容编辑器传 staged 感知版本：暂存中的新内容优先、写回内存）；
## 缺省直接用 ContentStore（已落盘条目的常规路径，带 .history 备份）。
## 返回 {written: n, failed: [{cid, why}]}。任一失败不停手——每条独立，
## 失败条目会在结果里列名（批量半成功是事实，不粉饰成成功或失败）。
static func apply_field(manifest: Dictionary, fn_id: String, plan: Dictionary,
		read_fn: Callable = Callable(), write_fn: Callable = Callable()) -> Dictionary:
	var code := str(plan.get("code", ""))
	var nv = plan.get("new", null)
	var written := 0
	var failed: Array = []
	for cid in (plan.get("targets", []) as Array):
		var id := str(cid)
		var data: Dictionary
		if read_fn is Callable and (read_fn as Callable).is_valid():
			data = read_fn.call(fn_id, id)
		else:
			data = ContentStore.read(manifest, fn_id, id)
		if data.is_empty():
			failed.append({"cid": id, "why": "读不到内容文件"})
			continue
		var fv: Dictionary = data.get("fields", {}) if data.get("fields", {}) is Dictionary else {}
		fv[code] = nv
		data["fields"] = fv
		var ok := false
		if write_fn is Callable and (write_fn as Callable).is_valid():
			ok = bool(write_fn.call(fn_id, id, data))
		else:
			ok = ContentStore.write(manifest, fn_id, id, data)
		if ok:
			written += 1
		else:
			failed.append({"cid": id, "why": "写入失败"})
	return {"written": written, "failed": failed}

## 同码同类型判据（给 UI 显示「哪些字段可以一起改」用）：
## 返回该功能里所有可批量字段 [{fd, code, type, name}]。
static func batchable_fields(manifest: Dictionary, fn_id: String) -> Array:
	var out := []
	for fd in FunctionDecls.function_fields(manifest, fn_id):
		if not (fd is Dictionary) or not is_batchable(fd):
			continue
		var f: Dictionary = fd
		out.append({"fd": f, "code": field_key(f), "type": str(f.get("type", "")),
			"name": _fname(f)})
	return out

static func _field_by_key(fields: Array, key: String) -> Dictionary:
	for fd in fields:
		if fd is Dictionary and field_key(fd) == key:
			return fd
	return {}

static func _fname(fd: Dictionary) -> String:
	var nm := str(fd.get("name", ""))
	return nm if nm != "" else str(fd.get("id", ""))

## 旧值类型是否与声明一致（与 field_widgets 的严格口径一致：不静默改写异类值）。
## null / "" 视为未填——批量把未填改成目标值是正常用法。
static func _value_ok(typ: String, v) -> bool:
	if v == null or (v is String and str(v) == ""):
		return true
	match typ:
		"bool":
			return v is bool
		"int":
			return v is int or (v is float and is_equal_approx(float(v), roundf(float(v))))
		"float", "range":
			return v is int or v is float
		"vector2":
			return v is Array and ((v as Array).size() == 2 or (v as Array).size() == 3)
		"color":
			return v is String
		"string":
			return v is String
		"choice":
			return v is String or v is Array
		"asset_ref":
			return v is String
		"array":
			return v is Array
		_:
			return false
