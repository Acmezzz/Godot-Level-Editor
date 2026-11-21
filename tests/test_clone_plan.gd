extends "res://tests/_suite_base.gd"
## C2：统一复制语义（组内 A→B、组外 A→C、普通字符串 AB23 与功能执行码 AB23、
## 复制内容独立文件、整图复制）。

const ClonePlan := preload("res://src/content/clone_plan.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const MapStore := preload("res://src/map/map_store.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")

const TMP := "user://test_clone_plan_tmp"

func _nuke(p: String) -> void:
	if not DirAccess.dir_exists_absolute(p):
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
		return
	for f in DirAccess.get_files_at(p):
		DirAccess.remove_absolute(p.path_join(str(f)))
	for d in DirAccess.get_directories_at(p):
		_nuke(p.path_join(str(d)))
	DirAccess.remove_absolute(p)

## 清单：实体类型 door（entity_ref 字段 TGT、配对地图 TMAP）+ 功能 dlg（带引用字段）
func _manifest() -> Dictionary:
	return {
		"_dir": TMP, "_maps_dir": TMP.path_join("maps"), "contentDir": "content",
		"assets": [
			{"id": "door", "kind": "entity", "visual": {"type": "rect"},
				"fields": [
					{"id": "TGT", "type": "entity_ref", "mapField": "TMAP"},
					{"id": "TMAP", "type": "map_ref"},
					{"id": "NOTE", "type": "string"},
				]},
			{"id": "guard", "kind": "entity", "visual": {"type": "rect"},
				"fields": [{"id": "TGT", "type": "entity_ref"}]},
		],
		"functions": [
			{"id": "dlg", "name": "对话", "code": "FN01", "fields": [
				{"id": "TEXT", "type": "string", "code": "F001"},
				{"id": "WHO", "type": "entity_ref", "code": "F002", "mapField": "WMAP"},
				{"id": "WMAP", "type": "map_ref", "code": "F003"},
			]},
		],
	}

func _wipe() -> void:
	_nuke(TMP)

## —— 组内 A→B、组外 A→C：只换组内引用，普通字符串不动 ——
func test_remap_in_group_vs_out_group() -> void:
	_wipe()
	var m := _manifest()
	var A := {"code": "AAAA", "asset": "door", "x": 0, "y": 0,
		"props": {"TGT": "BBBB", "NOTE": "AB23"}}
	var B := {"code": "BBBB", "asset": "door", "x": 1, "y": 0, "props": {"TGT": "CCCC"}}
	var C := {"code": "CCCC", "asset": "door", "x": 2, "y": 0}
	var data := {"meta": {"code": "MAP1"}, "objects": [A, B, C]}
	var plan: Dictionary = ClonePlan.build({"data": data, "manifest": m, "map": "m1"},
		{"data": {"meta": {"code": "MAP1"}, "objects": [C]}, "manifest": m, "map": "m1"},
		PackedStringArray(["AAAA", "BBBB"]))
	eq(str(plan.status), "ok", "计划成功")
	var imap: Dictionary = plan.instance_map
	ok(imap.has("AAAA") and imap.has("BBBB"), "组内两实例都发行新码")
	ok(not imap.has("CCCC"), "组外实例不发行")
	var a2: Dictionary = (plan.map_patch.objects as Array)[0]
	var b2: Dictionary = (plan.map_patch.objects as Array)[1]
	# A 的组内引用 B → B 的新码；NOTE 的 "AB23" 不是引用，不参与
	eq(str(a2.props.TGT), str(imap["BBBB"]), "组内 A→B 重映射")
	eq(str(a2.props.NOTE), "AB23", "普通字符串不盲扫")
	# B 的引用 C 在组外：同图复制原样保留
	eq(str(b2.props.TGT), "CCCC", "组外 A→C 保留原目标")
	eq(str(a2.code), str(imap["AAAA"]), "副本行用新码")
	ok(str(a2.code) != "AAAA", "新码 ≠ 旧码")
	_wipe()

## —— 普通字符串 AB23 与功能执行码 AB23 同值也不误改（C05） ——
func test_string_collision_safe() -> void:
	_wipe()
	var m := _manifest()
	# 实例码 AB23 + 清单功能码也是 AB23（同形四位码）
	(m["functions"] as Array)[0]["code"] = "AB23"
	var rows := {"code": "AAAA", "asset": "guard", "props": {"TGT": "ZZZZ", "TEXT": "AB23"}}
	var doc := {"meta": {"code": "MAPX"}, "objects": [rows]}
	var plan: Dictionary = ClonePlan.build({"data": doc, "manifest": m, "map": "m1"},
		{"data": {"meta": {"code": "MAPX"}, "objects": []}, "manifest": m, "map": "m1"},
		PackedStringArray(["AAAA"]))
	eq(str(plan.status), "ok", "计划成功")
	var row2: Dictionary = (plan.map_patch.objects as Array)[0]
	eq(str(row2.props.TEXT), "AB23", "非引用字段里的同形码不被换")
	eq(str(row2.props.TGT), "ZZZZ", "组外引用不被换")
	_wipe()

## —— 跨图组外引用：配对了地图字段就补源图码；无配对 = 冲突（不静默丢） ——
func test_cross_map_keeps_out_group_target() -> void:
	_wipe()
	var m := _manifest()
	var A := {"code": "AAAA", "asset": "door", "props": {"TGT": "CCCC", "TMAP": ""}}
	var C := {"code": "CCCC", "asset": "door"}
	var src := {"meta": {"code": "SRC1"}, "objects": [A, C]}
	var dst := {"meta": {"code": "DST1"}, "objects": []}
	var plan: Dictionary = ClonePlan.build({"data": src, "manifest": m, "map": "m1"},
		{"data": dst, "manifest": m, "map": "m2"}, PackedStringArray(["AAAA"]))
	eq(str(plan.status), "ok", "配对字段可保留组外引用：%s" % ClonePlan.conflicts_text(plan.conflicts))
	var row: Dictionary = (plan.map_patch.objects as Array)[0]
	eq(str(row.props.TGT), "CCCC", "组外引用保留原目标")
	eq(str(row.props.TMAP), "SRC1", "配对地图字段补源图码")
	# 无 mapField 的实体类型 + 组外引用 → 冲突
	var g := {"code": "GGGG", "asset": "guard", "props": {"TGT": "CCCC"}}
	var plan2: Dictionary = ClonePlan.build(
		{"data": {"meta": {"code": "SRC1"}, "objects": [g, C]}, "manifest": m, "map": "m1"},
		{"data": {"meta": {"code": "DST1"}, "objects": []}, "manifest": m, "map": "m2"},
		PackedStringArray(["GGGG"]))
	eq(str(plan2.status), "conflict", "无配对字段的跨图组外引用 → 冲突")
	ok(ClonePlan.conflicts_text(plan2.conflicts).contains("不支持地图配对"), "冲突说明原因")
	_wipe()

## —— 组内引用 + 配对地图字段：副本引用应指向副本所在图，而不是继承源图 ——
func test_in_group_pair_uses_target_map() -> void:
	_wipe()
	var m := _manifest()
	var A := {"code": "AAAA", "asset": "door", "props": {"TGT": "BBBB", "TMAP": "SRC1"}}
	var B := {"code": "BBBB", "asset": "door"}
	var plan: Dictionary = ClonePlan.build(
		{"data": {"meta": {"code": "SRC1"}, "objects": [A, B]}, "manifest": m, "map": "m1"},
		{"data": {"meta": {"code": "DST1"}, "objects": []}, "manifest": m, "map": "m2"},
		PackedStringArray(["AAAA", "BBBB"]))
	eq(str(plan.status), "ok", "计划成功")
	var a2: Dictionary = (plan.map_patch.objects as Array)[0]
	eq(str(a2.props.TGT), str(plan.instance_map["BBBB"]), "组内引用换新码")
	eq(str(a2.props.TMAP), "DST1", "配对地图字段指向副本所在图")
	_wipe()

## —— 副本内容独立成文件：内容 ID 不同，内容里的实例引用也重映射 ——
func test_content_clone_independent() -> void:
	_wipe()
	var m := _manifest()
	var mdir := TMP.path_join("content")
	DirAccess.make_dir_recursive_absolute(mdir)
	ok(ContentStore.write(m, "dlg", "CID1", {"name": "原台词", "function": "FN01",
		"fields": {"F001": "你好", "F002": "BBBB", "F003": "SRC1"}}), "源内容写入")
	var A := {"code": "AAAA", "asset": "door", "props": {},
		"functions": [{"fn": "FN01", "content": "CID1", "name": "对白"}]}
	var B := {"code": "BBBB", "asset": "door"}
	var plan: Dictionary = ClonePlan.build(
		{"data": {"meta": {"code": "SRC1"}, "objects": [A, B]}, "manifest": m, "map": "m1"},
		{"data": {"meta": {"code": "DST1"}, "objects": []}, "manifest": m, "map": "m2"},
		PackedStringArray(["AAAA", "BBBB"]))
	eq(str(plan.status), "ok", "计划成功：%s" % ClonePlan.conflicts_text(plan.conflicts))
	eq((plan.content_map as Dictionary).size(), 1, "一条内容进映射")
	var new_cid := str((plan.content_map as Dictionary).get("CID1", ""))
	ok(new_cid != "" and new_cid != "CID1", "内容 ID 换新")
	var pend: Array = plan.pending_contents
	eq(pend.size(), 1, "一份待写内容")
	if pend.size() == 1:
		var pd: Dictionary = (pend[0] as Dictionary).data
		eq(str(pd.get("name")), "原台词", "内容字段原样带过去")
		eq(str((pd.get("fields", {}) as Dictionary).get("F001")), "你好", "普通字段值不动")
		eq(str((pd.get("fields", {}) as Dictionary).get("F002")), str(plan.instance_map["BBBB"]),
			"内容里的组内实例引用也重映射")
		eq(str((pd.get("fields", {}) as Dictionary).get("F003")), "DST1",
			"配对地图字段指向副本所在图（组内引用）")
	# 实例行里的功能绑定换成新内容 ID
	var a2: Dictionary = (plan.map_patch.objects as Array)[0]
	eq(str((a2.functions as Array)[0].content), new_cid, "行绑定内容换成副本 ID")
	_wipe()

## —— 整图复制：瓦片/碰撞/出生点/图片/未知键都保留，实例与内容独立，目标重发地图码 ——
func test_whole_map_document() -> void:
	_wipe()
	var m := _manifest()
	DirAccess.make_dir_recursive_absolute(TMP.path_join("content"))
	ok(ContentStore.write(m, "dlg", "CID1", {"name": "n", "function": "FN01",
		"fields": {"F001": "x"}}), "源内容写入")
	var src := {
		"version": 7,
		"meta": {"name": "m1", "code": "SRC1", "w": 10, "h": 8,
			"layers": [{"id": "L1", "name": "地面"}]},
		"customGameKey": {"keep": true},
		"tiles": {"L1": [[0, 0, "tileA", 0, 0, 0]]},
		"collision": [{"x": 1, "y": 1}],
		"spawn": [2, 2],
		"objects": [{"code": "AAAA", "asset": "door", "layer": "L1", "x": 3, "y": 4,
			"props": {"TGT": ""}, "functions": [{"fn": "FN01", "content": "CID1"}], "sortAnchor": [1, 2]}],
	}
	var plan: Dictionary = ClonePlan.whole_map_document(
		{"data": src, "manifest": m, "map": "m1"}, "m2", "DST9")
	eq(str(plan.status), "ok", "整图计划成功：%s" % ClonePlan.conflicts_text(plan.conflicts))
	var doc: Dictionary = plan.document
	eq(str((doc.meta as Dictionary).get("name")), "m2", "副本改名")
	eq(str((doc.meta as Dictionary).get("code")), "DST9", "副本重发地图码")
	eq(doc.tiles.L1.size(), 1, "瓦片带过去")
	eq((doc.collision as Array).size(), 1, "碰撞带过去")
	eq(str(doc.spawn), str(src.spawn), "出生点带过去")
	ok(doc.has("customGameKey"), "游戏侧自定义顶层键保留")
	var o: Dictionary = (doc.objects as Array)[0]
	ok(str(o.code) != "AAAA", "实例码换新")
	ok(dict_has_array(o, "sortAnchor"), "sortAnchor 随行复制")
	eq(str((o.functions as Array)[0].content), str((plan.content_map as Dictionary)["CID1"]),
		"绑定内容独立")
	# 原始文档不被改写
	eq(str((src.objects as Array)[0].code), "AAAA", "源文档保持原状")
	_wipe()

func dict_has_array(d: Dictionary, key: String) -> bool:
	return d.get(key, null) is Array

## —— MapStore.duplicate_map 走整图计划：写盘成功、内容落盘、码不同 ——
func test_duplicate_map_through_plan() -> void:
	_wipe()
	var m := _manifest()
	DirAccess.make_dir_recursive_absolute(TMP.path_join("content"))
	ok(ContentStore.write(m, "dlg", "CID1", {"name": "n", "function": "FN01",
		"fields": {"F001": "x"}}), "源内容写入")
	var d := MapStore.new_map("t", 8, 8)
	(d.meta as Dictionary)["code"] = "SRC1"
	(d.objects as Array).append({"asset": "door", "code": "AAAA", "layer": str(d.meta.layers[0].id),
		"x": 1, "y": 1, "props": {}, "functions": [{"fn": "FN01", "content": "CID1"}]})
	ok(MapStore.write(m, "t", d), "原图写入")
	var conflicts: Array = []
	eq(MapStore.duplicate_map(m, "t", "t2", conflicts), "", "整图复制成功：%s" % ClonePlan.conflicts_text(conflicts))
	var d2 := MapStore.read(m, "t2")
	ok(not d2.is_empty(), "副本可读")
	eq(str((d2.meta as Dictionary).get("code")) != "SRC1", true, "复本码不同")
	var o2: Dictionary = (d2.objects as Array)[0]
	ok(str(o2.code) != "AAAA", "副本实例码不同")
	var cid2 := str((o2.functions as Array)[0].content)
	ok(cid2 != "CID1", "副本绑定独立内容")
	ok(ContentStore.read(m, "dlg", cid2).size() > 0, "副本内容文件已落盘")
	ok(ContentStore.read(m, "dlg", "CID1").size() > 0, "原内容文件仍在")
	_wipe()
