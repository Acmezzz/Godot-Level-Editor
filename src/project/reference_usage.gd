extends RefCounted
## Finds where a selected asset, content item or screen is used.

const FlowTarget := preload("res://src/content/flow_target.gd")
const ProjectSlots := preload("res://src/project/project_content_slots.gd")
const EventLayers := preload("res://src/project/event_layers.gd")
const MapStore := preload("res://src/map/map_store.gd")
const MapFlow := preload("res://src/map/map_flow.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const ReferenceIndex := preload("res://src/project/reference_index.gd")

## 检查正式地图和未保存画布，避免删除后任意一份数据变成悬空引用。
static func _map_content_usage(manifest: Dictionary, fn_id: String, cid: String,
		current_map: String, live_map: Dictionary, unreadable: Array) -> Dictionary:
	var by_map := {}
	var bad: Array = []
	var maps := MapStore.read_all_fresh(manifest, bad)
	for item in bad:
		unreadable.append("地图 %s 读不出来" % item.name)
	var target := {"function": fn_id, "content": cid}
	var fn_code := FunctionDecls.fn_code(manifest, fn_id)
	for name in maps:
		var rows := _map_content_refs(manifest, maps[name], target, fn_code)
		if not rows.is_empty():
			by_map[name] = rows
	if current_map != "":
		var rows: Array = by_map.get(current_map, [])
		for source in _map_content_refs(manifest, live_map, target, fn_code):
			if not rows.has(source):
				rows.append(source)
		if not rows.is_empty():
			by_map[current_map] = rows
	return by_map

static func _map_content_refs(manifest: Dictionary, data: Dictionary, target: Dictionary,
		fn_code: String) -> Array:
	var rows: Array = []
	for ref in _map_property_refs(manifest, data, ["flow_target"]):
		if ref.value == target and not rows.has(ref.code):
			rows.append(ref.code)
	if fn_code != "":
		for obj in data.get("objects", []):
			if not obj is Dictionary:
				continue
			var code := str(obj.get("code", ""))
			if code == "" or rows.has(code):
				continue
			for binding in obj.get("functions", []):
				if binding is Dictionary and binding.get("fn") == fn_code and binding.get("content") == target.content:
					rows.append(code)
					break
	return rows

static func content_inbound_refs(manifest: Dictionary, fn_id: String, cid: String,
		unreadable: Array = []) -> Array:
	var out: Array = []
	for kind in ContentStore.declared_kinds(manifest):
		var bad: Array = []
		var items := ContentStore.read_all(manifest, kind, bad)
		for item in bad:
			unreadable.append("内容 %s/%s 读不出来" % [kind, item.name])
		for id in items:
			if kind == fn_id and id == cid:
				continue
			for field in content_link_paths(manifest, str(kind), items[id], fn_id, cid):
				out.append({"kind": str(kind), "id": str(id), "field": field})
	return out

static func content_link_paths(manifest: Dictionary, source_fn: String, data: Dictionary,
		target_fn: String, target_id: String) -> Array:
	var out: Array = []
	for ref in _content_links(manifest, source_fn, data):
		if (target_fn == "" or ref.fn == target_fn) and ref.cid == target_id:
			out.append(ref.path)
	return out

static func _content_links(manifest: Dictionary, source_fn: String, data: Dictionary) -> Array:
	var out: Array = []
	for section in _content_sections(manifest, source_fn, data):
		_collect_content_links(manifest, section.decls, section.values, source_fn, section.prefix, out)
	return out

static func _content_sections(manifest: Dictionary, fn: String, data: Dictionary) -> Array:
	var decls := FunctionDecls.function_fields(manifest, fn).duplicate()
	var conds = FunctionDecls.function_decl(manifest, fn).get("conditions")
	if conds is Array:
		for condition in conds:
			var fields = ConditionDecls.condition_decl(manifest, str(condition)).get("fields")
			if fields is Array:
				decls.append_array(fields)
	var out: Array = [{"decls": decls, "values": data.get("fields"), "prefix": ""}]
	var steps = data.get("steps")
	if steps is Array:
		for i in steps.size():
			var step = steps[i]
			if not step is Dictionary:
				continue
			var sd := StepDecls.step_by_code(manifest, str(step.get("step", "")))
			var fields = sd.get("fields")
			if fields is Array:
				out.append({"decls": fields, "values": step.get("fields"), "prefix": "steps[%d]." % i})
	return out

static func draft_inbound_refs(manifest: Dictionary, cid: String, fn_id := "") -> Array:
	var out: Array = []
	var base := str(manifest.get("_dir", "")).path_join("editor/drafts")
	var d := DirAccess.open(base)
	if d == null:
		return out
	var target_code := FunctionDecls.fn_code(manifest, fn_id)
	for f in d.get_files():
		if not str(f).ends_with(".json"):
			continue
		var key := str(f).get_basename()
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(base.path_join(str(f))))
		if not parsed is Dictionary or not parsed.get("snapshot") is Dictionary:
			out.append(key)
			continue
		var snap: Dictionary = parsed.snapshot
		var objects = snap.get("objects", [])
		var pcs = parsed.get("pendingContents", [])
		if not objects is Array or not pcs is Array:
			out.append(key)
			continue
		var hit := false
		if fn_id != "" and _map_property_refs(manifest, snap, ["flow_target"]).any(func(ref):
			return ref.value is Dictionary and ref.value == {"function": fn_id, "content": cid}):
			hit = true
		for obj in objects:
			if not obj is Dictionary or not obj.get("functions", []) is Array:
				continue
			for binding in obj.get("functions", []):
				if binding is Dictionary and str(binding.get("content", "")) == cid \
						and (target_code == "" or str(binding.get("fn", "")) == target_code):
					hit = true
		for row in pcs:
			if not row is Dictionary or not row.get("data") is Dictionary:
				hit = true
				continue
			var source_fn := str(row.get("fn", row.get("fn_id", "")))
			if source_fn == "":
				hit = true
				continue
			if source_fn == fn_id and str(row.get("cid", row.get("id", ""))) == cid:
				continue
			if not content_link_paths(manifest, source_fn, row.data, fn_id, cid).is_empty():
				hit = true
		if hit:
			out.append(key)
	return out

static func _collect_content_links(manifest: Dictionary, decls: Array, values, source_fn: String,
		prefix: String, out: Array, depth := 0) -> void:
	if not values is Dictionary or depth > 8:
		return
	for fd in decls:
		if not fd is Dictionary:
			continue
		var id := str(fd.get("id", ""))
		var key := str(fd.get("code", ""))
		if key == "":
			key = id
		var desc := RefFields.describe(fd)
		if not values.has(key) and desc.kind != "flow_target":
			continue
		var value = values.get(key, fd.get("default"))
		var path := prefix + id
		for scope in RefFields.nested_scopes(manifest, fd, value):
			var subpath := path + "#%d." % int(scope.path[0])
			if scope.path.size() == 2:
				subpath += "fields."
			_collect_content_links(manifest, scope.decls, scope.values, source_fn, subpath, out, depth + 1)
		var ordered := RefFields.is_ordered_choice(fd)
		var entries := _as_list(value)
		if desc.kind == "flow_target":
			var targets := entries if desc.many else [value]
			for i in targets.size():
				var target = targets[i]
				var at := "%s[%d]" % [path, i] if desc.many else path
				if FlowTarget.kind(target) == "content":
					out.append({"fn": target.function, "cid": target.content, "path": at})
			continue
		if desc.kind != "content":
			continue
		var want_fn := str(desc.get("filter", {}).get("fn", ""))
		if want_fn == "":
			want_fn = source_fn
		var distinct := {}
		for i in entries.size():
			var cid = entries[i]
			if cid is String and cid != "" and (ordered or not distinct.has(cid)):
				distinct[cid] = true
				out.append({"fn": want_fn, "cid": cid, "path": "%s#%d" % [path, i] if ordered else path})

static func _as_list(v) -> Array:
	if v is Array:
		return v
	if v == null or str(v) == "":
		return []
	return [v]

static func asset_deletion_usage(manifest: Dictionary, asset_id: String, live: Dictionary, staged: Array) -> Dictionary:
	var bad: Array = []
	var maps_dir := str(manifest.get("_maps_dir", ""))
	if DirAccess.open(maps_dir) == null:
		bad.append({"name": maps_dir, "reason": "无法读取地图目录"})
	var maps := MapStore.read_all_fresh(manifest, bad)
	var refs := {}
	for name in maps:
		var count := _asset_map_count(manifest, asset_id, maps[name])
		if count > 0:
			refs[name] = count
	var live_count := _asset_map_count(manifest, asset_id, live)
	return {"maps": refs, "live": live_count, "contents": asset_content_refs(manifest, asset_id, bad, staged),
		"drafts": asset_draft_refs(manifest, asset_id, bad), "bad": bad,
		"views": ReferenceIndex.view_asset_refs(manifest, asset_id)}

static func _asset_map_count(manifest: Dictionary, asset_id: String, data: Dictionary) -> int:
	var count := 0
	for cells in (data.get("tiles", {}) as Dictionary).values():
		for cell in cells as Array:
			if cell is Array and cell.size() >= 3 and str(cell[2]) == asset_id:
				count += 1
	for obj in data.get("objects", []) as Array:
		if obj is Dictionary:
			var aid := str(obj.get("asset", ""))
			var decl := AssetDecl.by_id(manifest, aid)
			if aid == asset_id or not _fields_pointing(manifest, "asset", asset_id, decl.get("fields", []), obj.get("props", {}), false).is_empty():
				count += 1
	return count

static func asset_content_refs(manifest: Dictionary, asset_id: String, bad: Array = [],
		staged: Array = [], include_disk := true) -> Array:
	var out: Array = []
	for kind in ContentStore.declared_kinds(manifest):
		var items := {}
		if include_disk:
			var dir := ContentStore.dir_for(manifest, kind)
			if DirAccess.dir_exists_absolute(dir) and DirAccess.open(dir) == null:
				bad.append({"name": dir, "reason": "无法读取内容目录"})
			items = ContentStore.read_all(manifest, kind, bad)
		for row in staged:
			if row is Dictionary and str(row.get("fn_id", "")) == kind and row.get("data") is Dictionary:
				items["草稿:" + str(row.get("cid", ""))] = row.data
		for oid in items:
			for section in _content_sections(manifest, kind, items[oid]):
				for field in _fields_pointing(manifest, "asset", asset_id, section.decls, section.values):
					out.append({"kind": str(kind), "id": str(oid), "field": section.prefix + field})
	return out

static func _fields_pointing(manifest: Dictionary, kind: String, target: String, decls: Array, values,
		coded := true, depth := 0) -> Array:
	var out: Array = []
	if not (values is Dictionary) or depth > 8:
		return out
	var vals: Dictionary = values
	for fd in decls:
		if not (fd is Dictionary):
			continue
		var id := str(fd.get("id", ""))
		var key := str(fd.get("code", "")) if coded else id
		if key == "":
			key = id
		if not vals.has(key):
			continue
		for scope in RefFields.nested_scopes(manifest, fd, vals[key]):
			var prefix := "%s#%d." % [id, scope.path[0]]
			if scope.path.size() == 2:
				prefix += "fields."
			for sub in _fields_pointing(manifest, kind, target, scope.decls, scope.values, coded, depth + 1):
				out.append(prefix + str(sub))
		var desc := RefFields.describe(fd)
		if desc.kind == "flow_target":
			var targets := _as_list(vals[key]) if desc.many else [vals[key]]
			for i in targets.size():
				if targets[i] is Dictionary and targets[i].get(kind) == target:
					out.append("%s[%d]" % [id, i] if desc.many else id)
			continue
		if desc.kind != kind:
			continue
		for v in _as_list(vals[key]):
			if v is String and v == target:
				out.append(str((fd as Dictionary).get("id", key)))
				break
	return out

static func view_inbound_refs(manifest: Dictionary, id: String, staged: Array,
		live_map := {}, live_name := "") -> Dictionary:
	var refs: Array[String] = []
	if manifest.get("startup", {}).get("target", {}) == {"view": id}:
		refs.append("正式启动入口")
	for event in EventLayers.references(manifest):
		if event.target == {"view": id}:
			refs.append("事件层 · " + event.name)
	for ref in ReferenceIndex.view_transition_refs(manifest):
		if ref.target.view == id and ref.view != id:
			refs.append("%s · %s" % [ref.view, ref.path])
	var bad: Array = []
	for ref in ReferenceIndex.view_module_refs(manifest):
		if ref.view != id and _points_to_view(ref, id):
			refs.append("%s · %s" % [ref.view, ref.path])
	var scan_map := func(data: Dictionary, name: String):
		for ref in _map_property_refs(manifest, data, ["view", "flow_target"]):
			if _points_to_view(ref, id):
				var label := "%s · %s" % [name, ref.path]
				if not refs.has(label):
					refs.append(label)
	var maps := MapStore.read_all_fresh(manifest, bad)
	for name in maps:
		scan_map.call(maps[name], name)
	if not live_map.is_empty():
		scan_map.call(live_map, live_name)
	var inspect := func(kind: String, cid: String, data: Dictionary):
		for section in _content_sections(manifest, kind, data):
			for field in _fields_pointing(manifest, "view", id, section.decls, section.values):
				refs.append("%s.%s%s" % [cid, section.prefix, field])
	for kind in ContentStore.declared_kinds(manifest):
		var folder := ContentStore.dir_for(manifest, kind)
		if DirAccess.dir_exists_absolute(folder) and DirAccess.open(folder) == null:
			bad.append({"name": folder})
		var items := ContentStore.read_all(manifest, kind, bad)
		for cid in items:
			inspect.call(kind, "%s/%s" % [kind, cid], items[cid])
	for row in staged:
		inspect.call(row.fn_id, "暂存 %s/%s" % [row.fn_id, row.cid], row.data)
	for key in MapStore.Recovery.list_drafts(manifest):
		var draft := MapStore.Recovery.read_draft_key(manifest, key)
		var rows = draft.get("pendingContents", [])
		if draft.is_empty() or not rows is Array:
			bad.append({"name": "草稿 " + str(key)})
			continue
		scan_map.call(draft.get("snapshot", {}), "草稿 " + str(key))
		for row in rows:
			if not row is Dictionary or not row.get("data") is Dictionary:
				bad.append({"name": "草稿 " + str(key)})
				continue
			var kind := str(row.get("fn_id", ""))
			inspect.call(kind, "草稿 %s · %s" % [key, row.get("cid", row.get("id", kind))], row.data)
	return {"refs": refs, "bad": bad}

static func _points_to_view(ref: Dictionary, id: String) -> bool:
	return (ref.kind == "view" and ref.value == id) or (
		ref.kind == "flow_target" and ref.value is Dictionary and ref.value == {"view": id})

static func _map_property_refs(manifest: Dictionary, data: Dictionary, kinds: Array) -> Array:
	var result := MapFlow.references(manifest, data) if "flow_target" in kinds else []
	var declarations := {}
	for row in data.get("objects", []):
		if not row is Dictionary or not row.get("props", {}) is Dictionary:
			continue
		var asset: String = row.get("asset", "")
		if not declarations.has(asset):
			declarations[asset] = _fields_of(manifest, asset)
		if declarations[asset].is_empty():
			continue
		var code: String = row.get("code", "")
		var path := "%s(%s)" % [asset, code]
		for ref in ReferenceIndex.property_refs(manifest, declarations[asset], row.get("props", {}), {"code": code}, path):
			if ref.kind in kinds:
				result.append(ref)
	return result

static func _fields_of(manifest: Dictionary, asset_id: String) -> Array:
	var a: Dictionary = AssetDecl.by_id(manifest, asset_id)
	return (a.get("fields", []) as Array) if (a.get("fields", null) is Array) else []

static func asset_draft_refs(manifest: Dictionary, asset_id: String, bad: Array = []) -> Array:
	var out: Array = []
	var base := str(manifest.get("_dir", "")).path_join("editor/drafts")
	var d := DirAccess.open(base)
	if d == null:
		if DirAccess.dir_exists_absolute(base):
			bad.append({"name": base, "reason": "无法读取草稿目录"})
		return out
	for f in d.get_files():
		if not str(f).ends_with(".json"):
			continue
		var key := str(f).get_basename()
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(base.path_join(str(f))))
		if not (parsed is Dictionary) or not (parsed.get("snapshot") is Dictionary):
			bad.append({"name": key, "reason": "无法读取草稿"})
			continue
		var dd: Dictionary = parsed
		var hit := _asset_map_count(manifest, asset_id, dd.snapshot) > 0
		var pending = dd.get("pendingContents", [])
		if pending is Array and not asset_content_refs(manifest, asset_id, [], pending, false).is_empty():
			hit = true
		if hit:
			out.append(key)
	return out

## 内容删除前的来向。地图与内容各读一次，工作副本也计入。
static func inbound_content(manifest: Dictionary, fn_id: String, cid: String,
		cur_map := "", live_map := {}) -> Dictionary:
	var unreadable: Array = []
	var instances := _map_content_usage(manifest, fn_id, cid, cur_map, live_map, unreadable)
	var contents := content_inbound_refs(manifest, fn_id, cid, unreadable)
	var target := {"function": fn_id, "content": cid}
	return {
		"complete": unreadable.is_empty(),
		"unreadable_sources": unreadable,
		"edges": {
			"instances": instances,
			"contents": contents,
			"views": ReferenceIndex.view_content_refs(manifest).filter(func(ref): return ref.fn == fn_id and ref.cid == cid),
			"project_slots": (ProjectSlots.references(manifest) + EventLayers.references(manifest)).filter(
				func(ref): return ref.target == target),
			"drafts": draft_inbound_refs(manifest, cid, fn_id),
		},
	}
