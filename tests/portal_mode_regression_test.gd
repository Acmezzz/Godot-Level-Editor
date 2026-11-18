extends SceneTree

## 跨图落点回归：出口在目标图上选落点 → 确认 → 写盘 → 保存链路。
## （原「门配对 + 跨图选点」双段测试：门配对 UI 已随 props_panel 删除，
## 现只覆盖仍存活的 cross_map_picker 生产链路。）

const Store := preload("res://src/map_store.gd")
const CanvasScript := preload("res://src/canvas/editor_canvas.gd")
const PickerScript := preload("res://src/ui/cross_map_picker.gd")
const MapFileScript := preload("res://src/ui/map_file.gd")
const MapThumbScript := preload("res://src/ui/map_thumb.gd")

class TestHost extends Control:
	const MapStore := preload("res://src/map_store.gd")
	const Manifest := preload("res://src/manifest.gd")
	var manifest: Dictionary
	var canvas
	var selected_spr: Sprite2D
	var map_loaded := true
	var cur_map_name := "source"
	var cur_map_path := ""
	var _picker_ctrl
	var _map_file_ctrl
	func _set_status(_message: String) -> void: pass
	const POPUP_BODY_W := 340
	var picker_thumb: MapThumbScript
	func _sync_play_cfg_to_map() -> void: pass
	func _open_popup(pop: PopupPanel, _size := Vector2i.ZERO) -> void:
		add_child(pop)
		picker_thumb = _find_thumb(pop)
	func _open_map_point_picker(tmap: String, map_fid: String, point_fid: String, props: Dictionary) -> void:
		_picker_ctrl.open_map_point_picker(tmap, map_fid, point_fid, props)
	func _clear_exit_pair(map_name: String, exit_id: String, peer_map: String, peer_id: String) -> void:
		_picker_ctrl.clear_exit_pair(map_name, exit_id, peer_map, peer_id)
	func _ent_by_id(id: String) -> Sprite2D:
		for node in canvas.entities.get_children():
			if str(node.get_meta("ent_id", "")) == id:
				return node as Sprite2D
		return null
	func _find_thumb(node: Node) -> MapThumbScript:
		if node is MapThumbScript:
			return node as MapThumbScript
		for child in node.get_children():
			var found := _find_thumb(child)
			if found != null:
				return found
		return null

var host: TestHost
var map_dir := ""
var failures: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var project := OS.get_environment("BIRD_PROJECT")
	if project == "":
		_fail("BIRD_PROJECT must point to the game project")
		_finish()
		return
	host = TestHost.new()
	root.add_child(host)
	var loaded_manifest := EditorManifest.load_from(project)
	if loaded_manifest.has("_error"):
		_fail("game manifest failed to load: " + str(loaded_manifest.get("_error", "")))
		_finish()
		return
	map_dir = ProjectSettings.globalize_path("user://portal_flow_%d/maps" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(map_dir)
	host.manifest = loaded_manifest
	host.manifest["_maps_dir"] = map_dir
	host.canvas = CanvasScript.new()
	host.add_child(host.canvas)
	host.canvas.manifest = host.manifest
	host.canvas.set_thumbs({})
	host._picker_ctrl = PickerScript.new(host)
	host._map_file_ctrl = MapFileScript.new(host)
	var source := _map_data("source", [
		{"scene": "portal", "id": "e_1", "x": 2, "y": 2, "props": {}},
	])
	var forest := _map_data("forest", [])
	_check(Store.write(host.manifest, "source", source), "seed source map")
	_check(Store.write(host.manifest, "forest", forest), "seed target map")
	await host.canvas.load_data(source, "source")
	host.cur_map_name = "source"
	host.cur_map_path = Store.path_for(host.manifest, "source")
	host.selected_spr = host._ent_by_id("e_1")
	await process_frame

	# Pick a point on another map through the production picker.
	host._picker_ctrl.open_map_point_picker("forest", "target_map", "target_point",
		host.selected_spr.get_meta("props", {}))
	await process_frame
	_check(host.picker_thumb != null and host.picker_thumb.on_pick.is_valid(), "picker uses the production MapThumb callback")
	if host.picker_thumb != null and host.picker_thumb.on_pick.is_valid():
		host.picker_thumb.on_pick.call(Vector2i(5, 3), "", "")
	# P0-5：跨图配对先弹确认框（写盘不可撤销，不能一点就落盘）——这里确认它
	await process_frame
	var confirm := _find_confirm_dialog(host)
	_check(confirm != null, "picker asks for confirmation before writing the other map")
	if confirm != null:
		_check(not _target_has_point(host, "forest", 5, 3),
			"confirming is required before the destination map is written")
		confirm.emit_signal("confirmed")
	await process_frame
	var target_data := Store.read(host.manifest, "forest")
	var new_point := ""
	for ent in target_data.get("entities", []):
		if str(ent.get("scene", "")) == "spawn_point" and int(ent.get("x", -1)) == 5 and int(ent.get("y", -1)) == 3:
			new_point = str(ent.get("id", ""))
	_check(new_point != "", "picker writes a new target spawn_point to the destination map")
	_check(str(_props(host.canvas.extract(), "e_1").get("target_map", "")) == "forest", "portal stores selected target_map in canvas data")
	_check(str(_props(host.canvas.extract(), "e_1").get("target_point", "")) == new_point, "portal stores selected destination point id")
	_check(host._map_file_ctrl.on_save(), "save cross-map portal through MapFile")
	var saved := Store.read(host.manifest, "source")
	var saved_props: Dictionary = _props(saved, "e_1")
	_check(str(saved_props.get("target_map", "")) == "forest" and str(saved_props.get("target_point", "")) == new_point,
		"cross-map target pair survives source-map save and read")
	_cleanup()
	_finish()

func _map_data(name: String, entities: Array) -> Dictionary:
	return {"meta": {"name": name, "w": 12, "h": 8}, "spawn": [1, 1],
		"terrain": [], "decor": [], "collision": [], "entities": entities}

func _props(data: Dictionary, ent_id: String) -> Dictionary:
	for ent in data.get("entities", []):
		if str(ent.get("id", "")) == ent_id:
			return ent.get("props", {})
	return {}

func _find_confirm_dialog(node: Node) -> ConfirmationDialog:
	if node is ConfirmationDialog and (node as ConfirmationDialog).visible:
		return node as ConfirmationDialog
	for child in node.get_children():
		var found := _find_confirm_dialog(child)
		if found != null:
			return found
	return null

## 目标图上是否已有 (x,y) 的落点（用于断言「确认前没写盘」）
func _target_has_point(host, map_name: String, x: int, y: int) -> bool:
	for ent in Store.read(host.manifest, map_name).get("entities", []):
		if str(ent.get("scene", "")) == "spawn_point" and int(ent.get("x", -1)) == x and int(ent.get("y", -1)) == y:
			return true
	return false

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		printerr("PORTAL_FLOW_FAIL: ", message)

func _fail(message: String) -> void:
	_check(false, message)

func _cleanup() -> void:
	if map_dir == "":
		return
	for map_name in ["source", "forest"]:
		var path := Store.path_for(host.manifest, map_name)
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		if FileAccess.file_exists(path + ".tmp"):
			DirAccess.remove_absolute(path + ".tmp")
	DirAccess.remove_absolute(map_dir)
	var parent := map_dir.get_base_dir()
	if DirAccess.open(parent) != null:
		DirAccess.remove_absolute(parent)
	if host != null and is_instance_valid(host):
		host.queue_free()

func _finish() -> void:
	if failures.is_empty():
		print("PORTAL_MODE_REGRESSION_OK")
		quit(0)
	else:
		printerr("PORTAL_MODE_REGRESSION_FAILED: ", failures.size())
		quit(1)
