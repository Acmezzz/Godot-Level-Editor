extends "res://tests/_suite_base.gd"
## C3：挂载去重/补齐、按 (功能 id, 内容 ID) 查询来向。

const ReferenceUsage := preload("res://src/project/reference_usage.gd")
const MapStore := preload("res://src/map/map_store.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const V := preload("res://src/project/manifest_validation.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")

const TMP := "user://test_audit_c3_tmp"

func _fake_manifest() -> Dictionary:
	return {"_dir": TMP, "_maps_dir": TMP.path_join("maps"), "contentDir": "content",
		"projectName": "p", "tileSize": 16}

func _nuke_rec(p: String) -> void:
	if not DirAccess.dir_exists_absolute(p):
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
		return
	for f in DirAccess.get_files_at(p):
		DirAccess.remove_absolute(p.path_join(str(f)))
	for d in DirAccess.get_directories_at(p):
		_nuke_rec(p.path_join(str(d)))
	DirAccess.remove_absolute(p)

func _wipe() -> void:
	_nuke_rec(TMP)

func test_duplicate_mount_rejected_and_deduped() -> void:
	var m := _fake_manifest()
	m["functions"] = {"f1": {"name": "F", "code": "F111", "fields": []}}
	m["triggers"] = {"t1": {"name": "T", "code": "T111"}}
	m["assets"] = [{"id": "door", "kind": "entity", "prefab": "res://d.tscn", "functions": ["f1", "f1"]}]
	var dup_err := 0
	for e in V.validate(m):
		if str(e.get("message", "")).contains("duplicate mount"):
			dup_err += 1
	eq(dup_err, 1, "重复挂载报一条错误")
	eq(FunctionDecls.entity_mounts(m, "door").size(), 1, "运行期挂载去重成一条")
	_wipe()

## 补挂载：缺的追加 mounted 行；已有同码一条 = 不重复补；同码多条 = 报 ambiguous 不猜
func test_fill_bindings() -> void:
	var m := _fake_manifest()
	m["functions"] = {
		"f1": {"name": "F1", "code": "F111", "fields": []},
		"f2": {"name": "F2", "code": "F222", "fields": []},
	}
	m["assets"] = [{"id": "door", "kind": "entity", "prefab": "res://d.tscn", "functions": ["f1", "f2"]}]
	# 空绑定 → 两条 mounted 行，order 连续
	var r := FunctionDecls.fill_bindings(m, "door", [])
	eq(bool(r.get("changed")), true, "缺挂载被补齐")
	var fns: Array = r.get("functions", [])
	eq(fns.size(), 2, "补出两条")
	eq(bool((fns[0] as Dictionary).get("mounted", false)), true, "继承行带 mounted 标记")
	eq(int((fns[1] as Dictionary).get("order")), 2, "order 重排连续")
	# 再来一次：已有同码一条，不重复补
	var r2 := FunctionDecls.fill_bindings(m, "door", fns)
	eq(bool(r2.get("changed")), false, "已齐全时不改数据")
	eq((r2.get("functions", []) as Array).size(), 2, "绑定数不变")
	# 同码两条（旧图/库复用）：不猜哪条是继承行，报 ambiguous
	var dup: Array = [
		{"fn": "F111", "content": "", "name": "", "order": 1, "parallel": false},
		{"fn": "F111", "content": "", "name": "", "order": 2, "parallel": false},
	]
	var r3 := FunctionDecls.fill_bindings(m, "door", dup)
	ok((r3.get("ambiguous", []) as Array).has("F111"), "同码多条报 ambiguous")
	# 已有 mounted 标记时忍让：手动同功能行照旧保留
	var marked: Array = [
		{"fn": "F111", "content": "", "name": "", "order": 1, "parallel": false, "mounted": true},
		{"fn": "F111", "content": "", "name": "manual", "order": 2, "parallel": false},
	]
	var r4 := FunctionDecls.fill_bindings(m, "door", marked)
	eq((r4.get("ambiguous", []) as Array).size(), 0, "有继承行时不再报 ambiguous")
	_wipe()

# ──────────── 引用索引与绑定检查（C12） ────────────

## E3 内容库删除前的引用检查：实例引用（含当前图未保存绑定）与内容间引用都显形
func test_content_usage_and_inbound_refs() -> void:
	_wipe()
	var m := _fake_manifest()
	m["assets"] = [{"id": "door", "kind": "entity", "code": "DOOR"}]
	m["functions"] = {
		"f1": {"name": "F1", "code": "F111", "fields": [
			{"id": "next", "code": "N111", "kind": "choice", "type": "string", "source": "content:f1"}]},
		"f2": {"name": "F2", "code": "F222", "fields": []},
	}
	ok(ContentStore.write(m, "f1", "AAA1", {"name": "a", "function": "F111", "fields": {}}), "内容写入")
	ok(ContentStore.write(m, "f1", "BBB2", {"name": "b", "function": "F111", "fields": {"N111": "AAA1"}}),
		"引用 AAA1 的内容写入")
	var d := MapStore.new_map("m1", 8, 8)
	(d.objects as Array).append({"asset": "door", "code": "E1", "layer": str(d.meta.layers[0].id),
		"x": 0, "y": 0, "functions": [{"fn": "F111", "content": "AAA1"}]})
	(d.objects as Array).append({"asset": "door", "code": "E2", "layer": str(d.meta.layers[0].id),
		"x": 1, "y": 0, "functions": [{"fn": "F222", "content": "AAA1"}]})
	MapStore.write(m, "m1", d)
	var u := ReferenceUsage.inbound_content(m, "f1", "AAA1")
	var by_map: Dictionary = u.edges.instances
	eq(by_map.size(), 1, "统计到一张图")
	eq((by_map["m1"] as Array).size(), 1, "只算功能码匹配的那个实例（同内容 ID 的另一功能不算）")
	ok((by_map["m1"] as Array).has("E1"), "实例码正确")
	# 当前图以画布为准：磁盘上没引用、画布上新绑的也算
	var live := {"objects": [{"asset": "door", "code": "E9", "functions": [{"fn": "F111", "content": "AAA1"}]},
		{"asset": "unknown", "code": "E0", "functions": [{"fn": "F111", "content": "AAA1"}]}]}
	var u2 := ReferenceUsage.inbound_content(m, "f1", "AAA1", "m1", live)
	ok(u2.edges.instances["m1"].has("E9"), "当前画布未保存绑定计入")
	ok(not u2.edges.instances["m1"].has("E0"), "未知资产不产生执行引用")
	# 内容间引用：BBB2 的字段指向 AAA1
	var inbound := ReferenceUsage.content_inbound_refs(m, "f1", "AAA1")
	eq(inbound.size(), 1, "内容间入边一条")
	eq(str((inbound[0] as Dictionary).get("id", "")), "BBB2", "入边来源内容正确")
	eq(str((inbound[0] as Dictionary).get("field", "")), "next", "入边字段是字段 id")
	_wipe()

## E3：共享显示名/类别查询——声明名空时回落 id，类别三分类与图鉴一致
func test_asset_label_and_category() -> void:
	var m := _fake_manifest()
	m["assets"] = [
		{"id": "T1", "kind": "scene", "shape": "tile", "name": "草地"},
		{"id": "I1", "kind": "scene", "shape": "image", "name": "背景"},
		{"id": "E1", "kind": "entity", "name": ""},
	]
	eq(AssetDecl.label(m, "T1"), "草地", "声明名优先")
	eq(AssetDecl.label(m, "E1"), "E1", "空名回落 id")
	eq(AssetDecl.category_of(m, "T1"), "瓦片", "图集归瓦片")
	eq(AssetDecl.category_of(m, "I1"), "图片", "图片单列")
	eq(AssetDecl.category_of(m, "E1"), "实体", "实体单列")
	ok(AssetDecl.placeable(m, "I1"), "图片可摆放")
	ok(not AssetDecl.placeable(m, "nope"), "未知资产不可摆放")

## 解绑后内容文件仍在库里；绑定重新加回 → 引用索引恢复（同一批数据源）
