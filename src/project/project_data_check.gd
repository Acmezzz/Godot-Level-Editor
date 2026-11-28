extends RefCounted
## Checks the effective project, including any staged document overrides.

const Refs := preload("res://src/project/reference_index.gd")
const Usage := preload("res://src/project/reference_usage.gd")
const Spatial := preload("res://src/project/spatial_reference_check.gd")
const Screens := preload("res://src/project/screen_reference_validation.gd")
const Maps := preload("res://src/map/map_store.gd")
const Contents := preload("res://src/content/content_store.gd")
const Functions := preload("res://src/content/function_decl.gd")
const Targets := preload("res://src/project/startup_targets.gd")
const Timeline := preload("res://src/content/step_timeline.gd")
const Assets := preload("res://src/assets/asset_decl.gd")
const Audio := preload("res://src/content/audio_decl.gd")
const ContentValues := preload("res://src/content/content_value_validation.gd")

static func check(m: Dictionary, args := {}) -> Dictionary:
	var issues := EditorManifest.validate(m)
	var index := Maps.code_index(m)
	var codes: Dictionary = index.map
	var maps := {}
	var contents := {}
	var read_content := func(fn: String, cid: String) -> Dictionary:
		var key := [fn, cid]
		if not contents.has(key):
			contents[key] = Contents.read_ex(m, fn, cid)
		return contents[key]
	var validate_map := preload("res://src/map/map_data_validation.gd")
	for code in ([args.map] if args.has("map") else codes.keys()):
		if not codes.has(code):
			issues.append({"severity": "error", "path": "maps." + str(code), "message": "地图不存在或无法读取。"})
			continue
		var data := Maps.read(m, codes[code])
		maps[code] = data
		for issue in validate_map.validate(data, m):
			issues.append(issue.merged({"path": "maps." + code + "." + str(issue.path)}, true))
	for code in maps:
		var source: Dictionary = maps[code]
		var refs := Spatial.map_links(m, source)
		refs.append_array(Refs.entity_property_refs(m, source, ["map", "asset", "entity_type", "view", "audio"]))
		for ref in refs:
			var problem := _reference_problem(m, source, ref, maps, read_content)
			if problem != "":
				issues.append({"severity": "error", "path": "maps." + code + "." + ref.path, "message": problem, "reference": ref})
	if not args.has("map"):
		for issue in Screens.view_reference_issues(m, "", read_content):
			issues.append(issue.merged({"severity": "error"}))
		for name in index.unreadable:
			var path := Maps.path_for(m, name)
			var result := Maps.read_path(path, m)
			for error in result.errors:
				var suffix := "" if error.path == path else "." + str(error.path)
				issues.append({"severity": "error", "path": "maps." + name + suffix, "message": error.message})
		for code in Maps.code_conflicts(m):
			issues.append({"severity": "error", "path": "maps." + code, "message": "正式地图码重复。"})
		for id in m.get("eventLayers", {}):
			var group: Dictionary = m.eventLayers[id]
			var drawing: String = group.get("drawingMap", "")
			if (drawing != "" and not codes.has(drawing)) or group.get("maps", []).any(func(code): return not codes.has(code)):
				issues.append({"severity": "error", "path": "eventLayers." + id, "message": "图组所引用的地图不存在。"})
		for code in m.get("worldLayout", {}).get("chunks", {}):
			if not codes.has(code):
				issues.append({"severity": "error", "path": "worldLayout.chunks." + code, "message": "世界分块所引用的地图不存在。"})
		var startup: Dictionary = m.get("startup", {})
		var entry: Dictionary = startup.get("target", {})
		if not entry.is_empty() and not Targets.destination_available(m, startup, entry, maps, read_content):
			issues.append({"severity": "error", "path": "startup.target", "message": "项目入口不存在。"})
		if Targets.needs_content_map(startup, entry) and not Targets.content_map_available(m, startup.get("contentMap", "")):
			issues.append({"severity": "error", "path": "startup.contentMap", "message": "配对地图不存在。"})
		for ref in Refs.view_content_refs(m):
			if ref.has("context_map") and not codes.has(ref.context_map):
				issues.append({"severity": "error", "path": ref.path, "message": "配对地图不存在。"})
		var project_refs: Array = preload("res://src/project/project_content_slots.gd").references(m)
		project_refs.append_array(preload("res://src/project/event_layers.gd").references(m))
		for ref in project_refs:
			if not Targets.destination_available(m, ref.domains, ref.target, maps, read_content):
				issues.append({"severity": "error", "path": str(ref.get("path", ref.get("name", "project"))), "message": "项目或图组目标未声明或不可用。"})
	for code in maps:
		for obj in maps[code].get("objects", []):
			for binding in obj.get("functions", []):
				var cid: String = binding.get("content", "")
				var fn := Functions.fn_id_of(m, binding.fn)
				if cid != "" and fn != "" and read_content.call(fn, cid).status != "ok":
					issues.append({"severity": "error", "path": "maps." + code + ".objects." + str(obj.get("code", "")),
						"message": "绑定内容不存在：" + fn + "/" + cid})
	var content_items: Array = []
	var context_keys := []
	if not args.has("map") or args.has("content"):
		for fn in Contents.declared_kinds(m):
			for id in Contents.list_ids(m, fn):
				context_keys.append([fn, id])
				if args.has("content") or args.has("map"):
					continue
				var readback: Dictionary = read_content.call(fn, id)
				if readback.status != "ok":
					issues.append({"severity": "error", "path": "content.%s.%s" % [fn, id], "message": readback.error})
				else:
					content_items.append({"function": fn, "content": id, "data": readback.data})
	if args.has("content"):
		var fn: String = args.get("function", "")
		var item: Dictionary = read_content.call(fn, args.content)
		if item.status != "ok":
			issues.append({"severity": "error", "path": "content." + args.content, "message": "内容不存在或无法读取。"})
		else:
			content_items.append({"function": fn, "content": args.content, "data": item.data})
	elif not args.has("map"):
		content_items.append_array(m.get("_content_overrides", {}).values().filter(func(row): return row.get("deleted", false)))
	var binding_contexts := {}
	if not args.has("map") or args.has("content"):
		var context_maps := maps
		if args.has("map"):
			context_maps = {}
			for code in codes:
				context_maps[code] = Maps.read(m, codes[code])
		binding_contexts = Spatial.content_contexts(m, context_maps, func(fn: String, cid: String) -> Array:
			var data: Dictionary = read_content.call(fn, cid).data
			return Spatial.content_refs(m, fn, data) if not data.is_empty() else [], {}, context_keys)
	for row in content_items:
		if row.get("deleted", false):
			var incoming := Usage.inbound_content(m, row.function, row.content)
			if not incoming.complete or incoming.edges.values().any(func(rows): return not rows.is_empty()):
				issues.append({"severity": "error", "path": "content." + row.content, "message": "内容仍有引用。", "references": incoming})
		else:
			var invalid := ContentValues.check(m, row.function, row.data)
			for problem in invalid:
				issues.append({"severity": "error", "path": "content.%s.%s.%s" % [row.function, row.content, problem.path],
					"message": problem.message, "function": row.function, "content": row.content, "reference": {"path": problem.path}})
			if not invalid.is_empty():
				continue
			for section in Usage.content_sections(m, row.function, row.data):
				var values: Dictionary = section.values if section.values is Dictionary else {}
				var contexts: Array = binding_contexts.get([row.function, row.content], {}).values()
				if contexts.is_empty():
					contexts = [{}]
				for ref in Refs.property_refs(m, section.decls, values, {"function": row.function}, section.prefix, "code"):
					for source in contexts:
						var problem := _reference_problem(m, source, ref, maps, read_content)
						if problem != "":
							var map_code: String = source.get("meta", {}).get("code", "")
							issues.append({"severity": "error", "path": "content." + row.content + "." + ref.path,
								"message": problem if map_code == "" else "%s · %s" % [map_code, problem], "map": map_code,
								"function": row.function, "content": row.content, "reference": ref})
			for warning in Timeline.warnings(row.data.get("steps", [])):
				issues.append({"severity": "warning", "path": "content." + row.content + ".steps", "message": warning})
	return {"valid": not issues.any(func(issue): return issue.severity == "error"), "issues": issues}

static func _reference_problem(m: Dictionary, source: Dictionary, ref: Dictionary, maps: Dictionary,
		read_content: Callable) -> String:
	if Spatial.uses_paired_content_map(ref) and ref.get("paired", "") != "" \
			and not Maps.code_map(m).has(ref.paired):
		return "配对地图不存在或无法唯一解析：" + str(ref.paired)
	match ref.kind:
		"view":
			if not Refs.view_ids(m).has(ref.value):
				return "屏幕不存在：" + str(ref.value)
		"audio":
			if Audio.by_code(m, str(ref.value)).is_empty():
				return "音频不存在：" + str(ref.value)
		"asset", "entity_type":
			var item := Assets.by_id(m, str(ref.value))
			var kind: String = "entity" if ref.kind == "entity_type" else ref.filter.get("kind", "")
			var ids: Array = ref.filter.get("ids", [])
			if item.is_empty() or (kind != "" and item.kind != kind) or (not ids.is_empty() and ref.value not in ids):
				return "资源不存在或不符合字段声明：" + str(ref.value)
		"content":
			var fn: String = ref.filter.get("fn", "")
			if fn == "":
				fn = ref.get("function", "")
			if fn != "" and read_content.call(fn, str(ref.value)).status != "ok":
				return "内容不存在：" + fn + "/" + str(ref.value)
		"flow_target":
			if not Targets.destination_available(m, ref.decl, ref.value, maps, read_content):
				return "流程目标未声明或不存在：" + JSON.stringify(ref.value)
		_:
			return Spatial.link_problem(m, source, ref, maps)
	return ""
