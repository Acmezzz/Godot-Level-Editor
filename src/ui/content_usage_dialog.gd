extends RefCounted
## Select precise saved binding occurrences and produce a reviewable draft.

const Kit := preload("res://src/ui/ui_kit.gd")
const Store := preload("res://src/content/content_store.gd")
const Functions := preload("res://src/content/function_decl.gd")
const Usage := preload("res://src/project/reference_usage.gd")
const Drafts := preload("res://src/mcp/drafts.gd")

static func open(app, fn: String, from: String) -> void:
	var manifest: Dictionary = app.manifest
	var source := Store.read_ex(manifest, fn, from)
	if source.status != "ok":
		app._set_status("选中的内容不可读。")
		return
	var named := str(source.data.get("name", from))
	var shell: Dictionary = app._popup_body("查看使用处 / 批量改绑", named + " · " + from, true)
	var body: VBoxContainer = shell.body
	var pop: PopupPanel = shell.pop
	var usage := Usage.inbound_content(manifest, fn, from)
	var summary := Kit.hint_label("使用处：%d 张图 · %d 处内容字段 · %d 处屏幕 · %d 项项目/图组规则 · %d 个正式入口 · %d 份作者草稿" % [
		usage.edges.instances.size(), usage.edges.contents.size(), usage.edges.views.size(),
		usage.edges.project_slots.size(), usage.edges.startup.size(), usage.edges.drafts.size()], 600)
	body.add_child(summary)
	var target := OptionButton.new()
	target.fit_to_longest_item = false
	target.add_item("选择此功能的替换内容…")
	for id in Store.list_ids(manifest, fn):
		if id == from:
			continue
		var row := Store.read_ex(manifest, fn, id)
		if row.status == "ok":
			target.add_item("%s · %s" % [row.data.get("name", id), id])
			target.set_item_metadata(target.item_count - 1, id)
	body.add_child(Kit.field_row("改为", target, 74))
	var search := LineEdit.new()
	search.placeholder_text = "按地图或实例码筛选；勾选会跨筛选保留"
	body.add_child(search)
	var list := Tree.new()
	list.hide_root = true
	list.custom_minimum_size = Vector2(590, 270)
	body.add_child(list)
	var note := Kit.hint_label("只改勾选的正式实例绑定。其他引用可在流程关系中查看；先生成草稿，再核对和发布。", 600)
	body.add_child(note)
	var store := Drafts.new(app)
	var candidates := []
	var code: String = Functions.fn_code(manifest, fn)
	var names_to_code := app.MapStore.name_to_code(manifest) as Dictionary
	for name_ in usage.edges.instances:
		var map_code: String = names_to_code.get(name_, "")
		if map_code == "":
			continue
		var map := store.map_of({"maps": {}}, map_code)
		for obj in map.get("data", {}).get("objects", []):
			var bindings: Array = obj.get("functions", [])
			for index in bindings.size():
				var row: Dictionary = bindings[index]
				if row.get("fn") == code and row.get("content") == from:
					candidates.append({"map": map_code, "baseline": map.baseline,
						"instance": obj.code, "index": index, "id": row.get("bindingId", ""),
						"label": "%s · %s · #%d" % [name_, obj.code, index + 1]})
	var chosen := {}
	var refill := func():
		list.clear()
		var root := list.create_item()
		var query := search.text.strip_edges().to_lower()
		for i in candidates.size():
			var row: Dictionary = candidates[i]
			if query != "" and query not in row.label.to_lower():
				continue
			var item := list.create_item(root)
			item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
			item.set_text(0, row.label)
			item.set_editable(0, true)
			item.set_checked(0, chosen.has(i))
			item.set_metadata(0, i)
	list.item_edited.connect(func():
		var item := list.get_edited()
		var key: int = item.get_metadata(0)
		if item.is_checked(0):
			chosen[key] = true
		else:
			chosen.erase(key)
		note.text = "已选 %d 条正式绑定；未选中的引用保持原样。" % chosen.size())
	search.text_changed.connect(func(_value: String): refill.call())
	refill.call()
	var accept := func():
		if target.selected <= 0 or chosen.is_empty():
			note.text = "请选择替换内容，并至少勾选一条使用处。"
			return
		var dest: String = target.get_selected_metadata()
		var dest_data := Store.read_ex(manifest, fn, dest)
		if dest_data.status != "ok":
			note.text = "替换内容已不可读，请重新打开。"
			return
		var batch := store.state({})
		for index in chosen:
			var hit: Dictionary = candidates[index]
			if not batch.maps.has(hit.map):
				var map := store.map_of(batch, hit.map)
				if map.is_empty() or map.baseline != hit.baseline:
					note.text = "地图已变化，请重开查看使用处：" + hit.map
					return
				batch.maps[hit.map] = map
			var objects: Array = batch.maps[hit.map].data.objects
			for obj in objects:
				if obj.get("code", "") == hit.instance:
					obj.functions[hit.index]["content"] = dest
					obj.functions[hit.index]["name"] = dest_data.data.get("name", dest)
					break
		var created := store.manage({"action": "create", "name": "改绑 %s · %d 条" % [named, chosen.size()]})
		if created.has("error"):
			note.text = created.error
			return
		var saved := store.append(store.read(created.id), batch)
		if saved.has("error"):
			note.text = saved.error
			return
		pop.hide()
		preload("res://src/ui/mcp_draft_review.gd").open.call_deferred(app, saved.id)
	body.add_child(Kit.popup_buttons(accept, pop.hide, "生成改绑草稿"))
	app._open_popup(pop)
	search.grab_focus()
