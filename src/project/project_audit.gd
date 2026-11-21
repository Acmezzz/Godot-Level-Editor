extends RefCounted
## 全项目一致性审计：清单校验 + 地图校验 + 引用悬空 + 内容文件（码漂移/损坏 JSON/孤立内容），
## 统一产出 {kind, severity, path, message, map, jump} 条目。
## 纯字典/文件扫描，不碰场景树——UI（问题抽屉/自检入口）只是它的呈现层。

const ManifestValidation := preload("res://src/project/manifest_validation.gd")
const MapStore := preload("res://src/map/map_store.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")

## 审计全项目。manifest = 编辑器清单（含 _dir/_maps_dir）。
## 返回 [{kind, severity, path, message, map, jump}]；
## jump = {type: "map"/"asset", id: <地图名/资产 id>}（可跳转的条目带上）。
static func audit(manifest: Dictionary) -> Array:
	var out: Array = []
	# 1. 清单校验
	for e in ManifestValidation.validate(manifest, str(manifest.get("_dir", ""))):
		out.append(_wrap("manifest", e))
	# 2. 地图校验（读盘全图）+ 顺带收集被实例引用的内容 ID（孤立内容判定用）
	var used_content := {}
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
				_collect_used_content(d, used_content)
	# 3. 内容文件：损坏 JSON / function 码漂移 / 孤立内容
	out.append_array(_content_checks(manifest, used_content))
	return out

## 收集全项目被实例绑定引用的内容 ID（objects[].functions[].content）。
static func _collect_used_content(data: Dictionary, used: Dictionary) -> void:
	for o in (data.get("objects", []) as Array):
		if not (o is Dictionary):
			continue
		for f in ((o as Dictionary).get("functions", []) as Array):
			if not (f is Dictionary):
				continue
			var cid := str((f as Dictionary).get("content", ""))
			if cid != "":
				used[cid] = true

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
			if not used.has(cid):
				out.append({
					"kind": "content", "severity": "warning",
					"path": "%s/%s" % [kind, cid],
					"message": "孤立内容：没有任何实例引用（可能是复用库，确认后可删）",
					"map": "", "jump": {},
				})
	return out

## 引用悬空检查：objects[].props 里 entity_ref/map_ref 声明字段的值指向不存在对象 = 警告。
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
	for a in AssetDecl.of_kind(manifest, "entity"):
		var ad: Dictionary = a
		var flds := []
		for fd in (ad.get("fields", []) as Array):
			if fd is Dictionary and str((fd as Dictionary).get("type", "")) in ["entity_ref", "map_ref"]:
				flds.append(fd)
		if not flds.is_empty():
			refs[str(ad.get("id", ""))] = flds
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
			var ok_target: bool = map_codes.has(str(val)) \
				or (maps_dir == "" or FileAccess.file_exists(maps_dir.path_join(str(val) + ".json")))
			if typ == "entity_ref" and not codes.has(str(val)):
				out.append({
					"kind": "ref", "severity": "warning",
					"path": "%s · %s(%s).%s" % [map_name, aid, str(o.get("code", "?")), key],
					"message": "引用的实例码不存在: %s" % str(val),
					"map": map_name,
					"jump": {"type": "entity", "map": map_name, "code": str(o.get("code", ""))},
					"fix": {"op": "clear_prop", "map": map_name, "code": str(o.get("code", "")), "prop": key},
				})
			elif typ == "map_ref" and not ok_target:
				out.append({
					"kind": "ref", "severity": "warning",
					"path": "%s · %s(%s).%s" % [map_name, aid, str(o.get("code", "?")), key],
					"message": "目标地图不存在: %s" % str(val),
					"map": map_name,
					"jump": {"type": "entity", "map": map_name, "code": str(o.get("code", ""))},
					"fix": {"op": "clear_prop", "map": map_name, "code": str(o.get("code", "")), "prop": key},
				})
	return out
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
