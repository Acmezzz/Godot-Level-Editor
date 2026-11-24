extends RefCounted
## Captures the current map work copy for the game-owned renderer.

const GamePreview := preload("res://src/project/game_preview.gd")
const FrameDialog := preload("res://src/ui/game_frame_dialog.gd")
const Kit := preload("res://src/ui/ui_kit.gd")
const FieldWidgets := preload("res://src/ui/field_widgets.gd")
const Assets := preload("res://src/assets/asset_decl.gd")
const Geometry := preload("res://src/map/object_geometry.gd")
const Maps := preload("res://src/map/map_store.gd")
const RefIndex := preload("res://src/project/reference_index.gd")
const Recovery := preload("res://src/map/recovery.gd")
const ViewData := preload("res://src/map/map_view_data.gd")
const Layout := preload("res://src/project/screen_layout.gd")
const Picks := preload("res://src/project/frame_picks.gd")
const RefFields := preload("res://src/content/ref_fields.gd")
const CAPABILITY := "mapFrame"

class ReferenceSelection extends RefCounted:
	var mode: String
	var match_target: Callable
	var commit: Callable
	var read: Callable
	var initial: Array
	var selected: Array
	var regions: Array
	var status: String
	var ordered: bool
	var layer: String
	var clicks: PackedVector2Array

	func _init(kind: String, lookup: Callable, save: Callable, current: Callable, sequence: bool, target_layer: String) -> void:
		mode = kind
		match_target = lookup
		commit = save
		read = current
		ordered = sequence
		layer = target_layer
		initial = read.call()
		clear()

	func clear() -> void:
		selected = initial.duplicate()
		regions = []
		clicks.clear()
		_update_message()

	func _update_message() -> void:
		if ordered:
			var tail := selected.slice(maxi(0, selected.size() - 5)).map(func(value): return str(value))
			status = "%d 个途经点 · %s · 左键追加，右键移除末项。" % [selected.size(), " → ".join(tail)]
		else:
			status = "已选 %d 项 · 点击切换，右键恢复本次打开时的选择。" % selected.size()

	func message() -> String:
		return status

	func set_regions(hits: Array) -> void:
		regions = hits

	func ready() -> bool:
		return selected != initial

	func input(event: InputEvent, pixel: Vector2, hits: Array) -> bool:
		if not event is InputEventMouseButton or not event.pressed:
			return false
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if ordered:
				if not selected.is_empty():
					selected.pop_back()
				if not clicks.is_empty():
					clicks.resize(clicks.size() - 1)
			else:
				selected = initial.duplicate()
			_update_message()
			return true
		if event.button_index != MOUSE_BUTTON_LEFT:
			return false
		var hit := Picks.at(hits, pixel, mode, layer)
		var candidate: Dictionary = {} if hit.is_empty() else match_target.call(hit.value)
		if candidate.is_empty():
			status = "这里没有此字段可选的目标。当前已选 %d 项。" % selected.size()
			return true
		var value: Variant = candidate.v
		if not ordered and selected.has(value):
			selected.erase(value)
		else:
			selected.append(value)
			if mode in ["collision", "placement"]:
				clicks.append(pixel)
		_update_message()
		return true

	func apply() -> bool:
		if read.call() != initial:
			return false
		return await commit.call(selected.duplicate())

	func draw(frame: TextureRect, rect: Rect2) -> void:
		var scale := rect.size / frame.texture.get_size()
		if mode in ["collision", "placement"]:
			var line := PackedVector2Array()
			for point in clicks:
				line.append(rect.position + point * scale)
				frame.draw_circle(line[-1], 4.0, Color("#ffda67"))
			if line.size() >= 2:
				frame.draw_polyline(line, Color("#ffda67"), 2.0, true)
			return
		for region in regions:
			if not selected.has(region.targets.get(mode)):
				continue
			var line := PackedVector2Array()
			for pixel: Vector2 in region.screen:
				line.append(rect.position + pixel * scale)
			line.append(line[0])
			frame.draw_polyline(line, Color("#ffda67"), 2.0, true)

static func available(app) -> bool:
	return app.map_loaded and GamePreview.supports(app.manifest, CAPABILITY)

static func open(app) -> void:
	var asset: String = app.canvas.stamp_asset if app.map_loaded else ""
	var choose := func(value: Dictionary) -> Dictionary:
		var canvas: EditorCanvas = app.canvas
		if not canvas.is_placeable(asset):
			return {"text": "请关闭预览，在资产栏选一个可摆放资产后重试。"}
		var li := canvas._layer_index_of(value.layer)
		if li < 0 or canvas.is_layer_locked(li):
			return {"text": "映射图层已不存在或被锁定。"}
		var point: Vector2 = value.point
		return {"text": "%s → %s · 局部像素 (%.2f, %.2f)" % [asset, canvas.layer_name(li), point.x, point.y],
			"apply": func(): return canvas._tool_ops_ctrl.place_object(asset, li, point, true) != null}
	var decl := Assets.by_id(app.manifest, asset)
	var visual = decl.get("visual", {})
	var draft := {}
	if decl.get("kind") == "entity" and visual is Dictionary and visual.get("type") in ["poly", "path"]:
		draft = {"max_points": Geometry.MAX_POINTS, "closed": Geometry.closed(visual)}
		draft["draw_shape"] = func(hits: Array) -> Dictionary:
			var points: Array = hits.map(func(hit): return hit.value.point)
			var local := points.map(func(p): return p - points[0])
			var issue := Geometry.problem(local, visual)
			var title := "%s · %d 点" % [asset, points.size()]
			if issue != "":
				return {"text": title + " · " + issue}
			var canvas: EditorCanvas = app.canvas
			var li := canvas._layer_index_of(hits[0].value.layer)
			if li < 0 or canvas.is_layer_locked(li):
				return {"text": "映射图层已不存在或被锁定。"}
			return {"text": title + " · " + canvas.layer_name(li) + " · 可创建形状",
				"apply": func(): return canvas._tool_ops_ctrl.place_object(asset, li, points[0], true, points) != null}
	_open(app, "placement", choose, draft)

static func open_spawn(app) -> void:
	var choose := func(value: Dictionary) -> Dictionary:
		var canvas: EditorCanvas = app.canvas
		var cell: Vector2i = canvas.grid.pick_cell(value.point)
		if not canvas.can_move_spawn_to(cell):
			return {"text": "出生点须在地图内，且根碰撞层须解锁。"}
		if canvas.grid.pick_cell(canvas.spawn.position) == cell:
			return {"text": "出生点已在此格。"}
		return {"text": "将关卡出生点设在根格 (%d, %d)。" % [cell.x, cell.y],
			"apply": func(): return canvas.set_spawn_cell(cell)}
	_open(app, "collision", choose, {"title": "实景设置出生点", "confirm_label": "应用出生点",
		"initial": "渲染后，点击有根空间映射的地点，再确认出生点。"})

static func _saved_snapshot(preset: String, app, manifest: Dictionary, key: String,
		prepare: Callable) -> Dictionary:
	var resolve := func() -> Dictionary:
		return RefIndex.resolve_map(manifest, key)
	var resolved: Dictionary = resolve.call()
	if resolved.status != "ok":
		return {"error": "目标地图不可读或地图键不唯一。"}
	var path := Maps.path_for(manifest, resolved.key)
	var result := Maps.read_path(path, manifest)
	if not result.ok or result.data.meta.code != key:
		return {"error": "目标地图不可读或地图码已变更。"}
	var digest: String = result.digest
	var current := func() -> bool:
		var now: Dictionary = resolve.call()
		return now.status == "ok" and now.key == resolved.key and Recovery.digest(path) == digest
	var map: Dictionary = result.data
	if prepare.is_valid():
		var issue: String = prepare.call(map, current)
		if issue != "":
			return {"error": issue}
	var default_size: Vector2 = app.get_viewport_rect().size
	var size: Vector2 = Layout.sizes(manifest).get(preset, default_size)
	var bounds := ViewData.scene_bounds(map, manifest)
	var center := bounds.get_center()
	var zoom := minf(size.x / bounds.size.x, size.y / bounds.size.y) * 0.9
	return {"subject": {"map": map, "eventDrawings": RefIndex.event_drawings(manifest, key),
		"manifest": app._manifest_write_payload(manifest), "viewportId": preset,
		"camera": {"center": [center.x, center.y], "zoom": zoom}, "stagedContent": []},
		"default_size": default_size, "current": current}

static func reference_available(app, map_key: String) -> bool:
	return GamePreview.supports(app.manifest, CAPABILITY) and (app.map_loaded or map_key != "")

static func add_reference_button(app, row: Control, decl: Dictionary, pair: Callable,
		commit: Callable, resolve: Callable, project_scope: bool, refresh: Callable, context := "",
		read := Callable(), saved_only := false) -> Button:
	if not GamePreview.supports(app.manifest, CAPABILITY):
		return null
	var picker: OptionButton
	for child in row.get_children():
		picker = child.get_node_or_null("ReferenceTargetMap") as OptionButton
		if picker != null:
			break
	if picker == null and context == "" and (project_scope or not app.map_loaded) and not decl.has("mapField"):
		return null
	var selected_scope := func() -> Array:
		var scope: Array = pair.call()
		if picker != null:
			scope = [picker.get_selected_metadata(), scope[1]]
		return scope
	var button := Kit.button("实景选…", func():
		var scope: Array = selected_scope.call()
		var key: String = scope[0]
		var effective := key if key != "" else context
		if (project_scope and effective == "") or not reference_available(app, effective):
			app._set_status("请先选择此记录的配对地图。")
			return
		var scoped := decl.merged({"_mapKey": effective, "_pickLayer": scope[1]}, true)
		var save := func(value) -> bool:
			if not is_instance_valid(row) or not row.is_inside_tree() or row.is_queued_for_deletion() or selected_scope.call() != scope:
				return false
			# A temporary map resolves a local reference; it is not part of the authored value.
			if key.is_empty() and not context.is_empty() and value is Dictionary:
				value = value.merged({"map": ""}, true)
			if not await commit.call(value):
				return false
			refresh.call_deferred()
			return true
		open_reference(app, scoped, resolve, save, row.get_window(), read, saved_only), "ghost")
	button.name = "FrameFieldReference_" + str(decl.get("id", ""))
	row.add_child(button)
	return button

static func open_reference(app, decl: Dictionary, resolve: Callable, commit: Callable, window: Window,
		read := Callable(), saved_only := false) -> void:
	var mode := FieldWidgets.pick_mode(decl)
	var layer := str(decl.get("_pickLayer", ""))
	if mode == "placement" and layer.is_empty():
		app._set_status("请先选择此字段所属的图层。")
		return
	var source := decl.duplicate()
	var edge_scope := {}
	var prepare := Callable()
	match mode:
		"entity":
			source["source"] = "entity_inst:" + ",".join(PackedStringArray(FieldWidgets.canvas_pick_types(decl)))
		"port":
			source["source"] = "port:" + ",".join(PackedStringArray(FieldWidgets.canvas_pick_types(decl)))
		"edge":
			prepare = func(map: Dictionary, _current: Callable) -> String:
				edge_scope.assign(RefFields.edge_context(map.meta, app.manifest))
				return ""
	var match_target := func(value: Variant) -> Dictionary:
		if mode == "edge":
			return _match_edge(value, edge_scope)
		if mode in ["collision", "placement"]:
			var point: Vector2 = value.point
			var lo := float(decl.get("min", -999999))
			var hi := float(decl.get("max", 999999))
			if point.x < lo or point.x > hi or point.y < lo or point.y > hi:
				return {}
			var space := "图层 " + layer if mode == "placement" else "地图"
			return {"v": [point.x, point.y], "t": "%s坐标 (%.2f, %.2f)" % [space, point.x, point.y]}
		for row in resolve.call(source):
			var candidate = FieldWidgets.decode_pick(mode, str(row.v))
			if candidate != null and candidate == value:
				return {"v": candidate, "t": row.t}
		return {}
	var choose := func(value: Variant) -> Dictionary:
		var candidate := match_target.call(value) as Dictionary
		if not candidate.is_empty():
			return {"text": "目标：" + str(candidate.t), "apply": func(): return await commit.call(candidate.v)}
		return {"text": "该画面目标不在字段的候选范围内。"}
	var key := str(decl.get("_mapKey", ""))
	var local: bool = not saved_only and (key == "" or
		(app.map_loaded and key in [app.canvas.cur_map_code(), app.canvas.cur_map_name]))
	var parent := {"pick_layer": layer}
	if window is PopupPanel:
		parent["parent"] = window
	var ordered := FieldWidgets.ordered_frame_pick(decl)
	if ordered or bool(decl.get("multiple", false)):
		var selection := ReferenceSelection.new(mode, match_target, commit, read, ordered, layer)
		parent.merge({"interaction": selection, "on_picks": selection.set_regions, "confirm_label": "应用选择"})
	if local:
		_open(app, mode, choose, parent, prepare)
	else:
		var session = app._map_file_ctrl.sess
		var generation: int = session.generation
		var valid := func() -> bool: return not session.stale(generation)
		var options := {"title": "实景选引用 · " + key, "button": "渲染目标地图",
			"hint": "使用引用字段指定地图的已保存版本。确认后只写入当前字段。",
			"prefix": "MapGamePreview", "default_label": "当前窗口大小", "pick_mode": mode, "pick": choose, "camera": true}
		FrameDialog.open(app, CAPABILITY, options.merged(parent),
			_saved_snapshot.bind(app, app.manifest, key, prepare), valid)

static func _match_edge(value: Variant, scope: Dictionary) -> Dictionary:
	if not value is Dictionary or value.get("map") != scope.code or not value.get("edge") is String:
		return {}
	var canonical := RefFields.edge_at_coordinates(scope, value.edge)
	var cell = value.get("cell")
	if canonical.is_empty() or value.edge != canonical.edge or not cell is Array or cell.size() != 2 \
			or cell[0] != canonical.cell[0] or cell[1] != canonical.cell[1]:
		return {}
	return {"v": canonical, "t": canonical.edge.replace("|", " — ")}

static func _open(app, mode: String, choose: Callable, extra := {}, prepare := Callable()) -> void:
	if not available(app):
		app._set_status("打开地图并在游戏清单中声明 mapFrame 预览能力后可用。")
		return
	var canvas: EditorCanvas = app.canvas
	var session = app._map_file_ctrl.sess
	var generation: int = session.generation
	var valid := func() -> bool:
		return app.map_loaded and is_instance_valid(canvas) and is_same(app.canvas, canvas) and not session.stale(generation)
	var capture := func(preset: String) -> Dictionary:
		var subject := map_context(app)
		if subject.is_empty():
			return {"error": "地图正在重建，请稍后重试。"}
		subject["manifest"] = app._manifest_write_payload(app.manifest)
		subject["viewportId"] = preset
		var revision: int = session.revision
		var current := func() -> bool: return session.revision == revision and context_matches(app, subject)
		if prepare.is_valid():
			var issue: String = prepare.call(subject.map, current)
			if not issue.is_empty():
				return {"error": issue}
		return {"subject": subject, "default_size": canvas.get_viewport_rect().size,
			"current": current}
	FrameDialog.open(app, CAPABILITY, {"title": "关卡游戏画面预览", "button": "渲染关卡",
		"hint": "用游戏渲染当前关卡和画布取景。未保存的地图与暂存内容会随请求传入。",
		"prefix": "MapGamePreview", "default_label": "当前画布大小", "pick_mode": mode, "pick": choose,
		"camera": true, "initial": "中心与缩放留空时使用当前画布相机。"}.merged(extra), capture, valid)

static func map_context(app) -> Dictionary:
	var canvas: EditorCanvas = app.canvas
	var map := canvas.extract()
	if map.is_empty():
		return {}
	return {"map": map, "eventDrawings": RefIndex.event_drawings(app.manifest, canvas.cur_map_code()),
		"stagedContent": _staged_content(app), "camera": _camera(canvas)}

static func context_matches(app, captured: Dictionary) -> bool:
	return app.map_loaded and _camera(app.canvas) == captured.camera \
		and _staged_content(app) == captured.stagedContent

static func _staged_content(app) -> Array:
	var stage: Array = []
	if app.project_shell != null and app.project_shell.content_editor != null:
		for row in app.project_shell.content_editor.staged_rows_current_doc():
			stage.append({"function": row.fn_id, "content": row.cid, "data": row.data})
	return stage

static func _camera(canvas: EditorCanvas) -> Dictionary:
	return {"center": [canvas.cam_pos.x, canvas.cam_pos.y], "zoom": canvas.zoom}
