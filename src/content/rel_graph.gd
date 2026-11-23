extends RefCounted
## RelGraph：内容关系图（E2）。纯数据 + 单一写入口。
##
## 节点 = (功能 id, 内容 ID)；边 = 声明为 content 引用的字段（功能字段、条件字段、步骤字段）。
## 图的真相仍是那些字段——本模块不缓存副本，只负责：
##   build()      读内容文件生成 {nodes, edges, external}（可并入尚未落盘的 staged 内容）；
##   set_edge()   把一条边的目标写回同一个字段（读/写回调由调用方给，复用表单的 staged 路径）。
## 断开设空串 = 删键（与 C1「未设置」同一规则）；多选字段只替换/移除一个元素。
## 循环引用合法（游戏允许），这里不做任何去环。

const ContentStore := preload("res://src/content/content_store.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const RefFields := preload("res://src/content/ref_fields.gd")

## 建图。scope_fn = 当前功能 id（只画这个功能的内容条目与其出边）。
## extra = 尚未落盘的内容 {cid: data}（A2 staged），并入本功能目录参与建图。
## 返回 {nodes: [{key, cid, fn_id, name, fields}],
##       edges: [{from, to, field, label, cid, fn_id, step, decl, multi}],
##       external: [{from, field, value, fn, label, cid, step}]（引用了不存在的内容）,
##       bad: 读不出的内容文件}
## 节点 key = fn_id + "\u0001" + cid（与 ProjectAudit 的内容键同口径）。
static func build(manifest: Dictionary, fn_id: String, extra: Dictionary = {}) -> Dictionary:
	var nodes: Array = []
	var edges: Array = []
	var external: Array = []
	var bad: Array = []
	if fn_id == "":
		return {"nodes": nodes, "edges": edges, "external": external, "bad": bad}
	var items := ContentStore.read_all(manifest, fn_id, bad)
	# staged 内容（A2 未落盘）覆盖同名条目——表单里刚改的值图里必须立刻可见
	for cid_x in extra:
		if extra[cid_x] is Dictionary:
			items[str(cid_x)] = extra[cid_x]
	var local_ids := {}
	for k in items:
		local_ids[str(k)] = true
	var decls := _top_decls(manifest, fn_id)
	for cid in items:
		var data: Dictionary = items[cid]
		var key := _key(fn_id, str(cid))
		nodes.append({"key": key, "cid": str(cid), "fn_id": fn_id,
			"name": str(data.get("name", "")) if str(data.get("name", "")) != "" else str(cid),
			"fields": (data.get("fields", {}) as Dictionary).size() if data.get("fields", {}) is Dictionary else 0})
		var base := {"cid": str(cid), "fn_id": fn_id}
		# 出边：功能/条件字段
		var values = data.get("fields", null)
		if values is Dictionary:
			_collect(manifest, key, base, decls, values as Dictionary, -1, edges, external, local_ids)
		# 出边：步骤字段（按每步自己的声明）
		var steps = data.get("steps", null)
		if steps is Array:
			base["shown_steps"] = (steps as Array).duplicate(true)
			for i in (steps as Array).size():
				var st = (steps as Array)[i]
				if not (st is Dictionary):
					continue
				var sfields = (st as Dictionary).get("fields", null)
				if not (sfields is Dictionary):
					continue
				var step_by := StepDecls.step_by_code(manifest, str((st as Dictionary).get("step", "")))
				var sdecls = step_by.get("fields", [])
				if sdecls is Array and not (sdecls as Array).is_empty():
					_collect(manifest, key, base, sdecls as Array, sfields as Dictionary, i,
						edges, external, local_ids, "步骤%d" % (i + 1))
	_add_target_nodes(manifest, fn_id, nodes, edges)
	return {"nodes": nodes, "edges": edges, "external": external, "bad": bad}

static func _top_decls(manifest: Dictionary, fn_id: String) -> Array:
	var decls := FunctionDecls.function_fields(manifest, fn_id).duplicate()
	var conds = FunctionDecls.function_decl(manifest, fn_id).get("conditions", null)
	for cond_id in (conds as Array) if conds is Array else []:
		var cd := ConditionDecls.condition_decl(manifest, str(cond_id))
		if cd.get("fields", []) is Array:
			decls.append_array(cd.get("fields", []) as Array)
	return decls

static func declaration_matches(manifest: Dictionary, fn_id: String, edge: Dictionary) -> bool:
	var step := int(edge.get("step", -1))
	if step < 0:
		return _top_decls(manifest, fn_id).has(edge.decl)
	var row: Dictionary = edge.shown_steps[step]
	var decl := StepDecls.step_by_code(manifest, str(row.get("step", "")))
	var fields = decl.get("fields", [])
	return fields is Array and fields.has(edge.decl)

static func _collect(manifest: Dictionary, from_key: String, base: Dictionary, decls: Array,
		values: Dictionary, step: int, edges: Array, external: Array, local_ids: Dictionary,
		prefix := "") -> void:
	var own_fn := _fn_of_key(from_key)
	for fd in decls:
		if not (fd is Dictionary):
			continue
		var desc := RefFields.describe(fd)
		if str(desc.get("kind", "")) != "content":
			continue
		var key := str((fd as Dictionary).get("code", ""))
		if key == "":
			key = str((fd as Dictionary).get("id", ""))
		if not values.has(key):
			continue
		var fname := str((fd as Dictionary).get("name", key))
		if prefix != "":
			fname = "%s·%s" % [prefix, fname]
		var want_fn := str((desc.get("filter", {}) as Dictionary).get("fn", ""))
		# 声明限定了功能就用它；没限定 = 同功能内的引用（内容 ID 只在功能目录里唯一）
		var to_fn := want_fn if want_fn != "" else own_fn
		var shown = values[key]
		var snapshot = shown.duplicate(true) if shown is Array else shown
		var refs := _as_list(shown)
		for index in refs.size():
			var cid := str(refs[index])
			if cid == "":
				continue
			var row := base.duplicate()
			row["field"] = key
			row["label"] = fname
			row["step"] = step
			row["decl"] = (fd as Dictionary).duplicate(true)
			row["shown_value"] = snapshot
			row["index"] = index
			row["multi"] = bool(desc.get("many", false))
			var exists := ContentStore.list_ids(manifest, to_fn).has(cid)
			if not exists and to_fn == own_fn and local_ids.has(cid):
				exists = true   # staged 内容还没落盘
			if exists:
				row["from"] = from_key
				row["to"] = _key(to_fn, cid)
				edges.append(row)
			else:
				# 内容不存在（或声明的功能目录不匹配）：不编造节点，单独列出供定位修正
				external.append({"from": from_key, "field": key, "value": cid, "fn": to_fn,
					"label": fname, "cid": str(base.get("cid", "")), "step": step})

## 跨功能目标补占位节点：节点身份是 (功能 ID, 内容 ID)，别的功能的条目也要能看见。
static func _add_target_nodes(manifest: Dictionary, fn_id: String, nodes: Array, edges: Array) -> void:
	var seen := {}
	for n in nodes:
		seen[str((n as Dictionary).get("key", ""))] = true
	for e in edges:
		var tk := str((e as Dictionary).get("to", ""))
		if seen.has(tk):
			continue
		seen[tk] = true
		var tf := _fn_of_key(tk)
		var tc := str(tk.substr(tf.length() + 1))
		var td := ContentStore.read(manifest, tf, tc)
		nodes.append({"key": tk, "cid": tc, "fn_id": tf,
			"name": str(td.get("name", "")) if str(td.get("name", "")) != "" else tc,
			"fields": 0, "other_fn": tf != fn_id})

## 写一条边：把 from 内容的 field（step < 0 = 顶层 fields；否则 steps[step].fields）设成 to_cid。
## read_fn(fn_id, cid) → 内容字典；write_fn(fn_id, cid, data) → bool 或 "ok"/"conflict"/"fail"
## （表单的 staged 感知实现，F1/P04 起返回状态串）。
## multi 字段（值是数组）：old_cid 指出要替换/移除的元素，其余值原样保留。
## 返回 {status: ok/noop/missing/failed}。
static func set_edge(read_fn: Callable, write_fn: Callable, fn_id: String, cid: String,
		step: int, field: String, to_cid: String, multi: bool, old_cid := "", shown: Dictionary = {}) -> Dictionary:
	if cid == "" or field == "":
		return {"status": "failed"}
	var data: Dictionary = read_fn.call(fn_id, cid)
	if data.is_empty():
		return {"status": "missing"}
	var holder: Dictionary = data
	if step >= 0:
		var steps = data.get("steps", null)
		if not (steps is Array) or step >= (steps as Array).size() or not ((steps as Array)[step] is Dictionary):
			return {"status": "missing"}
		if not shown.is_empty() and steps != shown.get("shown_steps"):
			return {"status": "stale"}
		var st: Dictionary = (steps as Array)[step]
		if not (st.get("fields", null) is Dictionary):
			st["fields"] = {}
		holder = st
	var fields: Dictionary = holder.get("fields", {}) if holder.get("fields", null) is Dictionary else {}
	if not shown.is_empty() and (not fields.has(field) or fields[field] != shown.get("shown_value")):
		return {"status": "stale"}
	if multi:
		var arr: Array = fields.get(field, []) if fields.get(field, null) is Array else []
		var at := int(shown.get("index", -1)) if not shown.is_empty() else arr.find(old_cid if old_cid != "" else to_cid)
		if at < 0 or at >= arr.size():
			return {"status": "missing"}
		if to_cid == "":
			arr.remove_at(at)
		else:
			if str(arr[at]) == to_cid:
				return {"status": "noop"}
			arr[at] = to_cid
		fields[field] = arr
	else:
		var cur := str(fields.get(field, "")) if fields.get(field, null) != null else ""
		if cur == to_cid and (fields.has(field) or to_cid == ""):
			return {"status": "noop"}
		if to_cid == "":
			fields.erase(field)   # 断开：删键，与 C1「未设置」一致
		else:
			fields[field] = to_cid
	holder["fields"] = fields
	if not _write_ok(write_fn.call(fn_id, cid, data)):
		return {"status": "failed"}
	return {"status": "ok"}

## 写回结果归一：老回调返回 bool；表单 _content_write 返回 "ok"/"conflict"/"fail"。
## 字符串非空即真会漏判失败，必须显式认 "ok"（F1/P04）。
static func _write_ok(v) -> bool:
	if v is String:
		return (v as String) == "ok"
	return bool(v)

static func _as_list(v) -> Array:
	if v is Array:
		return v
	if v == null or str(v) == "":
		return []
	return [v]

static func _key(fn_id: String, cid: String) -> String:
	return fn_id + "\u0001" + cid

static func _fn_of_key(key: String) -> String:
	var parts := key.split("\u0001")
	return str(parts[0]) if parts.size() > 0 else ""
