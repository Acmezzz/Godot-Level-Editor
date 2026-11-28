extends RefCounted
## Checks references on a screen before it is saved or previewed.

const StartupTargets := preload("res://src/project/startup_targets.gd")
const MapStore := preload("res://src/map/map_store.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const AudioDecls := preload("res://src/content/audio_decl.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const CellGraphScript := preload("res://src/map/cell_graph.gd")
const ReferenceIndex := preload("res://src/project/reference_index.gd")
const SpatialCheck := preload("res://src/project/spatial_reference_check.gd")
const ScreenLayout := preload("res://src/project/screen_layout.gd")

static func view_reference_issues(manifest: Dictionary, view_id := "", read_content := Callable()) -> Array:
	var out := []
	var contents := {}
	var map_index := {}
	for ref in ReferenceIndex.view_content_refs(manifest):
		if view_id != "" and ref.view != view_id:
			continue
		var key := [ref.fn, ref.cid]
		if ref.has("domains"):
			if StartupTargets.destination_available(manifest, ref.domains, ref.target, {}, read_content):
				if ref.has("context_map"):
					if map_index.is_empty():
						map_index = MapStore.code_index(manifest)
					if ReferenceIndex.resolve_map_code(map_index, ref.context_map).status != "ok":
						out.append(_view_issue(ref, "请为内容出口选择可读取的配对地图。"))
			else:
				out.append(_view_issue(ref, _flow_target_message(ref.target)))
			continue
		if not contents.has(key):
			contents[key] = (read_content.call(ref.fn, ref.cid) if read_content.is_valid() \
				else ContentStore.read_ex(manifest, ref.fn, ref.cid)).status
		if contents[key] != "ok":
			out.append(_view_issue(ref, "内容目标无法读取：%s/%s" % [ref.fn, ref.cid]))
	var images := ScreenLayout.image_assets(manifest)
	for ref in ReferenceIndex.view_image_refs(manifest):
		if (view_id == "" or ref.view == view_id) and not images.has(ref.asset):
			out.append(_view_issue(ref, "图片资产无法解析：%s" % ref.asset))
	var views := ReferenceIndex.view_ids(manifest)
	for ref in ReferenceIndex.view_transition_refs(manifest):
		if (view_id == "" or ref.view == view_id) and not views.has(ref.target.view):
			out.append(_view_issue(ref, "屏幕目标不存在：" + ref.target.view))
	var assets := AssetDecl.all(manifest)
	var map_targets := {}
	for ref in ReferenceIndex.view_map_refs(manifest):
		if view_id != "" and ref.view != view_id:
			continue
		if ref.has("domains"):
			if not StartupTargets.destination_available(manifest, ref.domains, ref.target, {}, read_content):
				out.append(_view_issue(ref, _flow_target_message(ref.target)))
			continue
		if map_index.is_empty():
			map_index = MapStore.code_index(manifest)
		if ReferenceIndex.resolve_map_code(map_index, ref.target.map).status != "ok":
			out.append(_view_issue(ref, "地图目标不可用：" + ref.target.map))
	for ref in ReferenceIndex.view_module_refs(manifest):
		if view_id != "" and ref.view != view_id:
			continue
		var valid := true
		var label := ""
		match ref.kind:
			"flow_target":
				if not StartupTargets.destination_available(manifest, ref.decl, ref.value, {}, read_content):
					out.append(_view_issue(ref, _flow_target_message(ref.value)))
			"asset", "entity_type":
				label = "资产"
				var expected: String = "entity" if ref.kind == "entity_type" else ref.filter.kind
				var asset: Dictionary = assets.get(ref.value, {})
				valid = not asset.is_empty() and (expected == "" or asset.kind == expected) \
					and (ref.filter.ids.is_empty() or ref.filter.ids.has(ref.value))
			"view":
				label = "视图"
				valid = views.has(ref.value)
			"audio":
				label = "音频"
				valid = not AudioDecls.by_code(manifest, ref.value).is_empty()
			"map":
				label = "地图"
				if map_index.is_empty():
					map_index = MapStore.code_index(manifest)
				valid = ReferenceIndex.resolve_map_code(map_index, ref.value).status == "ok"
			"entity_inst", "port", "edge", "cell", "layer":
				if map_index.is_empty():
					map_index = MapStore.code_index(manifest)
				var message := _module_spatial_problem(manifest, ref, map_index, map_targets)
				if message != "":
					out.append(_view_issue(ref, message))
		if not valid:
			out.append(_view_issue(ref, "%s引用无法解析：%s" % [label, ref.value]))
	return out

static func _module_spatial_problem(manifest: Dictionary, ref: Dictionary,
		map_index: Dictionary, targets: Dictionary) -> String:
	var value = ref.value
	var object_ref: bool = ref.kind in ["port", "edge"]
	if object_ref and not value is Dictionary:
		return "端口和格边引用必须是对象。"
	if object_ref and not value.get("map", "") is String:
		return "空间引用的地图键必须是字符串。"
	var key := _module_map_key(ref)
	if key == "":
		return "屏幕模块没有所属地图，请先选择配对地图。"
	var resolved := ReferenceIndex.resolve_map_code(map_index, key)
	if resolved.status != "ok":
		return "无法定位空间引用的目标地图：%s（%s）" % [key, resolved.status]
	var name: String = resolved.key
	if not targets.has(name):
		targets[name] = MapStore.read(manifest, name)
	var target: Dictionary = targets[name]
	if target.is_empty():
		return "无法读取空间引用的目标地图：" + name
	return _module_target_problem(manifest, ref, name, target)

static func _module_map_key(ref: Dictionary) -> String:
	if ref.kind in ["port", "edge"] and ref.value is Dictionary and ref.value.get("map", "") is String:
		return RefFields.object_map_key(ref.value, ref.paired)
	return ref.paired if ref.kind in ["entity_inst", "cell", "layer"] else ""

static func _module_target_problem(manifest: Dictionary, ref: Dictionary,
		name: String, target: Dictionary) -> String:
	var value = ref.value
	if ref.kind in ["entity_inst", "cell", "layer"] and not value is String:
		return "实例、格和图层引用必须是 ID 字符串。"
	if ref.kind == "entity_inst":
		var asset_id := ReferenceIndex.entity_asset(manifest, target, value)
		if asset_id != "" and (ref.filter.ids.is_empty() or ref.filter.ids.has(asset_id)):
			return ""
		return "目标地图 %s 中没有符合声明的实例：%s" % [name, value]
	if ref.kind == "cell" and CellGraphScript.cell_ids(target.get("meta", {}).get("cellGraph", {})).is_empty():
		return "目标地图 %s 没有可引用的格。" % name
	var key := _module_map_key(ref)
	var problem := SpatialCheck.problem(manifest, ref.kind, target, value, ref.decl, key, {key: target})
	return str(problem.get("message", ""))

static func _view_issue(ref: Dictionary, message: String) -> Dictionary:
	return {"path": ref.path, "message": message}

static func _flow_target_message(value: Variant) -> String:
	return "流程目标不可用：" + JSON.stringify(value)
