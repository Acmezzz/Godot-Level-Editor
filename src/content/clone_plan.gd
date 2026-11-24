extends RefCounted
## C2 复制计划：把「复制一批实例 / 整张图」变成一份可校验、可预演的数据计划。
##
## build(src, dst, codes, include_world) 输入两份文档上下文，输出：
##   {status, instance_map, content_map, map_patch, pending_contents, conflicts}
##   src/dst = {data: 地图文档, manifest: 清单}；直接传地图文档也接受。
##   status = "ok" | "conflict"（冲突时不应用任何改动）
##   instance_map 旧实例码 → 新实例码（只为本次复制集合内的实体发行）
##   content_map  旧内容 ID → 新内容 ID（附属内容独立成文件）
##   map_patch    {objects, tiles?, collision?, spawn?}：目标文档要写入的段
##   pending_contents [{fn_id, id, data}]：先写内容、后写地图（A2 顺序）
##   conflicts    [{kind, id, message}]
##
## 引用重映射按 C1 声明规则（C05：不做字符串盲扫）：只改声明为引用
## （entity_inst / content）的字段；组内引用换到副本，组外引用保留原目标。
## 配对了地图字段（mapField）的实例引用同时维护目标图：
##   组内 → 指向副本所在的图；跨图时的组外 → 指向源图；无配对且跨图 = 冲突。
##
## 整图复制走 whole_map_document：保留图片/瓦片/碰撞/出生点与游戏侧自定义键，
## 实例与附属内容全部独立，目标图重发地图码（由调用方先发行）。

const ContentStore := preload("res://src/content/content_store.gd")
const ContentId := preload("res://src/content/content_id.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const MapFlow := preload("res://src/map/map_flow.gd")
const FlowTarget := preload("res://src/content/flow_target.gd")
const ReferenceIndex := preload("res://src/project/reference_index.gd")

static func _data(ctx: Dictionary) -> Dictionary:
	if ctx.get("data", null) is Dictionary:
		return ctx.get("data") as Dictionary
	return ctx

static func _manifest(ctx: Dictionary) -> Dictionary:
	var m = ctx.get("manifest", null)
	return m as Dictionary if m is Dictionary else {}

static func _map_code(data: Dictionary) -> String:
	return str(data.get("meta", {}).get("code", ""))

## 发行一个未占用实例码；重试耗尽返回 ""。
static func _fresh_code(taken: Dictionary) -> String:
	for i in 64:
		var c := ContentId.new_inst_code()
		if not taken.has(c):
			return c
	return ""

## 声明数组里按人类字段 id 找声明，返回它的值键（内容/步骤值键=code，实例 props 键=id）。
static func _key_of(decls: Array, want_id: String) -> String:
	if want_id == "":
		return ""
	for fd in decls:
		if fd is Dictionary and str((fd as Dictionary).get("id", "")) == want_id:
			var c := str((fd as Dictionary).get("code", ""))
			return c if c != "" else want_id
	return ""

## 内容里该功能可填的全部字段声明（功能字段 + 引用到的条件字段）。
static func _content_decls(manifest: Dictionary, fn_id: String) -> Array:
	var out: Array = []
	out.append_array(FunctionDecls.function_fields(manifest, fn_id))
	var conds = FunctionDecls.function_decl(manifest, fn_id).get("conditions", null)
	for cid in (conds as Array) if conds is Array else []:
		var cd: Dictionary = ConditionDecls.condition_decl(manifest, str(cid))
		if not cd.is_empty() and cd.get("fields", []) is Array:
			out.append_array(cd.get("fields", []) as Array)
	return out

## 值里是否有任何一项命中映射表（判「组内」用）。
static func _touches(v, id_map: Dictionary) -> bool:
	if id_map.is_empty():
		return false
	if v is Array:
		for it in (v as Array):
			if it is String and id_map.has(it):
				return true
		return false
	return v is String and id_map.has(v)

## 值是否**全部**落在映射表里（单值 = 是否命中；数组 = 非空且每项都命中）。
## 组内/组外混排的多值引用不能整组改判地图归属，调用方据此报冲突（V4 P1）。
static func _all_in(v, id_map: Dictionary) -> bool:
	if id_map.is_empty():
		return false
	if v is Array:
		var arr := v as Array
		if arr.is_empty():
			return false
		for it in arr:
			if not (it is String) or not id_map.has(it):
				return false
		return true
	return v is String and id_map.has(v)

## 按映射表换值（多选数组逐元素；未命中原样）。
static func _swap(v, id_map: Dictionary):
	if v is Array:
		var out: Array = []
		for it in (v as Array):
			out.append(id_map.get(str(it), it) if it is String else it)
		return out
	if v is String and id_map.has(v):
		return id_map[v]
	return v

static func _is_empty_value(v) -> bool:
	if v == null:
		return true
	if v is String:
		return str(v) == ""
	if v is Array:
		return (v as Array).is_empty()
	return false

## 主入口。codes 为空 = 源文档里的对象全部参与（配合 include_world 做整图）；
## 非空只复制这些实例码（缺码的实例 = 冲突）。清单可缺省（纯数据对拷）。
static func content_key(fn_id: String, cid: String) -> String:
	return fn_id + "\u0001" + cid

## staged_contents：源工作副本 {ContentKey: data}，优先于正式内容。
static func build(src: Dictionary, dst: Dictionary, codes: PackedStringArray = PackedStringArray(),
		include_world := false, staged_contents := {}, self_copy := false) -> Dictionary:
	var sdata := _data(src)
	var ddata := _data(dst)
	var m := _manifest(src) if not _manifest(src).is_empty() else _manifest(dst)
	var source_key := _map_code(sdata)
	var target_code := _map_code(ddata)
	# codes 空 = 源文档里的对象全部参与复制（剪贴板/区域粘贴的源文档只含待复制行）。
	# include_world 才决定是否连瓦片/碰撞/出生点一起带（整图复制）。
	var copy_all := codes.is_empty()
	var conflicts: Array = []
	# —— 选行：整图 = 全部；否则只取集合内且有码的实体行 ——
	var src_rows: Array = sdata.get("objects", []) if sdata.get("objects", []) is Array else []
	var wanted := {}
	for c in codes:
		if str(c) != "":
			wanted[str(c)] = true
	var selected: Array = []
	var entities: Array[Dictionary] = []
	var src_by_code := {}
	for row in src_rows:
		if not (row is Dictionary):
			continue
		var r: Dictionary = row
		var scene := AssetDecl.by_id(m, str(r.get("asset", ""))).get("kind") == "scene"
		var code := "" if scene else str(r.get("code", ""))
		if code != "":
			if src_by_code.has(code):
				conflicts.append({"kind": "duplicate_code", "id": code,
					"message": "源图里实例码重复：%s" % code})
				continue
			src_by_code[code] = r
		if copy_all or (code != "" and wanted.has(code)):
			selected.append(r)
			if code != "":
				entities.append(r)
	if not copy_all:
		for c in wanted:
			if not src_by_code.has(c):
				conflicts.append({"kind": "missing_instance", "id": str(c),
					"message": "源图里没有实例 %s" % str(c)})
	var src_codes := {}
	for c0 in src_by_code:
		src_codes[str(c0)] = true
	# —— 发行新实例码：避开目标已有码与本次已发行 ——
	var taken := {}
	if self_copy:
		taken.merge(src_codes)
	for row2 in (ddata.get("objects", []) as Array):
		if row2 is Dictionary:
			var dc := str((row2 as Dictionary).get("code", ""))
			if dc != "":
				taken[dc] = true
	var instance_map := {}
	for row in entities:
		var old_code := str(row.code)
		var nc := _fresh_code(taken)
		if nc == "":
			conflicts.append({"kind": "code_exhausted", "id": old_code,
				"message": "新实例码发行失败（重试耗尽）"})
			continue
		taken[nc] = true
		instance_map[old_code] = nc
	# —— 内容克隆：每份被复制的绑定内容各生成独立文件 ——
	var pending: Array = []
	var content_map := {}
	var seen_cid := {}
	for row in entities:
		var new_code := str(instance_map.get(str(row.code), ""))
		if new_code == "":
			continue
		for f in (row.get("functions", []) as Array):
			if not (f is Dictionary):
				continue
			var fb: Dictionary = f
			var cid := str(fb.get("content", ""))
			if cid == "":
				continue
			var fn_code := str(fb.get("fn", ""))
			var fn_id := FunctionDecls.fn_id_of(m, fn_code) if not m.is_empty() else ""
			if fn_id == "":
				if not m.is_empty():
					conflicts.append({"kind": "content_function", "id": cid,
						"message": "内容 %s 的功能码 %s 未在清单声明" % [cid, fn_code]})
				continue
			var key := content_key(fn_id, cid)
			if seen_cid.has(key):
				continue
			seen_cid[key] = true
			var cdata: Dictionary = staged_contents[key] if staged_contents.has(key) else ContentStore.read(m, fn_id, cid)
			if cdata.is_empty():
				conflicts.append({"kind": "content_missing", "id": cid,
					"message": "内容文件读不到：%s/%s" % [fn_id, cid]})
				continue
			if str(cdata.get("scope", "")) == "project":
				continue
			var new_cid := _new_content_id(m, fn_id, ddata, new_code, cid)
			if new_cid == "":
				conflicts.append({"kind": "content_id", "id": cid,
					"message": "新内容 ID 生成失败：%s" % cid})
				continue
			if not content_map.has(fn_id):
				content_map[fn_id] = {}
			content_map[fn_id][cid] = new_cid
			var clone: Dictionary = cdata.duplicate(true)
			clone["id"] = new_cid
			clone["function"] = FunctionDecls.fn_code(m, fn_id)
			pending.append({"fn_id": fn_id, "id": new_cid, "data": clone})
	# —— 行补丁：实例码 / 引用 / 绑定（按声明，不做字符串盲扫） ——
	# §4.2-3：cross_code 只给「局部跨图复制」用（组外引用要钉在源图）。
	# 整图复制（self_copy=true）时副本本身就是源图的新身份：map:"" 随副本解释，
	# 组外与组内的引用都指向副本自己——原先复用局部复制口径会把它们钉回源图（复制完还指旧图）。
	var cross_code := source_key if not self_copy and source_key != target_code else ""
	var spatial_refs := {"cells": src.get("cell_ids", {}), "edge": src.get("map_edge", Callable()),
		"whole_map": self_copy, "map_copy": _map_copy_codes(sdata, ddata)}
	var scoped_ids := {}
	if self_copy:
		var roots: Array = MapFlow.scoped_content(m, sdata).map(func(ref): return ref.value)
		for row in entities:
			var fields: Array = AssetDecl.by_id(m, row.get("asset", "")).get("fields", [])
			roots.append_array(ReferenceIndex.inherited_property_targets(m, fields, row.get("props", {})))
			for binding in row.get("functions", []):
				if binding is Dictionary and binding.get("content", "") != "":
					var fn := FunctionDecls.fn_id_of(m, binding.get("fn", ""))
					if fn != "":
						roots.append({"function": fn, "content": binding.content})
		var probe := func(data: Dictionary, fn: String, visit: Callable):
			_remap_content(data, m, fn, instance_map, {}, "", src_codes, conflicts, target_code,
				source_key, spatial_refs.merged({"visit_scoped": visit}))
		scoped_ids = _clone_scoped_chain(m, roots, staged_contents, content_map, pending, conflicts,
			target_code, probe)
	var scoped_copies := {}
	for key in scoped_ids:
		var fn: String = key.get_slice("\u0001", 0)
		scoped_copies[content_key(fn, scoped_ids[key])] = true
	var out_objects: Array = []
	var object_scope := spatial_refs.merged({"scoped_ids": scoped_ids}) if self_copy else spatial_refs
	for r5 in selected:
		out_objects.append(remap_row(r5 as Dictionary, instance_map, content_map, m,
			cross_code, src_codes, conflicts, target_code, source_key, object_scope))
	# —— 内容副本内部引用：组内实例码/内容跳转按声明重映射（C05） ——
	for pc in pending:
		var scope := spatial_refs.merged({"scoped_ids": scoped_ids}) \
			if scoped_copies.has(content_key(pc.fn_id, pc.id)) else spatial_refs
		_remap_content((pc as Dictionary).data, m, str((pc as Dictionary).fn_id),
			instance_map, content_map, cross_code, src_codes, conflicts,
			target_code, source_key, scope)
	var patch := {"objects": out_objects}
	if include_world:
		# 整图：图片/瓦片/碰撞/出生点原样带过去（实例行已重映射）
		for key in ["tiles", "spawn", "collision"]:
			var seg = sdata.get(key, null)
			if seg is Dictionary or seg is Array:
				patch[key] = (seg as Variant).duplicate(true)
	return {
		"status": "ok" if conflicts.is_empty() else "conflict",
		"instance_map": instance_map,
		"content_map": content_map,
		"scoped_ids": scoped_ids,
		"map_patch": patch,
		"pending_contents": pending,
		"conflicts": conflicts,
	}

## Walk each reachable content once, then copy only paths leading to a changed document.
static func _clone_scoped_chain(manifest: Dictionary, roots: Array, staged: Dictionary, content_map: Dictionary,
		pending: Array, conflicts: Array, target_key: String, probe: Callable) -> Dictionary:
	var queue := roots.duplicate()
	var rows := {}
	var parents := {}
	var dirty: Array[String] = []
	var seen := {}
	var cursor := 0
	while cursor < queue.size():
		var address: Dictionary = queue[cursor]
		cursor += 1
		var fn: String = address.function
		var cid: String = address.content
		var key := content_key(fn, cid)
		if seen.has(key):
			continue
		seen[key] = true
		var data: Dictionary = staged[key] if staged.has(key) else ContentStore.read(manifest, fn, cid)
		if data.is_empty():
			conflicts.append({"kind": "content_missing", "id": cid,
				"message": "地图内容链读不到：%s/%s" % [fn, cid]})
			continue
		rows[key] = {"fn": fn, "cid": cid, "data": data}
		var sample := data.duplicate(true)
		probe.call(sample, fn, func(next: Dictionary):
			var next_key := content_key(next.function, next.content)
			if not parents.has(next_key):
				parents[next_key] = []
			parents[next_key].append(key)
			queue.append(next))
		if sample != data or content_map.get(fn, {}).has(cid):
			dirty.append(key)
	var ids := {}
	cursor = 0
	while cursor < dirty.size():
		var key: String = dirty[cursor]
		cursor += 1
		if ids.has(key):
			continue
		var row: Dictionary = rows[key]
		var id: String = content_map.get(row.fn, {}).get(row.cid, "")
		if id == "":
			id = ContentId.unique(manifest, row.fn, "%s-%s" % [row.cid, target_key])
			if id == "":
				conflicts.append({"kind": "content_id", "id": row.cid, "message": "新内容 ID 生成失败：%s" % row.cid})
				continue
			var clone: Dictionary = row.data.duplicate(true)
			clone["id"] = id
			pending.append({"fn_id": row.fn, "id": id, "data": clone})
		ids[key] = id
		dirty.append_array(parents.get(key, []))
	return ids

## 单行重映射（活体贴/区域粘贴/整图共用）：返回深拷贝，原行不动。
##   instance_map 旧码→新码；content_map 旧内容 ID→新内容 ID；
##   cross_code 非空 = 跨图复制时组外引用该写入的源图键（"" = 同图/整图，组外原样保留）；
##   source_codes 源图全部实例码（空 = 未知：凡未在组内的引用都按源图算）。
## 配对地图字段规则见文件头；冲突写进 conflicts（调用方据此取消整个计划）。
static func remap_row(row: Dictionary, instance_map: Dictionary, content_map: Dictionary,
		manifest: Dictionary, cross_code := "", source_codes: Dictionary = {},
		conflicts = null, target_code := "", source_key := "", spatial_refs := {}) -> Dictionary:
	var out: Dictionary = row.duplicate(true)
	var ad := AssetDecl.by_id(manifest, str(out.get("asset", "")))
	if ad.get("kind") == "scene":
		out.erase("code")
		out.erase("functions")
		return out
	var old_code := str(out.get("code", ""))
	if instance_map.has(old_code):
		out["code"] = instance_map[old_code]
	var props: Dictionary = out.get("props", {}) if out.get("props", {}) is Dictionary else {}
	var fdecls: Array = ad.get("fields", []) if ad.get("fields", []) is Array else []
	_remap_props(manifest, props, fdecls, str(out.get("code", "")), instance_map, cross_code,
		source_codes, conflicts, target_code, source_key, 0, spatial_refs)
	# 功能绑定：内容跳转换成副本；未知键原样保留
	var fns: Array = out.get("functions", []) if out.get("functions", []) is Array else []
	for i in fns.size():
		if not (fns[i] is Dictionary):
			continue
		var fb: Dictionary = fns[i]
		var cid := str(fb.get("content", ""))
		var fn_id := FunctionDecls.fn_id_of(manifest, str(fb.get("fn", "")))
		var ids: Dictionary = content_map.get(fn_id, {})
		if cid != "" and ids.has(cid):
			fb["content"] = ids[cid]
		fns[i] = fb
	out["functions"] = fns
	out["props"] = props
	return out

static func _remap_props(manifest: Dictionary, values: Dictionary, fields: Array, owner: String,
		instance_map: Dictionary, cross_code: String, source_codes: Dictionary, conflicts: Variant,
		target_code: String, source_key: String, depth := 0,
		spatial_refs := {}) -> void:
	if depth > 8:
		return
	for field in fields:
		if not field is Dictionary:
			continue
		var id := str(field.get("id", ""))
		var desc := RefFields.describe(field)
		if desc.kind == "flow_target":
			_remap_flow_map(field, id, values, spatial_refs, instance_map)
			if spatial_refs.has("scoped_ids") and field.get("contentMapContext") == "inherit":
				_remap_scoped_link(field, id, values, fields, "", desc, source_key,
					target_code, spatial_refs, {})
		for scope in RefFields.nested_scopes(manifest, field, values.get(id)):
			var path := "%s.%s#%d" % [owner, id, scope.path[0]]
			if scope.path.size() == 2:
				_remap_field_map(manifest, scope.values, scope.decls, instance_map, {}, cross_code,
					source_codes, conflicts if conflicts is Array else [], path, target_code,
					source_key, "", depth + 1, spatial_refs)
			else:
				_remap_props(manifest, scope.values, scope.decls, path, instance_map, cross_code,
					source_codes, conflicts, target_code, source_key, depth + 1, spatial_refs)
	_remap_object_refs(values, fields, instance_map, target_code, cross_code,
		source_key, false, spatial_refs)
	_remap_entity_ref_fields(values, fields, owner, instance_map, cross_code, source_codes,
		conflicts, target_code, source_key, spatial_refs)

## 内容副本的引用重映射：fields 按键=字段码；steps[].fields 按步骤声明字段码。
## 只碰声明为引用（entity_inst / content）的键；其余值（含同形四位码）不动。
static func _remap_content(data: Dictionary, manifest: Dictionary, fn_id: String,
		instance_map: Dictionary, content_map: Dictionary, cross_code: String,
		source_codes: Dictionary, conflicts: Array, target_code: String, source_key := "", spatial_refs := {}) -> void:
	var decls := _content_decls(manifest, fn_id)
	var owner := str(data.get("id", ""))
	_remap_field_map(manifest, data.get("fields", null), decls, instance_map, content_map,
		cross_code, source_codes, conflicts, owner, target_code, source_key, fn_id, 0, spatial_refs)
	var steps = data.get("steps", null)
	for st in (steps as Array) if steps is Array else []:
		if not (st is Dictionary):
			continue
		var step_code := str((st as Dictionary).get("step", ""))
		var sd: Dictionary = StepDecls.step_by_code(manifest, step_code)
		var sdecls: Array = sd.get("fields", []) if sd.get("fields", []) is Array else []
		_remap_field_map(manifest, (st as Dictionary).get("fields", null), sdecls, instance_map,
			content_map, cross_code, source_codes, conflicts, owner, target_code,
			source_key, fn_id, 0, spatial_refs)

## 一组声明字段 → 值字典的引用重映射（功能字段/条件字段/步骤字段共用）。
static func _remap_field_map(manifest: Dictionary, values, decls: Array, instance_map: Dictionary,
		content_map: Dictionary, cross_code: String, source_codes: Dictionary,
		conflicts: Array, owner: String, target_code: String, source_key := "", fn_id := "", depth := 0, spatial_refs := {}) -> void:
	if not (values is Dictionary) or depth > 8:
		return
	var vals: Dictionary = values
	for fd in decls:
		if not fd is Dictionary:
			continue
		var key := str(fd.get("code", ""))
		if key == "":
			key = str(fd.get("id", ""))
		for scope in RefFields.nested_scopes(manifest, fd, vals.get(key)):
			_remap_field_map(manifest, scope.values, scope.decls, instance_map, content_map, cross_code,
				source_codes, conflicts, owner, target_code, source_key, fn_id, depth + 1, spatial_refs)
	_remap_object_refs(vals, decls, instance_map, target_code, cross_code,
		source_key, true, spatial_refs)
	var cell_ids: Dictionary = spatial_refs.get("cells", {})
	var pairs_to_fill := {}
	for fd in decls:
		if not (fd is Dictionary):
			continue
		var f: Dictionary = fd
		var desc := RefFields.describe(f)
		if not bool(desc.get("is_ref", false)):
			continue
		var kind := str(desc.get("kind", ""))
		var cell := kind == "cell" and not cell_ids.is_empty()
		if kind not in ["entity_inst", "content", "flow_target", "layer"] and not cell:
			continue
		var key := str(f.get("code", ""))
		if key == "":
			key = str(f.get("id", ""))
		if kind == "flow_target":
			_remap_flow_map(f, key, vals, spatial_refs, instance_map)
		if kind in ["content", "flow_target"] and (spatial_refs.has("visit_scoped") or spatial_refs.has("scoped_ids")):
			_remap_scoped_link(f, key, vals, decls, fn_id, desc, source_key,
				target_code, spatial_refs, pairs_to_fill)
		if kind == "flow_target" or not vals.has(key):
			continue
		var id_map: Dictionary = cell_ids if cell else instance_map
		if kind == "content":
			var target_fn := str((desc.get("filter", {}) as Dictionary).get("fn", ""))
			id_map = content_map.get(target_fn if target_fn != "" else fn_id, {})
		# R10：先看配对地图字段的现值——目标不是源图的引用原样保留（跨图身份）。
		var pair := str(f.get("mapField", ""))
		if kind != "content" and pair != "" and source_key != "":
			var pk := _key_of(decls, pair)
			var pv := str(vals.get(pk, "")) if pk != "" and vals.has(pk) else ""
			if pv != "" and pv != source_key:
				continue
		var v = vals[key]
		if kind == "layer":
			_keep_layer_scope(v, owner, str(f.get("id", "")), _key_of(decls, pair),
				pairs_to_fill, conflicts, cross_code, target_code, spatial_refs)
			continue
		var touched := _touches(v, id_map)
		if cell and cross_code != "" and touched and not _all_in(v, id_map):
			conflicts.append(_split_cell_ref(owner, key))
			continue
		if touched:
			vals[key] = _swap(v, id_map)
		if kind == "content" or _is_empty_value(v):
			continue
		var pair_key := _key_of(decls, pair)
		if touched:
			# 组内：配对地图字段指向副本所在的图。
			# 多值列表只命中一部分时不能整组改判：列表里同时有本图与组外引用，
			# 一个 mapField 表达不了两个归属——保留原值并报冲突（V4 P1）。
			if pair_key != "":
				if (not cell or cross_code != "") and not _all_in(v, id_map):
					conflicts.append({"kind": "ref_pair_partial", "id": owner,
						"message": "内容 %s 的字段 %s 是混合引用（部分在本图/部分指向别的图），配对地图字段 %s 无法同时表示：请拆分或取消" % [
							owner, str(f.get("id", "")), pair]})
					continue
				var tk := target_code
				if pairs_to_fill.has(pair_key) and str(pairs_to_fill[pair_key]) != tk:
					conflicts.append({"kind": "ref_pair_conflict", "id": owner,
						"message": "内容 %s 的配对地图字段被多条引用要求指向不同图：无法一次复制，请取消或拆分" % owner})
				pairs_to_fill[pair_key] = tk
			continue
		if cross_code == "":
			continue
		if not cell and not source_codes.is_empty() and not _touches(v, source_codes):
			continue
		if pair_key != "":
			if pairs_to_fill.has(pair_key) and str(pairs_to_fill[pair_key]) != cross_code:
				conflicts.append({"kind": "ref_pair_conflict", "id": owner,
					"message": "内容 %s 的配对地图字段被多条引用要求指向不同图：无法一次复制，请取消或拆分" % owner})
			pairs_to_fill[pair_key] = cross_code
		else:
			conflicts.append({"kind": "ref_unpaired", "id": owner,
				"message": "内容 %s 的字段 %s 指向源图，但该字段不支持地图配对：请改选目标或取消" % [
					owner, str(f.get("id", ""))]})
	for k in pairs_to_fill:
		vals[k] = pairs_to_fill[k]

static func _remap_scoped_link(field: Dictionary, key: String, values: Dictionary, decls: Array,
		fn: String, desc: Dictionary, source_key: String,
		target: String, scope: Dictionary, pairs: Dictionary) -> void:
	var mode: String = field.get("contentMapContext", "")
	if mode == "paired":
		var map_key := RefFields.effective_map_value(field, decls, values, "code")
		if map_key == "" or not RefFields.map_key_local(map_key, source_key):
			return
	elif mode != "inherit":
		return
	var mixed: bool = desc.kind == "flow_target"
	var value = values.get(key, field.get("default") if mixed else null)
	var entries: Array = value.duplicate() if value is Array else [value]
	var target_fn: String = desc.get("filter", {}).get("fn", "")
	var changed := false
	for i in entries.size():
		var item = entries[i]
		var address: Dictionary
		if mixed:
			if FlowTarget.kind(item) != "content" or not FlowTarget.allows(field, item):
				continue
			address = item
		else:
			if not item is String or item == "":
				continue
			address = {"function": target_fn if target_fn != "" else fn, "content": item}
		if scope.has("visit_scoped"):
			scope.visit_scoped.call(address)
		else:
			var id: String = scope.scoped_ids.get(content_key(address.function, address.content), "")
			if id != "":
				entries[i] = {"function": address.function, "content": id} if mixed else id
				changed = true
	if changed:
		values[key] = entries if value is Array else entries[0]
		if mode == "paired":
			pairs[_key_of(decls, field.mapField)] = target

## 新内容 ID：优先按分层身份重组（目标图码 + 类型码 + 新实例码 + 功能 id），
## 缺任一段时沿用源 ID 前缀 + 新随机内容段，最后查重。
static func _new_content_id(manifest: Dictionary, fn_id: String, target_data: Dictionary,
		new_inst_code: String, old_id: String) -> String:
	var map_code := str((target_data.get("meta", {}) as Dictionary).get("code", "")) \
		if (target_data.get("meta", {}) as Dictionary).get("code", null) != null else ""
	var ent_code := ""
	var cand := ""
	if map_code != "" and new_inst_code != "":
		# 类型码从源内容 ID 的第二段取（内容 ID = 图-类型-实例-功能-内容）
		var segs := old_id.split("-", false)
		if segs.size() >= 2:
			ent_code = str(segs[1])
	cand = ContentId.content_id(map_code, ent_code, new_inst_code, fn_id)
	if cand == "":
		# 老式内容 ID 不一定是五段（如 CID1）：沿用原 ID 作前缀，只换末段
		var cut := old_id.rfind("-")
		if cut < 0:
			cand = old_id
		else:
			cand = old_id.substr(0, cut) + "-" + ContentId.new_inst_code()
	return ContentId.unique(manifest, fn_id, cand)

## 计划里的冲突 → 给用户看的一行（预览弹窗/状态栏共用）。
static func conflicts_text(conflicts: Array) -> String:
	var lines: Array = []
	for c in conflicts:
		lines.append(str((c as Dictionary).get("message", str(c))))
	return "\n".join(PackedStringArray(lines))

## —— 整图复制（C2）：在 build 之上组装完整地图文档 ——
## 源文档全部保留（含游戏侧自定义顶层键），只替换 meta 身份与 objects/tiles/spawn/collision。
## 调用方先发行新图名与地图码；内容按 A2 顺序由调用方先写 pending_contents。
## 返回 build 的结果 + 额外键 "document"（可直接 MapStore.write 的文档）。
static func whole_map_document(src: Dictionary, new_name: String, new_code: String,
		staged_contents := {}) -> Dictionary:
	var sdata := _data(src)
	var m := _manifest(src) if not _manifest(src).is_empty() else {}
	var doc: Dictionary = sdata.duplicate(true)
	var meta: Dictionary = doc.get("meta", {}) if doc.get("meta", {}) is Dictionary else {}
	meta["name"] = new_name
	meta["code"] = new_code
	meta.erase("generatorSource")
	doc["meta"] = meta
	# 目标文档（自身）只用于实例码占位查询：整图复制到新文件，不能撞现有任何码
	var dst_ctx := {"data": {"meta": meta}, "manifest": m}
	# §4.2-3：整图复制 = 副本继承源图自己的引用（map:"" 指副本自己，不钉回源图）
	var plan: Dictionary = build({"data": sdata, "manifest": m}, dst_ctx,
		PackedStringArray(), true, staged_contents, true)
	var patch: Dictionary = plan.get("map_patch", {}) if plan.get("map_patch", {}) is Dictionary else {}
	for key in ["objects", "tiles", "spawn", "collision"]:
		if patch.has(key):
			doc[key] = patch[key]
	var map_copy := _map_copy_codes(sdata, doc)
	var outputs := MapFlow.targets(doc, MapFlow.OUTPUTS)
	for id in outputs:
		outputs[id] = _copied_map_target(outputs[id], map_copy, plan.instance_map, true)
	for ref in MapFlow.scoped_content(m, sdata):
		var key := content_key(ref.value.function, ref.value.content)
		if plan.scoped_ids.has(key):
			meta[ref.map_section][ref.field]["content"] = plan.scoped_ids[key]
	plan["document"] = doc
	return plan

static func _map_copy_codes(source: Dictionary, target: Dictionary) -> Dictionary:
	var code: String = source.get("meta", {}).get("code", "")
	var copy: String = target.get("meta", {}).get("code", "")
	return {code: copy} if code != "" and copy != "" else {}

static func _copied_map_target(value: Variant, codes: Dictionary, instances: Dictionary, whole_map: bool) -> Variant:
	if FlowTarget.kind(value) == "map" and codes.has(value.map):
		if value.has("port"):
			return {"map": codes[value.map], "inst": instances[value.inst], "port": value.port} if instances.has(value.inst) else value
		if whole_map:
			return {"map": codes[value.map]}
	return value

static func _remap_flow_map(field: Dictionary, key: String, values: Dictionary, scope: Dictionary, instances: Dictionary) -> void:
	var value = values.get(key, field.get("default"))
	var remap := func(target: Variant):
		return _copied_map_target(target, scope.get("map_copy", {}), instances, scope.get("whole_map", false))
	var mapped = value.map(remap) if value is Array else remap.call(value)
	if mapped != value:
		values[key] = mapped

## entity_ref 字段引用重映射（remap_row 顶层与 C1 记录行共用）：vals = 值字典（键=字段 id），
## fdecls = 兄弟声明（配对地图字段按 mapField 在这里找，值读 vals）。冲突 id 用 owner。
## 原逻辑保持不变（R10 配对优先、组内→指向目标图、组外→钉源图/报冲突）。
static func _remap_entity_ref_fields(vals: Dictionary, fdecls: Array, owner: String,
		instance_map: Dictionary, cross_code := "", source_codes: Dictionary = {},
		conflicts = null, target_code := "", source_key := "", spatial_refs := {}) -> void:
	var cell_ids: Dictionary = spatial_refs.get("cells", {})
	var pairs_to_fill := {}
	for fd in fdecls:
		if not (fd is Dictionary):
			continue
		var f: Dictionary = fd
		var fid := str(f.get("id", ""))
		var kind: String = RefFields.describe(f).kind
		var cell := not cell_ids.is_empty() and kind == "cell"
		if kind not in ["entity_inst", "layer"] and not cell:
			continue
		var vv = vals.get(fid, null)
		if _is_empty_value(vv):
			continue
		var pair := str(f.get("mapField", ""))
		# R10：先看配对地图字段的现值——目标不是源图的引用原样保留（跨图身份 (图码, 实例码)）。
		if pair != "" and source_key != "":
			var pv := str(vals.get(pair, ""))
			if pv != "" and pv != source_key:
				continue
		if kind == "layer":
			_keep_layer_scope(vv, owner, fid, pair, pairs_to_fill, conflicts,
				cross_code, target_code, spatial_refs)
			continue
		var id_map: Dictionary = cell_ids if cell else instance_map
		if _touches(vv, id_map):
			if cross_code != "" and not _all_in(vv, id_map):
				if conflicts is Array:
					conflicts.append(_split_cell_ref(owner, fid) if cell else {"kind": "ref_pair_partial", "id": owner,
						"message": "实例 %s 的字段 %s 同时引用复制范围内外的目标：跨图时请拆分选择" % [owner, fid]})
				continue
			vals[fid] = _swap(vv, id_map)
			# 组内：配对地图字段指向副本所在的图（同图复制也是本图当前码）。
			if pair != "":
				var tk := target_code
				if pairs_to_fill.has(pair) and str(pairs_to_fill[pair]) != tk:
					if conflicts is Array:
						(conflicts as Array).append({"kind": "ref_pair_conflict", "id": owner,
							"message": "实例 %s 的配对地图字段 %s 被多条引用要求指向不同图：无法一次复制，请取消或拆分选择" % [owner, pair]})
				pairs_to_fill[pair] = tk
			continue
		if cross_code == "":
			continue
		if not cell and not source_codes.is_empty() and not _touches(vv, source_codes):
			continue   # 本来就指向第三张图：引用与地图字段都原样保留
		# 组外且指向源图：跨图时只能靠配对地图字段把目标钉在源图
		if pair != "":
			if pairs_to_fill.has(pair) and str(pairs_to_fill[pair]) != cross_code:
				if conflicts is Array:
					(conflicts as Array).append({"kind": "ref_pair_conflict", "id": owner,
						"message": "实例 %s 的配对地图字段 %s 被多条引用要求指向不同图：无法一次复制，请取消或拆分选择" % [owner, pair]})
			pairs_to_fill[pair] = cross_code
		elif conflicts is Array:
			(conflicts as Array).append({"kind": "ref_unpaired", "id": owner,
				"message": "实例 %s 的字段 %s 指向源图 %s，但该字段不支持地图配对：请改选目标或取消" % [owner, fid, cross_code]})
	for k in pairs_to_fill:
		vals[k] = pairs_to_fill[k]

## 局部复制不移动坐标空间；整图副本带着原层 ID 和变换。
static func _keep_layer_scope(value: Variant, owner: String, field: String, pair: String,
		pairs: Dictionary, conflicts: Variant, source: String, target: String, spatial_refs: Dictionary) -> void:
	if _is_empty_value(value):
		return
	var map_key := target if spatial_refs.get("whole_map", false) else source
	if map_key == "":
		return
	if pair == "":
		if source != "" and conflicts is Array:
			conflicts.append({"kind": "ref_unpaired", "id": owner,
				"message": "%s 的图层字段 %s 属于源图 %s；跨图复制需要为该字段声明配对地图。" % [owner, field, source]})
		return
	if pairs.has(pair) and pairs[pair] != map_key:
		if conflicts is Array:
			conflicts.append({"kind": "ref_pair_conflict", "id": owner,
				"message": "%s 的图层字段 %s 与其他引用需要不同的配对地图：%s" % [owner, field, pair]})
		return
	pairs[pair] = map_key

static func _split_cell_ref(owner: String, field: String) -> Dictionary:
	return {"kind": "ref_pair_partial", "id": owner,
		"message": "%s 的格图字段 %s 同时引用框内和框外的格，跨图时请拆分选择。" % [owner, field]}

## 先解析引用，再改配对字段。对象自带地图键，能保留原目标，即使同一行的
## 实例引用随后改写了配对地图。端口跟随组内实例，区域复制也可提供格边坐标映射。
static func _remap_object_refs(vals: Dictionary, decls: Array, instance_map: Dictionary,
		target_code: String, cross_code: String, source_key: String, coded: bool, spatial_refs: Dictionary) -> void:
	var target := target_code
	var map_edge: Callable = spatial_refs.get("edge", Callable())
	for field in decls:
		if not field is Dictionary:
			continue
		var many: bool = field.get("type") == "array"
		var type := str(field.get("of", "")) if many else str(field.get("type", ""))
		if type not in ["port_ref", "edge_ref"]:
			continue
		var key := str(field.get("code", "")) if coded else ""
		if key == "":
			key = str(field.get("id", ""))
		var raw = vals.get(key)
		var entries: Array = raw if many and raw is Array else [raw] if not many else []
		var paired := RefFields.paired_map_value(field, decls, vals, "code" if coded else "id")
		for value in entries:
			if not value is Dictionary or value.is_empty():
				continue
			var map_key := RefFields.object_map_key(value, paired)
			if not RefFields.map_key_local(map_key, source_key):
				# 固化隐式跨图归属，防随兄弟字段改指向。
				if str(value.get("map", "")) == "":
					value["map"] = map_key
				continue
			if type == "port_ref":
				var inst := str(value.get("inst", ""))
				if inst == "":
					continue
				if instance_map.has(inst):
					value["inst"] = str(instance_map[inst])
					value["map"] = target
					continue
			elif map_edge.is_valid():
				var edge: Dictionary = map_edge.call(value, target)
				if not edge.is_empty():
					value.merge(edge, true)
					continue
			if cross_code != "":
				value["map"] = cross_code
			elif map_key != "" and target != "":
				value["map"] = target
