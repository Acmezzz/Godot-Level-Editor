extends RefCounted
## RelGraph：内容关系图（E2）。纯数据 + 单一写入口。
##
## 项目图包含内容和参考视图；关系写回声明字段、布局元素或热点。
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
const References := preload("res://src/project/reference_index.gd")
const ScreenLayout := preload("res://src/project/screen_layout.gd")
const VIEW_KIND := "@view"
const MAP_KIND := "@map"

## 建图。scope_fn = 当前功能 id（只画这个功能的内容条目与其出边）。
## extra = 尚未落盘的内容 {cid: data}（A2 staged），并入本功能目录参与建图。
## 返回 {nodes: [{key, cid, fn_id, name, fields}], slots: {node_key: [可编辑引用槽]},
##       edges: [{from, to, field, label, cid, fn_id, step, decl, multi}],
##       external: [带原始目标 ID 的可编辑槽]（引用了不存在的内容）,
##       bad: 读不出的内容文件}
## 节点 key = fn_id + "\u0001" + cid（与 ProjectAudit 的内容键同口径）。
static func build(manifest: Dictionary, fn_id: String, extra: Dictionary = {}) -> Dictionary:
	return _build(manifest, [fn_id] if fn_id != "" else [], {fn_id: extra}, fn_id)

## 项目图包含所有已声明功能的已保存内容，可从 slots 编辑尚未设置的引用。
static func build_project(manifest: Dictionary) -> Dictionary:
	var kinds := FunctionDecls.functions(manifest).keys()
	kinds.sort()
	return _build(manifest, kinds, {}, "")

## Index saved relations once for navigation. Unset and broken references stay in the full graph.
static func navigation(graph: Dictionary) -> Dictionary:
	var index := {"nodes": {}, "incoming": {}, "outgoing": {}}
	for node: Dictionary in graph.nodes:
		index.nodes[node.key] = node
		index.incoming[node.key] = []
		index.outgoing[node.key] = []
	for edge: Dictionary in graph.edges:
		if not index.nodes.has(edge.to):
			continue
		index.incoming[edge.to].append(edge)
		index.outgoing[edge.from].append(edge)
	return index

static func neighborhood(index: Dictionary, key: String) -> Dictionary:
	if not index.nodes.has(key):
		return {"nodes": [], "edges": []}
	var local := {key: index.nodes[key]}
	var edges: Array = index.outgoing[key].duplicate()
	for edge: Dictionary in edges:
		local[edge.to] = index.nodes[edge.to]
	for edge: Dictionary in index.incoming[key]:
		if edge.from != key:
			local[edge.from] = index.nodes[edge.from]
			edges.append(edge)
	return {"nodes": local.values(), "edges": edges}

static func _build(manifest: Dictionary, kinds: Array, extra: Dictionary, scope: String) -> Dictionary:
	var graph := {"nodes": [], "edges": [], "external": [], "bad": [], "slots": {}}
	var catalog := {}
	var contents := {}
	var steps_by_code := {}
	if scope.is_empty():
		catalog[VIEW_KIND] = {}
		for id in References.view_ids(manifest):
			catalog[VIEW_KIND][id] = true
		if manifest.get("directMapTargets") == true:
			catalog[MAP_KIND] = {}
			for map in References.map_target_options(manifest):
				catalog[MAP_KIND][map.code] = true
				graph.nodes.append({"key": _key(MAP_KIND, map.code), "cid": map.code, "fn_id": MAP_KIND, "name": map.name})
	for kind in kinds:
		var items := ContentStore.read_all(manifest, str(kind), graph.bad)
		var staged: Dictionary = extra.get(kind, {})
		for cid in staged:
			if staged[cid] is Dictionary:
				items[str(cid)] = staged[cid]
		contents[kind] = items
		catalog[kind] = {}
		for cid in items:
			catalog[kind][cid] = true
	for kind in kinds:
		var fn_id := str(kind)
		var decls := _top_decls(manifest, fn_id)
		for cid in contents[kind]:
			var data: Dictionary = contents[kind][cid]
			var key := _key(fn_id, str(cid))
			var values: Dictionary = data.fields if data.get("fields") is Dictionary else {}
			var label := str(data.get("name", ""))
			graph.nodes.append({"key": key, "cid": str(cid), "fn_id": fn_id,
				"name": label if label != "" else str(cid), "fields": values.size()})
			graph.slots[key] = []
			var base := {"cid": str(cid), "fn_id": fn_id}
			_collect(manifest, key, base, decls, values, -1, graph, catalog)
			var steps = data.get("steps")
			if not steps is Array:
				continue
			base["shown_steps"] = steps.duplicate(true)
			for i in steps.size():
				if not steps[i] is Dictionary:
					continue
				var row: Dictionary = steps[i]
				var code := str(row.get("step", ""))
				if not steps_by_code.has(code):
					steps_by_code[code] = StepDecls.step_by_code(manifest, code)
				var fields: Dictionary = row.fields if row.get("fields") is Dictionary else {}
				var sdecls = steps_by_code[code].get("fields", [])
				if sdecls is Array:
					_collect(manifest, key, base, sdecls, fields, i, graph, catalog, "步骤%d" % (i + 1))
	if scope.is_empty():
		_collect_views(manifest, graph, catalog)
	else:
		_add_target_nodes(manifest, scope, graph.nodes, graph.edges)
	return graph

static func _collect_views(manifest: Dictionary, graph: Dictionary, catalog: Dictionary) -> void:
	var views = manifest.get("views", [])
	if not views is Array:
		return
	var seen := {}
	var modules := ScreenLayout.modules(manifest)
	for view in views:
		if not view is Dictionary or not catalog[VIEW_KIND].has(view.get("view_id")) or seen.has(view.view_id):
			continue
		var id: String = view.view_id
		seen[id] = true
		var key := _key(VIEW_KIND, id)
		graph.nodes.append({"key": key, "cid": id, "fn_id": VIEW_KIND, "name": id})
		graph.slots[key] = []
		for group in ["elements", "hotspots"]:
			var rows := _view_rows(view, group).duplicate(true)
			for i in rows.size():
				if not rows[i] is Dictionary:
					continue
				var row: Dictionary = rows[i]
				var label := str(row.get("text", "")).strip_edges()
				if label.is_empty():
					label = ("布局元素 " if group == "elements" else "热点 ") + str(i + 1)
				var labels := ScreenLayout.output_labels(modules, row) if group == "elements" and row.get("kind") == "module" else {}
				if group == "hotspots" or row.has("target") or (labels.is_empty() and row.get("kind") in ["button", "module"]):
					labels[""] = ""
				for output in labels:
					var current = ScreenLayout.target_at(row, output)
					var direct: bool = manifest.get("directViewTargets") == true and ScreenLayout.view_target(current)
					var to_map: bool = catalog.has(MAP_KIND) and ScreenLayout.map_target(current)
					if current != null and not direct and not to_map and not ScreenLayout.content_target(current):
						continue
					var fn: String = MAP_KIND if to_map else (VIEW_KIND if direct else (current.function if current != null else ""))
					var value: String = current.map if to_map else (current.view if direct else (current.content if current != null else ""))
					var edge := {"from": key, "fn_id": VIEW_KIND, "cid": id, "fn": fn,
						"value": value, "label": label if output == "" else label + " · " + labels[output],
						"multi": false, "group": group, "index": i, "shown_rows": rows, "output": output}
					graph.slots[key].append(edge)
					if current == null:
						continue
					if catalog.get(fn, {}).has(value):
						edge["to"] = _key(fn, value)
						graph.edges.append(edge)
					else:
						graph.external.append(edge)

static func _view_rows(view: Dictionary, group: String) -> Array:
	var layout = view.get("layout")
	var rows = layout.get("elements") if group == "elements" and layout is Dictionary else view.get(group)
	return rows if rows is Array else []

## Build a new views payload using the same row the author selected in the graph.
static func change_view_target(manifest: Dictionary, edge: Dictionary, target: Dictionary) -> Dictionary:
	var current = manifest.get("views")
	if not current is Array:
		return {"status": "stale"}
	var views: Array = current.duplicate(true)
	for view in views:
		if not view is Dictionary or view.get("view_id") != edge.cid:
			continue
		var rows := _view_rows(view, edge.group)
		if rows != edge.shown_rows:
			return {"status": "stale"}
		var row: Dictionary = rows[edge.index]
		var output: String = edge.get("output", "")
		var current_target = ScreenLayout.target_at(row, output)
		if current_target == target or (current_target == null and target.is_empty()):
			return {"status": "noop"}
		ScreenLayout.set_target(row, output, target)
		return {"status": "ok", "views": views}
	return {"status": "stale"}

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
	var decls := _top_decls(manifest, fn_id)
	if step >= 0:
		var rows = edge.get("shown_steps")
		if not rows is Array or step >= rows.size() or not rows[step] is Dictionary:
			return false
		var decl := StepDecls.step_by_code(manifest, str(rows[step].get("step", "")))
		if not decl.get("fields") is Array:
			return false
		decls = decl.fields
	var trail: Array = edge.get("trail", [])
	var values := {}
	if not trail.is_empty():
		values[trail[0].field] = edge.get("shown_anchor")
	for part in trail:
		var desc := {}
		for fd in decls:
			if fd is Dictionary and _field_key(fd) == part.field:
				desc = fd
				break
		var descended := false
		for scope in RefFields.nested_scopes(manifest, desc, values.get(part.field)):
			if scope.path != part.branch:
				continue
			decls = scope.decls
			values = scope.values
			descended = true
			break
		if not descended:
			return false
	return decls.has(edge.decl)

static func _field_key(fd: Dictionary) -> String:
	var code := str(fd.get("code", ""))
	return code if code != "" else str(fd.get("id", ""))

static func _collect(manifest: Dictionary, from_key: String, base: Dictionary, decls: Array,
		values: Dictionary, step: int, graph: Dictionary, catalog: Dictionary, prefix := "") -> void:
	var trail: Array = base.get("trail", [])
	if trail.size() > 8:
		return
	for fd in decls:
		if not fd is Dictionary:
			continue
		var field := _field_key(fd)
		if field == "":
			continue
		var label := str(fd.get("name", field))
		if prefix != "":
			label = "%s · %s" % [prefix, label]
		var shown = values.get(field)
		var scopes := RefFields.nested_scopes(manifest, fd, shown)
		if not scopes.is_empty():
			var anchor = shown.duplicate(true) if trail.is_empty() else base.shown_anchor
			for scope in scopes:
				var nested := base.duplicate()
				nested["trail"] = trail + [{"field": field, "branch": scope.path}]
				nested["shown_anchor"] = anchor
				_collect(manifest, from_key, nested, scope.decls, scope.values, step, graph, catalog,
					"%s %s" % [label, scope.label])
		var desc := RefFields.describe(fd)
		if desc.kind != "content" and not (desc.kind == "view" and catalog.has(VIEW_KIND)):
			continue
		var to_fn := VIEW_KIND if desc.kind == "view" else str(desc.get("filter", {}).get("fn", ""))
		if to_fn == "":
			to_fn = str(base.fn_id)
		var multi := bool(desc.get("many", false))
		var row := base.duplicate()
		row.merge({"from": from_key, "field": field, "label": label, "step": step,
			"decl": fd.duplicate(true), "shown_value": shown.duplicate(true) if shown is Array or shown is Dictionary else shown,
			"shown_present": values.has(field), "multi": multi, "fn": to_fn})
		if not catalog.has(to_fn):
			var ids := {}
			for id in ContentStore.list_ids(manifest, to_fn):
				ids[id] = true
			catalog[to_fn] = ids
		var refs := _as_list(shown)
		for i in refs.size():
			var target := str(refs[i])
			var slot := row.duplicate()
			slot.merge({"index": i, "value": target})
			if target != "" and catalog[to_fn].has(target):
				slot["to"] = _key(to_fn, target)
				graph.edges.append(slot)
			elif target != "":
				graph.external.append(slot)
			graph.slots[from_key].append(slot)
		if multi or refs.is_empty():
			var slot := row.duplicate()
			slot.merge({"index": -1, "value": ""})
			graph.slots[from_key].append(slot)

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
## 返回 {status: ok/noop/missing/stale/failed}。
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
		if not shown.is_empty() and not _same_value(steps, shown.get("shown_steps")):
			return {"status": "stale"}
		var st: Dictionary = (steps as Array)[step]
		if not (st.get("fields", null) is Dictionary):
			st["fields"] = {}
		holder = st
	var fields: Dictionary = holder.get("fields", {}) if holder.get("fields", null) is Dictionary else {}
	var trail: Array = shown.get("trail", [])
	if not trail.is_empty():
		if not _same_value(fields.get(trail[0].field), shown.get("shown_anchor")):
			return {"status": "stale"}
		for part in trail:
			var nested = fields.get(part.field)
			for key in part.branch:
				if nested is Array and key is int and key >= 0 and key < nested.size():
					nested = nested[key]
				elif nested is Dictionary and nested.has(key):
					nested = nested[key]
				else:
					return {"status": "missing"}
			if not nested is Dictionary:
				return {"status": "missing"}
			fields = nested
	if not shown.is_empty() and (fields.has(field) != bool(shown.get("shown_present", true)) \
			or not _same_value(fields.get(field), shown.get("shown_value"))):
		return {"status": "stale"}
	if multi:
		var arr: Array = fields.get(field, []) if fields.get(field, null) is Array else []
		var at := int(shown.get("index", -1)) if not shown.is_empty() else arr.find(old_cid if old_cid != "" else to_cid)
		if not shown.is_empty() and at == -1:
			if to_cid == "" or (arr.has(to_cid) and not RefFields.is_ordered_choice(shown.get("decl", {}))):
				return {"status": "noop"}
			arr.append(to_cid)
		elif at < 0 or at >= arr.size():
			return {"status": "missing"}
		elif to_cid == "":
			arr.remove_at(at)
		else:
			if str(arr[at]) == to_cid:
				return {"status": "noop"}
			arr[at] = to_cid
		fields[field] = arr
	else:
		var cur := str(fields.get(field, "")) if fields.get(field, null) != null else ""
		if cur == to_cid and (to_cid != "" or not fields.has(field)):
			return {"status": "noop"}
		if to_cid == "":
			fields.erase(field)   # 断开：删键，与 C1「未设置」一致
		else:
			fields[field] = to_cid
	if trail.is_empty():
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

static func _same_value(a: Variant, b: Variant) -> bool:
	return typeof(a) == typeof(b) and a == b

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
