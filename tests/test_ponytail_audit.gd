extends "res://tests/_suite_base.gd"

const Store := preload("res://src/content/content_store.gd")
const Maps := preload("res://src/map/map_store.gd")
const Recovery := preload("res://src/map/recovery.gd")
const Workbench := preload("res://src/mcp/workbench.gd")
const Check := preload("res://src/project/project_data_check.gd")
const Spatial := preload("res://src/project/spatial_reference_check.gd")
const Undo := preload("res://src/core/undo_history.gd")
const App := preload("res://src/app.gd")

class Host extends Control:
	var manifest: Dictionary

func _host() -> Host:
	var host := Host.new()
	var dir := "user://audit-test-" + str(Time.get_ticks_usec())
	host.manifest = {"_dir": dir, "_maps_dir": dir.path_join("maps"), "_manifest_digest": "",
		"projectName": "Audit", "tileSize": 16, "contentDir": "content",
		"assets": [{"id": "marker", "code": "EN01", "kind": "entity", "prefab": "Marker.tscn"}],
		"functions": {
			"sequence": {"code": "FSEQ", "steps": true, "fields": [
				{"id": "destination", "code": "DEST", "kind": "choice", "source": "map"},
				{"id": "branch", "code": "BRAN", "kind": "choice", "source": "content:target",
					"contentMapContext": "paired", "mapField": "destination"},
				{"id": "duration", "code": "DURA", "kind": "input", "type": "int"}]},
			"target": {"code": "FTGT", "fields": [
				{"id": "marker", "code": "MARK", "kind": "choice", "source": "entity_inst:marker"},
				{"id": "loop", "code": "LOOP", "kind": "choice", "source": "content:sequence", "contentMapContext": "inherit"}]}},
		"steps": {"wait": {"code": "S001", "fields": [{"id": "blocking", "code": "BOOL", "kind": "input", "type": "bool"}]}}}
	return host

func _map_data(name_: String, code: String) -> Dictionary:
	var data := Maps.new_map(name_, 20, 20)
	data.meta.code = code
	return data

func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for file in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(file))
	for folder in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(folder))
	DirAccess.remove_absolute(dir)

func _done(host: Host, work: RefCounted) -> void:
	_wipe(work.drafts.folder())
	_wipe(host.manifest._dir)
	host.free()

func test_bad_values_fail_preflight_and_good_values_keep_extensions() -> void:
	var host := _host()
	var work := Workbench.new(host)
	var draft: Dictionary = work.drafts.manage({"action": "create"})
	var bad := {"fields": {"DURA": "oops"}, "steps": [42, {"step": "ZZZZ"}, {"step": "S001",
		"fields": {"BOOL": "false"}, "at": -1, "track": 0.5, "blocking": 1}]}
	var changed: Dictionary = work.edits.apply(work.drafts.read(draft.id), [
		{"op": "content.put", "function": "sequence", "data": bad}])
	var cid: String = changed.ids[0].id
	var row: Dictionary = work.drafts.read(draft.id)
	var batch: Dictionary = work.drafts.state(row)
	var checked: Dictionary = work._validate({}, batch)
	eq(checked.valid, false, "错误数据不能发布")
	var paths: Array = checked.issues.map(func(issue): return issue.path)
	for tail in ["fields.DURA", "steps[0]", "steps[1].step", "steps[2].fields.BOOL",
			"steps[2].at", "steps[2].track", "steps[2].blocking"]:
		ok(paths.has("content.sequence." + cid + "." + tail), tail)
	var repaired: Dictionary = work.edits.apply(row, [{"op": "content.put", "function": "sequence", "content": cid,
		"data": {"fields": {"DURA": 3.0, "EXT": {"game": true}}, "steps": [{"step": "S001",
			"fields": {"BOOL": false}, "custom": 15}]}}])
	eq(repaired.revision, 2, "允许在草稿修复保留的值")
	var candidate: Dictionary = work.drafts.candidate(work.drafts.state(work.drafts.read(draft.id)))
	eq(Check.check(candidate).valid, true, "同一项目层检查接受修复和扩展键")
	eq(Store.read(candidate, "sequence", cid).fields.EXT.game, true, "保留游戏扩展")
	_done(host, work)

func test_paired_context_reaches_unbound_branch_and_cycles() -> void:
	var host := _host()
	var work := Workbench.new(host)
	var m := host.manifest
	var alpha := _map_data("Alpha", "MAPA")
	var beta := _map_data("Beta", "MAPB")
	beta.objects = [{"asset": "marker", "code": "M001", "x": 3, "y": 4}]
	ok(Maps.write(m, "Alpha", alpha) and Maps.write(m, "Beta", beta), "测试地图")
	ok(Store.write(m, "sequence", "project-a", {"fields": {"DEST": "MAPB", "BRAN": "project-b"}}), "项目分支")
	ok(Store.write(m, "target", "project-b", {"fields": {"MARK": "M001", "LOOP": "project-a"}}), "循环分支")
	eq(Check.check(m).valid, true, "使用配对图的目标")
	var removed := beta.duplicate(true)
	removed.objects.clear()
	ok(Spatial.blocked_removals(m, beta, removed, []).contains("project-b"), "人工删除目标实例时定位分支")
	m["_map_overrides"] = {"Beta": removed}
	var scoped := Check.check(m, {"map": "MAPA", "function": "target", "content": "project-b"})
	var failed: Array = scoped.issues.filter(func(issue): return issue.get("map") == "MAPB")
	eq(failed.size(), 1, "局部预检也检查实际配对图")
	_done(host, work)

func test_publish_reports_commit_then_retries_cleanup_without_rewriting() -> void:
	var host := _host()
	var work := Workbench.new(host)
	var draft: Dictionary = work.drafts.manage({"action": "create"})
	var changed: Dictionary = work.edits.apply(work.drafts.read(draft.id), [
		{"op": "content.put", "function": "sequence", "data": {"name": "published", "fields": {"DURA": 1}}}])
	var row: Dictionary = work.drafts.read(draft.id)
	var plan: Dictionary = work.drafts.plan(row, work.drafts.state(row))
	var block: String = work.drafts.folder().path_join(draft.id).path_join("2.json")
	eq(DirAccess.make_dir_recursive_absolute(block), OK, "只阻断下一份草稿索引")
	var result: Dictionary = work.drafts.publish(row, plan)
	eq(result.get("published"), true, "正式写入结果单独报告")
	eq(result.get("cleanupPending"), true, "另报草稿整理未完成")
	var cid: String = changed.ids[0].id
	var path := Store.path_for(host.manifest, "sequence", cid)
	var digest := Recovery.digest(path)
	ok(digest != "" and Store.read(host.manifest, "sequence", cid).name == "published", "游戏文件已写入")
	var receipt: Dictionary = work.drafts.completed_publish(work.drafts.read(draft.id))
	ok(not receipt.is_empty(), "下次调用仍能找到原发布回执")
	DirAccess.remove_absolute(block)
	var done: Dictionary = work.drafts.finish_publish(work.drafts.read(draft.id), receipt.files, receipt.pending)
	eq(done.revision, 2, "重试只完成整理")
	eq(Recovery.digest(path), digest, "正式文件没再写")
	eq(Recovery.scan_pending(host.manifest).size(), 0, "回执整理完成")
	eq(work.drafts.last_publish(work.drafts.read(draft.id)).publishedRevision, 1, "重复请求仍能确认原版本已发布")
	_done(host, work)

func test_draft_reuses_map_document_and_reclaims_pruned_bodies() -> void:
	var host := _host()
	var work := Workbench.new(host)
	var draft: Dictionary = work.drafts.manage({"action": "create"})
	var created: Dictionary = work.edits.apply(work.drafts.read(draft.id), [{"op": "map.create", "name": "Alpha"}])
	var code: String = created.ids[0].id
	var dir: String = work.drafts.folder().path_join(draft.id)
	var first := Recovery.read_json(dir.path_join("1.json"))
	var added: Dictionary = work.edits.apply(work.drafts.read(draft.id), [
		{"op": "content.put", "function": "sequence", "data": {"name": "test", "fields": {"DURA": 1}}}])
	var second := Recovery.read_json(dir.path_join("2.json"))
	eq(second.documents.maps[code], first.documents.maps[code], "内容修改不写地图正文")
	ok(FileAccess.get_size(dir.path_join("2.json")) < FileAccess.get_size(dir.path_join("body-" + first.documents.maps[code] + ".json")), "版本索引小于地图正文")
	eq(work.drafts.manage({"action": "undo", "draft": draft.id, "revision": added.revision}).revision, 3, "撤销")
	eq(work.drafts.manage({"action": "redo", "draft": draft.id, "revision": 3}).revision, 4, "重做")
	eq(work.drafts.manage({"action": "undo", "draft": draft.id, "revision": 4}).revision, 5, "再撤销")
	var branch: Dictionary = work.edits.apply(work.drafts.read(draft.id), [
		{"op": "map.patch", "map": code, "data": {"spawn": [5, 5]}}])
	var body: String = second.documents.contents.values()[0]
	eq(branch.revision, 6, "重开版本分支")
	ok(not FileAccess.file_exists(dir.path_join("body-" + body + ".json")), "回收不可到达的旧正文")
	eq(work.drafts.state(work.drafts.read(draft.id)).maps[code].data.spawn, [5.0, 5.0], "仍可独立读取新版本")
	_done(host, work)

func test_large_draft_only_writes_changed_content_and_index() -> void:
	var host := _host()
	var work := Workbench.new(host)
	var draft: Dictionary = work.drafts.manage({"action": "create"})
	var batch: Dictionary = work.drafts.state(work.drafts.read(draft.id))
	for i in 10:
		var cells := []
		for cell in 12000:
			cells.append([cell % 120, floori(float(cell) / 120), "tile-%d" % i, 0, 0, 0])
		batch.maps["map-%d" % i] = {"data": {"tiles": {"floor": cells}}}
	eq(work.drafts.append(work.drafts.read(draft.id), batch).revision, 1, "写 120,000 个格")
	var prior: Dictionary = work.drafts.shallow_batch(batch)
	batch.contents["sequence/example"] = {"data": {"fields": {"DURA": 2}}}
	eq(work.drafts.append(work.drafts.read(draft.id), batch, prior).revision, 2, "只改一个内容")
	var dir: String = work.drafts.folder().path_join(draft.id)
	var first := Recovery.read_json(dir.path_join("1.json"))
	var second := Recovery.read_json(dir.path_join("2.json"))
	eq(second.documents.maps, first.documents.maps, "十张地图的正文全部复用")
	eq(Array(DirAccess.get_files_at(dir)).filter(func(file): return file.begins_with("body-")).size(), 11, "只新增一份正文")
	ok(FileAccess.get_size(dir.path_join("2.json")) < 2000, "索引保持小于 2 KB")
	_done(host, work)

func test_thumbnail_survives_unrelated_saves_and_shares_same_file() -> void:
	var fixture := _host()
	var host := App.new()
	var base: String = fixture.manifest._dir
	DirAccess.make_dir_recursive_absolute(base)
	var img := Image.create_empty(16, 16, false, Image.FORMAT_RGBA8)
	img.fill(Color.RED)
	ok(img.save_png(base.path_join("icon.png")) == OK, "生成测试图片")
	host.manifest = {"_dir": base, "assets": [{"id": "a", "thumb": "icon.png"}, {"id": "b", "thumb": "icon.png"}]}
	var first := host._entity_thumbs()
	ok(first.a == first.b, "同文件复用纹理")
	ok(Maps.write_text(base.path_join("other.txt"), "unrelated"), "保存非资产内容")
	ok(first.a == host._entity_thumbs().a, "普通保存不重建纹理")
	eq(host._ent_thumbs_cache.size(), 1, "保留一份缓存")
	host.manifest.assets.clear()
	eq(host._entity_thumbs().size(), 0, "删除清单项后不再显示")
	eq(host._ent_thumbs_cache.size(), 0, "不再保留未使用纹理")
	host.free()
	_wipe(base)
	fixture.free()

func test_mcp_binding_order_default_layer_and_disabled_assets() -> void:
	var host := _host()
	var work := Workbench.new(host)
	var m := host.manifest
	var data := _map_data("Alpha", "MAPA")
	data.objects = [{"asset": "marker", "code": "M001", "x": 3, "y": 4, "functions": [
		{"bindingId": "A", "fn": "FSEQ", "order": 1}, {"bindingId": "B", "fn": "FTGT", "order": 2}]}]
	var first: String = data.meta.layers[0].id
	ok(Maps.write(m, "Alpha", data), "允许省略 layer")
	var query: Dictionary = work._objects(m, work.drafts.state({}), {"kind": "bindings", "map": "MAPA", "layer": first})
	eq(query.total, 2, "按实际落层查询")
	eq(query.items[0].layer, first, "绑定返回实际图层")
	var order: Dictionary = work.edits._binding(data, {"op": "binding.put", "instance": "M001", "binding": "B", "index": 0}, {})
	eq(order.get("id"), "B", "调整绑定成功")
	eq(data.objects[0].functions.map(func(row): return [row.bindingId, row.order]), [["B", 1], ["A", 2]], "位置等于游戏执行顺序")
	m.assets[0]["disabled"] = true
	ok(work.edits._instance(data, {"op": "instance.put"}, {"asset": "marker", "x": 2, "y": 2}).has("error"), "停用资产不能新放")
	ok(not work.edits._instance(data, {"op": "instance.put", "instance": "M001"}, {"x": 2}).has("error"), "旧资产可编辑")
	m.assets[0].erase("disabled")
	ok(not work.edits._instance(data, {"op": "instance.put"}, {"asset": "marker", "x": 2, "y": 2}).has("error"), "恢复启用后可放")
	_done(host, work)

func test_steps_write_uses_content_history_without_a_map() -> void:
	var fixture := _host()
	var host := App.new()
	var canvas := EditorCanvas.new()
	host.canvas = canvas
	host.manifest = fixture.manifest
	canvas.manifest = host.manifest
	canvas._undo_history_ctrl = Undo.new(canvas)
	var editor: RefCounted = preload("res://src/ui/content_editor.gd").new(host)
	var steps: RefCounted = editor._steps
	steps._project_target = true
	steps._project_manifest = host.manifest
	steps._steps_fn_id = "sequence"
	steps._steps_cid = "project-timeline"
	var id := "project-timeline"
	ok(Store.write(host.manifest, "sequence", id, {"steps": []}), "初始演出")
	var data: Dictionary = steps._steps_data()
	data.steps = [{"step": "S001"}]
	ok(steps._steps_write(data), "改动演出")
	canvas._undo_history_ctrl._push_entry({"kind": "ents"})
	eq(canvas._undo_history_ctrl.undo_content_only(false, "sequence", id), "done", "独立撤销演出")
	eq(Store.read(host.manifest, "sequence", id).steps, [], "写回原步骤")
	eq(canvas._undo_history_ctrl.undo_stack.back().kind, "ents", "地图历史未动")
	eq(canvas._undo_history_ctrl.undo_content_only(true, "sequence", id), "done", "独立重做")
	eq(Store.read(host.manifest, "sequence", id).steps.size(), 1, "步骤恢复")
	ok(Store.write(host.manifest, "sequence", id, {"steps": [], "external": true}), "模拟外部写入")
	eq(canvas._undo_history_ctrl.undo_content_only(false, "sequence", id), "refused", "拒绝覆盖外部内容")
	eq(Store.read(host.manifest, "sequence", id).external, true, "外部数据保留")
	canvas.free()
	host.free()
	_wipe(fixture.manifest._dir)
	fixture.free()
