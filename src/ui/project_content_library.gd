extends RefCounted
## Project-wide content authoring. The saved file is the same resource used by instance bindings.

const Store := preload("res://src/content/content_store.gd")
const Id := preload("res://src/content/content_id.gd")
const Functions := preload("res://src/content/function_decl.gd")
const Conditions := preload("res://src/content/condition_decl.gd")
const Refs := preload("res://src/content/ref_fields.gd")
const Widgets := preload("res://src/ui/field_widgets.gd")
const RelGraph := preload("res://src/content/rel_graph.gd")
const RelGraphView := preload("res://src/ui/rel_graph_view.gd")
const ReferenceViews := preload("res://src/ui/reference_view_library.gd")
const MapFlowDialog := preload("res://src/ui/map_flow_dialog.gd")
const References := preload("res://src/project/reference_index.gd")
const FlowTarget := preload("res://src/content/flow_target.gd")
const StartupTargets := preload("res://src/project/startup_targets.gd")
const Kit := preload("res://src/ui/ui_kit.gd")
const FrameReference := preload("res://src/ui/map_game_preview.gd")
const FrameDialog := preload("res://src/ui/game_frame_dialog.gd")

var host
var app
var manifest: Dictionary:
	get: return host.manifest
var _last_kind := ""
var _last_id := ""

func _init(editor) -> void:
	host = editor
	app = editor.app

func open() -> void:
	if not host.commit_fields():
		return
	var shell: Dictionary = app._popup_body("项目内容库",
		"内容可以独立创建，由游戏按 ID 读取，也可以被字段或实例绑定引用。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var kinds := OptionButton.new()
	var controls := Kit.hbox(6)
	kinds.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls.add_child(kinds)
	body.add_child(controls)
	var list := ItemList.new()
	list.custom_minimum_size.y = 230
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(list)
	var kinds_data := Functions.functions(manifest)
	var keys := kinds_data.keys()
	keys.sort()
	for key in keys:
		kinds.add_item(str(kinds_data[key].get("name", key)) + " · " + str(key))
		kinds.set_item_metadata(kinds.item_count - 1, key)
		if key == _last_kind:
			kinds.select(kinds.item_count - 1)
	var selected_kind := func() -> String:
		return str(kinds.get_selected_metadata()) if kinds.selected >= 0 else ""
	var eligible := {}
	var reusable := {}
	var selected_entry := func() -> Dictionary:
		var selected := list.get_selected_items()
		if selected.is_empty() or not eligible.has(selected[0]):
			return {}
		return {"function": selected_kind.call(), "content": list.get_item_metadata(selected[0])}
	var play := Kit.button("试玩所选内容", func():
		var entry: Dictionary = selected_entry.call()
		if not entry.is_empty():
			pop.hide()
			app._playtest_ctrl.on_play(Vector2i(-1, -1), true, entry), "ghost")
	var copy := Kit.button("复制为草稿…", func():
		var selected := list.get_selected_items()
		if selected.is_empty():
			return
		var kind: String = selected_kind.call()
		var cid := str(list.get_item_metadata(selected[0]))
		var rd := Store.read_ex(manifest, kind, cid)
		if rd.status != "ok" or rd.data.get("scope") != "project" or not rd.data.get("fields") is Dictionary:
			app._set_status("无法复制该独立内容，请刷新内容库。")
			return
		var draft: Dictionary = rd.data.duplicate(true)
		draft.erase("id")
		draft["name"] = str(draft.get("name", cid)) + "（副本）"
		pop.hide()
		_open_item.call_deferred(kind, "", "", "", draft), "ghost")
	copy.tooltip_text = "复制独立内容及其演出步骤。保存时创建新 ID，原内容及外部引用保持不变。"
	var update_play := func():
		play.visible = Playtest.allows_entry(manifest, selected_kind.call())
		play.disabled = selected_entry.call().is_empty()
		var selected := list.get_selected_items()
		copy.disabled = selected.is_empty() or not reusable.has(selected[0])
	var refill := func():
		list.clear()
		eligible.clear()
		reusable.clear()
		var kind: String = selected_kind.call()
		for cid in Store.list_ids(manifest, kind):
			var rd := Store.read_ex(manifest, kind, str(cid))
			var label := str(rd.data.get("name", "")) if rd.status == "ok" else "[读取失败]"
			var idx := list.add_item("%s  %s" % [label, cid])
			list.set_item_metadata(idx, cid)
			if rd.status == "ok" and rd.data.get("scope") == "project" and rd.data.get("fields") is Dictionary:
				reusable[idx] = true
			if rd.status == "ok" and rd.data.get("scope") == "project" and rd.data.get("function") == kinds_data[kind].get("code"):
				eligible[idx] = true
			if kind == _last_kind and cid == _last_id:
				list.select(idx)
		update_play.call()
	var edit := func(idx: int):
		var kind: String = selected_kind.call()
		var cid := str(list.get_item_metadata(idx))
		pop.hide()
		_open_item.call_deferred(kind, cid)
	kinds.item_selected.connect(func(_idx: int): refill.call())
	list.item_activated.connect(edit)
	list.item_selected.connect(func(_idx: int): update_play.call())
	var add := Kit.button("新建…", func():
		var kind: String = selected_kind.call()
		pop.hide()
		_open_item.call_deferred(kind, ""), "primary")
	add.disabled = keys.is_empty()
	controls.add_child(add)
	controls.add_child(copy)
	var relations := Kit.button("流程关系…", func():
		pop.hide()
		_open_flow.call_deferred())
	relations.disabled = keys.is_empty()
	controls.add_child(relations)
	controls.add_child(play)
	if keys.is_empty():
		body.add_child(Kit.hint_label("游戏工程侧为项目声明功能后，这里才有可创建的内容类型。", 420))
	body.add_child(Kit.popup_buttons(func():
		var selected := list.get_selected_items()
		if not selected.is_empty():
			edit.call(selected[0]), func(): pop.hide(), "编辑", "关闭"))
	refill.call()
	app._open_popup(pop)

func _open_flow() -> void:
	var source := manifest
	var shell: Dictionary = app._popup_body("项目流程关系",
		"选择内容、屏幕以及它们的出口。接线写回内容字段、按钮或热点；游戏决定何时跳转。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var node := OptionButton.new()
	node.name = "FlowSource"
	var slot := OptionButton.new()
	var target := OptionButton.new()
	target.name = "FlowTarget"
	var broken := OptionButton.new()
	broken.name = "FlowMissingLinks"
	broken.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var source_search := LineEdit.new()
	source_search.name = "FlowSourceSearch"
	source_search.placeholder_text = "按内容名、类型或 ID 查找；回车选中首个匹配"
	var target_search := LineEdit.new()
	target_search.name = "FlowTargetSearch"
	target_search.placeholder_text = "按名称、类型或 ID 筛选可接目标"
	node.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	target.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	body.add_child(Kit.field_row("查找来源", source_search, 82))
	body.add_child(Kit.field_row("来源", node, 82))
	body.add_child(Kit.field_row("引用字段", slot, 82))
	body.add_child(Kit.field_row("筛选目标", target_search, 82))
	body.add_child(Kit.field_row("目标", target, 82))
	body.add_child(Kit.field_row("待修引用", broken, 82))
	var neighbors_only := CheckButton.new()
	neighbors_only.name = "FlowDirectOnly"
	neighbors_only.text = "只显示当前项及直接关系"
	body.add_child(neighbors_only)
	var links := ItemList.new()
	links.name = "FlowDirectLinks"
	links.custom_minimum_size.y = 78
	links.tooltip_text = "双击前往相连内容或屏幕；选中后可定位引用字段。"
	body.add_child(links)
	var notice := Kit.hint_label("", 640)
	body.add_child(notice)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(650, 200)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var view := RelGraphView.new()
	view.name = "FlowCanvas"
	view.expand_layout = true
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(view)
	body.add_child(scroll)
	var state := {"graph": {}, "index": {}, "slots": [], "source_positions": {}, "search_terms": {}, "saving": false}
	var selected := func(opt: OptionButton) -> String:
		return str(opt.get_selected_metadata()) if opt.selected >= 0 else ""
	var tokenize := func(query: String) -> PackedStringArray:
		return query.strip_edges().to_lower().split(" ", false)
	var matches := func(key: String, words: PackedStringArray) -> bool:
		var terms: String = state.search_terms[key]
		for word in words:
			if not terms.contains(word):
				return false
		return true
	var fill_targets := func():
		target.clear()
		target.add_item("（未设置 / 断开）")
		target.set_item_metadata(0, "")
		if slot.selected < 0:
			target.disabled = true
			return
		target.disabled = false
		var edge: Dictionary = state.slots[slot.selected]
		var match_idx := 0
		var from_view: bool = edge.fn_id == RelGraph.VIEW_KIND
		var mixed: bool = edge.get("flow_target", false)
		var words: PackedStringArray = tokenize.call(target_search.text)
		for item in state.graph.nodes:
			var address := RelGraph.node_target(item)
			if (from_view and item.fn_id == RelGraph.VIEW_KIND and source.get("directViewTargets") != true) \
					or (from_view and item.fn_id == RelGraph.MAP_KIND and source.get("directMapTargets") != true) \
					or (not from_view and not mixed and item.fn_id != edge.fn):
				continue
			if mixed and (not FlowTarget.allows(edge.decl, address) \
					or (address.has("content") and not item.get("project_content", false))):
				continue
			var is_current: bool = item.cid == edge.value and item.fn_id == edge.fn
			if not is_current and not matches.call(item.key, words):
				continue
			var label := _flow_node_label(item, true)
			target.add_item(label)
			var choice = address if from_view or mixed else item.cid
			target.set_item_metadata(target.item_count - 1, choice)
			if is_current:
				match_idx = target.item_count - 1
		var missing = edge.get("target", {}) if mixed else edge.value
		var has_missing: bool = missing != null and not (missing is Dictionary and missing.is_empty()) \
			and not (missing is String and missing.is_empty())
		if match_idx == 0 and has_missing:
			target.add_item("（失效引用）" + str(missing))
			match_idx = target.item_count - 1
			target.set_item_metadata(match_idx, edge.value)
			target.set_item_disabled(match_idx, true)
		target.select(match_idx)
	var show_graph := func(key: String):
		view.highlighted = key
		if neighbors_only.button_pressed:
			view.set_data(RelGraph.neighborhood(state.index, key))
		view.reveal.call_deferred(key, scroll)
		view.queue_redraw()
	var fill_slots := func():
		var key: String = selected.call(node)
		show_graph.call(key)
		links.clear()
		for direction in ["outgoing", "incoming"]:
			for edge in state.index[direction].get(key, []):
				if direction == "incoming" and edge.from == key:
					continue
				var other: String = edge.to if direction == "outgoing" else edge.from
				var item: Dictionary = state.index.nodes[other]
				var row := links.add_item("%s %s · %s · %s" % [
					"去往 →" if direction == "outgoing" else "来自 ←", edge.label, item.name, item.cid])
				links.set_item_metadata(row, {"edge": edge, "other": other})
		slot.clear()
		state.slots = state.graph.slots.get(key, [])
		for edge in state.slots:
			var suffix := "（添加目标）" if edge.multi and edge.index == -1 else (
				" #%d" % (int(edge.index) + 1) if edge.multi else "")
			var domain: String = edge.fn
			if edge.get("flow_target", false):
				domain = "流程目标"
			elif edge.fn_id == RelGraph.VIEW_KIND:
				domain = {RelGraph.VIEW_KIND: "屏幕", RelGraph.MAP_KIND: "地图"}.get(edge.fn, "内容")
			slot.add_item(str(edge.label) + suffix + " → " + domain)
		if slot.item_count > 0:
			slot.select(0)
		slot.disabled = slot.item_count == 0
		fill_targets.call()
	var fill_sources := func(key: String):
		node.clear()
		state.source_positions.clear()
		var words: PackedStringArray = tokenize.call(source_search.text)
		for item in state.graph.nodes:
			if item.key != key and not matches.call(item.key, words):
				continue
			node.add_item(_flow_node_label(item))
			node.set_item_metadata(node.item_count - 1, item.key)
			state.source_positions[item.key] = node.item_count - 1
		if state.source_positions.has(key):
			node.select(state.source_positions[key])
		node.disabled = node.item_count == 0
	var refresh := func(key: String):
		state.graph = RelGraph.build_project(source)
		state.index = RelGraph.navigation(state.graph)
		state.search_terms.clear()
		var kinds := Functions.functions(source)
		for item in state.graph.nodes:
			var kind: String = {"@view": "屏幕", "@map": "地图"}.get(item.fn_id, kinds.get(item.fn_id, {}).get("name", ""))
			state.search_terms[item.key] = ("%s %s %s %s" % [kind, item.fn_id, item.name, item.cid]).to_lower()
		if view.data.is_empty():
			neighbors_only.set_pressed_no_signal(state.graph.nodes.size() > 250)
		fill_sources.call(key)
		broken.clear()
		broken.add_item("选择一条待修引用…" if not state.graph.external.is_empty() else "没有待修引用")
		broken.set_item_disabled(0, true)
		for edge in state.graph.external:
			broken.add_item("%s/%s · %s → %s/%s" % [edge.fn_id, edge.cid, edge.label, edge.fn, edge.value])
		broken.select(0)
		broken.disabled = state.graph.external.is_empty()
		if not neighbors_only.button_pressed:
			view.set_data(state.graph)
		fill_slots.call()
		notice.text = "%d 条关系，%d 条失效引用，%d 个内容文件无法读取。可改接已建立分支或条件行内的引用。" % [
			state.graph.edges.size(), state.graph.external.size(), state.graph.bad.size()]
	var pick := func(key: String):
		if not state.source_positions.has(key):
			fill_sources.call(key)
		node.select(state.source_positions[key])
		fill_slots.call()
	node.item_selected.connect(func(_i: int): fill_slots.call())
	slot.item_selected.connect(func(_i: int): fill_targets.call())
	source_search.text_changed.connect(func(_text: String):
		fill_sources.call(selected.call(node)))
	source_search.text_submitted.connect(func(query: String):
		var words: PackedStringArray = tokenize.call(query)
		for i in node.item_count:
			var key := str(node.get_item_metadata(i))
			if matches.call(key, words):
				pick.call(key)
				break)
	target_search.text_changed.connect(func(_text: String): fill_targets.call())
	neighbors_only.toggled.connect(func(local: bool):
		if not local:
			view.set_data(state.graph)
		show_graph.call(selected.call(node)))
	view.on_pick = pick
	var pick_edge := func(edge: Dictionary):
		pick.call(edge.from)
		var i: int = state.slots.find(edge)
		if i >= 0:
			slot.select(i)
			fill_targets.call()
	view.on_edge = pick_edge
	links.item_activated.connect(func(i: int):
		pick.call(links.get_item_metadata(i).other))
	broken.item_selected.connect(func(i: int):
		if i > 0:
			pick_edge.call(state.graph.external[i - 1])
			broken.select(0))
	var actions := Kit.hbox(6)
	body.add_child(actions)
	actions.add_child(Kit.button("定位引用字段", func():
		var items := links.get_selected_items()
		if not items.is_empty():
			pick_edge.call(links.get_item_metadata(items[0]).edge), "ghost"))
	actions.add_child(Kit.button("应用关系", func():
		if state.saving or not is_same(app.manifest, source) or slot.selected < 0 or target.selected < 0 or target.is_item_disabled(target.selected):
			return
		var edge: Dictionary = state.slots[slot.selected]
		if edge.fn_id == RelGraph.VIEW_KIND:
			var chosen = target.get_selected_metadata()
			var next: Dictionary = chosen if chosen is Dictionary else {}
			var resolved := true
			if next.has("map"):
				resolved = References.resolve_graph_map(app.MapStore.code_index(source), next.map).status == "ok"
			elif next.has("view"):
				resolved = References.view_ids(source).has(next.view)
			elif not next.is_empty():
				resolved = Store.read_ex(source, next.function, next.content).status == "ok"
			if not resolved:
				refresh.call(edge.from)
				notice.text = "目标已变更；请选择有效目标后重试。"
				return
			var changed := RelGraph.change_view_target(source, edge, next)
			if changed.status != "ok":
				refresh.call(edge.from)
				notice.text = "关系未变。" if changed.status == "noop" else "屏幕已变更，请重试。"
				return
			var candidate := source.duplicate(true)
			candidate.views = changed.views
			var before: Array = source.views.duplicate(true)
			var current := func() -> bool:
				return is_instance_valid(pop) and pop.visible and is_same(app.manifest, source) and source.views == before
			state.saving = true
			var published: bool = await app._save_manifest_file_async(current, candidate, "views")
			state.saving = false
			if is_instance_valid(pop) and pop.visible:
				refresh.call(edge.from)
				notice.text = "关系已保存。" if published else "屏幕关系未保存，请重试。"
			return
		var want = target.get_selected_metadata()
		var valid_target: bool
		if edge.get("flow_target", false):
			want = want if want is Dictionary else {}
			valid_target = want.is_empty() or StartupTargets.destination_available(source, edge.decl, want)
		else:
			valid_target = want.is_empty() or (References.view_ids(source).has(want) if edge.fn == RelGraph.VIEW_KIND
				else Store.read_ex(source, edge.fn, want).status == "ok")
		if not RelGraph.declaration_matches(source, edge.fn_id, edge) or not valid_target:
			refresh.call(edge.from)
			notice.text = "声明或目标已变更；请选择有效目标后重试。"
			return
		var rd := Store.read_ex(source, edge.fn_id, edge.cid)
		if rd.status != "ok" or str(rd.digest) == "":
			refresh.call(edge.from)
			notice.text = "源内容已删除或无法读取，未写入。"
			return
		var result := RelGraph.set_edge(func(_kind, _id): return rd.data,
			func(kind, id, data): return Store.write_ex(source, kind, id, data, rd.digest).ok,
			edge.fn_id, edge.cid, edge.step, edge.field, want, edge.multi, edge.value, edge)
		if result.status == "ok":
			host.refresh_after_external_write(edge.fn_id, edge.cid)
		refresh.call(edge.from)
		notice.text = "关系已保存。" if result.status == "ok" else (
			"关系未变。" if result.status == "noop" else "写入未完成；请根据刷新后的关系重试。"), "primary"))
	actions.add_child(Kit.button("编辑选中项", func():
		var key: String = selected.call(node)
		if key.is_empty() or not is_same(app.manifest, source):
			return
		var item: Dictionary = state.index.nodes[key]
		pop.hide()
		if item.fn_id == RelGraph.VIEW_KIND:
			ReferenceViews.open.call_deferred(app, item.cid)
		elif item.fn_id == RelGraph.MAP_KIND:
			var map := References.resolve_graph_map(app.MapStore.code_index(source), item.cid)
			if map.status == "ok":
				if app.cur_map_name != map.key or not app.map_loaded:
					await app._open_map_by_name(map.key)
				if app.map_loaded and app.cur_map_name == map.key:
					app._set_mode("map")
					MapFlowDialog.open(app)
		else:
			_open_item.call_deferred(item.fn_id, item.cid)))
	actions.add_child(Kit.button("重新扫描", func():
		if is_same(app.manifest, source):
			refresh.call(selected.call(node)), "ghost"))
	actions.add_child(Kit.button("返回内容库", func():
		pop.hide()
		open.call_deferred(), "ghost"))
	refresh.call("")
	app._open_popup(pop, Vector2i(750, mini(680, int(app.get_viewport_rect().size.y) - 40)))

static func _flow_node_label(item: Dictionary, short := false) -> String:
	match item.fn_id:
		RelGraph.VIEW_KIND: return "屏幕 · " + item.cid
		RelGraph.MAP_KIND: return "地图 · %s [%s]" % [item.name, item.cid]
	return "%s · %s" % [item.name, item.cid] if short else "%s · %s · %s" % [item.fn_id, item.name, item.cid]

func open_issue(jump: Dictionary) -> void:
	var fn: String = jump.fn
	var cid: String = jump.id
	var field: String = jump.field
	var context: String = jump.context
	var step_index: int = jump.step_index
	if step_index >= 0 and Functions.fn_has_steps(manifest, fn):
		host._steps.open_content(fn, cid, context, step_index, field)
	elif host.commit_fields():
		_open_item(fn, cid, context, field)

func _open_item(kind: String, cid: String, context := "", field := "", draft := {}) -> void:
	var fn := Functions.function_decl(manifest, kind)
	if fn.is_empty():
		return
	var source := manifest
	var creating := cid == ""
	var rd := Store.read_ex(source, kind, cid) if not creating else {}
	var readable: bool = creating or rd.get("status") == "ok"
	var data: Dictionary = {"name": "", "fields": {}, "scope": "project"} if creating else rd.get("data", {})
	if creating:
		data.merge(draft, true)
	var state := {"id": cid, "digest": str(rd.get("digest", "")), "new": creating, "map": context}
	var title := "复制草稿" if not draft.is_empty() else "编辑"
	var shell: Dictionary = app._popup_body(title + " · " + str(fn.get("name", kind)),
		"保存写入内容文件。依赖其他字段的引用选项会在保存后更新。")
	var pop: PopupPanel = shell.pop
	FrameDialog.keep_on_focus_loss(pop)
	var body: VBoxContainer = shell.body
	var notice := Label.new()
	notice.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(notice)
	if not readable:
		notice.text = str(rd.get("error", "无法读取内容"))
		body.add_child(Kit.button("返回内容库", func():
			pop.hide()
			open.call_deferred(), "ghost"))
		app._open_popup(pop)
		return
	var name_edit := LineEdit.new()
	name_edit.text = str(data.get("name", ""))
	body.add_child(Kit.field_row("显示名", name_edit, 92))
	var id_edit := LineEdit.new()
	id_edit.editable = creating
	id_edit.text = cid
	id_edit.placeholder_text = "可填固定 ID 后缀，留空自动分配"
	body.add_child(Kit.field_row("内容 ID", id_edit, 92))
	var fields = data.get("fields", {})
	if not fields is Dictionary:
		notice.text = "此内容的 fields 不是对象，已保留原数据。"
		body.add_child(Kit.button("返回内容库", func():
			pop.hide()
			open.call_deferred(), "ghost"))
		app._open_popup(pop)
		return
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size.y = 300
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var form := Kit.vbox(6)
	form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(form)
	var commits: Array = []
	var refresh := func():
		for commit in commits:
			if not bool(commit.call()):
				return
		form.get_meta("render_fields").call()
	var render := func():
		commits.clear()
		for child in form.get_children():
			form.remove_child(child)
			child.queue_free()
		_build_fields(form, fn, fields, commits, notice, str(state.map), refresh)
		if field != "":
			for row in form.get_children():
				if row.get_meta("field_id", "") == field:
					Kit.highlight_field_row(row)
					scroll.ensure_control_visible.call_deferred(row)
					break
	form.set_meta("render_fields", render)
	var map_selector: OptionButton = host._form.reference_context_selector(context, func(key: String) -> bool:
		for commit in commits:
			if not bool(commit.call()):
				return false
		state.map = key
		render.call()
		return true)
	if map_selector.item_count > 1:
		body.add_child(Kit.field_row("本图候选", map_selector, 92))
	else:
		map_selector.free()
	body.add_child(scroll)
	render.call()
	var saving := {"active": false}
	var store := func() -> bool:
		if saving.active:
			return false
		if not is_same(app.manifest, source):
			notice.text = "当前项目已变更。请在新项目重新打开内容库。"
			return false
		for commit in commits:
			if not bool(commit.call()):
				return false
		if bool(source.get("_codes_issued", false)):
			saving.active = true
			var guard := func() -> bool:
				return is_instance_valid(pop) and pop.visible and is_same(app.manifest, source)
			var published: bool = await app._save_manifest_file_async(guard)
			saving.active = false
			if not guard.call():
				return false
			if not published:
				notice.text = "清单尚未保存，内容文件未写入。"
				return false
		var save_id := str(state.id)
		if state.new:
			var slug := id_edit.text.strip_edges()
			save_id = "project-" + slug if slug != "" else Id.unique(
				source, kind, "project-" + Id.new_inst_code() + Id.new_inst_code())
			if not Store.is_valid_id(save_id):
				notice.text = "ID 只接受字母、数字、下划线、点与连字符。"
				return false
		var name_text := name_edit.text.strip_edges()
		data["name"] = name_text if name_text != "" else str(fn.get("name", kind))
		data["function"] = str(fn.get("code", ""))
		data["fields"] = fields
		var was_new := bool(state.new)
		var wr := Store.write_ex(source, kind, save_id, data, str(state.digest), false, was_new)
		if not wr.ok:
			notice.text = ("该 ID 已被占用，请换一个。" if was_new else "内容已在别处修改，请重新打开后再编辑。") if wr.get("conflict", false) else "内容保存失败。"
			return false
		state.id = save_id
		state.new = false
		state.digest = Store.file_digest(Store.path_for(source, kind, save_id))
		id_edit.text = save_id
		id_edit.editable = false
		_last_kind = kind
		_last_id = save_id
		notice.text = "已保存。"
		host.refresh_after_external_write(kind, save_id)
		app._set_status("已保存项目内容：" + save_id)
		return true
	var actions := Kit.hbox(6)
	body.add_child(actions)
	actions.add_child(Kit.button("保存", func():
		if await store.call():
			render.call_deferred(), "primary"))
	if Functions.fn_has_steps(source, kind):
		actions.add_child(Kit.button("保存并编辑演出", func():
			if not await store.call():
				return
			pop.hide()
			Callable(host._steps, "open_content").call_deferred(kind, str(state.id), str(state.map)), "ghost"))
	if not creating:
		actions.add_child(Kit.button("删除…", func():
			pop.hide()
			_delete.call_deferred(kind, cid), "ghost"))
	actions.add_child(Kit.button("返回内容库", func():
		pop.hide()
		open.call_deferred(), "ghost"))
	app._open_popup(pop)

func _delete(kind: String, cid: String) -> void:
	await host._form._delete_library_item(kind, cid)
	open()

func _build_fields(form: VBoxContainer, fn: Dictionary, values: Dictionary, commits: Array, notice: Label,
		context: String, refresh: Callable) -> void:
	var groups := [{"name": "功能参数", "fields": fn.get("fields", [])}]
	var siblings: Array = (fn.get("fields", []) as Array).duplicate()
	var conditions = fn.get("conditions", [])
	if conditions is Array:
		for id in conditions:
			var c := Conditions.condition_decl(manifest, str(id))
			var fields := Conditions.condition_fields(manifest, str(id))
			if not c.is_empty() and not fields.is_empty():
				siblings.append_array(fields)
				groups.append({"name": "条件 · " + str(c.get("name", id)), "fields": fields})
	for group in groups:
		form.add_child(Kit.section_header(str(group.name)))
		for fd in group.fields:
			if fd is Dictionary:
				_build_field(form, fd, siblings, values, commits, notice, context, refresh)

func _build_field(form: VBoxContainer, fd: Dictionary, siblings: Array, values: Dictionary, commits: Array,
		notice: Label, context: String, refresh: Callable) -> void:
	var key := str(fd.get("code", ""))
	if key == "":
		return
	var decl := fd.duplicate(true)
	var pair := func() -> Array[String]: return Refs.frame_scope(fd, siblings, values)
	var map_key: String = pair.call()[0]
	if map_key != "":
		decl["_mapKey"] = map_key
	var set_value := func(v) -> bool:
		if v is String and v.is_empty() and Refs.wants_empty_option(fd):
			values.erase(key)
		else:
			values[key] = v
		return true
	var use := func(v) -> bool:
		if pair.call()[0] != map_key:
			notice.text = "请先保存配对地图，再选择新的引用值。"
			return false
		set_value.call(v)
		if siblings.any(func(other): return other is Dictionary and other.get("mapField") == fd.get("id")):
			refresh.call_deferred()
		return true
	var options := func(d: Dictionary) -> Array:
		return host._form.project_reference_options(d, context)
	var frame_pick := func(row: Control, nested: Dictionary, nested_pair: Callable, save: Callable, read: Callable):
		FrameReference.add_reference_button(app, row, nested, nested_pair, save, options, true, refresh, context, read)
	var built := Widgets.build(decl, values.get(key, fd.get("default", Widgets.default_for(fd))), use, options, "code", frame_pick)
	var commit: Callable = built.get("commit", Callable())
	if commit.is_valid():
		commits.append(commit)
	var row := Kit.field_row(str(fd.get("name", fd.get("id", key))), built.ctl, 92)
	row.set_meta("field_id", str(fd.get("id", "")))
	row.tooltip_text = Widgets.decl_tooltip(fd)
	form.add_child(row)
	if Widgets.wants_frame_pick(fd) and Widgets.frame_value_available(fd, built):
		FrameReference.add_reference_button(app, row, fd, pair, set_value, options, true, refresh, context,
			built.get("pick_values", Callable()))
