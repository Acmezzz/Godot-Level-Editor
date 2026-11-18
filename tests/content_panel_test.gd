extends SceneTree

## 内容库界面回归：真实 ContentPanel + 临时内容目录。
## 验证新建/列表/选择、对话框节点编辑落盘、校验问题展示、组件跳转。
## 不依赖真实游戏项目，也不建完整 app。

const ContentPanelScript := preload("res://src/ui/content_panel.gd")
const ContentDockScript := preload("res://src/ui/content_dock.gd")
const ContentStore := preload("res://src/content/content_store.gd")
const ContentTemplates := preload("res://src/content/content_templates.gd")
const Kit := preload("res://src/ui/ui_kit.gd")

class TestHost extends Control:
	var closed_count := 0
	var manifest: Dictionary = {}
	const POPUP_BODY_W := 340
	func _popup_body(_title: String, _subtitle := "") -> Dictionary:
		var pop := PopupPanel.new()
		var col := VBoxContainer.new()
		pop.add_child(col)
		return {"pop": pop, "root": col, "body": col}
	func _open_popup(_pop: PopupPanel) -> void: pass
	func _mark_def_used(_def_id: String) -> void: pass
	func _open_content_at(_kind: String, _id: String) -> void: pass

var failures: Array[String] = []
var project: Dictionary
var panel

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	project = {"_dir": "user://content_panel_test",
		"_content_dir": "user://content_panel_test/content",
		"projectName": "test",
		"entities": [{"id": "npc", "name": "NPC"}],
		"items": [{"id": "item.ore", "name": "矿石"}]}
	DirAccess.make_dir_recursive_absolute(str(project["_content_dir"]))
	_seed()
	panel = ContentPanelScript.new()
	panel.manifest = project
	root.add_child(panel)
	panel.build()
	await process_frame
	await _test_kinds_and_list()
	await _test_dialogue_edit()
	await _test_validation_surface()
	await _test_component_jump()
	await _test_event_ref_dropdown()
	await _test_delete_with_references()
	await _test_content_dock()
	panel.queue_free()
	await process_frame
	_cleanup()
	if failures.is_empty():
		print("CONTENT_PANEL_OK")
	else:
		for failure in failures:
			printerr("CONTENT_PANEL_FAIL: ", failure)
	quit(failures.size())

## 预置三类资源，覆盖「有内容」的渲染路径
func _seed() -> void:
	ContentStore.write(project, "dialogues", "dlg.a", {
		"version": 1, "start": "n1", "nodes": [
			{"id": "n1", "speaker": "s1", "text": "你好。", "next": "n2"},
			{"id": "n2", "speaker": "", "text": "走吧。", "choices": [
				{"text": "好", "next": "end"}, {"text": "不", "next": "end"}]},
			{"id": "end", "end": true},
		],
		"speakers": {"s1": {"name": "铁匠"}},
	})
	ContentStore.write(project, "events", "evt.a", {
		"version": 1, "steps": [
			{"type": "dialogue", "dialogue": "dlg.a"},
			{"type": "wait", "seconds": 0.5},
		]})
	ContentStore.write(project, "shops", "shop.a", {
		"version": 1, "entries": [{"item": "item.ore", "price": 12, "stock": 5}]})
	ContentStore.write(project, "defs", "def.a", {
		"version": 1, "kind": "npc", "name": "铁匠",
		"components": {"dialogue": {"id": "dlg.a"}, "shop": {"id": "shop.a"}}})
	ContentStore.write(project, "schema", ContentStore.SCHEMA_ID, {
		"version": 1, "actions": {
			"dialogue": {"params": {"dialogue": {"type": "dialogue_ref", "required": true}}},
			"wait": {"params": {"seconds": {"type": "float", "default": 0.5}}},
		}})

## 页签切换 + 列表填充 + 自动选中第一项
func _test_kinds_and_list() -> void:
	for kind in ["dialogues", "events", "shops", "defs"]:
		panel.show_kind(kind)
		await process_frame
		_check(panel.id_list.item_count == 1, "list shows one resource for " + kind)
		_check(panel.data.size() > 0, "first resource of " + kind + " is auto-selected")
		_check(panel.body.get_child_count() > 0, "body renders for " + kind)
	panel.show_kind("dialogues")
	await process_frame
	_check(str(panel.data.get("id", "")) == "dlg.a", "dialogue list selects dlg.a")
	_check(panel.issue_box.get_child_count() >= 1, "validation row is shown for a valid dialogue")

## 对话编辑：改文本 / 加节点 / 加选项都要落盘，且 id 自动避让
func _test_dialogue_edit() -> void:
	panel.show_kind("dialogues")
	await process_frame
	var editor = panel._editors["dialogues"]
	editor._set_node_field(0, "text", "改过的台词")
	await process_frame
	var back := ContentStore.read(project, "dialogues", "dlg.a")
	_check(str((back.nodes[0] as Dictionary).get("text", "")) == "改过的台词",
		"editing a node text writes through to disk")

	editor._add_node()
	await process_frame
	back = ContentStore.read(project, "dialogues", "dlg.a")
	_check((back.nodes as Array).size() == 4, "adding a node appends to disk")
	_check(str((back.nodes[3] as Dictionary).get("id", "")) == "n3",
		"new node id avoids existing ids")

	editor._add_choice(1)
	await process_frame
	back = ContentStore.read(project, "dialogues", "dlg.a")
	var choices = (back.nodes[1] as Dictionary).get("choices", [])
	_check((choices as Array).size() == 3, "adding a choice appends to disk")

	editor._delete_choice(1, 2)
	await process_frame
	back = ContentStore.read(project, "dialogues", "dlg.a")
	_check(((back.nodes[1] as Dictionary).get("choices", []) as Array).size() == 2,
		"deleting a choice removes it from disk")

## 校验面：坏对话必须把 error 行渲染出来，而不是静默通过
func _test_validation_surface() -> void:
	ContentStore.write(project, "dialogues", "dlg.bad", {
		"version": 1, "start": "ghost", "nodes": [{"id": "n1", "text": "x"}]})
	panel.show_kind("dialogues")
	await process_frame
	panel.refresh_list("dlg.bad")
	await process_frame
	var text := _all_label_text(panel.issue_box)
	_check(text.contains("起始"), "invalid start node surfaces as an issue row")
	_check(not text.contains("校验通过"), "a broken dialogue is not reported as passing")
	ContentStore.remove(project, "dialogues", "dlg.bad")

## 定义页组件「编辑」应跳到对应种类并选中该资源
func _test_component_jump() -> void:
	panel.show_kind("defs")
	await process_frame
	panel.open_kind("shops", "shop.a")
	await process_frame
	_check(panel.kind == "shops", "component jump switches to the shop kind")
	_check(str(panel.data.get("id", "")) == "shop.a", "component jump selects the referenced shop")

## 事件参数里的引用类型必须是资源下拉，而不是手填 id
func _test_event_ref_dropdown() -> void:
	panel.show_kind("events")
	await process_frame
	panel.refresh_list("evt.a")
	await process_frame
	var opt := _find_ref_dropdown(panel.body, "dlg.a")
	_check(opt != null, "dialogue_ref param renders a dropdown listing content resources")
	if opt == null:
		return
	_check(opt.item_count >= 2 and opt.get_item_text(0) == "(空)",
		"dropdown offers an empty option first")
	var idx := -1
	for i in opt.item_count:
		if opt.get_item_text(i) == "dlg.a":
			idx = i
	_check(opt.get_item_text(opt.selected) == "dlg.a", "dropdown selects the currently referenced dialogue")
	_check(idx >= 0, "existing dialogue appears as a choice")
	if idx >= 0:
		opt.select(idx)
		opt.item_selected.emit(idx)
		await process_frame
		var back := ContentStore.read(project, "events", "evt.a")
		_check(str((back.steps[0] as Dictionary).get("dialogue", "")) == "dlg.a",
			"picking from the dropdown writes the id into the step")

## 在控件树里找列出某 id 的下拉（引用下拉是唯一含该 id 文本的 OptionButton）
func _find_ref_dropdown(node: Node, res_id: String) -> OptionButton:
	if node is OptionButton:
		var opt := node as OptionButton
		for i in opt.item_count:
			if opt.get_item_text(i) == res_id:
				return opt
	for child in node.get_children():
		var found := _find_ref_dropdown(child, res_id)
		if found != null:
			return found
	return null

## 删除前必须先扫引用：有引用要列出来，没引用也要能删掉且列表刷新
func _test_delete_with_references() -> void:
	var refs := ContentStore.find_references(project, "dialogues", "dlg.a")
	_check(refs.size() >= 2, "find_references finds the event and the definition pointing at dlg.a")
	panel.show_kind("dialogues")
	await process_frame
	panel.refresh_list("dlg.a")
	await process_frame
	panel.delete_current()
	await process_frame
	var dialog := _find_accept_dialog(panel)
	_check(dialog != null, "deleting a resource opens a confirmation dialog")
	if dialog == null:
		return
	var body_text := _all_label_text(dialog)
	_check(body_text.contains("引用"), "confirmation lists outstanding references")
	_check(body_text.contains("evt.a"), "the referencing event is named in the dialog")
	_check(FileAccess.file_exists(ContentStore.path_for(project, "dialogues", "dlg.a")),
		"nothing is deleted before confirming")
	dialog.confirmed.emit()
	await process_frame
	_check(not FileAccess.file_exists(ContentStore.path_for(project, "dialogues", "dlg.a")),
		"confirming deletes the resource file")
	_check(panel.id_list.item_count == 0, "list refreshes to empty after the only dialogue is deleted")

func _find_accept_dialog(node: Node) -> AcceptDialog:
	if node is AcceptDialog:
		return node as AcceptDialog
	for child in node.get_children():
		var found := _find_accept_dialog(child)
		if found != null:
			return found
	return null

## 内容抽屉：实例为主的内容入口。
## 1) 槽位必须列出对话/互动事件/商店三个组件；
## 2) 在抽屉里新建的资源要带实体归属 id 并立刻绑定到内容组；
## 3) 一次性/可重复是内容组里的播放语义，同一份资源共享、每个实例可覆盖。
func _test_content_dock() -> void:
	ContentStore.write(project, "defs", "grp.map1.e_7", {
		"version": 1, "id": "grp.map1.e_7", "kind": "npc", "name": "e_7",
		"components": {}})
	var host := TestHost.new()
	host.manifest = project
	root.add_child(host)
	var dock = ContentDockScript.new(host)
	host.add_child(dock)
	await process_frame

	dock.open_for("grp.map1.e_7")
	await process_frame
	var labels := _all_label_text(dock.body)
	for slot_label in ["对话", "互动事件", "商店"]:
		_check(labels.contains(slot_label), "dock lists the %s slot" % slot_label)
	_check(labels.contains("未配置"), "an empty content group says each slot is unconfigured")

	# 新建：id 必须带内容组归属，且立刻写进 components
	var before := ContentStore.list_ids(project, "dialogues")
	await _dock_new_dialogue(dock)
	var created := _newest_id(project, "dialogues", before)
	_check(created != "", "creating from the dock writes a dialogue resource")
	_check(created.begins_with("grp.map1.e_7"), "created id carries the instance ownership prefix")
	var bound := ContentStore.read(project, "defs", "grp.map1.e_7")
	_check(_first_id(bound, "dialogue") == created,
		"the new dialogue is bound to the content group immediately")
	_check(not ContentStore.read(project, "dialogues", created).is_empty(),
		"the created dialogue is usable straight away, not an empty shell")

	# 就地编辑：抽屉里改台词要落盘到同一份共享资源
	dock.commit()
	var loaded := ContentStore.read(project, "dialogues", created)
	_check(str(loaded.get("start", "")) == "n1", "in-place editing loads a ready-to-use dialogue")

	# 一次性语义：写到内容组里，不删文件
	dock._set_item_field("dialogue", 0, "once", true)
	await process_frame
	bound = ContentStore.read(project, "defs", "grp.map1.e_7")
	var comp := _slot_items(bound, "dialogue")
	_check(comp.size() == 1 and bool((comp[0] as Dictionary).get("once", false)),
		"once-only playback is recorded on the component")
	_check(not ContentStore.read(project, "dialogues", created).is_empty(),
		"a once-only dialogue keeps its file — it is a mode, not a deletion")
	dock._set_item_field("dialogue", 0, "once", false)
	await process_frame
	bound = ContentStore.read(project, "defs", "grp.map1.e_7")
	comp = _slot_items(bound, "dialogue")
	_check(not (comp[0] as Dictionary).has("once"), "repeatable dialogue clears the once flag")

	# 多段：同一槽位可挂多份，顺序即优先级
	var before_multi := ContentStore.list_ids(project, "dialogues")
	await _dock_new_dialogue(dock)
	var second := _newest_id(project, "dialogues", before_multi)
	bound = ContentStore.read(project, "defs", "grp.map1.e_7")
	comp = _slot_items(bound, "dialogue")
	_check(comp.size() == 2, "a slot can hold more than one dialogue")
	_check(str((comp[1] as Dictionary).get("id", "")) == second,
		"a newly created entry is appended after the existing ones")
	dock._set_item_field("dialogue", 1, "when", "met_smith")
	await process_frame
	bound = ContentStore.read(project, "defs", "grp.map1.e_7")
	comp = _slot_items(bound, "dialogue")
	_check(str((comp[1] as Dictionary).get("when", "")) == "met_smith",
		"a per-entry condition is stored on that entry only")
	_check(not (comp[0] as Dictionary).has("when"),
		"setting a condition on one entry does not leak to the others")
	dock._move_item("dialogue", 1, -1)
	await process_frame
	bound = ContentStore.read(project, "defs", "grp.map1.e_7")
	comp = _slot_items(bound, "dialogue")
	_check(str((comp[0] as Dictionary).get("id", "")) == second,
		"moving an entry up changes match priority")
	dock._remove_item("dialogue", 0)
	await process_frame
	bound = ContentStore.read(project, "defs", "grp.map1.e_7")
	comp = _slot_items(bound, "dialogue")
	_check(comp.size() == 1 and str((comp[0] as Dictionary).get("id", "")) == created,
		"removing an entry leaves the others intact")

	# 共享：同一份对话可被另一个内容组引用
	ContentStore.write(project, "defs", "grp.map1.e_8", {
		"version": 1, "id": "grp.map1.e_8", "kind": "npc", "name": "e_8", "components": {}})
	dock.open_for("grp.map1.e_8")
	await process_frame
	dock._append_item("dialogue", {"id": created})
	await process_frame
	var shared := ContentStore.read(project, "defs", "grp.map1.e_8")
	_check(_first_id(shared, "dialogue") == created,
		"a second instance can share the same dialogue resource")

	if is_instance_valid(host):
		host.queue_free()
	await process_frame

## 槽位条目（归一化后）：兼容单对象与数组两种写法
func _slot_items(definition: Dictionary, comp: String) -> Array:
	var raw = (definition.get("components", {}) as Dictionary).get(comp, [])
	if raw is Dictionary:
		return [raw]
	return raw if raw is Array else []

func _first_id(definition: Dictionary, comp: String) -> String:
	var items := _slot_items(definition, comp)
	if items.is_empty():
		return ""
	return str((items[0] as Dictionary).get("id", ""))

## 点抽屉里「新建」按钮（槽位行第一个「新建」）
func _dock_new_dialogue(dock) -> void:
	dock._new_for("dialogue", "dialogues")
	await process_frame

func _newest_id(project: Dictionary, kind: String, before: Array) -> String:
	for res_id in ContentStore.list_ids(project, kind):
		if not before.has(res_id):
			return str(res_id)
	return ""

func _all_label_text(node: Node) -> String:
	var out := ""
	if node is Label:
		out += (node as Label).text + "\n"
	for child in node.get_children():
		out += _all_label_text(child)
	return out

func _cleanup() -> void:
	var root_dir := str(project["_content_dir"])
	# 批次 B：种类不再有白名单——直接清空内容根下的全部子目录
	var root_handle := DirAccess.open(root_dir)
	if root_handle != null:
		for kind in root_handle.get_directories():
			var dir := root_dir.path_join(str(kind))
			var handle := DirAccess.open(dir)
			if handle != null:
				for filename in handle.get_files():
					DirAccess.remove_absolute(dir.path_join(filename))
			DirAccess.remove_absolute(dir)
	var base := str(project["_dir"])
	if DirAccess.dir_exists_absolute(base):
		DirAccess.remove_absolute(base)

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
#CHUNK_END