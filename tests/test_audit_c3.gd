extends "res://tests/_suite_base.gd"
## C3：挂载去重/补齐、按 (功能 id, 内容 ID) 索引的引用自检、过期报告的安全清理。

const ProjectAudit := preload("res://src/project/project_audit.gd")
const MapStore := preload("res://src/map/map_store.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const FunctionDecls := preload("res://src/content/function_decl.gd")
const V := preload("res://src/project/manifest_validation.gd")
const ContentId := preload("res://src/content/content_id.gd")

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

## 写失败不计数：清除项落地在内存里，但 MapStore.write 失败时成功数不增加
func test_clear_write_failure_not_counted() -> void:
	_wipe()
	var m := _fake_manifest()
	var d := _dangling_map(m)
	var fixes: Array = []
	for e in ProjectAudit._ref_checks(d, m, "m1"):
		fixes.append((e as Dictionary).get("fix"))
	# 注入写失败：目标 .tmp 变成目录 → 原子替换必失败
	DirAccess.make_dir_recursive_absolute(str(m._maps_dir).path_join("m1.json.tmp"))
	var res := ProjectAudit.apply_ref_fixes(m, "m1", fixes, d)
	eq(int(res.get("erased", 0)), 2, "内存里两条都清")
	ok(not MapStore.write(m, "m1", d), "写盘被注入失败")
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
	# 当前图用画布行覆盖磁盘
	u = ProjectAudit.asset_usage(m, "door", "m1", [{"id": "D9", "x": 9, "y": 9}])
	eq(str(((u.get("by_map", {}) as Dictionary)["m1"] as Array)[0].get("id", "")), "D9", "当前图以画布为准")
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
