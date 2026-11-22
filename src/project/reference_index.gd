extends RefCounted
## ReferenceIndex（§7.2）：稳定身份键与引用解析的统一入口。
## MapKey = 地图码；InstanceKey = (地图码, 实例码)；ContentKey = (功能 id, 内容 ID)。
## resolve 系列是候选（ref_fields）、审计悬空判定（project_audit）与删除入边检查
## （content_form）共享的同一套解析结果；status = ok / unset / missing / ambiguous / incomplete。
## 只读查询走快速索引（MapStore 缓存）；破坏性检查的入边全景按实际磁盘构建（R29 口径）。

const MapStore := preload("res://src/map/map_store.gd")

## 地图键（码或图名）解析 → {status, key(图名), candidates}。
## 一码多图（R09 拒绝猜测，候选 = 冲突图名列表）；键同时是图名又是另一张图的码 = ambiguous
## （名字先于码命中会让按码存储的引用悄悄改指另一张图，宁可报歧义让人修）。
## 同一张图「图名 == 自己的码」不算歧义。missing：键不存在；ok：唯一图名（码命中时 key_code 带回原码）。
static func resolve_map(manifest: Dictionary, map_key: String) -> Dictionary:
	if map_key == "":
		return {"status": "unset", "key": "", "candidates": []}
	var names: Array = MapStore.list_maps(manifest)
	var conflicts: Dictionary = MapStore.code_conflicts(manifest)
	var by_name := names.has(map_key)
	if by_name and conflicts.has(map_key):
		return {"status": "ambiguous", "key": "", "candidates": conflicts[map_key]}
	var name := str(MapStore.code_map(manifest).get(map_key, ""))
	if by_name and name != "" and name != map_key:
		# 键既是图名又是别的图的码：两种解释指向不同文件，不猜
		var cands: Array = [str(map_key), name]
		return {"status": "ambiguous", "key": "", "candidates": cands}
	if by_name:
		return {"status": "ok", "key": str(map_key), "candidates": [str(map_key)]}
	if conflicts.has(map_key):
		return {"status": "ambiguous", "key": "", "candidates": conflicts[map_key]}
	if name == "":
		return {"status": "missing", "key": "", "candidates": []}
	return {"status": "ok", "key": name, "key_code": map_key, "candidates": [name]}

## 消费口径：地图键 → 图名（unset/ambiguous/missing 返回 ""，调用方按 status 区分）。
static func map_name_of(manifest: Dictionary, map_key: String) -> String:
	return str(resolve_map(manifest, map_key).get("key", ""))

## 入边全景（§7.2 inbound）：内容 (fn_id, cid) 的全部入边，破坏性检查共用这一个入口。
## edges = {instances: {地图名: [实例码]}, contents: [{kind,id,field}], drafts: [草稿键]}；
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
			"drafts": PA.draft_inbound_refs(manifest, cid),
		},
	}
