extends RefCounted
## ReferenceIndex（§7.2）：稳定身份键与引用解析的统一入口。
## MapKey = 地图码；InstanceKey = (地图码, 实例码)；ContentKey = (功能 id, 内容 ID)。
## resolve 系列是候选（ref_fields）、审计悬空判定（project_audit）与删除入边检查
## （content_form）共享的同一套解析结果；status = ok / unset / missing / ambiguous /
## unreadable / invalid（V4 §4.2-4：解析不出时不再一律压成 missing，让审计与控件各自分得清
## 「没有这张图」与「图在但读不出来」与「键本身不合法」）。
## 只读查询走快速索引（MapStore code_index 缓存）；破坏性检查的入边全景按实际磁盘构建（R29 口径）。

const MapStore := preload("res://src/map/map_store.gd")
const ManifestScript := preload("res://src/project/manifest.gd")

## 地图键（码或图名）解析 → {status, key(图名), candidates}。
## 一码多图（R09 拒绝猜测，候选 = 冲突图名列表）；键同时是图名又是另一张图的码 = ambiguous
## （名字先于码命中会让按码存储的引用悄悄改指另一张图，宁可报歧义让人修）。
## 同一张图「图名 == 自己的码」不算歧义。missing：键不存在；ok：唯一图名（码命中时 key_code 带回原码）。
## §4.2-4 两态细分：
##   invalid   —— 键根本不能当地图名（含路径分隔符/保留名/首点等），永远解析不成文件；
##   unreadable——键命中了某个文件，但那份文件读不出来（坏 JSON / 结构校验不过），
##                「目标里有没有这个实例/这条边」无从判定，调用方不能据此报悬空。
static func resolve_map(manifest: Dictionary, map_key: String) -> Dictionary:
	return resolve_indexed_map(MapStore.code_index(manifest), map_key) if map_key != "" else _unset_map()

static func _unset_map() -> Dictionary:
	return {"status": "unset", "key": "", "candidates": []}

static func resolve_indexed_map(ci: Dictionary, map_key: String) -> Dictionary:
	if map_key == "":
		return _unset_map()
	var names: Array = ci.get("names", [])
	var unreadable: Array = ci.get("unreadable", [])
	var by_code: Dictionary = ci.get("by_code", {})
	var candidates: Array = by_code.get(map_key, [])
	var by_name := names.has(map_key)
	if by_name and candidates.size() > 1:
		return {"status": "ambiguous", "key": "", "candidates": candidates}
	var name := str((ci.get("map") as Dictionary).get(map_key, ""))
	if by_name and name != "" and name != map_key:
		# 键既是图名又是别的图的码：两种解释指向不同文件，不猜
		var cands: Array = [str(map_key), name]
		return {"status": "ambiguous", "key": "", "candidates": cands}
	if by_name:
		# 命中了目录里的文件：内容读不出就是 unreadable，不是「图不存在」
		if unreadable.has(map_key):
			return {"status": "unreadable", "key": str(map_key), "candidates": [str(map_key)]}
		return {"status": "ok", "key": str(map_key), "candidates": [str(map_key)]}
	if candidates.size() > 1:
		return {"status": "ambiguous", "key": "", "candidates": candidates}
	if name == "":
		# 码表里没有：键本身能不能当地图名？不能 = invalid（永远不可能有这张图）
		if not ManifestScript.is_valid_map_name(map_key):
			return {"status": "invalid", "key": "", "candidates": []}
		return {"status": "missing", "key": "", "candidates": []}
	if unreadable.has(name):
		return {"status": "unreadable", "key": name, "key_code": map_key, "candidates": [name]}
	return {"status": "ok", "key": name, "key_code": map_key, "candidates": [name]}

## Cross-map graph edges require a stable code, never a file-name fallback.
static func resolve_graph_map(index: Dictionary, code: String) -> Dictionary:
	var resolved := resolve_indexed_map(index, code)
	if resolved.status == "ok" and index.get("by_name", {}).get(resolved.key) != code:
		return {"status": "missing", "key": "", "candidates": []}
	return resolved

## 消费口径：地图键 → 图名（unset/ambiguous/missing 返回 ""，调用方按 status 区分）。
static func map_name_of(manifest: Dictionary, map_key: String) -> String:
	return str(resolve_map(manifest, map_key).get("key", ""))

## 只识别编辑器创建的内容目标形态，游戏自己的热点目标由游戏解释。
static func is_view_content_target(value: Variant) -> bool:
	return value is Dictionary and value.size() == 2 and value.get("function") is String \
		and value.get("content") is String

static func view_ids(manifest: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	var rows = manifest.get("views", [])
	if rows is Array:
		for row in rows:
			if row is Dictionary and row.get("view_id") is String and row.view_id != "":
				ids.append(row.view_id)
	return ids

static func view_content_refs(manifest: Dictionary) -> Array:
	var out := []
	var views = manifest.get("views")
	if not views is Array:
		return out
	for i in views.size():
		var view = views[i]
		if not view is Dictionary:
			continue
		_collect_view_targets(view.get("hotspots"), view, "views[%d].hotspots" % i, out)
		var layout = view.get("layout")
		if layout is Dictionary:
			_collect_view_targets(layout.get("elements"), view, "views[%d].layout.elements" % i, out)
	return out

static func _collect_view_targets(rows: Variant, view: Dictionary, prefix: String, out: Array) -> void:
	if not rows is Array:
		return
	for i in rows.size():
		var row = rows[i]
		if not row is Dictionary:
			continue
		if is_view_content_target(row.get("target")):
			out.append({"fn": row.target.function, "cid": row.target.content,
				"view": str(view.get("view_id", "")), "path": "%s[%d].target" % [prefix, i]})
		if row.get("kind") == "module" and row.get("outputs") is Dictionary:
			for id in row.outputs:
				var target = row.outputs[id]
				if is_view_content_target(target):
					out.append({"fn": target.function, "cid": target.content,
						"view": str(view.get("view_id", "")), "path": "%s[%d].outputs.%s" % [prefix, i, id]})

static func view_image_refs(manifest: Dictionary) -> Array:
	var out := []
	var views = manifest.get("views", [])
	for i in (views.size() if views is Array else 0):
		var view = views[i]
		if not view is Dictionary or not view.get("layout") is Dictionary:
			continue
		var elements = view.layout.get("elements", [])
		for j in (elements.size() if elements is Array else 0):
			var row = elements[j]
			if row is Dictionary and row.get("imageAsset") is String and row.imageAsset != "":
				out.append({"asset": row.imageAsset, "view": str(view.get("view_id", "")),
					"path": "views[%d].layout.elements[%d].imageAsset" % [i, j]})
	return out

## 入边全景（§7.2 inbound）：内容 (fn_id, cid) 的全部入边，破坏性检查共用这一个入口。
## edges = {instances: {地图名: [实例码]}, contents: [{kind,id,field}], views: [热点引用], drafts: [草稿键]}；
## complete=false 时 unreadable_sources 列出读不全的源（删除/清理必须拦截，D07 口径）。
## 暂存（会话内未落盘）的入边由调用方自行并入（见 content_form._delete_blocked_reason）。
static func inbound_content(manifest: Dictionary, fn_id: String, cid: String,
		cur_map := "", live_codes: Array = []) -> Dictionary:
	var PA = load("res://src/project/project_audit.gd")   # 懒加载：project_audit 反向 preload 本模块，避免环
	var usage: Dictionary = PA.content_usage(manifest, fn_id, cid, cur_map, live_codes)
	var unreadable: Array = []
	for u in (usage.get("unreadable", []) as Array):
		unreadable.append("地图 %s 读不出来" % str(u))
	for bc in (usage.get("bad_contents", []) as Array):
		unreadable.append(str(bc))
	return {
		"complete": unreadable.is_empty(),
		"unreadable_sources": unreadable,
		"edges": {
			"instances": usage.get("by_map", {}),
			"contents": PA.content_inbound_refs(manifest, fn_id, cid),
			"views": view_content_refs(manifest).filter(func(ref): return ref.fn == fn_id and ref.cid == cid),
			"drafts": PA.draft_inbound_refs(manifest, cid, fn_id),
		},
	}
