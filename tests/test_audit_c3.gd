extends "res://tests/_suite_base.gd"
## C3：挂载去重/补齐、按 (功能 id, 内容 ID) 索引的引用自检、过期报告的安全清理。

const ProjectAudit := preload("res://src/project/project_audit.gd")
const MapStore := preload("res://src/map/map_store.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const V := preload("res://src/project/manifest_validation.gd")
const ContentId := preload("res://src/content/content_id.gd")
const AssetDecl := preload("res://src/assets/asset_decl.gd")
const MapResize := preload("res://src/ui/map_resize.gd")
const Edge := preload("res://src/map/edge_ref.gd")
const ViewData := preload("res://src/map/map_view_data.gd")

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

func test_flow_context_follows_nested_routes_without_looping_or_guessing() -> void:
	_wipe()
	var m := _fake_manifest()
	m.assets = [{"id": "door", "kind": "entity"}, {"id": "switch", "kind": "entity"}]
	m.functions = {"flow": {"name": "Flow", "code": "FLOW", "fields": [
		{"id": "next", "code": "NEXT", "kind": "choice", "source": "content:flow", "contentMapContext": "inherit"},
		{"id": "independent", "code": "FREE", "kind": "choice", "source": "content:flow"},
		{"id": "local", "code": "LOCL", "kind": "choice", "source": "entity_inst:"}]},
		"entry": {"name": "Entry", "code": "BOOT", "steps": true}}
	m.steps = {"route": {"name": "Route", "code": "STEP", "fields": [
		{"id": "routes", "code": "ROWS", "kind": "input", "type": "array", "of": "record", "fields": [
			{"id": "destination_map", "code": "DMAP", "kind": "choice", "source": "map"},
			{"id": "destination", "code": "DEST", "kind": "choice", "source": "content:flow",
				"mapField": "destination_map", "contentMapContext": "paired"}]}]}}
	var primary := MapStore.new_map("primary", 12, 10, "orthogonal")
	var spare := MapStore.new_map("spare", 12, 10, "orthogonal")
	for map in [primary, spare]:
		var layer: String = map.meta.layers[0].id
		map.objects = [{"code": "GOAL", "asset": "door", "x": 10, "y": 2, "layer": layer},
			{"code": "LOAD", "asset": "switch", "x": 2, "y": 2, "layer": layer,
				"functions": [{"fn": "FLOW", "content": "middle"}]}]
		ok(MapStore.write(m, map.meta.name, map), "store a map with its own GOAL")
	ok(ContentStore.write(m, "flow", "middle", {"function": "FLOW", "fields": {"NEXT": "finish", "FREE": "free"}}),
		"save shared flow with an inherited and an independent branch")
	ok(ContentStore.write(m, "flow", "finish", {"function": "FLOW", "fields": {"NEXT": "middle", "LOCL": "GOAL"}}),
		"save a cycle returning to the previous record")
	ok(ContentStore.write(m, "flow", "free", {"function": "FLOW", "fields": {"LOCL": "GOAL"}}),
		"save independent flow without an inferred map")
	ok(ContentStore.write(m, "entry", "boot", {"function": "BOOT", "scope": "project", "steps": [
		{"step": "STEP", "fields": {"ROWS": [{"DMAP": primary.meta.code, "DEST": "paired-only"}]}}]}),
		"save explicit map handoff from a standalone flow")
	ok(ContentStore.write(m, "flow", "paired-only", {"function": "FLOW", "fields": {"LOCL": "GOAL"}}),
		"save destination reached only by pairing")
	var crop: Dictionary = MapResize.plan(primary, 8, 8, false).map
	var result := ProjectAudit.map_change_reference_impacts(m, "primary", primary, crop)
	var messages := "\n".join(result.added)
	eq(result.added.size(), 2, "one invalid reference for each route mode: " + messages)
	ok(messages.contains("flow/finish.local · 地图 primary") and messages.contains("flow/paired-only.local · 地图 primary")
		and not messages.contains("flow/free") and not messages.contains("spare"), "inheritance only follows declared routes")
	ok(MapStore.write(m, "primary", crop), "publish the changed map")
	var audit := ProjectAudit.audit(m)
	ok(audit.any(func(issue): return str(issue.path).contains("flow/finish.local · 地图 primary")),
		"project audit sees indirect dangling refs after publish")
	m.steps.route.fields[0].fields[1].mapField = "not_in_this_row"
	ok(V.validate(m).any(func(issue): return str(issue.path).ends_with("destination.contentMapContext")),
		"paired layout rejects a missing sibling map field")
	_wipe()

func test_map_change_checks_steps_staging_and_recovery_contexts() -> void:
	_wipe()
	var m := _fake_manifest()
	m.assets = [{"id": "door", "kind": "entity"},
		{"id": "switch", "kind": "entity", "functions": ["route"]}]
	m.functions = {"route": {"code": "ROUT", "name": "Route", "steps": true, "fields": [
		{"id": "destination", "code": "DEST", "type": "entity_ref"}]}}
	m.steps = {"jump": {"code": "JUMP", "name": "Jump", "fields": [
		{"id": "routes", "code": "ROWS", "type": "array", "of": "record", "fields": [
			{"id": "map", "code": "MAP1", "type": "map_ref"},
			{"id": "edge", "code": "EDGE", "type": "edge_ref", "mapField": "map"}]}]}}
	var live := MapStore.new_map("resize", 12, 10, "orthogonal")
	var other := MapStore.new_map("other", 12, 10, "orthogonal")
	var lid: String = live.meta.layers[0].id
	live.objects = [
		{"code": "DROP", "asset": "door", "x": 10, "y": 2, "layer": lid},
		{"code": "HOLD", "asset": "switch", "x": 1, "y": 2, "layer": lid,
			"functions": [{"fn": "ROUT", "content": "local"}, {"fn": "ROUT", "content": "staged"}]}]
	ok(MapStore.write(m, "resize", live), "store resize target")
	var step := {"step": "JUMP", "fields": {"ROWS": [{"MAP1": live.meta.code,
		"EDGE": Edge.value_of("", Vector2i(7, 3), Vector2i(8, 3))}]}}
	var local := {"function": "ROUT", "fields": {"DEST": "DROP"}, "steps": [step]}
	ok(ContentStore.write(m, "route", "local", local), "store bound record")
	var project := {"function": "ROUT", "scope": "project", "fields": {"DEST": "UNKNOWN"},
		"steps": [step]}
	ok(ContentStore.write(m, "route", "project", project), "store standalone flow with explicit map")
	var source := {"function": "ROUT", "fields": {"DEST": "UNKNOWN"}, "steps": [step]}
	var draft_path := MapStore.Recovery.write_draft(m, other.meta.code, "other",
		MapStore.path_for(m, "other"), "", other, [{"fn_id": "route", "id": "future", "data": source}])
	ok(draft_path != "", "store draft pending flow")
	var staged := [{"fn_id": "route", "cid": "staged", "data": local}]
	var crop: Dictionary = MapResize.plan(live, 8, 8, false).map
	var result := ProjectAudit.map_change_reference_impacts(m, "resize", live, crop, staged)
	var paths := "\n".join(result.added)
	eq(result.added.size(), 6, "bound, standalone, staged and draft refs only: " + paths)
	ok(paths.contains("route/local.destination") and paths.contains("route/project.steps[0].routes#0.edge")
		and paths.contains("当前暂存 · route/staged.destination")
		and paths.contains("route/future.steps[0].routes#0.edge") and not paths.contains("UNKNOWN"),
		"references use coded fields, local binding contexts and explicit cross-map parents")
	eq(result.unreadable, [], "all input files readable")
	m.assets[0].fields = [{"id": "boundary", "type": "edge_ref"}]
	var cross_edge := Edge.value_of(live.meta.code, Vector2i(7, 3), Vector2i(8, 3))
	other.objects = [{"code": "PEER", "asset": "door", "x": 0, "y": 0,
		"layer": other.meta.layers[0].id, "props": {"boundary": cross_edge}}]
	ok(MapStore.write(m, "other", other), "save a map with an incoming rule edge")
	live.objects[0].props = {"boundary": cross_edge}
	var grid := ViewData.effective_grid(live, m)
	var area := Rect2(118, 48, 20, 16)
	var size := Vector2i(12, 10)
	var mapper := Edge.region_mapper(grid, size, Transform2D.IDENTITY, area,
		grid, size, Transform2D.IDENTITY, area.position - Vector2(16, 0))
	var retained := ProjectAudit.retained_region_edge_refs(m, "resize", live, mapper, staged)
	var edges := "\n".join(retained.retained)
	eq(retained.retained.size(), 5, "five external sources keep the original edge: " + edges)
	ok(edges.contains("other · door(PEER).boundary") and edges.contains("route/local.steps[0].routes#0.edge")
		and edges.contains("route/project.steps[0].routes#0.edge") and edges.contains("当前暂存 · route/staged")
		and edges.contains("route/future.steps[0].routes#0.edge") and not edges.contains("door(DROP)"),
		"the changed map's live props are excluded while maps, steps, staging and recovery have concrete paths")
	_wipe()

# ──────────── 挂载去重与补齐（C09） ────────────

## 重复挂载 = 清单错误（不静默别名），运行期 entity_mounts 也去重兜底
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

## 两个功能共用同一内容 ID 尾码：引用只算在命中的那个功能名下
func test_used_content_index_is_per_function() -> void:
	_wipe()
	var m := _fake_manifest()
	m["functions"] = {
		"f1": {"name": "F1", "code": "F111", "fields": []},
		"f2": {"name": "F2", "code": "F222", "fields": []},
	}
	ok(ContentStore.write(m, "f1", "AAA1", {"name": "a", "function": "F111", "fields": {}}), "f1 内容写入")
	ok(ContentStore.write(m, "f2", "AAA1", {"name": "b", "function": "F222", "fields": {}}), "f2 同尾码内容写入")
	var used := {}
	var missing: Array = []
	ProjectAudit._collect_used_content({"objects": [
		{"code": "E1", "asset": "door", "functions": [{"fn": "F111", "content": "AAA1"}]},
	]}, m, used, missing, "m1")
	eq(missing.size(), 0, "绑定文件存在 → 无缺失条目")
	ok(used.has(ProjectAudit._content_key("f1", "AAA1")), "命中的功能名被索引")
	ok(not used.has(ProjectAudit._content_key("f2", "AAA1")), "同尾码的另一个功能不被算作已引用")
	# f2/AAA1 因此应报孤立内容
	var orphan_f2 := 0
	for e in ProjectAudit._content_checks(m, used):
		if str(e.get("path", "")) == "f2/AAA1" and str(e.get("message", "")).contains("孤立"):
			orphan_f2 += 1
	eq(orphan_f2, 1, "同尾码在另一功能名下仍报孤立")
	_wipe()

## 绑定指向的内容文件不存在 → 审计显形
func test_binding_missing_reported() -> void:
	_wipe()
	var m := _fake_manifest()
	m["functions"] = {"f1": {"name": "F1", "code": "F111", "fields": []}}
	var used := {}
	var missing: Array = []
	ProjectAudit._collect_used_content({"objects": [
		{"code": "E1", "asset": "door", "functions": [{"fn": "F111", "content": "NOPE"}]},
	]}, m, used, missing, "m1")
	eq(missing.size(), 1, "绑定目标文件缺失报一条")
	if missing.size() == 1:
		ok(str((missing[0] as Dictionary).get("message", "")).contains("NOPE"), "消息带内容 ID")
	_wipe()

## 两图同实例码：引用按配对地图解析，本图不误判（C1 已测）；此处验收审计层不串图
func test_same_instance_code_two_maps() -> void:
	_wipe()
	var m := _fake_manifest()
	m["assets"] = [{"id": "door", "kind": "entity", "fields": [{"id": "TGT", "type": "entity_ref"}]}]
	var a := MapStore.new_map("a", 8, 8)
	var b := MapStore.new_map("b", 8, 8)
	(a.meta as Dictionary)["code"] = "AAAA"
	(b.meta as Dictionary)["code"] = "BBBB"
	# 两图都有同码实例 X1
	(a.objects as Array).append({"asset": "door", "code": "X1", "layer": str(a.meta.layers[0].id), "x": 0, "y": 0})
	(b.objects as Array).append({"asset": "door", "code": "X1", "layer": str(b.meta.layers[0].id), "x": 0, "y": 0})
	# a 图里的引用指向 X1（本图存在）→ 不报
	(a.objects as Array).append({"asset": "door", "code": "A2", "layer": str(a.meta.layers[0].id),
		"x": 1, "y": 0, "props": {"TGT": "X1"}})
	eq(ProjectAudit._ref_checks(a, m, "a").size(), 0, "同码实例在本图存在 → 不报悬空")
	_wipe()

## 挂载缺失与时机白名单：数据层检查显形（不自动改）
func test_binding_checks_mount_and_trigger() -> void:
	var m := _fake_manifest()
	m["functions"] = {"f1": {"name": "F1", "code": "F111", "fields": [], "triggers": ["t1"]}}
	m["triggers"] = {"t1": {"name": "开场", "code": "T111"}, "t2": {"name": "结束", "code": "T222"}}
	m["assets"] = [{"id": "door", "kind": "entity", "prefab": "res://d.tscn", "functions": ["f1"]}]
	var data := {"objects": [
		{"code": "E1", "asset": "door", "functions": []},   # 挂载缺失
		{"code": "E2", "asset": "door", "functions": [
			{"fn": "F111", "content": "", "trigger": "T222"}]},   # 时机不在白名单
		{"code": "E3", "asset": "door", "functions": [
			{"fn": "F111", "content": "", "trigger": "T111"}]},   # 合法
	]}
	var out := ProjectAudit._binding_checks(data, m, "m1")
	eq(out.size(), 2, "挂载缺失 + 时机越界各一条：%s" % str(out))
	var mount_msg := 0
	var trg_msg := 0
	for e in out:
		var msg := str((e as Dictionary).get("message", ""))
		if msg.contains("挂载缺失"):
			mount_msg += 1
		if msg.contains("时机不在白名单"):
			trg_msg += 1
	eq(mount_msg, 1, "挂载缺失条目")
	eq(trg_msg, 1, "时机越界条目")

## 步骤池与内容池字段引用（C12）：非法步骤码、不存在的内容引用
func test_content_ref_checks_steps_and_content_pool() -> void:
	_wipe()
	var m := _fake_manifest()
	m["functions"] = {"show": {"name": "演出", "code": "S111", "steps": true, "fields": [
		{"id": "next", "code": "N111", "kind": "choice", "type": "string", "source": "content:show"},
	]}}
	m["steps"] = [{"id": "move", "code": "M111", "name": "移动", "fields": []}]
	ok(ContentStore.write(m, "show", "GOOD1", {"name": "g", "function": "S111", "fields": {}}), "被引用内容写入")
	var bad := {
		"name": "b", "function": "S111",
		"fields": {"N111": "GONE1"},
		"steps": [{"step": "XXXX", "fields": {}}, {"step": "M111", "fields": {}}],
	}
	var out := ProjectAudit._content_ref_checks(m, "show", "BAD01", bad)
	var bad_step := 0
	var bad_content := 0
	for e in out:
		var msg := str((e as Dictionary).get("message", ""))
		if msg.contains("步骤码不在清单步骤池里"):
			bad_step += 1
		if msg.contains("引用的内容不存在"):
			bad_content += 1
	eq(bad_step, 1, "非法步骤码报一条（合法的 M111 不报）")
	eq(bad_content, 1, "不存在的内容引用报一条")
	# 合法内容零问题
	var good := {"name": "g", "function": "S111", "fields": {"N111": "GOOD1"},
		"steps": [{"step": "M111", "fields": {}}]}
	eq(ProjectAudit._content_ref_checks(m, "show", "GOOD1", good).size(), 0, "合法引用零问题")
	_wipe()

# ──────────── 安全清理（D07） ────────────

func _dangling_map(m: Dictionary) -> Dictionary:
	m["assets"] = [{"id": "door", "kind": "entity", "fields": [{"id": "TGT", "type": "entity_ref"}]}]
	var d := MapStore.new_map("m1", 8, 8)
	var lid := str(d.meta.layers[0].id)
	(d.objects as Array).append({"asset": "door", "code": "A1", "layer": lid, "x": 0, "y": 0,
		"props": {"TGT": "GGGG"}})
	(d.objects as Array).append({"asset": "door", "code": "B1", "layer": lid, "x": 1, "y": 0,
		"props": {"TGT": "HHHH"}})
	MapStore.write(m, "m1", d)
	return d

## 过期报告：一个字段已被修好（目标补上了对象）→ 清理跳过它，只清仍悬空的那条
func test_stale_report_skips_repaired_field() -> void:
	_wipe()
	var m := _fake_manifest()
	_dangling_map(m)
	var d := MapStore.read(m, "m1")
	var fixes: Array = []
	for e in ProjectAudit._ref_checks(d, m, "m1"):
		fixes.append((e as Dictionary).get("fix"))
	eq(fixes.size(), 2, "初始两条悬空")
	# 期间修好 B1：补一个 HHHH 实例
	(d.objects as Array).append({"asset": "door", "code": "HHHH", "layer": str(d.meta.layers[0].id), "x": 5, "y": 5})
	var res := ProjectAudit.apply_ref_fixes(m, "m1", fixes, d)
	eq(int(res.get("erased", 0)), 1, "只清掉仍悬空的 A1.TGT")
	eq(int(res.get("skipped", 0)), 1, "已修好的 B1.TGT 跳过")
	for o in (d.objects as Array):
		if str((o as Dictionary).get("code", "")) == "A1":
			ok(not ((o as Dictionary).get("props", {}) as Dictionary).has("TGT"), "A1 字段被清")
		if str((o as Dictionary).get("code", "")) == "B1":
			eq(str(((o as Dictionary).get("props", {}) as Dictionary).get("TGT", "")), "HHHH", "B1 已修值不变")
	_wipe()

## 字段已被改成别的值（也仍悬空）→ 报告过期，不按旧值清
func test_stale_report_skips_changed_value() -> void:
	_wipe()
	var m := _fake_manifest()
	var d := _dangling_map(m)
	var fixes: Array = []
	for e in ProjectAudit._ref_checks(d, m, "m1"):
		if str(((e as Dictionary).get("fix", {}) as Dictionary).get("code", "")) == "A1":
			fixes.append((e as Dictionary).get("fix"))
	eq(fixes.size(), 1, "拿到 A1 的修复项")
	# 期间作者把 A1 指向改成了另一个仍悬空的码
	for o in (d.objects as Array):
		if str((o as Dictionary).get("code", "")) == "A1":
			((o as Dictionary).get("props", {}) as Dictionary)["TGT"] = "ZZZZ"
	var res := ProjectAudit.apply_ref_fixes(m, "m1", fixes, d)
	eq(int(res.get("erased", 0)), 0, "值变过 → 不清")
	eq(int(res.get("skipped", 0)), 1, "记一次跳过")
	_wipe()

## §7.2：清除悬空引用时配对地图字段不能无脑删——还有别的引用字段用它就保留。
func test_clear_dangling_keeps_still_used_pair_map() -> void:
	_wipe()
	var m := _fake_manifest()
	# door 有两个引用字段共用同一个配对地图字段 TGTMAP
	m["assets"] = [{"id": "door", "kind": "entity", "fields": [
		{"id": "TGT", "type": "entity_ref", "mapField": "TGTMAP"},
		{"id": "TGT2", "type": "entity_ref", "mapField": "TGTMAP"},
		{"id": "TGTMAP", "type": "map_ref"},
	]}]
	var d := MapStore.new_map("m1", 8, 8)
	var lid := str(d.meta.layers[0].id)
	# A1：TGT 悬空、TGT2 有效（指向本图 KEEP）→ TGTMAP 必须保留
	(d.objects as Array).append({"asset": "door", "code": "A1", "layer": lid, "x": 0, "y": 0,
		"props": {"TGT": "GONE", "TGT2": "KEEP", "TGTMAP": "m1"}})
	# B1：两个引用都悬空 → 清掉两条后 TGTMAP 无人使用，可以删
	(d.objects as Array).append({"asset": "door", "code": "B1", "layer": lid, "x": 1, "y": 0,
		"props": {"TGT": "GONE2", "TGT2": "GONE3", "TGTMAP": "m1"}})
	(d.objects as Array).append({"asset": "door", "code": "KEEP", "layer": lid, "x": 2, "y": 0})
	MapStore.write(m, "m1", d)   # 配对图目标要能从磁盘解析出来（KEEP 才算有效引用）
	var fixes: Array = []
	for e in ProjectAudit._ref_checks(d, m, "m1"):
		fixes.append((e as Dictionary).get("fix"))
	ok(fixes.size() >= 3, "拿到全部悬空修复项（实得 %d）" % fixes.size())
	var res := ProjectAudit.apply_ref_fixes(m, "m1", fixes, d)
	ok(int(res.get("erased", 0)) >= 3, "至少清掉 3 个引用字段")
	for o in (d.objects as Array):
		var od: Dictionary = o
		var props: Dictionary = od.get("props", {})
		if str(od.get("code", "")) == "A1":
			eq(str(props.get("TGTMAP", "")), "m1", "TGT2 还在用配对地图 → TGTMAP 保留")
			eq(str(props.get("TGT2", "")), "KEEP", "有效引用不动")
		if str(od.get("code", "")) == "B1":
			ok(not props.has("TGT"), "B1.TGT 已清")
			ok(not props.has("TGTMAP"), "两个引用都没了 → 配对地图字段一并清理")
	_wipe()

## 写失败不计数：清除项落地在内存里，但 MapStore.write 失败时成功数不增加
func test_clear_write_failure_not_counted() -> void:
	_wipe()
	var m := _fake_manifest()
	var d := _dangling_map(m)
	var fixes: Array = []
	for e in ProjectAudit._ref_checks(d, m, "m1"):
		fixes.append((e as Dictionary).get("fix"))
	# 注入写失败：写盘注入口命中该图（唯一临时名之后无法再靠占用 .tmp 路径）
	MapStore.test_fail_prefix = str(m._maps_dir).path_join("m1.json")
	var res := ProjectAudit.apply_ref_fixes(m, "m1", fixes, d)
	eq(int(res.get("erased", 0)), 2, "内存里两条都清")
	ok(not MapStore.write(m, "m1", d), "写盘被注入失败")
	MapStore.test_fail_prefix = ""
	var disk := MapStore.read(m, "m1")
	for o in (disk.objects as Array):
		if str((o as Dictionary).get("code", "")) == "A1":
			eq(str(((o as Dictionary).get("props", {}) as Dictionary).get("TGT", "")), "GGGG",
				"磁盘字段未变（失败不算成功）")
	_wipe()

## 检查范围不完整：有地图读不出来 → meta 标 incomplete（UI 据此禁用清除）
func test_audit_marks_incomplete_on_unreadable_map() -> void:
	_wipe()
	var m := _fake_manifest()
	_dangling_map(m)
	DirAccess.make_dir_recursive_absolute(str(m._maps_dir))
	# 造一个坏 JSON 地图文件
	var f := FileAccess.open(str(m._maps_dir).path_join("broken.json"), FileAccess.WRITE)
	f.store_string("{ not json")
	f.close()
	var meta := {}
	ProjectAudit.audit(m, meta)
	eq(bool(meta.get("incomplete", false)), true, "读不出的地图让检查范围不完整")
	ok((meta.get("unreadable_maps", []) as Array).has("broken"), "列出读不出的图名")
	_wipe()

# ──────────── 解绑/撤销与内容留存 ────────────

## 配对地图解析不出（码不存在）：只由 map_ref 报一条，不逐引用重复报（目标域未知 ≠ 每个引用都悬空）
func test_paired_map_unknown_reports_once() -> void:
	var m := _fake_manifest()
	m["assets"] = [{"id": "switch", "kind": "entity", "fields": [
		{"id": "target_map", "type": "map_ref"},
		{"id": "target", "type": "entity_ref", "mapField": "target_map"},
	]}]
	var data := {"objects": [
		{"code": "S1", "asset": "switch", "props": {"target_map": "ZZZZ", "target": "T1"}},
		{"code": "S2", "asset": "switch", "props": {"target_map": "ZZZZ", "target": "T2"}},
	]}
	var out := ProjectAudit._ref_checks(data, m, "m1")
	eq(out.size(), 2, "两个 map_ref 各一条（entity_ref 不重复报）")
	for e in out:
		ok(str((e as Dictionary).get("message", "")).contains("目标地图不存在"), "只有 map_ref 条目")

# ──────────── 使用统计（C3） ────────────

## E3 内容库删除前的引用检查：实例引用（含当前图未保存绑定）与内容间引用都显形
func test_content_usage_and_inbound_refs() -> void:
	_wipe()
	var m := _fake_manifest()
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
	var u := ProjectAudit.content_usage(m, "f1", "AAA1")
	var by_map: Dictionary = u.get("by_map", {})
	eq(by_map.size(), 1, "统计到一张图")
	eq((by_map["m1"] as Array).size(), 1, "只算功能码匹配的那个实例（同内容 ID 的另一功能不算）")
	ok((by_map["m1"] as Array).has("E1"), "实例码正确")
	# 当前图以画布为准：磁盘上没引用、画布上新绑的也算
	var u2 := ProjectAudit.content_usage(m, "f1", "AAA1", "m1", ["E9"])
	ok(((u2.get("by_map", {}) as Dictionary)["m1"] as Array).has("E9"), "当前画布未保存绑定计入")
	# 内容间引用：BBB2 的字段指向 AAA1
	var inbound := ProjectAudit.content_inbound_refs(m, "f1", "AAA1")
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

## 使用统计与引用自检同源：坏图显形为 incomplete，不假装零引用
func test_asset_usage_reports_unreadable() -> void:
	_wipe()
	var m := _fake_manifest()
	var d := MapStore.new_map("m1", 8, 8)
	(d.objects as Array).append({"asset": "door", "code": "D1", "layer": str(d.meta.layers[0].id), "x": 2, "y": 3})
	MapStore.write(m, "m1", d)
	var u := ProjectAudit.asset_usage(m, "door")
	eq((u.get("by_map", {}) as Dictionary).size(), 1, "统计到一张图")
	eq(((u.get("by_map", {}) as Dictionary)["m1"] as Array).size(), 1, "统计到一个实例")
	ok(not bool(u.get("incomplete", false)), "全部可读 = 完整")
	# 当前图 = 磁盘行 ∪ 画布行（V4 P0-4：磁盘正式文件里的绑定不能因画布解绑而消失）
	u = ProjectAudit.asset_usage(m, "door", "m1", [{"id": "D9", "x": 9, "y": 9}])
	var cur_rows: Array = (u.get("by_map", {}) as Dictionary)["m1"]
	var ids: Array = []
	for r in cur_rows:
		ids.append(str((r as Dictionary).get("id", "")))
	ok(ids.has("D1"), "当前图磁盘行保留：%s" % str(ids))
	ok(ids.has("D9"), "当前图画布行并入：%s" % str(ids))
	# 注入坏图
	var f := FileAccess.open(str(m._maps_dir).path_join("bad.json"), FileAccess.WRITE)
	f.store_string("{oops")
	f.close()
	u = ProjectAudit.asset_usage(m, "door")
	ok(bool(u.get("incomplete", false)), "坏图让统计标记不完整")
	ok((u.get("unreadable", []) as Array).has("bad"), "列出坏图名")
	_wipe()

## 解绑后内容文件仍在库里；绑定重新加回 → 引用索引恢复（同一批数据源）
func test_unbind_keeps_content_and_rebinds() -> void:
	_wipe()
	var m := _fake_manifest()
	m["functions"] = {"f1": {"name": "F1", "code": "F111", "fields": []}}
	ok(ContentStore.write(m, "f1", "KEEP1", {"name": "k", "function": "F111", "fields": {}}), "内容写入")
	var used := {}
	var missing: Array = []
	ProjectAudit._collect_used_content({"objects": [{"code": "E1", "asset": "door",
		"functions": [{"fn": "F111", "content": "KEEP1"}]}]}, m, used, missing, "m1")
	ok(used.has(ProjectAudit._content_key("f1", "KEEP1")), "绑定存在 → 有入边")
	# 解绑
	used = {}
	ProjectAudit._collect_used_content({"objects": [{"code": "E1", "asset": "door", "functions": []}]},
		m, used, missing, "m1")
	ok(not used.has(ProjectAudit._content_key("f1", "KEEP1")), "解绑 → 零入边")
	ok(ContentStore.read(m, "f1", "KEEP1").size() > 0, "内容文件仍在库里")
	# 撤销 = 绑定恢复 → 入边恢复
	used = {}
	ProjectAudit._collect_used_content({"objects": [{"code": "E1", "asset": "door",
		"functions": [{"fn": "F111", "content": "KEEP1"}]}]}, m, used, missing, "m1")
	ok(used.has(ProjectAudit._content_key("f1", "KEEP1")), "撤销后入边恢复")
	_wipe()
