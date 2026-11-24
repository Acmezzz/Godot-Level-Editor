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

const ManifestValidation := preload("res://src/project/manifest_validation.gd")
const MapStore := preload("res://src/map/map_store.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const AudioDecls := preload("res://src/content/audio_decl.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const TriggerDecls := preload("res://src/content/trigger_decl.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const K := preload("res://src/core/constants.gd")
const EdgeRef := preload("res://src/map/edge_ref.gd")
const CellGraphScript := preload("res://src/map/cell_graph.gd")
const ReferenceIndex := preload("res://src/project/reference_index.gd")
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
	for e in ManifestValidation.validate(manifest, str(manifest.get("_dir", ""))):
		out.append(_wrap("manifest", e))
	# 2. 地图校验（读盘全图）+ 顺带收集被实例引用的内容（孤立内容判定用）
	var used_content := {}
	var content_contexts := {}
	var binding_missing: Array = []
	var maps_dir := str(manifest.get("_maps_dir", ""))
	var graph_targets := {}
	var graph_index: Array = []
	var world_codes := {}
	var delta_problems := {}
	var world_chunks: Dictionary = manifest.worldLayout.chunks if manifest.has("worldLayout") \
		and WorldLayout.issues(manifest).is_empty() else {}
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
		var ent := _asset_by_id(manifest, str(aid))
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

## 按 id 取清单里的资产条目原件（无则空字典）。
## The view editor and project audit share these checks; only the audit asks for usage.
static func view_reference_issues(manifest: Dictionary, view_id := "", used_content := {}) -> Array:
	var out := []
	var contents := {}
	for ref in ReferenceIndex.view_content_refs(manifest):
		if view_id != "" and ref.view != view_id:
			continue
		var key := _content_key(ref.fn, ref.cid)
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
	var assets := AssetDecl.all(manifest)
	for ref in ReferenceIndex.view_module_refs(manifest):
		if view_id != "" and ref.view != view_id:
			continue
		var valid := true
		var label := ""
		match ref.kind:
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
				valid = ReferenceIndex.resolve_map(manifest, ref.value).status == "ok"
		if not valid:
			out.append(_view_issue(ref, "%s引用无法解析：%s" % [label, ref.value]))
	return out

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

static func _asset_by_id(manifest: Dictionary, aid: String) -> Dictionary:
	for a in (manifest.get("assets", []) as Array):
		if a is Dictionary and str((a as Dictionary).get("id", "")) == aid:
			return a
	return {}

## 收集全项目被实例绑定引用的内容（C12：按 `(功能 id, 内容 ID)` 索引，裸 ID 会跨功能误判）。
## 绑定里的 fn 是执行码，先解析成功能 id；解析不到 = 数据漂移，按 `?\u0001<cid>` 记。
## binding_missing 收「绑定指向的内容文件不存在」条目（后续统一进审计）。
static func _collect_used_content(data: Dictionary, manifest: Dictionary, used: Dictionary,
		binding_missing: Array, map_name: String) -> void:
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
	var graph := _content_context_graph(manifest, contexts, rows, {})
	for key in rows:
		var row: Dictionary = rows[key]
		if str(row.data.get("scope", "")) != "project" and not used.has(key) and not graph.inbound.has(key):
			out.append({"kind": "content", "severity": "warning", "path": "%s/%s" % [row.fn_id, row.cid],
				"message": "孤立内容：没有实例绑定或内容入边（可能是复用库，确认后可删）",
				"map": "", "jump": {}})
		out.append_array(_contextual_content_checks(manifest, row.fn_id, row.cid, row.data,
			graph.contexts.get(key, {}), {}))
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
		current_map := "", current_codes: Array = []) -> Dictionary:
	var by_map := {}
	var bad: Array = []
	# R29：删除前引用图驱动破坏性动作，读磁盘实际内容（不走浏览缓存）
	var maps := MapStore.read_all_fresh(manifest, bad)
	var want_code := FunctionDecls.fn_code(manifest, fn_id)
	# V4 P0-4：当前图不能整张跳过。画布上的活体绑定可能已被解除，而磁盘正式文件里
	# 仍有绑定——永久删除后放弃地图改动，正式图就会恢复成悬空引用。因此当前图的
	# 磁盘命中与活体命中取并集。
	for map_name in maps:
		var is_current := current_map != "" and str(map_name) == current_map
		var rows: Array = []
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
				rows.append(str((obj as Dictionary).get("code", "")))
				break
		if is_current:
			# 活体绑定也并入（磁盘是旧的：未保存的新绑定同样必须在报告里）
			for c in current_codes:
				if str(c) != "" and not rows.has(str(c)):
					rows.append(str(c))
		if not rows.is_empty():
			by_map[str(map_name)] = rows
	# 新建未保存的图不在磁盘列表里：活体命中仍要计入（否则删除检查看不到它）
	if current_map != "" and not by_map.has(current_map):
		var lone: Array = []
		for c in current_codes:
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
		findings: Array = []) -> Array:
	var out: Array = []
	for section in _content_sections(manifest, source_fn, data):
		_collect_content_links(manifest, section.decls, section.values, source_fn, section.prefix, out, findings, section.step_index)
	return out

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
	var objects = data.get("objects", [])
	if not objects is Array:
		return
	for obj in objects:
		if not obj is Dictionary or not obj.get("functions", []) is Array:
			continue
		for binding in obj.get("functions", []):
			if not binding is Dictionary:
				continue
			var fn := FunctionDecls.fn_id_of(manifest, str(binding.get("fn", "")))
			var cid := str(binding.get("content", ""))
			if fn == "" or cid == "":
				continue
			var key := _content_key(fn, cid)
			if not contexts.has(key):
				contexts[key] = {}
			contexts[key][label if label != "" else name] = {"map": data, "name": name}

static func _contextual_content_checks(manifest: Dictionary, fn: String, cid: String,
		data: Dictionary, contexts: Dictionary, overrides: Dictionary, prefix := "", probe := Callable()) -> Array:
	var out: Array = []
	var sources := contexts if not contexts.is_empty() else {"": {"map": {}, "name": ""}}
	for section in _content_sections(manifest, fn, data):
		for label in sources:
			var context: Dictionary = sources[label]
			for issue in _spatial_fields(manifest, section.decls, section.values, context.map,
					context.name, overrides, true, section.prefix, 0, "", probe):
				var path := prefix + "%s/%s.%s" % [fn, cid, issue.path]
				if label != "" and label != context.name:
					path += " · " + str(label)
				elif label != "":
					path += " · 地图 " + str(label)
				out.append({"kind": "content", "severity": "warning", "path": path,
					"message": issue.message, "map": context.name,
					"jump": _content_jump(fn, cid, issue.prop, context.name, section.step_index) if prefix == "" else {}})
	return out

## 传播状态由 (功能, 内容, 入口, 当前地图) 唯一确定。分支只传地图，不替游戏计算条件；
## 循环与汇合都不会反复扫描。rows 是本次评估可见的内容版本，lookup 只用于按需读取副本依赖。
static func _content_context_graph(manifest: Dictionary, seeds: Dictionary, rows: Dictionary,
		overrides: Dictionary, lookup := Callable(), include_standalone := true,
		standalone_keys := []) -> Dictionary:
	var contexts := {}
	var links := {}
	var inbound := {}
	var queue: Array = []
	for key in seeds:
		for label in seeds[key]:
			_enqueue_content_context(queue, contexts, key, label, seeds[key][label])
	for key in rows.keys() if include_standalone else standalone_keys:
		queue.append({"key": key, "label": "", "context": {"map": {}, "name": ""}})
	var cursor := 0
	var map_cache := overrides.duplicate()
	while cursor < queue.size():
		var visit: Dictionary = queue[cursor]
		cursor += 1
		var key: String = visit.key
		if not links.has(key):
			if not rows.has(key) and lookup.is_valid():
				var parts := key.split("\u0001", true, 1)
				rows[key] = {"fn_id": parts[0], "cid": parts[1], "data": lookup.call(parts[0], parts[1])}
			var row: Dictionary = rows.get(key, {})
			links[key] = _content_links(manifest, row.fn_id, row.data) if not row.is_empty() else []
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

## 对同一批磁盘来源比较两种地图状态。其他草稿保留自己的本图上下文，
## 但其指向正在编辑地图的跨图引用按候选状态解析。
static func map_change_reference_impacts(manifest: Dictionary, name: String, before: Dictionary,
		after: Dictionary, staged: Array = []) -> Dictionary:
	var project := _reference_sources(manifest)
	var aliases: Array = []
	for key in [name, str(before.get("meta", {}).get("code", ""))]:
		var resolved := ReferenceIndex.resolve_indexed_map(project.index, key)
		if resolved.status == "ok" and resolved.key == name:
			aliases.append(key)
	var old := _map_change_issues(manifest, name, before, after, project.maps, project.targets, aliases, project.contents, project.drafts, staged)
	var next := _map_change_issues(manifest, name, after, after, project.maps, project.targets, aliases, project.contents, project.drafts, staged)
	return {"added": _new_reference_messages(old, next), "unreadable": project.unreadable}

static func retained_region_edge_refs(manifest: Dictionary, name: String, live: Dictionary,
		mapper: Callable, staged: Array) -> Dictionary:
	var project := _reference_sources(manifest)
	var code := str(live.meta.code)
	var probe := func(kind: String, value: Variant, source: Dictionary, source_name: String, paired: String) -> Dictionary:
		if kind != "edge" or not value is Dictionary:
			return {}
		var map_key := RefFields.object_map_key(value, paired)
		if map_key == "":
			if source_name != name or str(source.get("meta", {}).get("code", "")) != code:
				return {}
		elif not map_key in [name, code]:
			return {}
		var moved: Dictionary = mapper.call(value, "")
		if moved.is_empty() or moved.edge == value.get("edge"):
			return {}
		return {"message": "%s → %s" % [value.edge, moved.edge], "fixable": false}
	var issues := _map_change_issues(manifest, name, live, live, project.maps, project.targets,
		[name, code], project.contents, project.drafts, staged, probe)
	return {"retained": _new_reference_messages([], issues), "unreadable": project.unreadable}

static func _reference_sources(manifest: Dictionary) -> Dictionary:
	var unreadable: Array = []
	var maps := MapStore.read_all_fresh(manifest, unreadable)
	var index := MapStore.code_index(manifest)
	var targets := {}
	for source in maps:
		for key in [source, str(maps[source].get("meta", {}).get("code", ""))]:
			var resolved := ReferenceIndex.resolve_indexed_map(index, key)
			if resolved.status == "ok" and resolved.key == source:
				targets[key] = maps[source]
	var drafts := {}
	var contents := {}
	for fn in ContentStore.declared_kinds(manifest):
		var bad: Array = []
		var rows := ContentStore.read_all(manifest, fn, bad)
		for cid in rows:
			contents[_content_key(fn, str(cid))] = {"fn_id": fn, "cid": cid, "data": rows[cid]}
		for item in bad:
			unreadable.append("内容 %s/%s" % [fn, str(item.get("name", ""))])
	for key in MapStore.Recovery.list_drafts(manifest):
		var draft := MapStore.Recovery.read_draft_key(manifest, str(key))
		if not draft.get("snapshot") is Dictionary or not draft.get("pendingContents", []) is Array \
				or not draft.snapshot.get("meta") is Dictionary or not draft.snapshot.get("objects", []) is Array:
			unreadable.append("草稿 " + str(key))
			continue
		drafts[key] = draft
	return {"index": index, "maps": maps, "targets": targets, "contents": contents,
		"drafts": drafts, "unreadable": unreadable}

## 检查真正要发布的副本与它的新内容。反事实基线恢复原格空间，副本身份
## 保持相同，因此不会把指回源图或其他图的引用算成副本拓扑问题。
static func projection_copy_impacts(manifest: Dictionary, targets: Array, source_grid: Dictionary) -> Dictionary:
	var copy := {}
	var name := ""
	var pending := {}
	for target in targets:
		if target.get("kind") == "map":
			copy = target.map_data
			name = str(target.id)
		elif target.get("kind") == "content":
			pending[_content_key(str(target.fn_id), str(target.id))] = {
				"fn_id": str(target.fn_id), "cid": str(target.id), "data": target.data}
	if copy.is_empty():
		return {"added": [], "unreadable": []}
	var baseline := copy.duplicate()
	baseline.meta = copy.meta.duplicate()
	for key in ["gridProjection", "gridBasis", "gridTopology"]:
		baseline.meta.erase(key)
	baseline.meta.merge(source_grid, true)
	var old := _ref_checks(baseline, manifest, name)
	var next := _ref_checks(copy, manifest, name)
	var unreadable: Array = []
	var lookup := func(fn: String, cid: String) -> Dictionary:
		var read := ContentStore.read_ex(manifest, fn, cid)
		if read.status != "ok":
			unreadable.append("%s/%s" % [fn, cid])
			return {}
		return read.data
	for state in [baseline, copy]:
		var seeds := {}
		_collect_spatial_contexts(manifest, state, name, seeds)
		var overrides := {name: state, str(copy.meta.code): state}
		var graph := _content_context_graph(manifest, seeds, pending, overrides, lookup, false)
		var issues: Array = old if is_same(state, baseline) else next
		for key in graph.contexts:
			var row: Dictionary = pending.get(key, {})
			if not row.is_empty():
				issues.append_array(_contextual_content_checks(manifest, row.fn_id, row.cid, row.data,
					graph.contexts[key], overrides))
	return {"added": _new_reference_messages(old, next), "unreadable": unreadable}

static func _new_reference_messages(old: Array, next: Array) -> Array[String]:
	var prior := {}
	for issue in old:
		prior[[issue.path, issue.message]] = true
	var added: Array[String] = []
	for issue in next:
		var identity := [issue.path, issue.message]
		if not prior.has(identity):
			prior[identity] = true
			added.append("%s：%s" % [issue.path, issue.message])
	return added

static func _map_change_issues(manifest: Dictionary, name: String, target: Dictionary, retained: Dictionary,
		maps: Dictionary, targets: Dictionary, aliases: Array, contents: Dictionary, drafts: Dictionary,
		staged: Array, probe := Callable()) -> Array:
	var out: Array = []
	var overrides := targets.duplicate()
	for alias in aliases:
		overrides[alias] = target
	var sources := maps.duplicate()
	sources[name] = target
	var contexts := {}
	for source in sources:
		if not probe.is_valid() or source != name:
			out.append_array(_ref_checks(sources[source], manifest, source, overrides, probe))
		var bindings: Dictionary = retained if source == name else sources[source]
		# 只比较操作后仍绑定内容的地图，本图上下文仍用前后各自的几何与实例。
		_collect_spatial_contexts(manifest, bindings, source, contexts)
	for context_key in contexts:
		if contexts[context_key].has(name):
			contexts[context_key][name].map = target
	var graph := _content_context_graph(manifest, contexts, contents, overrides)
	for key in contents:
		var row: Dictionary = contents[key]
		out.append_array(_contextual_content_checks(manifest, row.fn_id, row.cid, row.data,
			graph.contexts.get(key, {}), overrides, "", probe))
	for key in drafts:
		var draft: Dictionary = drafts[key]
		var snapshot: Dictionary = draft.snapshot
		var draft_name := str(draft.get("mapName", snapshot.meta.get("name", "")))
		var label := "草稿 " + str(key)
		for issue in _ref_checks(snapshot, manifest, draft_name, overrides, probe):
			issue.path = label + " · " + str(issue.path)
			out.append(issue)
		var draft_contexts := {}
		_collect_spatial_contexts(manifest, snapshot, draft_name, draft_contexts, label)
		_append_pending_spatial(manifest, draft.get("pendingContents", []), draft_contexts,
			contents, overrides, out, label + " · ", {}, probe)
	var staged_contexts := {}
	for key in contexts:
		if contexts[key].has(name):
			staged_contexts[key] = {name: contexts[key][name]}
	if not staged.is_empty():
		_append_pending_spatial(manifest, staged, staged_contexts, contents, overrides, out,
			"当前暂存 · ", graph.contexts, probe)
	return out

static func _append_pending_spatial(manifest: Dictionary, rows: Array, contexts: Dictionary,
		contents: Dictionary, overrides: Dictionary, out: Array, label: String,
		already_checked := {}, probe := Callable()) -> void:
	var overlay := contents.duplicate()
	var pending := {}
	for row in rows:
		if not row is Dictionary or not row.get("data") is Dictionary:
			continue
		var fn := str(row.get("fn_id", row.get("fn", "")))
		var cid := str(row.get("cid", row.get("id", "")))
		if fn == "" or cid == "":
			continue
		var key := _content_key(fn, cid)
		pending[key] = row
		overlay[key] = {"fn_id": fn, "cid": cid, "data": row.data}
	var graph := _content_context_graph(manifest, contexts, overlay, overrides, Callable(), false, pending.keys())
	for key in pending:
		if not graph.contexts.has(key):
			graph.contexts[key] = {}
	for key in graph.contexts:
		var row: Dictionary = overlay.get(key, {})
		if row.is_empty():
			continue
		var contexts_to_check: Dictionary = graph.contexts[key]
		if not pending.has(key):
			contexts_to_check = contexts_to_check.duplicate()
			for known in already_checked.get(key, {}):
				contexts_to_check.erase(known)
			if contexts_to_check.is_empty():
				continue
		out.append_array(_contextual_content_checks(manifest, row.fn_id, row.cid, row.data,
			contexts_to_check, overrides, label, probe))

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
		if not values.has(key):
			continue
		var value = values[key]
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
		var desc := RefFields.describe(fd)
		if desc.kind == "view":
			var views := ReferenceIndex.view_ids(manifest)
			for entry in _as_list(value):
				if not _empty_reference_value(entry) and not views.has(entry):
					findings.append({"path": path, "field": field, "step_index": step_index,
						"message": "引用的参考视图不存在：" + str(entry)})
			continue
		if desc.kind != "content":
			continue
		var want_fn := str(desc.get("filter", {}).get("fn", ""))
		if want_fn == "":
			want_fn = source_fn
		var distinct := {}
		for cid in _as_list(value):
			if cid is String and cid != "" and not distinct.has(cid):
				distinct[cid] = true
				out.append({"fn": want_fn, "cid": cid, "path": path, "field": field, "step_index": step_index,
					"map_context": fd.get("contentMapContext", ""),
					"map_key": RefFields.paired_map_value(fd, decls, values)})

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
		if desc.kind != kind:
			continue
		for v in _as_list(vals[key]):
			if v is String and v == target:
				out.append(str((fd as Dictionary).get("id", key)))
				break
	return out

## Ignore outgoing references from the view being removed along with its own layout.
static func view_inbound_refs(manifest: Dictionary, id: String, staged: Array) -> Dictionary:
	var refs: Array[String] = []
	var bad: Array = []
	for ref in ReferenceIndex.view_module_refs(manifest):
		if ref.kind == "view" and ref.value == id and ref.view != id:
			refs.append("%s · %s" % [ref.view, ref.path])
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
		for row in rows:
			if not row is Dictionary or not row.get("data") is Dictionary:
				bad.append({"name": "草稿 " + str(key)})
				continue
			var kind := str(row.get("fn_id", ""))
			inspect.call(kind, "草稿 %s · %s" % [key, row.get("cid", row.get("id", kind))], row.data)
	return {"refs": refs, "bad": bad}

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
static func _ref_checks(data: Dictionary, manifest: Dictionary, map_name: String, overrides := {}, probe := Callable()) -> Array:
	var out: Array = []
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
				map_name, overrides, false, "", 0, "", probe):
			var issue := {"kind": "ref", "severity": "warning", "path": label + str(finding.path),
				"message": finding.message, "map": map_name,
				"jump": {"type": "entity", "map": map_name, "code": code, "prop": finding.prop}}
			if finding.fixable and finding.top_level and code != "":
				issue["fix"] = {"op": "clear_prop", "map": map_name, "code": code,
					"prop": finding.prop, "expect": _val_str(finding.value)}
			out.append(issue)
	return out

static func _empty_reference_value(value: Variant) -> bool:
	return value == null or (value is String and value.is_empty()) \
		or (value is Dictionary and value.is_empty()) or (value is Array and value.is_empty())

static func _spatial_fields(manifest: Dictionary, decls: Array, values: Variant, source: Dictionary,
		map_name: String, overrides: Dictionary, coded: bool, prefix := "", depth := 0,
		root_prop := "", probe := Callable()) -> Array:
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
				map_name, overrides, coded or scope.path.size() == 2, sub, depth + 1, prop, probe))
		var desc := RefFields.describe(field)
		if desc.kind not in ["entity_inst", "port", "edge", "cell", "map", "layer"]:
			continue
		var paired := RefFields.paired_map_value(field, decls, values, "code" if coded else "id")
		var entries := _as_list(value) if desc.many or field.get("type") == "array" else [value]
		for i in entries.size():
			var entry = entries[i]
			if _empty_reference_value(entry):
				continue
			var problem: Dictionary = probe.call(desc.kind, entry, source, map_name, paired) if probe.is_valid() \
				else _spatial_problem(manifest, desc.kind, source, map_name, entry, field, paired, overrides)
			if not problem.is_empty() and str(problem.get("message", "")) != "":
				out.append({"path": path + ("#%d" % i if value is Array else ""),
					"prop": prop, "message": problem.message, "fixable": bool(problem.get("fixable", false)),
					"top_level": depth == 0 and not value is Array, "value": value})
	return out

static func _spatial_problem(manifest: Dictionary, kind: String, source: Dictionary, map_name: String,
		value: Variant, field: Dictionary, paired: String, overrides: Dictionary) -> Dictionary:
	var local_code := str(source.get("meta", {}).get("code", ""))
	match kind:
		"entity_inst", "layer":
			if not value is String:
				return {"message": ("图层引用必须是图层 ID 字符串" if kind == "layer" else "实例引用必须是实例码字符串"), "fixable": false}
			var target := source
			if not RefFields.map_key_local(paired, map_name, local_code):
				if overrides.has(paired):
					target = overrides[paired]
				else:
					var resolved := ReferenceIndex.resolve_map(manifest, paired)
					target = MapStore.read(manifest, str(resolved.key)) if resolved.status == "ok" else {}
			if target.is_empty():
				return {}
			var where := "目标图 %s" % paired if paired != "" else "本图"
			if kind == "layer":
				for layer in target.get("meta", {}).get("layers", []):
					if layer is Dictionary and layer.get("id") == value:
						return {}
				# 保留 ID，作者可重新选择坐标空间；不要把原路径默认为别的空间。
				return {"message": "%s不存在图层：%s" % [where, value], "fixable": false}
			for row in target.get("objects", []):
				if row is Dictionary and row.get("code", "") == value:
					return {}
			return {"message": "引用的实例码在%s不存在: %s" % [where, str(value)], "fixable": true}
		"port":
			if source.is_empty() and paired == "" and value is Dictionary \
					and value.get("map", "") is String and str(value.get("map", "")) == "":
				return {}
			return _port_ref_problem(manifest, source, map_name, value, field, paired, overrides)
		"edge":
			if source.is_empty() and paired == "" and value is Dictionary \
					and value.get("map", "") is String and str(value.get("map", "")) == "":
				return {}
			return _edge_ref_problem(manifest, source, value, overrides, map_name, paired)
		"cell":
			return _cell_ref_problem(manifest, source, str(value), paired, field, overrides, map_name)
		"map":
			if manifest.get("_maps_dir", "") != "" and not overrides.has(str(value)) \
					and not RefFields.map_key_local(str(value), map_name, local_code) \
					and ReferenceIndex.resolve_map(manifest, str(value)).status not in ["ok", "ambiguous", "unreadable"]:
				return {"message": "目标地图不存在: %s" % str(value), "fixable": true}
	return {}

static func _port_ref_problem(manifest: Dictionary, data: Dictionary, map_name: String,
		value: Variant, field: Dictionary, paired_map: String, overrides := {}) -> Dictionary:
	if value is Dictionary and value.is_empty():
		return {}
	if not value is Dictionary or not value.get("map") is String \
			or not value.get("inst") is String or not value.get("port") is String:
		return {"message": "端口引用需要 {map, inst, port} 字符串字段", "fixable": true}
	var local_code := str(data.get("meta", {}).get("code", ""))
	var target_key := RefFields.object_map_key(value, paired_map)
	var target := data
	if RefFields.map_key_local(target_key, map_name, local_code):
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
				return {"message": "端口的目标地图不存在：" + target_key, "fixable": true}
			_:
				return {}
	var types := str(field.get("of", "")).split(",", false)
	for obj in target.get("objects", []):
		if not obj is Dictionary or str(obj.get("code", "")) != value.inst:
			continue
		var asset := AssetDecl.by_id(manifest, str(obj.get("asset", "")))
		for port in RefFields.ports_of(asset):
			if port is Dictionary and port.get("id") == value.port:
				if types.is_empty() or types.has(str(port.get("type", ""))):
					return {}
				return {"message": "目标端口类型与字段声明不匹配：" + str(value.port), "fixable": true}
		return {"message": "实例没有对应的端口：" + str(value.port), "fixable": true}
	return {"message": "目标端口的实例不存在：" + str(value.inst), "fixable": true}

## edge_ref 悬空判定（§7.4）：边身份由格拓扑推导，因此只验「目标图存在 + 两格确实相邻 + cell 自洽」。
## 目标图本图/跨图取法与 map_ref 一致；图读不出来时比对双方拓扑会误报，故只按「读不到不判悬空」放行。
## 返回 {message, fixable}：fixable=false 表示判定范围不完整（目标图歧义/读不出），不可自动清除。
static func _edge_ref_problem(manifest: Dictionary, data: Dictionary, val, overrides: Dictionary,
		map_name: String, paired: String) -> Dictionary:
	if not (val is Dictionary):
		return {"message": "格边引用值不是 {map, cell, edge} 字典", "fixable": true}
	var v: Dictionary = val
	if not v.get("edge") is String or not v.get("map", "") is String:
		return {"message": "格边引用的 map 和 edge 必须是字符串", "fixable": true}
	var e_code := str(v.get("edge", ""))
	var ends := EdgeRef.parse_edge(e_code)
	if ends.size() != 2:
		return {"message": "格边引用格式不合法: %s" % e_code, "fixable": true}
	var e_map := RefFields.object_map_key(v, paired)
	var tgt_meta: Dictionary = data.get("meta", {}) if data.get("meta", {}) is Dictionary else {}
	if RefFields.map_key_local(e_map, map_name, str(tgt_meta.get("code", ""))):
		pass
	elif overrides.has(e_map):
		tgt_meta = overrides[e_map].meta
	else:
		var resolved := ReferenceIndex.resolve_map(manifest, e_map)
		var rstat := str(resolved.status)
		if rstat == "ambiguous":
			# 一码多图：不知道指的是哪张图，比对邻接没有意义（由码冲突条目单列）
			return {"message": "", "fixable": false}
		if rstat == "unreadable":
			# §4.2-4：目标图在但读不出来——拓扑不可比，同样不可自动清（不报、也不给清空项）
			return {"message": "", "fixable": false}
		if rstat != "ok":
			return {"message": "格边引用的目标地图不存在: %s" % e_map, "fixable": true}
		var td: Dictionary = MapStore.read(manifest, str(resolved.key))
		if td.is_empty():
			# 目标图存在但读不出来：拓扑不可比，不判悬空
			return {"message": "", "fixable": false}
		tgt_meta = td.get("meta", {}) if td.get("meta", {}) is Dictionary else {}
	var g: GridSpace = GridSpace.resolve(tgt_meta, manifest).get("grid") as GridSpace
	var ea := Vector2i(int(ends[0][0]), int(ends[0][1]))
	var eb := Vector2i(int(ends[1][0]), int(ends[1][1]))
	var w := int(tgt_meta.get("w", K.DEFAULT_MAP_W))
	var h := int(tgt_meta.get("h", K.DEFAULT_MAP_H))
	if not g.cell_in_map(ea, w, h) or not g.cell_in_map(eb, w, h):
		return {"message": "格边引用超出目标地图范围: %s" % e_code, "fixable": true}
	if EdgeRef.segment(g, ea, eb, w, h).is_empty():
		return {"message": "格边引用的两格在地图里不相邻: %s" % e_code, "fixable": true}
	var cell = v.get("cell", null)
	if not cell is Array or cell.size() != 2 or cell[0] != ea.x or cell[1] != ea.y:
		return {"message": "格边引用的 cell 与 edge 不自洽: %s" % e_code, "fixable": true}
	return {"message": "", "fixable": false}

## cell: 引用悬空判定（§4.2-2）：有限格图的合法性**只由声明决定**——cell_id 必须在目标图
## meta.cellGraph.cells 里，不按整数格坐标或邻接推导（格图是游戏侧契约，可任意多边形）。
## 目标图解析歧义/读不出、或目标图根本没有格图声明 = 判定范围不完整，只报诊断不给清空项。
## 返回 {message, fixable}。
static func _cell_ref_problem(manifest: Dictionary, data: Dictionary, cid: String,
		paired: String, decl: Dictionary, overrides: Dictionary, map_name: String) -> Dictionary:
	var tgt_meta: Dictionary = data.get("meta", {})
	if not RefFields.map_key_local(paired, map_name, str(tgt_meta.get("code", ""))):
		if overrides.has(paired):
			tgt_meta = overrides[paired].get("meta", {})
		else:
			var resolved := ReferenceIndex.resolve_map(manifest, paired)
			if resolved.status in ["ambiguous", "unreadable"]:
				return {}
			if resolved.status != "ok":
				return {"message": "格图引用的目标地图不存在: %s" % paired, "fixable": true}
			tgt_meta = MapStore.read(manifest, str(resolved.key)).get("meta", {})
	var graph: Dictionary = tgt_meta.get("cellGraph", {}) if tgt_meta.get("cellGraph", {}) is Dictionary else {}
	var ids: Array = CellGraphScript.cell_ids(graph)
	if ids.is_empty():
		# 没有格图声明：无法判定这枚 cell_id 是否合法（不是「确证悬空」），不产清空项
		return {"message": "", "fixable": false}
	if not ids.has(cid):
		return {"message": "引用的格 id 不在目标图的格图里: %s" % cid, "fixable": true}
	var space = CellGraphScript.cell_source_space(decl)
	if space != null and not CellGraphScript.cell_options(graph, space).any(func(o): return o.v == cid):
		return {"message": "引用的格不在声明的空间 %s: %s" % [space, cid], "fixable": false}
	return {"message": "", "fixable": false}

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
