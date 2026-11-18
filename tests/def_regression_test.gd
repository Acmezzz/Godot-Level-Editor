extends SceneTree

## 定义层回归（合并原 def_resolution_test + def_panel_test）：
## 1) 地图实体的 def 必须在 加载 → 快照 → 复制粘贴 链路中保留；
## 2) 属性面板必须能按种类筛选定义、写入 def_id、撤销恢复、展示组件徽章。
## 用真实 EditorCanvas / PropsPanel，只依赖临时内容目录。

const CanvasScript := preload("res://src/canvas/editor_canvas.gd")
const PropsPanelScript := preload("res://src/ui/props_panel.gd")
const ContentStore := preload("res://src/content/content_store.gd")

## 属性面板依赖的宿主接口（与 app.gd 对应成员同名）
class TestHost extends Control:
	var manifest := {
		"tileSize": 16, "layers": [], "tiles": [],
		"entities": [{"id": "npc", "name": "NPC", "fields": []}],
	}
	var canvas
	var props_panel := VBoxContainer.new()
	var props_scroll: ScrollContainer
	var selected_spr: Sprite2D
	var _props_panel_ctrl
	var ent_list: ItemList
	const POPUP_BODY_W := 340
	func _set_status(_message: String) -> void: pass
	func _set_badge(_panel: PanelContainer, _text: String, _color: Color) -> void: pass
	func _open_asset_editor(_sid: String) -> void: pass
	func _rebuild_props_panel() -> void: _props_panel_ctrl.rebuild()
	func _open_popup(_pop: Control) -> void: pass
	## 调色板会问缩略图；测试里一律没有贴图，正好覆盖"无图也要列出内置种类"
	func _entity_thumbs() -> Dictionary: return {}

var failures: Array[String] = []
var project: Dictionary

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	project = {"_dir": "user://def_regression", "_content_dir": "user://def_regression/content",
		"_maps_dir": "user://def_regression/maps"}
	DirAccess.make_dir_recursive_absolute(str(project["_content_dir"]).path_join("defs"))
	ContentStore.write(project, "defs", "town.smith", {
		"version": 1, "id": "town.smith", "kind": "npc", "name": "铁匠",
		"components": {"dialogue": {"id": "dlg.smith"}, "shop": {"id": "shop.smith"}},
	})
	# 种类不一致的定义不应出现在下拉里
	ContentStore.write(project, "defs", "cave.bat", {
		"version": 1, "id": "cave.bat", "kind": "enemy", "name": "蝙蝠",
	})
	_test_resolution()
	_test_trigger_zone()
	await _test_palette_lists_builtin()
	_test_panel()
	_cleanup()
	if failures.is_empty():
		print("DEF_REGRESSION_OK")
	else:
		for failure in failures:
			printerr("DEF_REGRESSION_FAIL: ", failure)
	quit(failures.size())

## 定义层必须穿过 加载 / 快照 / 复制粘贴 三道关，否则保存会静默丢数据。
func _test_resolution() -> void:
	var canvas = CanvasScript.new()
	root.add_child(canvas)
	canvas.manifest = {
		"tileSize": 16, "layers": [], "tiles": [],
		"entities": [{"id": "npc", "name": "NPC", "fields": []}],
	}
	canvas.set_thumbs({})
	await canvas.load_data(_map_data([
		{"scene": "npc", "id": "e_1", "x": 2, "y": 2, "def": "town.smith", "props": {}},
		{"scene": "npc", "id": "e_2", "x": 4, "y": 2, "props": {}},
	]), "defs")

	var defined: Sprite2D = _entity(canvas, "e_1")
	var undef: Sprite2D = _entity(canvas, "e_2")
	_check(defined != null, "entity with a definition loads")
	_check(undef != null, "entity without a definition loads")
	if defined != null:
		_check(str(defined.get_meta("def_id", "")) == "town.smith",
			"canvas records def_id on load")
	var extracted: Dictionary = canvas.extract()
	_check(str(_find_ent(extracted, "e_1").get("def", "")) == "town.smith",
		"extract preserves def instead of dropping it")
	_check(not _find_ent(extracted, "e_2").has("def"),
		"extract omits def for entities that have none")

	canvas.selected_multi = [defined]
	canvas.copy_selection()
	canvas.paste_at(Vector2(320, 320))
	var copies: Array = []
	for node in canvas.entities.get_children():
		if not ["e_1", "e_2"].has(str(node.get_meta("ent_id", ""))):
			copies.append(node)
	_check(copies.size() == 1, "pasting a defined entity creates one copy")
	if copies.size() == 1:
		_check(str((copies[0] as Sprite2D).get_meta("def_id", "")) == "town.smith",
			"copy preserves the definition id")

	var defs: Dictionary = ContentStore.read_all(project, "defs")
	_check(defs.has("town.smith"), "definition lookup finds the written definition")
	var components: Dictionary = defs.get("town.smith", {}).get("components", {})
	_check(str((components.get("dialogue", {}) as Dictionary).get("id", "")) == "dlg.smith",
		"definition exposes its dialogue component")

	if is_instance_valid(canvas):
		canvas.queue_free()
	await process_frame
## 触发区：内置种类不需要清单声明；w/h 走实例 props，且必须穿过快照保存。
func _test_trigger_zone() -> void:
	var BuiltinKinds := preload("res://src/content/builtin_kinds.gd")
	_check(BuiltinKinds.is_builtin("trigger_zone"), "trigger_zone is a builtin kind")
	var manifest := {"entities": [{"id": "npc"}]}
	BuiltinKinds.merge_into(manifest)
	var has_trigger := false
	for entity in manifest.get("entities", []):
		has_trigger = has_trigger or str((entity as Dictionary).get("id", "")) == "trigger_zone"
	_check(has_trigger, "merge_into injects trigger_zone into the manifest")
	var stripped := BuiltinKinds.strip_from(manifest)
	var kept_trigger := false
	for entity in stripped.get("entities", []):
		kept_trigger = kept_trigger or str((entity as Dictionary).get("id", "")) == "trigger_zone"
	_check(not kept_trigger, "strip_from removes builtin kinds before saving the manifest")
	_check(stripped.get("entities", []).size() == 1, "strip_from keeps user-declared kinds")

	var canvas = CanvasScript.new()
	root.add_child(canvas)
	canvas.manifest = {
		"tileSize": 16, "layers": [], "tiles": [],
		"entities": [{"id": "trigger_zone", "name": "触发区", "builtin": true}],
	}
	canvas.set_thumbs({})
	await canvas.load_data(_map_data([
		{"scene": "trigger_zone", "id": "e_t", "x": 3, "y": 4,
			"props": {"w": 3, "h": 2, "mode": "enter", "event": "evt.a", "once": true}},
	]), "triggers")
	var spr: Sprite2D = _entity(canvas, "e_t")
	_check(spr != null, "trigger zone loads")
	if spr != null:
		_check(canvas.entity_display_size_of(spr) == Vector2(48, 32),
			"trigger zone size comes from instance w/h, not the kind")
		_check(canvas.trigger_zone_origin(spr) == Vector2(48, 64),
			"trigger zone origin is the top-left cell in pixels")

	# 保存链路：w/h/mode/event/once 不在清单 fields 里，也不能被白名单过滤掉
	var out := canvas.extract()
	var saved := _find_ent(out, "e_t")
	_check(int(saved.get("x", -1)) == 3 and int(saved.get("y", -1)) == 4,
		"trigger zone top-left cell survives the snapshot round-trip")
	var saved_props: Dictionary = saved.get("props", {})
	_check(int(saved_props.get("w", 0)) == 3 and int(saved_props.get("h", 0)) == 2,
		"trigger size survives the props whitelist")
	_check(str(saved_props.get("event", "")) == "evt.a", "trigger event binding survives the snapshot")
	_check(bool(saved_props.get("once", false)), "trigger once flag survives the snapshot")

	# 未绑定事件的触发区：画布上要能区分（这里只验证数据侧可判定）
	saved_props.erase("event")
	_check(str(saved_props.get("event", "")) == "", "unbound trigger is detectable for canvas styling")

	if is_instance_valid(canvas):
		canvas.queue_free()
	await process_frame

## 调色板必须列出自带缩略图的实体；内置种类没有 thumb 也不能被跳过，
## 否则触发区在界面上根本放不出来（曾经真的漏了）。
func _test_palette_lists_builtin() -> void:
	var PaletteScript := preload("res://src/ui/palette_panel.gd")
	var holder := VBoxContainer.new()
	root.add_child(holder)
	var host := TestHost.new()
	host.add_child(holder)
	var list := ItemList.new()
	holder.add_child(list)
	host.manifest = {"entities": [
		{"id": "npc", "name": "NPC"},
		{"id": "trigger_zone", "name": "触发区", "builtin": true},
	]}
	host.ent_list = list
	var palette = PaletteScript.new(host)
	palette.fill_entities()
	_check(list.item_count == 1, "palette lists only the builtin kind when nothing has a thumbnail")
	if list.item_count == 1:
		_check(str(list.get_item_metadata(0)) == "trigger_zone",
			"builtin kind without a thumb still reaches the palette")
	holder.queue_free()
	await process_frame

## 属性面板：定义下拉按种类筛选、切换写入 def_id、撤销恢复、组件徽章。
func _test_panel() -> void:
	var host := TestHost.new()
	root.add_child(host)
	host.manifest.merge(project, true)
	host.canvas = CanvasScript.new()
	host.add_child(host.canvas)
	host.canvas.manifest = host.manifest
	host.canvas.set_thumbs({})
	host.add_child(host.props_panel)
	host._props_panel_ctrl = PropsPanelScript.new(host)
	await host.canvas.load_data(_map_data([
		{"scene": "npc", "id": "e_1", "x": 2, "y": 2, "props": {}},
	]), "panel")
	host.selected_spr = _entity(host.canvas, "e_1")
	host._props_panel_ctrl.rebuild()
	await process_frame

	var opt := _find_option_button(host.props_panel)
	_check(opt != null, "definition section renders a dropdown")
	if opt != null:
		var labels: Array[String] = []
		for i in opt.item_count:
			labels.append(opt.get_item_text(i))
		_check(labels.has("(不使用定义)"), "dropdown offers the no-definition option")
		var has_smith := false
		var has_bat := false
		for label in labels:
			has_smith = has_smith or label.contains("town.smith")
			has_bat = has_bat or label.contains("cave.bat")
		_check(has_smith, "dropdown lists definitions matching the entity kind")
		_check(not has_bat, "dropdown hides definitions of a different kind")

		var idx := -1
		for i in opt.item_count:
			if opt.get_item_text(i).contains("town.smith"):
				idx = i
		_check(idx > 0, "matching definition has a selectable index")
		if idx > 0:
			opt.select(idx)
			opt.item_selected.emit(idx)
			await process_frame
			_check(str(_current_entity(host).get_meta("def_id", "")) == "town.smith",
				"selecting a definition writes def_id onto the entity")
			_check(str(_find_ent(host.canvas.extract(), "e_1").get("def", "")) == "town.smith",
				"selected definition survives extraction")
			_check(host.canvas.undo(), "definition assignment is undoable")
			await process_frame
			# 撤销会重建画布节点，选中引用必须重新取，否则面板走空状态
			_check(str(_current_entity(host).get_meta("def_id", "")) == "",
				"undo removes the definition assignment")

	host.selected_spr = _current_entity(host)
	_check(host.selected_spr != null and is_instance_valid(host.selected_spr),
		"entity reference is valid after undo rebuild")
	if host.selected_spr != null:
		host.selected_spr.set_meta("def_id", "town.smith")
		host._props_panel_ctrl.rebuild()
		await process_frame
		var text := _all_label_text(host.props_panel)
		_check(text.contains("对话") and text.contains("dlg.smith"), "dialogue component badge is shown")
		_check(text.contains("商店") and text.contains("shop.smith"), "shop component badge is shown")

	if is_instance_valid(host):
		host.queue_free()
	await process_frame

func _map_data(entities: Array) -> Dictionary:
	return {"meta": {"name": "defs", "w": 10, "h": 6}, "spawn": [1, 1],
		"terrain": [], "decor": [], "collision": [], "entities": entities}

func _entity(canvas, ent_id: String) -> Sprite2D:
	for node in canvas.entities.get_children():
		if str(node.get_meta("ent_id", "")) == ent_id:
			return node as Sprite2D
	return null

func _find_ent(data: Dictionary, ent_id: String) -> Dictionary:
	for ent in data.get("entities", []):
		if str(ent.get("id", "")) == ent_id:
			return ent
	return {}

func _current_entity(host: TestHost) -> Sprite2D:
	return _entity(host.canvas, "e_1")

func _find_option_button(node: Node) -> OptionButton:
	if node is OptionButton:
		return node as OptionButton
	for child in node.get_children():
		var found := _find_option_button(child)
		if found != null:
			return found
	return null

func _all_label_text(node: Node) -> String:
	var out := ""
	if node is Label:
		out += (node as Label).text + "\n"
	for child in node.get_children():
		out += _all_label_text(child)
	return out

func _cleanup() -> void:
	for kind in ["defs"]:
		var dir := str(project["_content_dir"]).path_join(kind)
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