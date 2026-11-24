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

static func content_usage(manifest: Dictionary, fn_id: String, cid: String,
		current_map := "", current_codes: Array = [], live_map := {}) -> Dictionary:
	var by_map := {}
	var bad: Array = []
	# R29：删除前引用图驱动破坏性动作，读磁盘实际内容（不走浏览缓存）
	var maps := MapStore.read_all_fresh(manifest, bad)
	var want_code := FunctionDecls.fn_code(manifest, fn_id)
	var target := {"function": fn_id, "content": cid}
	var live_codes := current_codes.duplicate()
	for ref in _map_property_refs(manifest, live_map, ["flow_target"]):
		if ref.value is Dictionary and ref.value == target and not live_codes.has(ref.code):
			live_codes.append(ref.code)
	# V4 P0-4：当前图不能整张跳过。画布上的活体绑定可能已被解除，而磁盘正式文件里
	# 仍有绑定——永久删除后放弃地图改动，正式图就会恢复成悬空引用。因此当前图的
	# 磁盘命中与活体命中取并集。
	for map_name in maps:
		var is_current := current_map != "" and str(map_name) == current_map
		var rows: Array = []
		for ref in _map_property_refs(manifest, maps[map_name], ["flow_target"]):
			if ref.value is Dictionary and ref.value == target and not rows.has(ref.code):
				rows.append(ref.code)
		for obj in ((maps[map_name] as Dictionary).get("objects", []) as Array):
			if not (obj is Dictionary):
				continue

			for f in ((obj as Dictionary).get("functions", []) as Array):
				if not (f is Dictionary):
					continue
				if str((f as Dictionary).get("content", "")) != cid:
					continue
				if want_code != "" and str((f as Dictionary).get("fn", "")) != want_code:
					continue
				var code := str(obj.get("code", ""))
				if not rows.has(code):
					rows.append(code)
				break
		if is_current:
			# 活体绑定也并入（磁盘是旧的：未保存的新绑定同样必须在报告里）
			for c in live_codes:
				if str(c) != "" and not rows.has(str(c)):
					rows.append(str(c))
		if not rows.is_empty():
			by_map[str(map_name)] = rows
	# 新建未保存的图不在磁盘列表里：活体命中仍要计入（否则删除检查看不到它）
	if current_map != "" and not by_map.has(current_map):
		var lone: Array = []
		for c in live_codes:
			if str(c) != "":
				lone.append(str(c))
		if not lone.is_empty():
			by_map[current_map] = lone
	var unreadable: Array = []
	for b in bad:
		unreadable.append(str((b as Dictionary).get("name", "")))
	# 内容文件自身读不出来时「有没有内容引用它」同样不可判定
	var bad_contents: Array = []
	for kind in ContentStore.declared_kinds(manifest):
		var bad2: Array = []
		ContentStore.read_all(manifest, kind, bad2)
		for b2 in bad2:
			bad_contents.append("%s/%s" % [kind, str((b2 as Dictionary).get("name", ""))])
	return {"by_map": by_map, "unreadable": unreadable, "bad_contents": bad_contents,
		"incomplete": not unreadable.is_empty() or not bad_contents.is_empty()}

static func content_inbound_refs(manifest: Dictionary, fn_id: String, cid: String) -> Array:
	var out: Array = []
	for kind in ContentStore.declared_kinds(manifest):
		var items := ContentStore.read_all(manifest, kind)
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

static func asset_usage(manifest: Dictionary, asset_id: String, current_map := "",
		current_rows: Array = []) -> Dictionary:
	var by_map := {}
	var bad: Array = []
	# R29：资产删除判定同样驱动破坏性动作，读磁盘实际内容
	var maps := MapStore.read_all_fresh(manifest, bad)
	for map_name in maps:
		# V4 P0-4：当前图不能整张跳过（解绑后放弃改动会恢复正式文件里的绑定），
		# 磁盘命中与活体命中取并集，见 content_usage 同名注释。
		var is_current := current_map != "" and str(map_name) == current_map
		var rows: Array = []
		for obj in ((maps[map_name] as Dictionary).get("objects", []) as Array):
			if not (obj is Dictionary):
				continue
			if str((obj as Dictionary).get("asset", "")) != asset_id:
				continue
			rows.append({
				"id": str((obj as Dictionary).get("code", "")),
				"x": floori(float((obj as Dictionary).get("x", 0))),
				"y": floori(float((obj as Dictionary).get("y", 0))),
			})
		if is_current:
			var have := {}
			for r in rows:
				have[str((r as Dictionary).get("id", ""))] = true
			for r2 in current_rows:
				if r2 is Dictionary and not have.has(str((r2 as Dictionary).get("id", ""))):
					rows.append(r2)
		if not rows.is_empty():
			by_map[str(map_name)] = rows
	if current_map != "" and not by_map.has(current_map) and not current_rows.is_empty():
		by_map[current_map] = current_rows   # 新建未保存的图不在磁盘列表里
	var unreadable: Array = []
	for b in bad:
		unreadable.append(str((b as Dictionary).get("name", "")))
	return {"by_map": by_map, "unreadable": unreadable, "incomplete": not unreadable.is_empty()}

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

static func content_edges_bulk(manifest: Dictionary, fn_id: String, cids: Array,
		cur_map := "", live_binds: Array = []) -> Dictionary:
	var refs := {}
	for c in cids:
		if str(c) != "":
			refs[str(c)] = {"instances": {}, "contents": [], "views": [], "n": 0}
	var instance_sets := {}
	var want_code := FunctionDecls.fn_code(manifest, fn_id)
	var bad: Array = []
	var maps := MapStore.read_all(manifest, bad)
	for map_name in maps:
		for obj in maps[map_name].get("objects", []):
			if not obj is Dictionary:
				continue
			for f in obj.get("functions", []):
				if not f is Dictionary or (want_code != "" and str(f.get("fn", "")) != want_code):
					continue
				var cid := str(f.get("content", ""))
				if refs.has(cid):
					_collect_content_instance(instance_sets, cid, str(map_name), str(obj.get("code", "")))
	for live in live_binds:
		var cid := str(live.get("cid", ""))
		if refs.has(cid):
			_collect_content_instance(instance_sets, cid, cur_map, str(live.get("code", "")))
	for cid in instance_sets:
		for map_name in instance_sets[cid]:
			var codes: Array = instance_sets[cid][map_name].keys()
			refs[cid].instances[map_name] = codes
			refs[cid].n += codes.size()
	var unreadable: Array = []
	for b in bad:
		unreadable.append("地图 %s 读不出来" % str(b))
	for kind in ContentStore.declared_kinds(manifest):
		var bad_content: Array = []
		var items := ContentStore.read_all(manifest, kind, bad_content)
		for b in bad_content:
			unreadable.append("内容 %s/%s 读不出来" % [kind, b.name])
		for oid in items:
			for ref in _content_links(manifest, kind, items[oid]):
				if ref.fn != fn_id or not refs.has(ref.cid) or (kind == fn_id and oid == ref.cid):
					continue
				var target: Dictionary = refs[ref.cid]
				target.contents.append({"kind": kind, "id": oid, "field": ref.path})
				target.n += 1
	for ref in ReferenceIndex.view_content_refs(manifest):
		if ref.fn == fn_id and refs.has(ref.cid):
			refs[ref.cid].views.append(ref)
			refs[ref.cid].n += 1
	return {"refs": refs, "unreadable": unreadable}

static func _collect_content_instance(sets: Dictionary, cid: String, map_name: String, code: String) -> void:
	if map_name == "" or code == "":
		return
	if not sets.has(cid):
		sets[cid] = {}
	if not sets[cid].has(map_name):
		sets[cid][map_name] = {}
	sets[cid][map_name][code] = true

## 入边全景（§7.2 inbound）：内容 (fn_id, cid) 的全部入边，破坏性检查共用这一个入口。
## edges = {instances: {地图名: [实例码]}, contents: [{kind,id,field}], views: [热点引用], drafts: [草稿键]}；
## complete=false 时 unreadable_sources 列出读不全的源（删除/清理必须拦截，D07 口径）。
## 暂存（会话内未落盘）的入边由调用方自行并入（见 content_form._delete_blocked_reason）。
static func inbound_content(manifest: Dictionary, fn_id: String, cid: String,
		cur_map := "", live_codes: Array = [], live_map := {}) -> Dictionary:
	var usage: Dictionary = content_usage(manifest, fn_id, cid, cur_map, live_codes, live_map)
	var unreadable: Array = []
	for u in (usage.get("unreadable", []) as Array):
		unreadable.append("地图 %s 读不出来" % str(u))
	for bc in (usage.get("bad_contents", []) as Array):
		unreadable.append(str(bc))
	var target := {"function": fn_id, "content": cid}
	return {
		"complete": unreadable.is_empty(),
		"unreadable_sources": unreadable,
		"edges": {
			"instances": usage.get("by_map", {}),
			"contents": content_inbound_refs(manifest, fn_id, cid),
			"views": ReferenceIndex.view_content_refs(manifest).filter(func(ref): return ref.fn == fn_id and ref.cid == cid),
			"project_slots": (ProjectSlots.references(manifest) + EventLayers.references(manifest)).filter(
				func(ref): return ref.target == target),
			"drafts": draft_inbound_refs(manifest, cid, fn_id),
		},
	}
