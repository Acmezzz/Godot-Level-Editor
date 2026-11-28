extends RefCounted
## Checks one spatial reference against the source and any supplied map snapshots.

const MapStore := preload("res://src/map/map_store.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const K := preload("res://src/core/constants.gd")
const EdgeRef := preload("res://src/map/edge_ref.gd")
const CellGraphScript := preload("res://src/map/cell_graph.gd")
const ReferenceIndex := preload("res://src/project/reference_index.gd")
const FlowTarget := preload("res://src/content/flow_target.gd")
const MapFlow := preload("res://src/map/map_flow.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const EventLayers := preload("res://src/project/event_layers.gd")
const Usage := preload("res://src/project/reference_usage.gd")

static func map_links(manifest: Dictionary, data: Dictionary) -> Array:
	var rows := ReferenceIndex.entity_property_refs(manifest, data,
		["entity_inst", "port", "edge", "cell", "layer", "flow_target", "content"])
	rows.append_array(MapFlow.references(manifest, data))
	return rows

static func link_problem(manifest: Dictionary, source: Dictionary, ref: Dictionary, overrides := {}) -> String:
	var kind: String = ref.kind
	if kind == "flow_target":
		if not ref.value is Dictionary or not ref.value.has("port") or not ref.value.has("map"):
			return ""
		kind = "port"
	return problem(manifest, kind, source, ref.value, ref.decl, ref.get("paired", ""), overrides).get("message", "")

static func removed_targets(before: Dictionary, after: Dictionary) -> bool:
	var ids := func(map: Dictionary) -> Dictionary:
		var result := {}
		for row in map.get("objects", []):
			if row.get("code", "") != "":
				result[["entity", row.code, row.get("asset", "")]] = true
		for layer in map.get("meta", {}).get("layers", []):
			result[["layer", layer.id]] = true
		for cell in CellGraphScript.cell_ids(map.get("meta", {}).get("cellGraph", {})):
			result[["cell", cell]] = true
		return result
	var remaining: Dictionary = ids.call(after)
	var old: Dictionary = ids.call(before)
	return old.keys().any(func(key): return not remaining.has(key)) \
		or before.meta.get("w", 0) > after.meta.get("w", 0) or before.meta.get("h", 0) > after.meta.get("h", 0)

static func blocked_removals(manifest: Dictionary, before: Dictionary, after: Dictionary, staged: Array) -> String:
	if before.is_empty() or not removed_targets(before, after):
		return ""
	var sources := MapStore.read_all_fresh(manifest)
	sources[after.meta.name] = after
	var contexts_by_code := {}
	var links_by_code := {}
	for name in sources:
		var data: Dictionary = sources[name]
		var refs := map_links(manifest, data)
		var link_issue := _broken_link(manifest, data, refs, before, after)
		if link_issue != "":
			return "%s · %s" % [name, link_issue]
		var code: String = data.meta.get("code", "")
		var key := code if code != "" else ":" + str(name)
		contexts_by_code[key] = data
		links_by_code[key] = refs

	var project_refs := ReferenceIndex.view_module_refs(manifest)
	var targets := [{"target": manifest.get("startup", {}).get("target", {}), "path": "startup.target"}]
	targets.append_array(ReferenceIndex.view_map_refs(manifest))
	for ref in EventLayers.references(manifest):
		targets.append({"target": ref.target, "path": "图组事件层 · " + ref.name})
	for ref in targets:
		project_refs.append({"kind": "flow_target", "value": ref.target, "path": ref.path, "decl": {}})
	var error := _broken_link(manifest, {}, project_refs, before, after)
	if error != "":
		return error

	var items_by_key := {}
	for kind in ContentStore.declared_kinds(manifest):
		var items := ContentStore.read_all(manifest, kind)
		for cid in items:
			items_by_key[[kind, cid]] = content_refs(manifest, kind, items[cid])
	for row in staged:
		items_by_key[[row.fn_id, row.cid]] = content_refs(manifest, row.fn_id, row.data)
	for key in items_by_key:
		error = _broken_link(manifest, {}, items_by_key[key], before, after)
		if error != "":
			return "内容 %s/%s · %s" % [key[0], key[1], error]
	var contexts := content_contexts(manifest, contexts_by_code, func(fn: String, cid: String) -> Array:
		return items_by_key.get([fn, cid], []), links_by_code, items_by_key.keys())
	for key in contexts:
		for data in contexts[key].values():
			error = _broken_link(manifest, data, items_by_key.get(key, []), before, after)
			if error != "":
				return "%s · 内容 %s/%s · %s" % [data.meta.get("name", data.meta.get("code", "")), key[0], key[1], error]
	return ""

static func _context_content(ref: Dictionary, fn: String) -> Array:
	if ref.kind == "flow_target" and FlowTarget.kind(ref.value) == "content":
		return [ref.value.function, ref.value.content]
	if ref.kind == "content":
		var target_fn: String = ref.filter.get("fn", "")
		return [target_fn if target_fn != "" else fn, ref.value]
	return []

static func uses_paired_content_map(ref: Dictionary) -> bool:
	return ref.decl.get("contentMapContext") == "paired" and not _context_content(ref, "").is_empty()

## Follow only links that declare how to supply a map; each (content, map) is processed once.
static func content_contexts(manifest: Dictionary, maps: Dictionary, refs_for: Callable, map_refs := {}, content_keys := []) -> Dictionary:
	var contexts := {}
	var queue := []
	var enqueue := func(key: Array, code: String):
		if key.is_empty() or key[0] == "" or not maps.has(code):
			return
		var by_map: Dictionary = contexts.get_or_add(key, {})
		if not by_map.has(code):
			by_map[code] = maps[code]
			queue.append([key, code])
	var forward := func(ref: Dictionary, fn: String, code: String):
		match ref.decl.get("contentMapContext"):
			"inherit":
				if code != "":
					enqueue.call(_context_content(ref, fn), code)
			"paired":
				enqueue.call(_context_content(ref, fn), ref.get("paired", ""))
	var refs_by_content := {}
	var read_refs := func(key: Array) -> Array:
		if not refs_by_content.has(key):
			refs_by_content[key] = refs_for.call(key[0], key[1])
		return refs_by_content[key]
	for key in content_keys:
		for ref in read_refs.call(key):
			forward.call(ref, key[0], "")
	for code in maps:
		var map: Dictionary = maps[code]
		for object in map.get("objects", []):
			for binding in object.get("functions", []):
				var cid: String = binding.get("content", "")
				if cid != "":
					enqueue.call([FunctionDecls.fn_id_of(manifest, binding.get("fn", "")), cid], code)
		var links: Array = map_refs[code] if map_refs.has(code) else map_links(manifest, map)
		for ref in links:
			forward.call(ref, "", code)
	for ref in ReferenceIndex.view_content_refs(manifest):
		if ref.has("context_map"):
			enqueue.call([ref.fn, ref.cid], ref.context_map)
	var startup: Dictionary = manifest.get("startup", {})
	var entry: Dictionary = startup.get("target", {})
	if FlowTarget.kind(entry) == "content" and startup.get("contentMap", "") != "":
		enqueue.call([entry.function, entry.content], startup.contentMap)
	var i := 0
	while i < queue.size():
		var item: Array = queue[i]
		i += 1
		var key: Array = item[0]
		for ref in read_refs.call(key):
			forward.call(ref, key[0], item[1])
	return contexts

## A new valid canvas link that the published map cannot resolve must wait for map save.
static func needs_map_save(manifest: Dictionary, fn: String, data: Dictionary, live: Dictionary, saved: Dictionary) -> bool:
	var code: String = live.meta.code
	for ref in content_refs(manifest, fn, data):
		if not _local_spatial_ref(ref, code):
			continue
		if link_problem(manifest, live, ref, {code: live}) != "":
			continue
		if saved.is_empty():
			if ref.kind != "flow_target" or (ref.value is Dictionary and ref.value.has("port")):
				return true
		elif link_problem(manifest, saved, ref, {code: saved}) != "":
			return true
	return false

static func _local_spatial_ref(ref: Dictionary, code: String) -> bool:
	if ref.kind not in ["entity_inst", "layer", "cell", "edge", "port", "flow_target"]:
		return false
	var target: String = ref.get("paired", "")
	if ref.kind in ["port", "edge", "flow_target"] and ref.value is Dictionary:
		target = RefFields.object_map_key(ref.value, target)
	return RefFields.map_key_local(target, code)

## A target placed and undone in this session never appears in the saved map's removal set.
## Check new/changed references in the content about to be published against the submitted map.
static func staged_problem(manifest: Dictionary, data: Dictionary, rows: Array) -> String:
	var code: String = data.get("meta", {}).get("code", "")
	for row in rows:
		var old := {}
		if not row.get("expect_absent", true):
			var published := ContentStore.read(manifest, row.fn_id, row.cid)
			for ref in content_refs(manifest, row.fn_id, published):
				old[ref.path] = [ref.kind, ref.value, ref.get("paired", "")]
		for ref in content_refs(manifest, row.fn_id, row.data):
			if not _local_spatial_ref(ref, code) or old.get(ref.path) == [ref.kind, ref.value, ref.get("paired", "")]:
				continue
			var error := link_problem(manifest, data, ref, {code: data})
			if error != "":
				return "内容 %s/%s · %s：%s" % [row.fn_id, row.cid, ref.path, error]
	return ""

static func _broken_link(manifest: Dictionary, source: Dictionary, refs: Array,
		before: Dictionary, after: Dictionary) -> String:
	var code: String = after.meta.code
	var old_source := before if source.get("meta", {}).get("code") == code else source
	for ref in refs:
		if link_problem(manifest, old_source, ref, {code: before}) != "":
			continue
		var error := link_problem(manifest, source, ref, {code: after})
		if error != "":
			return "%s：%s" % [ref.path, error]
	return ""

static func content_refs(manifest: Dictionary, fn: String, data: Dictionary) -> Array:
	var refs := []
	for section in Usage.content_sections(manifest, fn, data):
		refs.append_array(ReferenceIndex.property_refs(manifest, section.decls,
			section.values if section.values is Dictionary else {}, {}, section.prefix, "code"))
	return refs

static func converted_edge_problem(manifest: Dictionary, document: Dictionary, contents: Array) -> String:
	var refs := map_links(manifest, document)
	for row in contents:
		for ref in content_refs(manifest, row.fn_id, row.data):
			ref.path = "%s · %s" % [row.cid, ref.path]
			refs.append(ref)
	for ref in refs:
		if ref.kind != "edge" or not ref.value is Dictionary:
			continue
		var key := RefFields.object_map_key(ref.value, ref.get("paired", ""))
		if RefFields.map_key_local(key, document.meta.code):
			var error := link_problem(manifest, document, ref)
			if error != "":
				return "%s：%s" % [ref.path, error]
	return ""

static func problem(manifest: Dictionary, kind: String, source: Dictionary,
		value: Variant, field: Dictionary, paired: String, overrides: Dictionary) -> Dictionary:
	var local_code := str(source.get("meta", {}).get("code", ""))
	match kind:
		"entity_inst", "layer":
			if not value is String:
				return {"message": ("图层引用必须是图层 ID 字符串" if kind == "layer" else "实例引用必须是实例码字符串")}
			var target := source
			if not RefFields.map_key_local(paired, local_code):
				if overrides.has(paired):
					target = overrides[paired]
				else:
					var resolved := ReferenceIndex.resolve_map(manifest, paired)
					target = MapStore.read(manifest, str(resolved.key)) if resolved.status == "ok" else {}
				if target.is_empty():
					return {"message": "目标地图不存在或不可读：%s" % paired}
			if target.is_empty():
				return {}
			var where := "目标图 %s" % paired if paired != "" else "本图"
			if kind == "layer":
				for layer in target.get("meta", {}).get("layers", []):
					if layer is Dictionary and layer.get("id") == value:
						return {}
				# 保留 ID，作者可重新选择坐标空间；不要把原路径默认为别的空间。
				return {"message": "%s不存在图层：%s" % [where, value]}
			if ReferenceIndex.entity_asset(manifest, target, value) != "":
				return {}
			return {"message": "引用的实例码在%s不存在: %s" % [where, str(value)]}
		"port":
			if source.is_empty() and paired == "" and value is Dictionary \
					and value.get("map", "") is String and str(value.get("map", "")) == "":
				return {}
			return _port_ref_problem(manifest, source, value, field, paired, overrides)
		"edge":
			if source.is_empty() and paired == "" and value is Dictionary \
					and value.get("map", "") is String and str(value.get("map", "")) == "":
				return {}
			return _edge_ref_problem(manifest, source, value, overrides, paired)
		"cell":
			return _cell_ref_problem(manifest, source, str(value), paired, field, overrides)
		"map":
			if manifest.get("_maps_dir", "") != "" and not overrides.has(str(value)) \
					and not RefFields.map_key_local(str(value), local_code) \
					and ReferenceIndex.resolve_map(manifest, str(value)).status not in ["ok", "ambiguous"]:
				return {"message": "目标地图不存在: %s" % str(value)}
	return {}

static func _port_ref_problem(manifest: Dictionary, data: Dictionary,
		value: Variant, field: Dictionary, paired_map: String, overrides := {}) -> Dictionary:
	if value is Dictionary and value.is_empty():
		return {}
	if not value is Dictionary or not value.get("map") is String \
			or not value.get("inst") is String or not value.get("port") is String:
		return {"message": "端口引用需要 {map, inst, port} 字符串字段"}
	var local_code := str(data.get("meta", {}).get("code", ""))
	var target_key := RefFields.object_map_key(value, paired_map)
	var target := data
	if RefFields.map_key_local(target_key, local_code):
		pass
	elif overrides.has(target_key):
		target = overrides[target_key]
	else:
		var resolved := ReferenceIndex.resolve_map(manifest, target_key)
		match str(resolved.status):
			"ok":
				target = MapStore.read(manifest, str(resolved.key))
				if target.is_empty():
					return {}
			"missing":
				return {"message": "端口的目标地图不存在：" + target_key}
			_:
				return {}
	var types := str(field.get("of", "")).split(",", false)
	var asset_id := ReferenceIndex.entity_asset(manifest, target, value.inst)
	if asset_id == "":
		return {"message": "目标端口的实例不存在：" + str(value.inst)}
	for port in RefFields.ports_of(AssetDecl.by_id(manifest, asset_id)):
		if port is Dictionary and port.get("id") == value.port:
			if types.is_empty() or types.has(str(port.get("type", ""))):
				return {}
			return {"message": "目标端口类型与字段声明不匹配：" + str(value.port)}
	return {"message": "实例没有对应的端口：" + str(value.port)}


## edge_ref 悬空判定（§7.4）：边身份由格拓扑推导，因此只验「目标图存在 + 两格确实相邻 + cell 自洽」。
## 目标图本图/跨图取法与 map_ref 一致；图读不出来时比对双方拓扑会误报，故只按「读不到不判悬空」放行。
## 目标图有歧义或不可读时，由地图检查报告。
static func _edge_ref_problem(manifest: Dictionary, data: Dictionary, val, overrides: Dictionary,
		paired: String) -> Dictionary:
	if not (val is Dictionary):
		return {"message": "格边引用值不是 {map, cell, edge} 字典"}
	var v: Dictionary = val
	if not v.get("edge") is String or not v.get("map", "") is String:
		return {"message": "格边引用的 map 和 edge 必须是字符串"}
	var e_code := str(v.get("edge", ""))
	var ends := EdgeRef.parse_edge(e_code)
	if ends.size() != 2:
		return {"message": "格边引用格式不合法: %s" % e_code}
	var e_map := RefFields.object_map_key(v, paired)
	var tgt_meta: Dictionary = data.get("meta", {}) if data.get("meta", {}) is Dictionary else {}
	if RefFields.map_key_local(e_map, str(tgt_meta.get("code", ""))):
		pass
	elif overrides.has(e_map):
		tgt_meta = overrides[e_map].meta
	else:
		var resolved := ReferenceIndex.resolve_map(manifest, e_map)
		var rstat := str(resolved.status)
		if rstat == "ambiguous":
			# 一码多图：不知道指的是哪张图，比对邻接没有意义（由码冲突条目单列）
			return {"message": ""}
		if rstat != "ok":
			return {"message": "格边引用的目标地图不存在: %s" % e_map}
		var td: Dictionary = MapStore.read(manifest, str(resolved.key))
		if td.is_empty():
			# 目标图存在但读不出来：拓扑不可比，不判悬空
			return {"message": ""}
		tgt_meta = td.get("meta", {}) if td.get("meta", {}) is Dictionary else {}
	var g: GridSpace = GridSpace.resolve(tgt_meta, manifest).get("grid") as GridSpace
	var ea := Vector2i(int(ends[0][0]), int(ends[0][1]))
	var eb := Vector2i(int(ends[1][0]), int(ends[1][1]))
	var w := int(tgt_meta.get("w", K.DEFAULT_MAP_W))
	var h := int(tgt_meta.get("h", K.DEFAULT_MAP_H))
	if not g.cell_in_map(ea, w, h) or not g.cell_in_map(eb, w, h):
		return {"message": "格边引用超出目标地图范围: %s" % e_code}
	if EdgeRef.segment(g, ea, eb, w, h).is_empty():
		return {"message": "格边引用的两格在地图里不相邻: %s" % e_code}
	var cell = v.get("cell", null)
	if not cell is Array or cell.size() != 2 or cell[0] != ea.x or cell[1] != ea.y:
		return {"message": "格边引用的 cell 与 edge 不自洽: %s" % e_code}
	return {"message": ""}

## cell: 引用悬空判定（§4.2-2）：有限格图的合法性**只由声明决定**——cell_id 必须在目标图
## meta.cellGraph.cells 里，不按整数格坐标或邻接推导（格图是游戏侧契约，可任意多边形）。
## 目标图解析歧义/读不出、或目标图根本没有格图声明 = 判定范围不完整，只报诊断不给清空项。
## 返回 {message}。
static func _cell_ref_problem(manifest: Dictionary, data: Dictionary, cid: String,
		paired: String, decl: Dictionary, overrides: Dictionary) -> Dictionary:
	var tgt_meta: Dictionary = data.get("meta", {})
	if not RefFields.map_key_local(paired, str(tgt_meta.get("code", ""))):
		if overrides.has(paired):
			tgt_meta = overrides[paired].get("meta", {})
		else:
			var resolved := ReferenceIndex.resolve_map(manifest, paired)
			if resolved.status in ["ambiguous"]:
				return {}
			if resolved.status != "ok":
				return {"message": "格图引用的目标地图不存在: %s" % paired}
			tgt_meta = MapStore.read(manifest, str(resolved.key)).get("meta", {})
	var graph: Dictionary = tgt_meta.get("cellGraph", {}) if tgt_meta.get("cellGraph", {}) is Dictionary else {}
	var ids: Array = CellGraphScript.cell_ids(graph)
	if ids.is_empty() and not overrides.values().any(func(doc): return doc.get("meta", {}) == tgt_meta):
		# 没有格图声明：无法判定这枚 cell_id 是否合法（不是「确证悬空」），不产清空项
		return {"message": ""}
	if not ids.has(cid):
		return {"message": "引用的格 id 不在目标图的格图里: %s" % cid}
	var space = CellGraphScript.cell_source_space(decl)
	if space != null and not CellGraphScript.cell_options(graph, space).any(func(o): return o.v == cid):
		return {"message": "引用的格不在声明的空间 %s: %s" % [space, cid]}
	return {"message": ""}
