extends RefCounted
## 全项目一致性审计：清单校验 + 地图校验 + 引用悬空 + 内容文件（码漂移/损坏 JSON/孤立内容），
## 统一产出 {kind, severity, path, message, map, jump} 条目。
## 纯字典/文件扫描，不碰场景树——UI（问题抽屉/自检入口）只是它的呈现层。
##
## 与编辑期解析的**口径统一**（否则会出现「界面能选、自检说悬空」）：地图键一律走
## ReferenceIndex.resolve_map，撞码/缺键都不猜；引用字段一律先过 RefFields.describe 的
## is_ref 判据，不按字符串形状猜。
## mapField 配对的可验证约束：
##   - 配对字段未填 = 目标就是本图（合法，不报）；填了别的图 = 跨图引用（不报，只校验目标存在）。
##   - 配对字段值既不是地图码也不是图名 = 悬空（报警告，路径指到配对字段本身）。
##   - 一个 entity_ref 指向的实例在目标图里查不到 = 悬空；目标图读不出来时**只记「未扫描」，
##     不判悬空**（读不到 ≠ 不存在，破坏性清理据 this 判断是否允许动手）。
## 批量入边扫描（content_edges_bulk）走浏览缓存读盘一次，为内容库列表与详情共用；
## 破坏性操作（如清空悬空）必须走 inbound_content / read_all_fresh，不吃旧缓存。

const StartupTargets := preload("res://src/project/startup_targets.gd")
const ProjectSlots := preload("res://src/project/project_content_slots.gd")
const FlowTarget := preload("res://src/content/flow_target.gd")
const ManifestValidation := preload("res://src/project/manifest_validation.gd")
const MapStore := preload("res://src/map/map_store.gd")
const MapFlow := preload("res://src/map/map_flow.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const AudioDecls := preload("res://src/content/audio_decl.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const TriggerDecls := preload("res://src/content/trigger_decl.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const CellGraphScript := preload("res://src/map/cell_graph.gd")
const ReferenceIndex := preload("res://src/project/reference_index.gd")
const SpatialCheck := preload("res://src/project/spatial_reference_check.gd")
const ScreenLayout := preload("res://src/project/screen_layout.gd")
const WorldLayout := preload("res://src/project/world_layout.gd")

## 审计全项目。manifest = 编辑器清单（含 _dir/_maps_dir）。
## 返回 [{kind, severity, path, message, map, jump}]；
## jump = {type: "map"/"asset", id: <地图名/资产 id>}（可跳转的条目带上）。
## meta_out（可选）：诊断信息 {incomplete: bool, unreadable_maps: [图名]}
## —— 有地图读不出来时「检查范围不完整」，清除悬空引用必须禁用（D07）。
static func audit(manifest: Dictionary, meta_out: Dictionary = {}) -> Array:
	var out: Array = []
	meta_out["incomplete"] = false
	meta_out["unreadable_maps"] = []
	# 1. 清单校验
	var startup_valid := true
	var world_valid := true
	for e in ManifestValidation.validate(manifest, str(manifest.get("_dir", ""))):
		out.append(_wrap("manifest", e))
		if str(e.path).begins_with("startup"):
			startup_valid = false
		elif str(e.path).begins_with("worldLayout"):
			world_valid = false
	if startup_valid:
		var startup_target: Dictionary = manifest.get("startup", {}).get("target", {})
		if not StartupTargets.available(manifest, startup_target):
			out.append(_wrap("manifest", {"severity": "error", "path": "startup.target",
				"message": "正式启动入口不可读取：%s。" % JSON.stringify(startup_target)
			}).merged({"jump": {"type": "startup"}}, true))
		elif StartupTargets.needs_content_map(manifest.get("startup", {}), startup_target) \
				and not StartupTargets.content_map_available(manifest, manifest.startup.get("contentMap", "")):
			out.append(_wrap("manifest", {"severity": "error", "path": "startup.contentMap",
				"message": "正式内容入口需要一张可读取的配对地图。"
			}).merged({"jump": {"type": "startup"}}, true))
	# 2. 地图校验（读盘全图）+ 顺带收集被实例引用的内容（孤立内容判定用）
	var used_content := {}
	for ref in ProjectSlots.references(manifest):
		if StartupTargets.destination_available(manifest, ref.domains, ref.target):
			used_content[_content_key(ref.target.function, ref.target.content)] = true
		else:
			out.append({"kind": "ref", "severity": "warning", "path": ref.path,
				"message": "项目规则引用不可用：" + JSON.stringify(ref.target),
				"jump": {"type": "project_slot", "id": ref.id}})
	var content_contexts := {}
	var binding_missing: Array = []
	var maps_dir := str(manifest.get("_maps_dir", ""))
	var graph_targets := {}
	var graph_index: Array = []
	var world_codes := {}
	var delta_problems := {}
	var world_chunks: Dictionary = manifest.worldLayout.chunks if world_valid and manifest.has("worldLayout") else {}
	if maps_dir != "" and DirAccess.open(maps_dir) == null:
		meta_out["incomplete"] = true
		out.append(_wrap("map", {"path": maps_dir, "message": "无法扫描地图目录", "severity": "error"}))
	elif maps_dir != "":
		for name in MapStore.list_maps(manifest):
			var r: Dictionary = MapStore.read_path(maps_dir.path_join(name + ".json"), manifest)
			for e in (r.get("warnings", []) as Array):
				out.append(_wrap_map_issue("map", e, str(name)))
			for e in (r.get("errors", []) as Array):
				out.append(_wrap_map_issue("map", e, str(name)))
			if bool(r.get("ok", false)):
				var d: Dictionary = r.get("data", {}) as Dictionary
				var code := str(d.get("meta", {}).get("code", ""))
				if code != "":
					world_codes[code] = int(world_codes.get(code, 0)) + 1
					var mode := str(world_chunks.get(code, {}).get("generatedMode", ""))
					if WorldLayout.is_delta_mode(mode):
						delta_problems[code] = WorldLayout.delta_problem(d, mode)
				out.append_array(_ref_checks(d, manifest, str(name)))
				out.append_array(_graph_target_checks(d, manifest, str(name), graph_index, graph_targets))
				out.append_array(_binding_checks(d, manifest, str(name)))
				_collect_used_content(d, manifest, used_content, binding_missing, str(name))
				_collect_spatial_contexts(manifest, d, str(name), content_contexts)
			else:
				meta_out["incomplete"] = true
				(meta_out["unreadable_maps"] as Array).append(str(name))
	# 绑定目标内容文件缺失（C12）：绑定是引用入口，文件没了必须显形
	out.append_array(binding_missing)
	for code in world_chunks:
		var count := int(world_codes.get(code, 0))
		if count != 1:
			out.append(_wrap("manifest", {"severity": "warning", "path": "worldLayout.chunks." + str(code),
				"message": "世界分块地图码重复" if count > 1 else "世界分块地图未找到或无法读取"}))
		elif delta_problems.get(code, "") != "":
			out.append(_wrap("manifest", {"severity": "warning", "path": "worldLayout.chunks." + str(code),
				"message": delta_problems[code]}))
	out.append_array(view_reference_issues(manifest, "", used_content))
	# 3. 内容文件：损坏 JSON / function 码漂移 / 孤立内容
	out.append_array(_content_checks(manifest, used_content, content_contexts))
	# 4. 资产停用/改名待确认（A4）：已有引用仍按原 ID 解析，但要让人看见问题所在
	var scan: Dictionary = manifest.get("_scan_report", {}) if manifest.get("_scan_report", {}) is Dictionary else {}
	for aid in (scan.get("retired", []) as Array):
		var ent := AssetDecl.live_by_id(manifest, str(aid))
		out.append({
			"kind": "asset", "severity": "warning",
			"path": "assets/" + str(aid),
			"message": "资产停用：%s 的源文件不在 %s（可恢复；原 ID 引用仍有效）" % [
				str(ent.get("name", aid)), str(ent.get("retiredPath", "?"))],
			"map": "", "jump": {"type": "asset", "id": str(aid)},
		})
	for amb in (scan.get("ambiguous", []) as Array):
		var aid2 := str((amb as Dictionary).get("id", ""))
		var cands: Array = (amb as Dictionary).get("candidates", [])
		out.append({
			"kind": "asset", "severity": "warning",
			"path": "assets/" + aid2,
			"message": "资产改名待确认：%d 个同指纹候选（资产页选择）" % cands.size(),
			"map": "", "jump": {"type": "asset", "id": aid2},
		})
	# 5. 地图码唯一性（A2/D08）：重复码必须列出全部路径，引用解析据此拒绝猜测
	var dup_codes := MapStore.code_conflicts(manifest)
	for code in dup_codes:
		var names: Array = dup_codes[code]
		var paths: PackedStringArray = PackedStringArray()
		for nm in names:
			paths.append(maps_dir.path_join(str(nm) + ".json") if maps_dir != "" else str(nm))
		out.append({
			"kind": "map", "severity": "warning",
			"path": "maps/" + str(code),
			"message": "地图码重复：%s（引用解析会拒绝猜测，请改名或重发码）" % ", ".join(paths),
			"map": str(names[0]) if not names.is_empty() else "", "jump": {},
		})
	return out

## The view editor and project audit share these checks; only the audit asks for usage.
static func view_reference_issues(manifest: Dictionary, view_id := "", used_content := {}) -> Array:
	var out := []
	var contents := {}
	var map_index := {}
	for ref in ReferenceIndex.view_content_refs(manifest):
		if view_id != "" and ref.view != view_id:
			continue
		var key := _content_key(ref.fn, ref.cid)
		if ref.has("domains"):
			if StartupTargets.destination_available(manifest, ref.domains, ref.target):
				used_content[key] = true
				if ref.has("context_map"):
					if map_index.is_empty():
						map_index = MapStore.code_index(manifest)
					if ReferenceIndex.resolve_indexed_map(map_index, ref.context_map).status != "ok":
						out.append(_view_issue(ref, "请为内容出口选择可读取的配对地图。"))
			else:
				out.append(_view_issue(ref, _flow_target_message(ref.target)))
			continue
		if not contents.has(key):
			contents[key] = ContentStore.read_ex(manifest, ref.fn, ref.cid).status
		if contents[key] == "ok":
			used_content[key] = true
		else:
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
			if not StartupTargets.destination_available(manifest, ref.domains, ref.target):
				out.append(_view_issue(ref, _flow_target_message(ref.target)))
			continue
		if map_index.is_empty():
			map_index = MapStore.code_index(manifest)
		if ReferenceIndex.resolve_graph_map(map_index, ref.target.map).status != "ok":
			out.append(_view_issue(ref, "地图目标不可用：" + ref.target.map))
	for ref in ReferenceIndex.view_module_refs(manifest):
		if view_id != "" and ref.view != view_id:
			continue
		var valid := true
		var label := ""
		match ref.kind:
			"flow_target":
				if not StartupTargets.destination_available(manifest, ref.decl, ref.value):
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
				valid = not AudioDecls.from_value(manifest, ref.value).is_empty()
			"map":
				label = "地图"
				if map_index.is_empty():
					map_index = MapStore.code_index(manifest)
				valid = ReferenceIndex.resolve_indexed_map(map_index, ref.value).status == "ok"
			"entity_inst", "port", "edge", "cell", "layer":
				if map_index.is_empty():
					map_index = MapStore.code_index(manifest)
				var message := _module_spatial_problem(manifest, ref, assets, map_index, map_targets)
				if message != "":
					out.append(_view_issue(ref, message))
		if not valid:
			out.append(_view_issue(ref, "%s引用无法解析：%s" % [label, ref.value]))
	return out

static func _module_spatial_problem(manifest: Dictionary, ref: Dictionary, assets: Dictionary,
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
	var resolved := ReferenceIndex.resolve_indexed_map(map_index, key)
	if resolved.status != "ok":
		return "无法定位空间引用的目标地图：%s（%s）" % [key, resolved.status]
	var name: String = resolved.key
	if not targets.has(name):
		targets[name] = MapStore.read(manifest, name)
	var target: Dictionary = targets[name]
	if target.is_empty():
		return "无法读取空间引用的目标地图：" + name
	return _module_target_problem(manifest, ref, assets, name, target)

static func _module_map_key(ref: Dictionary) -> String:
	if ref.kind in ["port", "edge"] and ref.value is Dictionary and ref.value.get("map", "") is String:
		return RefFields.object_map_key(ref.value, ref.paired)
	return ref.paired if ref.kind in ["entity_inst", "cell", "layer"] else ""

## The caller has already resolved the map; use its supplied snapshot for every check.
static func _module_target_problem(manifest: Dictionary, ref: Dictionary, assets: Dictionary,
		name: String, target: Dictionary) -> String:
	var value = ref.value
	if ref.kind in ["entity_inst", "cell", "layer"] and not value is String:
		return "实例、格和图层引用必须是 ID 字符串。"
	if ref.kind == "entity_inst":
		for obj in target.get("objects", []):
			if obj.get("code") != value:
				continue
			var asset_id: String = obj.get("asset", "")
			if assets.get(asset_id, {}).get("kind") == "entity" \
					and (ref.filter.ids.is_empty() or ref.filter.ids.has(asset_id)):
				return ""
		return "目标地图 %s 中没有符合声明的实例：%s" % [name, value]
	if ref.kind == "cell" and CellGraphScript.cell_ids(target.get("meta", {}).get("cellGraph", {})).is_empty():
		return "目标地图 %s 没有可引用的格。" % name
	var key := _module_map_key(ref)
	var problem := SpatialCheck.problem(manifest, ref.kind, target, name, value, ref.decl, key, {key: target})
	return str(problem.get("message", ""))

static func _view_issue(ref: Dictionary, message: String) -> Dictionary:
	var out := _wrap("manifest", {"path": ref.path, "message": "参考视图 %s：%s" % [ref.view, message]})
	out.jump = {"type": "view", "id": ref.view, "element": ref.get("element", ""),
		"field": ref.get("field", ""), "hotspot": ref.get("hotspot", -1)}
	return out

static func _graph_target_checks(data: Dictionary, manifest: Dictionary, name: String,
		index: Array, cached_targets: Dictionary) -> Array:
	var out: Array = []
	var graph := CellGraphScript.graph_of(data.get("meta", {}))
	var edges: Array = graph.get("edges", [])
	for i in edges.size():
		var edge: Dictionary = edges[i]
		var code := str(edge.get("toMap", ""))
		if code == "":
			continue
		if not cached_targets.has(code):
			if index.is_empty():
				index.append(MapStore.code_index(manifest))
			var resolved := ReferenceIndex.resolve_graph_map(index[0], code)
			var target := {}
			if resolved.status == "ok":
				var dest := MapStore.read(manifest, str(resolved.key))
				if dest.is_empty() or dest.get("meta", {}).get("code") != code:
					resolved["status"] = "unreadable"
				else:
					for id in CellGraphScript.cell_ids(CellGraphScript.graph_of(dest.meta)):
						target[id] = true
			cached_targets[code] = {"status": resolved.status, "cells": target}
		var result: Dictionary = cached_targets[code]
		var message := ""
		var path := "meta.cellGraph.edges[%d].toMap" % i
		match result.status:
			"ok":
				if not result.cells.has(edge.to):
					path = "meta.cellGraph.edges[%d].to" % i
					message = "格图边 %s 的目标格 %s 在地图 %s 中不存在" % [edge.id, edge.to, code]
			"ambiguous":
				message = "格图边 %s 的目标地图码有歧义：%s" % [edge.id, code]
			"unreadable":
				message = "格图边 %s 的目标地图无法核验：%s" % [edge.id, code]
			_:
				message = "格图边 %s 的目标地图码不存在：%s" % [edge.id, code]
		if message != "":
			out.append(_wrap_map_issue("ref", {"severity": "warning", "path": path, "message": message}, name))
	return out

## 收集全项目被实例绑定引用的内容（C12：按 `(功能 id, 内容 ID)` 索引，裸 ID 会跨功能误判）。
## 绑定里的 fn 是执行码，先解析成功能 id；解析不到 = 数据漂移，按 `?\u0001<cid>` 记。
## binding_missing 收「绑定指向的内容文件不存在」条目（后续统一进审计）。
static func _collect_used_content(data: Dictionary, manifest: Dictionary, used: Dictionary,
		binding_missing: Array, map_name: String) -> void:
	for ref in MapFlow.references(manifest, data):
		if FlowTarget.kind(ref.value) == "content":
			used[_content_key(ref.value.function, ref.value.content)] = true
	for o in (data.get("objects", []) as Array):
		if not (o is Dictionary):
			continue
		for f in ((o as Dictionary).get("functions", []) as Array):
			if not (f is Dictionary):
				continue
			var cid := str((f as Dictionary).get("content", ""))
			if cid == "":
				continue
			var fn_code := str((f as Dictionary).get("fn", ""))
			var fn_id := FunctionDecls.fn_id_of(manifest, fn_code)
			used[_content_key(fn_id, cid)] = true
			if fn_id == "":
				continue
			var path := ContentStore.path_for(manifest, fn_id, cid)
			if path == "" or not FileAccess.file_exists(path):
				binding_missing.append({
					"kind": "content", "severity": "warning",
					"path": "%s/%s" % [fn_id, cid],
					"message": "绑定目标内容文件不存在：%s → %s/%s（实例 %s）" % [
						map_name, fn_id, cid, str((o as Dictionary).get("code", "?"))],
					"map": map_name, "jump": {},
				})

static func _content_key(fn_id: String, cid: String) -> String:
	return (fn_id if fn_id != "" else "?") + "\u0001" + cid

## 内容文件检查（全部警告级）：损坏 JSON；function 码漂移（清单改码后旧文件仍带旧码，
## 写盘时按当前码重写自愈）；孤立内容（无任何实例引用，可能是复用库，只提醒）。
static func _content_checks(manifest: Dictionary, used: Dictionary, contexts := {}) -> Array:
	var out: Array = []
	var root := ContentStore.root_dir(manifest)
	if root == "" or not DirAccess.dir_exists_absolute(root):
		return out
	var rows := {}
	for kind in ContentStore.declared_kinds(manifest):
		var bad: Array = []
		var items := ContentStore.read_all(manifest, kind, bad)
		for b in bad:
			out.append({
				"kind": "content", "severity": "warning",
				"path": "%s/%s" % [kind, str(b.get("name", ""))],
				"message": "内容文件损坏（JSON 解析失败或非对象）",
				"map": "", "jump": {},
			})
		var cur_code := str(FunctionDecls.fn_code(manifest, kind))
		for cid in items:
			var data: Dictionary = items[cid]
			var fc := str(data.get("function", ""))
			if cur_code != "" and fc != "" and fc != cur_code:
				out.append({
					"kind": "content", "severity": "warning",
					"path": "%s/%s" % [kind, cid],
					"message": "码漂移：内容记录的功能码 %s 与清单当前码 %s 不一致（改动任一字段即按当前码重写）" % [fc, cur_code],
					"map": "", "jump": {},
				})
			rows[_content_key(kind, cid)] = {"fn_id": kind, "cid": cid, "data": data}
			# C12：内容自身的引用范围——步骤码、条件字段、内容池字段
			out.append_array(_content_ref_checks(manifest, kind, str(cid), data))
	_collect_entry_contexts(manifest, contexts)
	var graph := _content_context_graph(manifest, contexts, rows)
	for key in rows:
		var row: Dictionary = rows[key]
		if str(row.data.get("scope", "")) != "project" and not used.has(key) and not graph.inbound.has(key):
			out.append({"kind": "content", "severity": "warning", "path": "%s/%s" % [row.fn_id, row.cid],
				"message": "孤立内容：没有实例绑定或内容入边（可能是复用库，确认后可删）",
				"map": "", "jump": {}})
		out.append_array(_contextual_content_checks(manifest, row.fn_id, row.cid, row.data,
			graph.contexts.get(key, {})))
	return out

## 内容文件的引用自检（C12）：只查**声明驱动**的引用，不做字符串猜测。
##   steps[].step 必须是步骤池里存在的码；步骤字段只认该步骤声明的字段码；
##   功能/条件字段里 content 类引用（source: content:<fn>）的值必须在对应内容目录内。
## 只报 warning：内容可能由游戏侧预置、编辑器还没扫到；但必须让人看见。
static func _content_ref_checks(manifest: Dictionary, kind: String, cid: String,
		data: Dictionary) -> Array:
	var out: Array = []
	var label := "%s/%s" % [kind, cid]
	# 1) 步骤引用
	var steps = data.get("steps", null)
	if steps is Array and not (steps as Array).is_empty():
		var pool := StepDecls.steps(manifest)
		if pool.is_empty():
			out.append({"kind": "content", "severity": "warning", "path": label,
				"message": "内容带 steps 数组，但清单没有步骤声明（步骤码无法解析）",
				"map": "", "jump": {}})
		else:
			for i in (steps as Array).size():
				var st = (steps as Array)[i]
				if not (st is Dictionary):
					continue
				var sc := str((st as Dictionary).get("step", ""))
				if sc != "" and StepDecls.step_by_code(manifest, sc).is_empty():
					out.append({"kind": "content", "severity": "warning", "path": "%s.steps[%d]" % [label, i],
						"message": "步骤码不在清单步骤池里: %s" % sc,
						"map": "", "jump": _content_jump(kind, cid, "", "", i)})
	var findings: Array = []
	var targets := {}
	for ref in _content_links(manifest, kind, data, findings):
		var key := _content_key(ref.fn, ref.cid)
		if not targets.has(key):
			targets[key] = ContentStore.read_ex(manifest, ref.fn, ref.cid).status
		if targets[key] == "missing":
			findings.append({"path": ref.path, "field": ref.field, "step_index": ref.step_index,
				"message": "引用的内容不存在：%s/%s" % [ref.fn, ref.cid]})
		elif targets[key] != "ok":
			findings.append({"path": ref.path, "field": ref.field, "step_index": ref.step_index,
				"message": "引用的内容无法读取：%s/%s (%s)" % [
				ref.fn, ref.cid, targets[key]]})
	for issue in findings:
		out.append({"kind": "content", "severity": "warning", "path": label + "." + str(issue.path),
			"message": str(issue.message), "map": "",
			"jump": _content_jump(kind, cid, issue.field, "", issue.step_index)})
	return out

static func _content_jump(fn: String, cid: String, field: String, map_context: String, step_index: int) -> Dictionary:
	return {"type": "content", "fn": fn, "id": cid, "field": field, "context": map_context, "step_index": step_index}

static func _as_list(v) -> Array:
	if v is Array:
		return v
	if v == null or str(v) == "":
		return []
	return [v]

## 绑定的声明一致性（C09/C12）：类型挂载缺失、时机不在白名单。
## 只提示不自动修：这两类都可能是有意的临时状态（挂载会在下次载图补，时机可能等声明更新）。
static func _binding_checks(data: Dictionary, manifest: Dictionary, map_name: String) -> Array:
	var out: Array = []
	for e in (data.get("objects", []) as Array):
		if not (e is Dictionary):
			continue
		var o: Dictionary = e
		var aid := str(o.get("asset", ""))
		if aid == "":
			continue
		var ad := AssetDecl.by_id(manifest, aid)
		if str(ad.get("kind", "")) != "entity":
			continue
		var fns: Array = o.get("functions", []) if o.get("functions", null) is Array else []
		var counts := {}
		var mount_codes := {}
		var location := "%s · %s(%s).functions" % [map_name, aid, str(o.get("code", "?"))]
		var jump := {"type": "entity", "map": map_name, "code": str(o.get("code", ""))}
		var messages: Array[String] = []
		for f in fns:
			if f is Dictionary:
				var code := str(f.get("fn", ""))
				counts[code] = int(counts.get(code, 0)) + 1
		for mt in FunctionDecls.entity_mounts(manifest, aid):
			var code := str(mt.code)
			mount_codes[code] = true
			var state := FunctionDecls.mounted_index(fns, code)
			var label := FunctionDecls.function_name(manifest, str(mt.id))
			if state == -1:
				messages.append("挂载缺失：%s（重开该图会自动补齐）" % label)
			elif state == -2:
				messages.append("挂载有歧义：%s 有多条旧绑定，请在内容页选择自带行" % label)
		for code in counts:
			var id := FunctionDecls.fn_id_of(manifest, code)
			if int(counts[code]) > 1 and id != "" and not FunctionDecls.is_repeatable(manifest, id):
				messages.append("功能 %s 有多条绑定，但未声明 repeatable" % id)
		for f in fns:
			if f is Dictionary and f.get("mounted") is bool and f.mounted and not mount_codes.has(str(f.get("fn", ""))):
				messages.append("这条绑定已不属于类型挂载：%s" % str(f.get("fn", "")))
		for message in messages:
			out.append({"kind": "binding", "severity": "warning", "path": location,
				"message": message, "map": map_name, "jump": jump})
		# 2) 时机白名单：绑定写的时机码必须是该功能声明 triggers 里的某个
		for f in fns:
			if not (f is Dictionary):
				continue
			var trg := str((f as Dictionary).get("trigger", ""))
			if trg == "":
				continue
			var fn_id := FunctionDecls.fn_id_of(manifest, str((f as Dictionary).get("fn", "")))
			if fn_id == "":
				continue   # 未声明的功能码由地图校验报，避免重复
			var allowed := {}
			for tid in FunctionDecls.fn_triggers(manifest, fn_id):
				allowed[str(TriggerDecls.trigger_decl(manifest, str(tid)).get("code", ""))] = true
			if not allowed.has(trg):
				out.append({
					"kind": "binding", "severity": "warning",
					"path": "%s · %s(%s).functions" % [map_name, aid, str(o.get("code", "?"))],
					"message": "时机不在白名单：%s 的声明未允许时机码 %s" % [
						FunctionDecls.function_name(manifest, fn_id), trg],
					"map": map_name,
					"jump": {"type": "entity", "map": map_name, "code": str(o.get("code", ""))},
				})
	return out

## D07：把过期报告里的清除项安全落地到一张已读出的地图数据上（就地修改 d）。
## 双重复验：① 现在重跑引用检查，该实例该字段仍是同一条悬空引用（目标域可能已补好）；
## ② 字段当前值仍等于报告里的预期旧值（期间可能已改指向）。
## 两项都过才擦键。返回 {changed, erased, skipped}，由调用方决定是否写盘与计数。
##
## §7.2 配对地图字段：擦掉一个引用字段后，如果它是某个 `mapField` 的消费方，
## **只在没有别的引用字段还在用它时**才把配对地图字段一起擦掉；还有用途就保留
## （否则会把仍然有效的图目标一起删掉，其它引用随之失义）。
static func apply_ref_fixes(manifest: Dictionary, map_name: String, fix_list: Array,
		d: Dictionary) -> Dictionary:
	var fresh := {}
	for e2 in _ref_checks(d, manifest, map_name):
		var f2 = (e2 as Dictionary).get("fix", null)
		if f2 is Dictionary:
			fresh["%s\u0001%s\u0001%s" % [str((f2 as Dictionary).get("code", "")),
				str((f2 as Dictionary).get("prop", "")), str((f2 as Dictionary).get("expect", ""))]] = true
	var changed := false
	var erased := 0
	var skipped := 0
	for fx in fix_list:
		if not (fx is Dictionary):
			continue
		var f: Dictionary = fx
		var code := str(f.get("code", ""))
		var prop := str(f.get("prop", ""))
		var expect := str(f.get("expect", ""))
		if code == "" or prop == "" or expect == "" \
				or not fresh.has("%s\u0001%s\u0001%s" % [code, prop, expect]):
			skipped += 1
			continue
		for o in (d.get("objects", []) as Array):
			if not (o is Dictionary):
				continue
			var od: Dictionary = o
			if str(od.get("code", "")) != code:
				continue
			var props: Dictionary = od.get("props", {}) if od.get("props", {}) is Dictionary else {}
			if _val_str(props.get(prop, "")) != expect:
				skipped += 1
				continue
			props.erase(prop)
			# 配对地图字段只在没人再用时才清（保留仍有用途的图目标）
			var pair := _pair_field_of(manifest, str(od.get("asset", "")), prop)
			if pair != "" and not _pair_still_used(manifest, str(od.get("asset", "")), pair, props):
				props.erase(pair)
			od["props"] = props
			changed = true
			erased += 1
	return {"changed": changed, "erased": erased, "skipped": skipped}

## 某资产里字段 `prop` 声明的 `mapField`（人类字段 id）；无声明/无配对返回 ""。
static func _pair_field_of(manifest: Dictionary, asset_id: String, prop: String) -> String:
	for fd in (_fields_of(manifest, asset_id) as Array):
		if fd is Dictionary and str((fd as Dictionary).get("id", "")) == prop:
			return str((fd as Dictionary).get("mapField", ""))
	return ""

## 配对地图字段 `pair` 是否还有别的引用字段在用：该资产下除 `skip_prop` 外
## 任一声明 mapField == pair 的引用字段仍有非空值 = 有用途。
static func _pair_still_used(manifest: Dictionary, asset_id: String, pair: String,
		props: Dictionary, skip_prop := "") -> bool:
	for fd in (_fields_of(manifest, asset_id) as Array):
		if not (fd is Dictionary):
			continue
		var d2: Dictionary = fd
		if str(d2.get("mapField", "")) != pair:
			continue
		var k := str(d2.get("id", ""))
		if k == skip_prop:
			continue
		if str(props.get(k, "")) != "":
			return true
	return false

## 资产声明里的字段表（停用条目也读——清理旧图仍要按它的声明判断配对）。
static func _fields_of(manifest: Dictionary, asset_id: String) -> Array:
	var a: Dictionary = AssetDecl.by_id(manifest, asset_id)
	return (a.get("fields", []) as Array) if (a.get("fields", null) is Array) else []

## 内容使用统计：扫全项目实例绑定，找引用 (功能 id, 内容 ID) 的实例；
## 当前图的磁盘和活体引用取并集。
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

## 反查「哪些内容文件引用了 (fn_id, cid)」（E3 删除前检查）：
## 只认声明为 content 类引用（RefFields kind=content）的字段；返回 [{kind, id, field}]。
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

## 正式文件、暂存与草稿共用同一目标身份与字段路径解析。
static func content_link_paths(manifest: Dictionary, source_fn: String, data: Dictionary,
		target_fn: String, target_id: String) -> Array:
	var out: Array = []
	for ref in _content_links(manifest, source_fn, data):
		if (target_fn == "" or ref.fn == target_fn) and ref.cid == target_id:
			out.append(ref.path)
	return out

static func _content_links(manifest: Dictionary, source_fn: String, data: Dictionary,
		findings: Array = [], include_views := false) -> Array:
	var out: Array = []
	for section in _content_sections(manifest, source_fn, data):
		_collect_content_links(manifest, section.decls, section.values, source_fn, section.prefix, out, findings, section.step_index)
	return out if include_views else out.filter(func(link): return link.fn != "@view")

static func _content_sections(manifest: Dictionary, fn: String, data: Dictionary) -> Array:
	var decls := FunctionDecls.function_fields(manifest, fn).duplicate()
	var conds = FunctionDecls.function_decl(manifest, fn).get("conditions")
	if conds is Array:
		for condition in conds:
			var fields = ConditionDecls.condition_decl(manifest, str(condition)).get("fields")
			if fields is Array:
				decls.append_array(fields)
	var out: Array = [{"decls": decls, "values": data.get("fields"), "prefix": "", "step_index": -1}]
	var steps = data.get("steps")
	if steps is Array:
		for i in steps.size():
			var step = steps[i]
			if not step is Dictionary:
				continue
			var sd := StepDecls.step_by_code(manifest, str(step.get("step", "")))
			var fields = sd.get("fields")
			if fields is Array:
				out.append({"decls": fields, "values": step.get("fields"), "prefix": "steps[%d]." % i, "step_index": i})
	return out

static func _collect_spatial_contexts(manifest: Dictionary, data: Dictionary, name: String,
		contexts: Dictionary, label := "") -> void:
	var context_label := label if label != "" else name
	for ref in MapFlow.scoped_content(manifest, data):
		_add_map_context(contexts, _content_key(ref.value.function, ref.value.content), data, name, context_label)
	for ref in MapFlow.references(manifest, data):
		if ref.decl.get("viewMapContext") == "inherit" and ScreenLayout.view_target(ref.value):
			_add_map_context(contexts, _content_key("@view", ref.value.view), data, name, context_label)
	var objects = data.get("objects", [])
	if not objects is Array:
		return
	for obj in objects:
		if not obj is Dictionary or not obj.get("functions", []) is Array:
			continue
		for target in ReferenceIndex.inherited_property_targets(manifest,
				_fields_of(manifest, obj.get("asset", "")), obj.get("props", {}), true):
			var key := _content_key("@view", target.view) if target.has("view") else _content_key(target.function, target.content)
			_add_map_context(contexts, key, data, name, context_label)
		for binding in obj.get("functions", []):
			if not binding is Dictionary:
				continue
			var fn := FunctionDecls.fn_id_of(manifest, str(binding.get("fn", "")))
			var cid := str(binding.get("content", ""))
			if fn == "" or cid == "":
				continue
			_add_map_context(contexts, _content_key(fn, cid), data, name, context_label)

static func _add_map_context(contexts: Dictionary, key: String, data: Dictionary, name: String, label: String) -> void:
	if not contexts.has(key):
		contexts[key] = {}
	contexts[key][label] = {"map": data, "name": name}

static func _collect_entry_contexts(manifest: Dictionary, contexts: Dictionary) -> void:
	var cache := {}
	var startup: Dictionary = manifest.get("startup", {})
	var target = startup.get("target")
	var refs := ReferenceIndex.view_content_refs(manifest)
	if StartupTargets.needs_content_map(startup, target) and startup.get("contentMap") is String:
		refs.append({"fn": target.function, "cid": target.content, "context_map": startup.contentMap})
	var index := {}
	for ref in refs:
		if not ref.has("context_map") or ref.context_map == "":
			continue
		var map_key: String = ref.context_map
		if not cache.has(map_key):
			if index.is_empty():
				index = MapStore.code_index(manifest)
			var resolved := ReferenceIndex.resolve_indexed_map(index, map_key) if ref.has("view") \
				else ReferenceIndex.resolve_graph_map(index, map_key)
			cache[map_key] = MapStore.read(manifest, resolved.key) if resolved.status == "ok" else {}
		var map: Dictionary = cache[map_key]
		if map.is_empty():
			continue
		var name := str(map.meta.get("name", map_key))
		var source := "屏幕 " + str(ref.view) if ref.has("view") else "正式启动"
		_add_map_context(contexts, _content_key(ref.fn, ref.cid), map, name, "%s → 地图 %s" % [source, name])

static func _contextual_content_checks(manifest: Dictionary, fn: String, cid: String,
		data: Dictionary, contexts: Dictionary) -> Array:
	var out: Array = []
	var sources := contexts if not contexts.is_empty() else {"": {"map": {}, "name": ""}}
	for section in _content_sections(manifest, fn, data):
		for label in sources:
			var context: Dictionary = sources[label]
			for issue in _spatial_fields(manifest, section.decls, section.values, context.map,
					context.name, true, {}, section.prefix):
				var path := "%s/%s.%s" % [fn, cid, issue.path]
				if label != "" and label != context.name:
					path += " · " + str(label)
				elif label != "":
					path += " · 地图 " + str(label)
				out.append({"kind": "content", "severity": "warning", "path": path,
					"message": issue.message, "map": context.name,
					"jump": _content_jump(fn, cid, issue.prop, context.name, section.step_index)})
	return out

static func _screen_context_links(manifest: Dictionary) -> Dictionary:
	var links := {}
	for ref in ReferenceIndex.view_transition_refs(manifest):
		if ref.get("domains", {}).get("viewMapContext") == "inherit":
			_append_screen_context_link(links, ref.view, "@view", ref.target.view)
	for ref in ReferenceIndex.view_content_refs(manifest):
		if ref.get("domains", {}).get("contentMapContext") == "inherit":
			_append_screen_context_link(links, ref.view, ref.fn, ref.cid)
	return links

static func _append_screen_context_link(links: Dictionary, view: String, fn: String, cid: String) -> void:
	var key := _content_key("@view", view)
	if not links.has(key):
		links[key] = []
	links[key].append({"fn": fn, "cid": cid, "map_context": "inherit"})

## 传播状态由 (内容或屏幕, 入口, 当前地图) 唯一确定。分支只传地图，不替游戏计算条件；
## 循环与汇合都不会反复扫描。rows 为已保存的内容。
static func _content_context_graph(manifest: Dictionary, seeds: Dictionary, rows: Dictionary) -> Dictionary:
	var contexts := {}
	var links := _screen_context_links(manifest)
	var inbound := {}
	var queue: Array = []
	for key in seeds:
		for label in seeds[key]:
			_enqueue_content_context(queue, contexts, key, label, seeds[key][label])
	for key in rows:
		queue.append({"key": key, "label": "", "context": {"map": {}, "name": ""}})
	var cursor := 0
	var map_cache := {}
	while cursor < queue.size():
		var visit: Dictionary = queue[cursor]
		cursor += 1
		var key: String = visit.key
		if not links.has(key):
			var row: Dictionary = rows.get(key, {})
			links[key] = _content_links(manifest, row.fn_id, row.data, [], true) if not row.is_empty() else []
			for link in links[key]:
				inbound[_content_key(link.fn, link.cid)] = true
		for link in links[key]:
			var context: Dictionary = visit.context
			var origin := str(context.get("origin", visit.label))
			var label: String = visit.label
			match str(link.get("map_context", "")):
				"inherit":
					if context.map.is_empty():
						continue
				"paired":
					var map_key := str(link.get("map_key", ""))
					if map_key == "":
						continue
					if context.map.is_empty() or not RefFields.map_key_local(map_key, context.name,
							str(context.map.get("meta", {}).get("code", ""))):
						if not map_cache.has(map_key):
							var resolved := ReferenceIndex.resolve_map(manifest, map_key)
							map_cache[map_key] = MapStore.read(manifest, str(resolved.key)) if resolved.status == "ok" else {}
						var target: Dictionary = map_cache[map_key]
						if target.is_empty():
							continue
						var target_name := str(target.get("meta", {}).get("name", map_key))
						label = target_name if origin == "" or origin == target_name else "%s → 地图 %s" % [origin, target_name]
						context = {"map": target, "name": target_name, "origin": origin}
				_:
					continue
			_enqueue_content_context(queue, contexts, _content_key(link.fn, link.cid), label, context)
	return {"contexts": contexts, "inbound": inbound}

static func _enqueue_content_context(queue: Array, contexts: Dictionary, key: String,
		label: String, context: Dictionary) -> void:
	if not contexts.has(key):
		contexts[key] = {}
	if contexts[key].has(label):
		return
	contexts[key][label] = context
	queue.append({"key": key, "label": label, "context": context})

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
		prefix: String, out: Array, findings: Array, step_index: int, depth := 0, root_field := "") -> void:
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
		var field := id if root_field == "" else root_field
		if fd.get("type") == "array" and fd.get("of") == "condition":
			var first := findings.size()
			_check_condition_rows(manifest, fd, value, path, findings)
			for i in range(first, findings.size()):
				findings[i].merge({"field": field, "step_index": step_index})
		for scope in RefFields.nested_scopes(manifest, fd, value):
			var subpath := path + "#%d." % int(scope.path[0])
			if scope.path.size() == 2:
				subpath += "fields."
			_collect_content_links(manifest, scope.decls, scope.values, source_fn, subpath, out, findings, step_index, depth + 1, field)
		var ordered := RefFields.is_ordered_choice(fd)
		var entries := _as_list(value)
		if desc.kind == "flow_target":
			if desc.many and not _empty_reference_value(value) and not value is Array:
				findings.append({"path": path, "field": field, "step_index": step_index,
					"message": "流程目标列表必须是数组"})
				continue
			var targets := entries if desc.many else [value]
			for i in targets.size():
				var target = targets[i]
				var at := "%s[%d]" % [path, i] if desc.many else path
				if not _empty_reference_value(target) and not StartupTargets.destination_available(manifest, fd, target):
					findings.append({"path": at, "field": field, "step_index": step_index,
						"message": _flow_target_message(target)})
				if FlowTarget.kind(target) == "content":
					out.append(_content_link(target.function, target.content, at, field, step_index, fd, decls, values))
				elif FlowTarget.kind(target) == "view" and fd.get("viewMapContext") == "inherit":
					out.append({"fn": "@view", "cid": target.view, "map_context": "inherit"})
			continue
		if desc.kind == "view":
			var views := ReferenceIndex.view_ids(manifest)
			for i in entries.size():
				var entry = entries[i]
				if not _empty_reference_value(entry) and not views.has(entry):
					findings.append({"path": "%s#%d" % [path, i] if ordered else path, "field": field, "step_index": step_index,
						"message": "引用的参考视图不存在：" + str(entry)})
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
				out.append(_content_link(want_fn, cid, "%s#%d" % [path, i] if ordered else path,
					field, step_index, fd, decls, values))

static func _content_link(fn: String, cid: String, path: String, field: String, step_index: int,
		decl: Dictionary, siblings: Array, values: Dictionary) -> Dictionary:
	return {"fn": fn, "cid": cid, "path": path, "field": field, "step_index": step_index,
		"map_context": decl.get("contentMapContext", ""), "map_key": RefFields.effective_map_value(decl, siblings, values, "code")}

static func _check_condition_rows(manifest: Dictionary, fd: Dictionary, rows: Variant,
		path: String, findings: Array) -> void:
	if not rows is Array:
		findings.append({"path": path, "message": "条件组必须是数组"})
		return
	for i in rows.size():
		var row = rows[i]
		var why := ""
		if not row is Dictionary or ConditionDecls.row_schema(manifest, fd, row).is_empty():
			why = "条件未选择、未声明或不在本组白名单"
		elif not row.get("fields") is Dictionary:
			why = "条件参数必须是对象"
		elif row.has("negate") and not row.negate is bool:
			why = "条件取反必须是布尔值"
		if why != "":
			findings.append({"path": path + "#%d" % i, "message": why})

## 资产使用统计（C3）：与引用自检同一批读盘结果（MapStore.read_all），
## 当前图可用画布内存覆盖（磁盘可能是旧的）。返回
## {by_map: {地图名: [{id,x,y}]}, unreadable: [图名], incomplete: bool}。
## unreadable 非空 = 统计范围不完整，呈现层必须显形（不能假装「没有引用」）。
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

## R15：资产在内容文件里的引用字段（asset_ref / source=asset: 声明，值 = 资产 id）。
## 返回 [{kind, id, field}]，与 content_inbound_refs 同形；含 steps 段。
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

## 按声明定位嵌套引用；普通字符串即使同名也不参与。
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

## Ignore outgoing references from the view being removed along with its own layout.
static func view_inbound_refs(manifest: Dictionary, id: String, staged: Array,
		live_map := {}, live_name := "") -> Dictionary:
	var refs: Array[String] = []
	if manifest.get("startup", {}).get("target", {}) == {"view": id}:
		refs.append("正式启动入口")
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

## R15：草稿里的资产使用（快照实例的 asset 键 + 待提交内容载荷的字段值）。
## 返回引用它的草稿键数组；读不出的草稿按「有使用」保守处理。
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

## 地图属性以字段 id 寻址；内容以字段码寻址。自动清理只支持顶层摆放物属性。
static func _ref_checks(data: Dictionary, manifest: Dictionary, map_name: String, targets := {}) -> Array:
	var out: Array = []
	var views := ReferenceIndex.view_ids(manifest)
	for ref in _map_property_refs(manifest, data, ["view", "flow_target"]):
		var message := ""
		if ref.kind == "view" and not views.has(ref.value):
			message = "引用的参考视图不存在：" + ref.value
		elif ref.kind == "flow_target" and not StartupTargets.destination_available(manifest, ref.decl, ref.value, targets):
			message = _flow_target_message(ref.value)
		if message != "":
			var jump := {"type": "map_flow", "map": map_name, "field": ref.field,
				"section": ref.map_section} if ref.has("map_section") \
				else {"type": "entity", "map": map_name, "code": ref.code, "prop": ref.field}
			out.append({"kind": "ref", "severity": "warning", "path": "%s · %s" % [map_name, ref.path],
				"message": message, "map": map_name, "jump": jump})
	var declarations := {}
	var objects = data.get("objects", [])
	if not objects is Array:
		return out
	for o in objects:
		if not o is Dictionary or not o.get("props", {}) is Dictionary:
			continue
		var aid := str(o.get("asset", ""))
		if not declarations.has(aid):
			declarations[aid] = _fields_of(manifest, aid)
		var code := str(o.get("code", ""))
		var label := "%s · %s(%s)." % [map_name, aid, code]
		for finding in _spatial_fields(manifest, declarations[aid], o.get("props", {}), data,
				map_name, false, targets):
			var issue := {"kind": "ref", "severity": "warning", "path": label + str(finding.path),
				"message": finding.message, "map": map_name,
				"jump": {"type": "entity", "map": map_name, "code": code, "prop": finding.prop}}
			if finding.fixable and finding.top_level and code != "":
				issue["fix"] = {"op": "clear_prop", "map": map_name, "code": code,
					"prop": finding.prop, "expect": _val_str(finding.value)}
			out.append(issue)
	return out

static func _flow_target_message(value: Variant) -> String:
	return "流程目标不可用：" + JSON.stringify(value)

static func _empty_reference_value(value: Variant) -> bool:
	return value == null or (value is String and value.is_empty()) \
		or (value is Dictionary and value.is_empty()) or (value is Array and value.is_empty())

static func _spatial_fields(manifest: Dictionary, decls: Array, values: Variant, source: Dictionary,
		map_name: String, coded: bool, targets := {}, prefix := "", depth := 0,
		root_prop := "") -> Array:
	var out: Array = []
	if not values is Dictionary or depth > 8:
		return out
	for field in decls:
		if not field is Dictionary:
			continue
		var id := str(field.get("id", ""))
		var key := str(field.get("code", "")) if coded else id
		if key == "":
			key = id
		var value = values.get(key)
		if _empty_reference_value(value):
			continue
		var path := prefix + id
		var prop := id if root_prop == "" else root_prop
		for scope in RefFields.nested_scopes(manifest, field, value):
			var sub := "%s#%d." % [path, scope.path[0]]
			if scope.path.size() == 2:
				sub += "fields."
			out.append_array(_spatial_fields(manifest, scope.decls, scope.values, source,
				map_name, coded or scope.path.size() == 2, targets, sub, depth + 1, prop))
		var desc := RefFields.describe(field)
		if desc.kind not in ["entity_inst", "port", "edge", "cell", "map", "layer"]:
			continue
		var paired := RefFields.paired_map_value(field, decls, values, "code" if coded else "id")
		var entries := _as_list(value) if desc.many or field.get("type") == "array" else [value]
		var ref_decl: Dictionary = RefFields.array_element_decl(field) if field.get("type") == "array" else field
		for i in entries.size():
			var entry = entries[i]
			if _empty_reference_value(entry):
				continue
			var problem := SpatialCheck.problem(manifest, desc.kind, source, map_name, entry, ref_decl, paired, targets)
			if not problem.is_empty() and str(problem.get("message", "")) != "":
				out.append({"path": path + ("#%d" % i if value is Array else ""),
					"prop": prop, "message": problem.message, "fixable": bool(problem.get("fixable", false)),
					"top_level": depth == 0 and not value is Array, "value": value})
	return out

## 清空比对用的值串：字典（edge_ref）走 JSON，保持键序稳定；其余走 str()。
static func _val_str(v) -> String:
	if v is Dictionary or v is Array:
		return JSON.stringify(v)
	return str(v)

## 清单校验条目包装（带 kind 标记；清单级问题不可跳转）。
static func _wrap(kind: String, e: Dictionary) -> Dictionary:
	return {
		"kind": kind, "severity": str(e.get("severity", "warning")),
		"path": str(e.get("path", "")), "message": str(e.get("message", "")),
		"map": "", "jump": {},
	}

## 地图校验条目包装（map = 地图名，可跳转开图）。
static func _wrap_map_issue(kind: String, e: Dictionary, map_name: String) -> Dictionary:
	return {
		"kind": kind, "severity": str(e.get("severity", "warning")),
		"path": str(map_name) + " · " + str(e.get("path", "")),
		"message": str(e.get("message", "")),
		"map": map_name,
		"jump": {"type": "map", "map": map_name},
	}

## C2：内容库批量引用扫描（一次读盘；浏览口径 = 缓存读取，破坏性检查仍走 inbound_content（R29））。
## 返回 {refs: {cid: {instances: {图名: [实例码]}, contents: [{kind,id,field}], n: 总入边数}}, unreadable: [源名]}。
## cids 为目标内容 ID；每个实例仅计一次，内容入边按声明路径计数；live_binds = [{cid, code}] 活体绑定由调用方从画布收集。
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
