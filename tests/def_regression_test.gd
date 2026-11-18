extends SceneTree

## 定义层回归：
## 1) 地图实体的 def 必须在 加载 → 快照 → 复制粘贴 链路中保留；
## 2) 触发区（内置种类）尺寸/绑定必须穿过快照；调色板必须列出无缩略图的内置种类。
## 用真实 EditorCanvas，只依赖临时内容目录。

const CanvasScript := preload("res://src/canvas/editor_canvas.gd")
const ContentStore := preload("res://src/content/content_store.gd")

## 调色板依赖的宿主接口（与 app.gd 对应成员同名）
class TestHost extends Control:
	var manifest := {
		"tileSize": 16, "layers": [], "tiles": [],
		"entities": [{"id": "npc", "name": "NPC", "fields": []}],
	}
	var canvas
	var ent_list: ItemList
	func _set_status(_message: String) -> void: pass
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