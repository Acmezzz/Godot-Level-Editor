extends RefCounted
## 全项目一致性审计：清单校验 + 地图校验 + 引用悬空 + 内容文件（码漂移/损坏 JSON/孤立内容），
## 统一产出 {kind, severity, path, message, map, jump} 条目。
## 纯字典/文件扫描，不碰场景树——UI（问题抽屉/自检入口）只是它的呈现层。

const ManifestValidation := preload("res://src/project/manifest_validation.gd")
const MapStore := preload("res://src/map/map_store.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const ConditionDecls := preload("res://src/content/condition_decl.gd")
const StepDecls := preload("res://src/content/step_decl.gd")
const TriggerDecls := preload("res://src/content/trigger_decl.gd")
const RefFields := preload("res://src/content/ref_fields.gd")

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
	var binding_missing: Array = []
	var maps_dir := str(manifest.get("_maps_dir", ""))
	if maps_dir != "":
		for name in MapStore.list_maps(manifest):
			var r: Dictionary = MapStore.read_path(maps_dir.path_join(name + ".json"), manifest)
			for e in (r.get("warnings", []) as Array):
				out.append(_wrap_map_issue("map", e, str(name)))
			for e in (r.get("errors", []) as Array):
				out.append(_wrap_map_issue("map", e, str(name)))
			if bool(r.get("ok", false)):
				var d: Dictionary = r.get("data", {}) as Dictionary
				out.append_array(_ref_checks(d, manifest, str(name)))
				out.append_array(_binding_checks(d, manifest, str(name)))
				_collect_used_content(d, manifest, used_content, binding_missing, str(name))
			else:
				meta_out["incomplete"] = true
				(meta_out["unreadable_maps"] as Array).append(str(name))
	# 绑定目标内容文件缺失（C12）：绑定是引用入口，文件没了必须显形
	out.append_array(binding_missing)
	# 3. 内容文件：损坏 JSON / function 码漂移 / 孤立内容
	out.append_array(_content_checks(manifest, used_content))
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
static func _content_checks(manifest: Dictionary, used: Dictionary) -> Array:
	var out: Array = []
	var root := ContentStore.root_dir(manifest)
	if root == "" or not DirAccess.dir_exists_absolute(root):
		return out
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
			if not used.has(_content_key(kind, cid)):
				out.append({
					"kind": "content", "severity": "warning",
					"path": "%s/%s" % [kind, cid],
					"message": "孤立内容：没有任何实例引用（可能是复用库，确认后可删）",
					"map": "", "jump": {},
				})
			# C12：内容自身的引用范围——步骤码、条件字段、内容池字段
			out.append_array(_content_ref_checks(manifest, kind, str(cid), data))
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
						"map": "", "jump": {}})
	# 2) 字段里的内容池引用（功能字段 + 条件字段，只认声明为 content 引用的键）
	var decls: Array = []
	decls.append_array(FunctionDecls.function_fields(manifest, kind))
	var conds = FunctionDecls.function_decl(manifest, kind).get("conditions", null)
	for cond_id in (conds as Array) if conds is Array else []:
		var cd := ConditionDecls.condition_decl(manifest, str(cond_id))
		if cd.get("fields", []) is Array:
			decls.append_array(cd.get("fields", []) as Array)
	var values = data.get("fields", null)
	if values is Dictionary:
		out.append_array(_content_field_refs(manifest, label, decls, values))
	# 3) 步骤字段里的内容池引用：按每步自己的字段声明查（步骤字段键 = 字段码）
	if steps is Array:
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
				out.append_array(_content_field_refs(manifest, "%s.steps[%d]" % [label, i],
					sdecls as Array, sfields))
	return out

## 一组字段声明 + 值里的 content 类引用是否落在对应功能内容目录内（多选逐项）。
static func _content_field_refs(manifest: Dictionary, label: String, decls: Array,
		values: Dictionary) -> Array:
	var out: Array = []
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
		var want_fn := str((desc.get("filter", {}) as Dictionary).get("fn", ""))
		for v in _as_list(values[key]):
			if v == "" or ContentStore.is_valid_id(v) == false:
				continue
			if want_fn != "" and not ContentStore.list_ids(manifest, want_fn).has(v):
				out.append({"kind": "content", "severity": "warning", "path": "%s.%s" % [label, key],
					"message": "引用的内容不存在：%s/%s" % [want_fn, v],
					"map": "", "jump": {}})
	return out

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
		var have := {}
		for f in fns:
			if f is Dictionary:
				have[str((f as Dictionary).get("fn", ""))] = true
		# 1) 挂载缺失：类型声明了自带功能、实例没有对应绑定行
		for mt in FunctionDecls.entity_mounts(manifest, aid):
			var code := str((mt as Dictionary).get("code", ""))
			if code != "" and not have.has(code):
				out.append({
					"kind": "binding", "severity": "warning",
					"path": "%s · %s(%s).functions" % [map_name, aid, str(o.get("code", "?"))],
					"message": "挂载缺失：类型自带功能 %s 没有绑定（重开该图会自动补齐）" % \
						FunctionDecls.function_name(manifest, str((mt as Dictionary).get("id", ""))),
					"map": map_name,
					"jump": {"type": "entity", "map": map_name, "code": str(o.get("code", ""))},
				})
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
			if str(props.get(prop, "")) != expect:
				skipped += 1
				continue
			props.erase(prop)
			od["props"] = props
			changed = true
			erased += 1
	return {"changed": changed, "erased": erased, "skipped": skipped}

## 资产使用统计（C3）：与引用自检同一批读盘结果（MapStore.read_all），
## 当前图可用画布内存覆盖（磁盘可能是旧的）。返回
## {by_map: {地图名: [{id,x,y}]}, unreadable: [图名], incomplete: bool}。
## unreadable 非空 = 统计范围不完整，呈现层必须显形（不能假装「没有引用」）。
static func asset_usage(manifest: Dictionary, asset_id: String, current_map := "",
		current_rows: Array = []) -> Dictionary:
	var by_map := {}
	var bad: Array = []
	var maps := MapStore.read_all(manifest, bad)
	for map_name in maps:
		if current_map != "" and str(map_name) == current_map:
			continue   # 当前图以画布为准，下面统一补
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
		if not rows.is_empty():
			by_map[str(map_name)] = rows
	if current_map != "" and not current_rows.is_empty():
		by_map[current_map] = current_rows
	var unreadable: Array = []
	for b in bad:
		unreadable.append(str((b as Dictionary).get("name", "")))
	return {"by_map": by_map, "unreadable": unreadable, "incomplete": not unreadable.is_empty()}

## 引用悬空检查：objects[].props 里 entity_ref/map_ref 声明字段的值指向不存在对象 = 警告。
## C1：声明了 mapField 的 entity_ref 目标是**配对地图**里的实例（(地图码, 实例码)），
## 本图码集不参与判定；配对地图未填 = 取所属图。
static func _ref_checks(data: Dictionary, manifest: Dictionary, map_name: String) -> Array:
	var out: Array = []
	var map_codes := MapStore.code_map(manifest)
	# 本图实例码集合
	var codes := {}
	for e in (data.get("objects", []) as Array):
		if not (e is Dictionary):
			continue
		var oc := str((e as Dictionary).get("code", ""))
		if oc != "":
			codes[oc] = true
	# 实体类型声明的 entity_ref/map_ref 字段（值存 props，键 = 字段名）
	var refs := {}
	var all_fields := {}
	for a in AssetDecl.of_kind(manifest, "entity"):
		var ad: Dictionary = a
		var flds := []
		var fld_all := []
		for fd in (ad.get("fields", []) as Array):
			if not (fd is Dictionary):
				continue
			fld_all.append(fd)
			if str((fd as Dictionary).get("type", "")) in ["entity_ref", "map_ref"]:
				flds.append(fd)
		if not flds.is_empty():
			refs[str(ad.get("id", ""))] = flds
			all_fields[str(ad.get("id", ""))] = fld_all
	var maps_dir := str(manifest.get("_maps_dir", ""))
	for e in (data.get("objects", []) as Array):
		if not (e is Dictionary):
			continue
		var o: Dictionary = e
		var aid := str(o.get("asset", ""))
		if not refs.has(aid):
			continue
		var props: Dictionary = o.get("props", {}) if o.get("props", {}) is Dictionary else {}
		for fd in (refs[aid] as Array):
			var f: Dictionary = fd
			var key := str(f.get("id", ""))
			var val = props.get(key, null)
			if val == null or str(val) == "":
				continue   # 未填 = 合法状态
			var typ := str(f.get("type", ""))
			# map_ref 值 = 地图码（v7）：码表判定为主；图名兜底（老图兼容值）/ maps_dir 未配放行
			var map_key := str(val)
			var ok_target: bool = map_codes.has(map_key) \
				or (maps_dir == "" or FileAccess.file_exists(maps_dir.path_join(map_key + ".json")))
			# 配对地图（C1）：目标码必须在目标图的 objects 里；未配对 = 本图
			var target_codes := codes
			var target_map := ""
			var target_unknown := false
			if typ == "entity_ref":
				var pair := str(f.get("mapField", ""))
				if pair != "":
					var paired: Dictionary = {}
					for pf in (all_fields.get(aid, []) as Array):
						if pf is Dictionary and str((pf as Dictionary).get("id", "")) == pair:
							paired = pf
							break
					target_map = str(props.get(pair, "")) if not paired.is_empty() else ""
					# 配对地图未填 = 取所属图（C1）：本图码集就是目标域，不去猜磁盘上的图码
					if target_map != "":
						target_codes = _codes_of_map(manifest, target_map)
						# 目标图本身解析不出来 → 由 map_ref 字段报一条；这里不再逐引用重复报
						target_unknown = _map_name_of(manifest, target_map) == ""
			if typ == "entity_ref" and not target_unknown and not target_codes.has(str(val)):
				var where := ("目标图 %s" % target_map) if target_map != "" else "本图"
				out.append({
					"kind": "ref", "severity": "warning",
					"path": "%s · %s(%s).%s" % [map_name, aid, str(o.get("code", "?")), key],
					"message": "引用的实例码在%s不存在: %s" % [where, str(val)],
					"map": map_name,
					"jump": {"type": "entity", "map": map_name, "code": str(o.get("code", ""))},
					# expect = 报告时的坏值（D07）：清除前复验当前值仍相同才动手
					"fix": {"op": "clear_prop", "map": map_name, "code": str(o.get("code", "")),
						"prop": key, "expect": str(val)},
				})
			elif typ == "map_ref" and not ok_target:
				out.append({
					"kind": "ref", "severity": "warning",
					"path": "%s · %s(%s).%s" % [map_name, aid, str(o.get("code", "?")), key],
					"message": "目标地图不存在: %s" % str(val),
					"map": map_name,
					"jump": {"type": "entity", "map": map_name, "code": str(o.get("code", ""))},
					"fix": {"op": "clear_prop", "map": map_name, "code": str(o.get("code", "")),
						"prop": key, "expect": str(val)},
				})
	return out

## 目标地图键（地图码或图名）→ 该图实例码集合。读不到/未知键返回空集合（引用因此报悬空）。
static func _codes_of_map(manifest: Dictionary, map_key: String) -> Dictionary:
	var out := {}
	var name := _map_name_of(manifest, map_key)
	if name == "":
		return out
	var d: Dictionary = MapStore.read(manifest, name)
	for o in (d.get("objects", []) as Array):
		if o is Dictionary:
			var c := str((o as Dictionary).get("code", ""))
			if c != "":
				out[c] = true
	return out

## 地图键（图名或地图码）→ 图名；未知/空返回 ""。码重复时拒绝猜测（code_map 已按重复剔除）。
static func _map_name_of(manifest: Dictionary, map_key: String) -> String:
	if map_key == "":
		return ""
	if MapStore.list_maps(manifest).has(map_key):
		return map_key
	return str(MapStore.code_map(manifest).get(map_key, ""))

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
