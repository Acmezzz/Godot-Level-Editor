extends RefCounted
## 全项目一致性审计（REFACTOR_PLAN 4.6-3/4/5）：清单校验 + 地图校验 + 内容码漂移 +
## 引用悬空，统一产出 {kind, severity, path, message, map, jump} 条目。
## 纯字典/文件扫描，不碰场景树——UI（问题抽屉/自检入口）只是它的呈现层。

const ManifestValidation := preload("res://src/manifest_validation.gd")
const MapStore := preload("res://src/map_store.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")

## 审计全项目。manifest = 编辑器清单（含 _dir/_maps_dir）。
## 返回 [{kind, severity, path, message, map, jump}]；
## jump = {type: "map"/"asset", id: <地图名/资产 id>}（可跳转的条目带上）。
static func audit(manifest: Dictionary) -> Array:
	var out: Array = []
	# 1. 清单校验
	for e in ManifestValidation.validate(manifest, str(manifest.get("_dir", ""))):
		out.append(_wrap("manifest", e))
	# 2. 地图校验（读盘全图）
	var maps_dir := str(manifest.get("_maps_dir", ""))
	if maps_dir != "":
		for name in MapStore.list_maps(manifest):
			var r: Dictionary = MapStore.read_path(maps_dir.path_join(name + ".json"), manifest)
			for e in (r.get("warnings", []) as Array):
				out.append(_wrap_map_issue("map", e, str(name)))
			for e in (r.get("errors", []) as Array):
				out.append(_wrap_map_issue("map", e, str(name)))
			if bool(r.get("ok", false)):
				out.append_array(_ref_checks(r.get("data", {}) as Dictionary, manifest, str(name)))
	return out

## 引用悬空检查：objects[].props 里 entity_ref/map_ref 声明字段的值指向不存在对象 = 警告。
static func _ref_checks(data: Dictionary, manifest: Dictionary, map_name: String) -> Array:
	var out: Array = []
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
			var ok_target: bool = maps_dir == "" or FileAccess.file_exists(maps_dir.path_join(str(val) + ".json"))
			if typ == "entity_ref" and not codes.has(str(val)):
				out.append({
					"kind": "ref", "severity": "warning",
					"path": "%s · %s(%s).%s" % [map_name, aid, str(o.get("code", "?")), key],
					"message": "引用的实例码不存在: %s" % str(val),
					"map": map_name,
					"jump": {"type": "entity", "map": map_name, "code": str(o.get("code", ""))},
				})
			elif typ == "map_ref" and not ok_target:
				out.append({
					"kind": "ref", "severity": "warning",
					"path": "%s · %s(%s).%s" % [map_name, aid, str(o.get("code", "?")), key],
					"message": "目标地图不存在: %s" % str(val),
					"map": map_name,
					"jump": {"type": "entity", "map": map_name, "code": str(o.get("code", ""))},
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
