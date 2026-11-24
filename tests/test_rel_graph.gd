extends "res://tests/_suite_base.gd"
## E2-3：关系图（纯数据层）——节点/边生成、写回同一字段、断开删键、staged 并入、循环保留。

const RelGraph := preload("res://src/content/rel_graph.gd")
const ContentStore := preload("res://src/content/content_store.gd")

const TMP := "user://test_rel_graph_tmp"

func _manifest() -> Dictionary:
	return {"_dir": TMP, "_maps_dir": TMP.path_join("maps"), "contentDir": "content",
		"projectName": "p", "tileSize": 16,
		"functions": {
			"dialog": {"name": "对话", "code": "F100", "fields": [
				{"id": "next", "code": "N100", "name": "下一句", "kind": "choice", "source": "content:dialog"},
				{"id": "intro", "code": "N200", "name": "开场", "kind": "input", "type": "string"},
			]},
			"quest": {"name": "任务", "code": "F200", "fields": [
				{"id": "goal", "code": "N300", "name": "目标", "kind": "choice", "source": "content:dialog"},
			]},
		},
		"steps": {"say": {"code": "S100", "name": "说", "fields": [
			{"id": "line", "code": "N400", "name": "台词", "kind": "intro"},
			{"id": "to", "code": "N500", "name": "跳到", "kind": "choice", "source": "content:dialog"},
		]}},
		"assets": []}

func _nuke(p: String) -> void:
	if DirAccess.dir_exists_absolute(p):
		for f in DirAccess.get_files_at(p):
			DirAccess.remove_absolute(p.path_join(str(f)))
		for d in DirAccess.get_directories_at(p):
			_nuke(p.path_join(str(d)))
		DirAccess.remove_absolute(p)

func _cleanup() -> void:
	_nuke(TMP)

func _write(m: Dictionary, fn_id: String, cid: String, fields: Dictionary, name := "") -> void:
	ContentStore.write(m, fn_id, cid, {"id": cid, "name": name if name != "" else cid, "fields": fields})

## 建图：边读声明字段（含步骤字段），跨功能目标补占位节点，不存在目标进 external
func test_build_edges() -> void:
	_cleanup()
	var m := _manifest()
	_write(m, "dialog", "a", {"N100": "b"})
	_write(m, "dialog", "b", {"N100": "a"})   # 循环（游戏允许，必须保留）
	_write(m, "dialog", "c", {"N100": "gone"})
	_write(m, "quest", "q1", {"N300": "a"})
	var g := RelGraph.build(m, "dialog")
	var keys := []
	for n in g.nodes:
		keys.append(str((n as Dictionary).get("key", "")))
	ok(keys.has("dialog\u0001a") and keys.has("dialog\u0001b"), "两端节点都在")
	ok(keys.has("dialog\u0001c"), "孤立节点也画（可从这里接线）")
	eq((g.get("edges", []) as Array).size(), 2, "a→b 与 b→a 两条边（循环保留）")
	eq((g.get("external", []) as Array).size(), 1, "指向不存在内容的引用进 external")
	eq(str((g.external[0] as Dictionary).get("value", "")), "gone", "external 带原值")
	# 跨功能：任务→对话 a 从 quest 侧建图时补出 dialog 占位节点
	var g2 := RelGraph.build(m, "quest")
	var keys2 := []
	for n in g2.nodes:
		keys2.append(str((n as Dictionary).get("key", "")))
	ok(keys2.has("dialog\u0001a"), "跨功能目标补占位节点（身份含功能 ID）")
	_cleanup()

## 步骤字段里的内容引用也要成边（step 下标随边带出，写回定位用）
func test_build_step_edges() -> void:
	_cleanup()
	var m := _manifest()
	_write(m, "dialog", "a", {})
	_write(m, "dialog", "b", {})
	ContentStore.write(m, "dialog", "a", {"id": "a", "name": "a", "fields": {},
		"steps": [{"step": "S100", "fields": {"N500": "b"}}]})
	var g := RelGraph.build(m, "dialog")
	eq((g.get("edges", []) as Array).size(), 1, "步骤字段引用生成一条边")
	var e: Dictionary = g.edges[0]
	eq(int(e.get("step", -2)), 0, "边带步骤下标")
	eq(str(e.get("field", "")), "N500", "边带字段码")
	_cleanup()

## staged 内容并入建图（A2 未落盘的新内容在图上立刻可见）
func test_build_merges_staged() -> void:
	_cleanup()
	var m := _manifest()
	_write(m, "dialog", "a", {"N100": "new1"})
	var g0 := RelGraph.build(m, "dialog")
	eq((g0.get("external", []) as Array).size(), 1, "新内容未落盘前，引用算悬空")
	var staged := {"new1": {"id": "new1", "name": "新一句", "fields": {}}}
	var g1 := RelGraph.build(m, "dialog", staged)
	eq((g1.get("edges", []) as Array).size(), 1, "并入 staged 后边成立")
	var keys := []
	for n in g1.nodes:
		keys.append(str((n as Dictionary).get("key", "")))
	ok(keys.has("dialog\u0001new1"), "staged 节点在图上")
	_cleanup()

## 写回同一字段：改接、断开（删键）、幂等、多选原位替换
func test_set_edge_roundtrip() -> void:
	_cleanup()
	var m := _manifest()
	_write(m, "dialog", "a", {"N100": "b"})
	_write(m, "dialog", "b", {})
	_write(m, "dialog", "c", {})
	var rd := func(fid: String, cid: String) -> Dictionary: return ContentStore.read(m, fid, cid)
	var wr := func(fid: String, cid: String, data: Dictionary) -> bool:
		return ContentStore.write(m, fid, cid, data)
	# 改接
	var r1 := RelGraph.set_edge(rd, wr, "dialog", "a", -1, "N100", "c", false)
	eq(str(r1.get("status", "")), "ok", "改接成功")
	eq(str(ContentStore.read(m, "dialog", "a").get("fields", {}).get("N100", "")), "c", "字段换成新目标")
	# 幂等
	var r2 := RelGraph.set_edge(rd, wr, "dialog", "a", -1, "N100", "c", false)
	eq(str(r2.get("status", "")), "noop", "同值不重写")
	# 断开 = 删键（C1 未设置语义）
	var r3 := RelGraph.set_edge(rd, wr, "dialog", "a", -1, "N100", "", false)
	eq(str(r3.get("status", "")), "ok", "断开成功")
	ok(not (ContentStore.read(m, "dialog", "a").get("fields", {}) as Dictionary).has("N100"),
		"断开删键而不是留空串")
	# 图与表单一致：重读图的边
	_write(m, "dialog", "a", {"N100": "b"})
	var g := RelGraph.build(m, "dialog")
	eq(str((g.edges[0] as Dictionary).get("to", "")), "dialog\u0001b", "重开后边指向同一目标")
	_cleanup()

func test_set_edge_rejects_changed_display() -> void:
	var shown := {"shown_value": "b", "shown_steps": [{"step": "S100", "fields": {"N500": "b"}}]}
	var data := {"fields": {"N100": "c"}, "steps": [{"step": "S200", "fields": {"N500": "b"}}]}
	var writes := [0]
	var rd := func(_fn: String, _cid: String) -> Dictionary: return data.duplicate(true)
	var wr := func(_fn: String, _cid: String, _data: Dictionary) -> bool:
		writes[0] += 1
		return true
	eq(RelGraph.set_edge(rd, wr, "dialog", "a", -1, "N100", "", false, "b", shown).status,
		"stale", "顶层引用改变后拒绝断开")
	eq(RelGraph.set_edge(rd, wr, "dialog", "a", 0, "N500", "", false, "b", shown).status,
		"stale", "步骤被替换后拒绝断开同下标的引用")
	eq(writes[0], 0, "过期操作不写回")

func test_set_edge_step_scope_and_multi() -> void:
	_cleanup()
	var m := _manifest()
	_write(m, "dialog", "a", {"N100": "x"})
	_write(m, "dialog", "b", {})
	ContentStore.write(m, "dialog", "a", {"id": "a", "fields": {"N100": "x"},
		"steps": [{"step": "S100", "fields": {"N500": "b"}}]})
	var rd := func(fid: String, cid: String) -> Dictionary: return ContentStore.read(m, fid, cid)
	var wr := func(fid: String, cid: String, data: Dictionary) -> bool:
		return ContentStore.write(m, fid, cid, data)
	# 步骤内字段写回只动该步
	var r := RelGraph.set_edge(rd, wr, "dialog", "a", 0, "N500", "", false)
	eq(str(r.get("status", "")), "ok", "步骤字段断开")
	var d := ContentStore.read(m, "dialog", "a")
	ok(not (((d.get("steps", []) as Array)[0] as Dictionary).get("fields", {}) as Dictionary).has("N500"),
		"只删步骤里的键")
	eq(str((d.get("fields", {}) as Dictionary).get("N100", "")), "x", "顶层字段不受影响")
	# 多选：原位替换一条、其余保留
	_write(m, "dialog", "a", {"N100": ["x", "b"]})
	var r2 := RelGraph.set_edge(rd, wr, "dialog", "a", -1, "N100", "b", true, "x")
	eq(str(r2.get("status", "")), "ok", "多选改接成功")
	var arr: Array = ContentStore.read(m, "dialog", "a").get("fields", {}).get("N100", [])
	eq(str(arr), str(["b", "b"]), "原位替换，其余元素保留")
	_cleanup()

## F1/P04：表单的写回回调返回状态串（"ok"/"conflict"/"fail"），
## 非 "ok" 必须判失败——字符串非空在 GDScript 里为真，不能当成功吞掉。
func test_set_edge_string_write_status() -> void:
	_cleanup()
	var m := _manifest()
	_write(m, "dialog", "a", {"N100": "b"})
	_write(m, "dialog", "c", {})
	var rd := func(fid: String, cid: String) -> Dictionary: return ContentStore.read(m, fid, cid)
	var wr_ok := func(_fid: String, _cid: String, data: Dictionary) -> String:
		return "ok" if not data.is_empty() else "fail"
	var r1 := RelGraph.set_edge(rd, wr_ok, "dialog", "a", -1, "N100", "c", false)
	eq(str(r1.get("status", "")), "ok", "写回回调返回 \"ok\" 视为成功")
	var wr_conflict := func(_fid: String, _cid: String, _data: Dictionary) -> String:
		return "conflict"
	var r2 := RelGraph.set_edge(rd, wr_conflict, "dialog", "a", -1, "N100", "c", false)
	eq(str(r2.get("status", "")), "failed", "写回返回 \"conflict\" 判失败")
	var wr_fail := func(_fid: String, _cid: String, _data: Dictionary) -> String:
		return "fail"
	var r3 := RelGraph.set_edge(rd, wr_fail, "dialog", "a", -1, "N100", "c", false)
	eq(str(r3.get("status", "")), "failed", "写回返回 \"fail\" 判失败")
	_cleanup()


func test_nested_slot_cannot_edit_reordered_rows_with_same_target() -> void:
	_cleanup()
	var m := _manifest()
	m.functions.quest.fields = [
		{"id": "branches", "code": "BRCH", "kind": "input", "type": "array", "of": "record", "fields": [
			{"id": "label", "kind": "input", "type": "string"},
			{"id": "goal", "kind": "choice", "source": "content:dialog"},
		]},
	]
	_write(m, "dialog", "a", {})
	_write(m, "dialog", "b", {})
	var rows := [{"label": "first", "goal": "a"}, {"label": "second", "goal": "a"}]
	_write(m, "quest", "q", {"BRCH": rows})
	var graph := RelGraph.build_project(m)
	var slot: Dictionary = graph.slots["quest\u0001q"][0]
	rows.reverse()
	_write(m, "quest", "q", {"BRCH": rows})
	var read := func(fn: String, id: String): return ContentStore.read(m, fn, id)
	var write := func(fn: String, id: String, data: Dictionary): return ContentStore.write(m, fn, id, data)
	eq(RelGraph.set_edge(read, write, "quest", "q", -1, slot.field, "b", false, "a", slot).status,
		"stale", "同一引用值不能掩盖分支已重排")
	eq(ContentStore.read(m, "quest", "q").fields.BRCH, rows, "两条分支均保持原值")
	_cleanup()

func test_project_slots_append_repair_and_disconnect() -> void:
	_cleanup()
	var m := _manifest()
	m.functions.quest.fields[0]["multiple"] = true
	_write(m, "dialog", "a", {})
	_write(m, "dialog", "b", {})
	_write(m, "quest", "a", {"N300": ["missing"]})
	var g := RelGraph.build_project(m)
	var slots: Array = g.slots["quest\u0001a"]
	var missing: Dictionary = slots[0]
	var append: Dictionary = slots[1]
	var read := func(fn: String, id: String): return ContentStore.read(m, fn, id)
	var write := func(fn: String, id: String, data: Dictionary): return ContentStore.write(m, fn, id, data)
	eq(missing.fn, "dialog", "scoped target does not collide with quest of the same ID")
	eq(missing.value, "missing", "missing target has an editable slot")
	eq(RelGraph.set_edge(read, write, "quest", "a", -1, "N300", "a", true, "", append).status,
		"ok", "appending a target keeps existing positions")
	eq(RelGraph.set_edge(read, write, "quest", "a", -1, "N300", "b", true, "missing", missing).status,
		"stale", "a graph slot cannot overwrite a newer multi-value list")
	g = RelGraph.build_project(m)
	missing = g.slots["quest\u0001a"][0]
	eq(RelGraph.set_edge(read, write, "quest", "a", -1, "N300", "b", true, "missing", missing).status,
		"ok", "reroute a missing target")
	g = RelGraph.build_project(m)
	var first: Dictionary = g.slots["quest\u0001a"][0]
	eq(RelGraph.set_edge(read, write, "quest", "a", -1, "N300", "", true, "b", first).status,
		"ok", "disconnect only the selected reference")
	eq(ContentStore.read(m, "quest", "a").fields.N300, ["a"], "remaining target survives")
	_cleanup()
