extends RefCounted
## Captures the current map work copy for the game-owned renderer.

const GamePreview := preload("res://src/project/game_preview.gd")
const FrameDialog := preload("res://src/ui/game_frame_dialog.gd")
const FieldWidgets := preload("res://src/ui/field_widgets.gd")
const Assets := preload("res://src/assets/asset_decl.gd")
const Geometry := preload("res://src/map/object_geometry.gd")
const GridBrush := preload("res://src/ui/frame_grid_brush.gd")
const ObjectEdit := preload("res://src/ui/frame_object_edit.gd")
const CellGraphEdit := preload("res://src/ui/frame_cell_graph.gd")
const Maps := preload("res://src/map/map_store.gd")
const RefIndex := preload("res://src/project/reference_index.gd")
const Recovery := preload("res://src/map/recovery.gd")
const ViewData := preload("res://src/map/map_view_data.gd")
const Graph := preload("res://src/map/cell_graph.gd")
const Layout := preload("res://src/project/screen_layout.gd")
const CAPABILITY := "mapFrame"

static func available(app) -> bool:
	return app.map_loaded and GamePreview.supports(app.manifest, CAPABILITY)

static func open(app) -> void:
	if app.map_loaded and app.canvas._is_grid_layer(app.canvas.active_layer):
		_open(app, "collision", Callable(), {"title": "关卡游戏画面 · 碰撞笔刷",
			"interaction": GridBrush.new(app.canvas, true), "confirm_label": "应用碰撞笔画"})
		return
	if app.map_loaded and app.canvas.place_kind != "object" and app.canvas.source_of_asset(app.canvas.paint_asset) >= 0:
		_open(app, "placement", Callable(), {"interaction": GridBrush.new(app.canvas), "confirm_label": "应用笔画"})
		return
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

static func open_object_edit(app) -> void:
	if available(app):
		_open(app, "objectEdit", Callable(), {"title": "实景调整实例和轮廓",
			"interaction": ObjectEdit.new(app.canvas), "tools": ObjectEdit.TOOLS,
			"confirm_label": "应用调整", "refresh_on_apply": true})

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

static func open_cell_graph(app) -> void:
	if not available(app):
		return
	var editor := CellGraphEdit.new(app.canvas)
	var index := Maps.code_index(app.manifest)
	var maps := []
	for name in index.names:
		var code: String = index.by_name.get(name, "")
		if code != "" and code != app.canvas.cur_map_code() and RefIndex.resolve_graph_map(index, code).status == "ok":
			maps.append({"name": name, "code": code})
	var controls := editor.controls(maps)
	var bind_current := func(parent: Window, current: Callable):
		editor.destination_button.pressed.connect(func(): _open_cell_destination(app, editor, parent, current))
	_open(app, "cellGraphEdit", Callable(), {"title": "实景编辑格图", "interaction": editor,
		"tools": CellGraphEdit.TOOLS, "controls": controls, "controls_changed": editor.controls_changed,
		"bind_current": bind_current,
		"confirm_label": "应用格图调整", "refresh_on_apply": true})

static func _open_cell_destination(app, editor, parent: Window, source_current: Callable) -> void:
	if not source_current.call() or not editor.destination_row.visible:
		return
	var manifest: Dictionary = app.manifest
	var code: String = editor.destination_map.get_selected_metadata()
	var source := [editor.tool, editor.from, editor.pending.get("id", "")]
	var valid := func() -> bool:
		return source_current.call() and editor.destination_row.visible \
			and source == [editor.tool, editor.from, editor.pending.get("id", "")]
	var rendered := {}
	var prepare := func(map: Dictionary, current: Callable) -> String:
		var cells := Graph.cell_ids(Graph.graph_of(map.meta))
		if cells.is_empty():
			return "请先在目标地图创建格并保存。"
		rendered.assign({"cells": cells, "current": current})
		return ""
	var choose := func(cell: String) -> Dictionary:
		if not rendered.cells.has(cell):
			return {"text": "请选择目标地图已有的格。"}
		var current: Callable = rendered.current
		return {"text": "终点：%s / %s" % [code, cell],
			"apply": func(): return editor.set_destination(code, cell, current)}
	FrameDialog.open(app, CAPABILITY, {"title": "跨地图选择终点 · " + code, "button": "渲染目标地图",
		"hint": "目标地图使用已保存版本。确认选点后，回到起点地图应用连接。",
		"prefix": "MapGamePreview", "default_label": "当前画布大小", "pick_mode": "cell", "pick": choose,
		"camera": true, "parent": parent}, _saved_snapshot.bind(app, manifest, code, true, prepare), valid)

static func _saved_snapshot(preset: String, app, manifest: Dictionary, key: String,
		stable_code: bool, prepare: Callable) -> Dictionary:
	var resolve := func() -> Dictionary:
		return RefIndex.resolve_graph_map(Maps.code_index(manifest), key) if stable_code \
			else RefIndex.resolve_map(manifest, key)
	var resolved: Dictionary = resolve.call()
	if resolved.status != "ok":
		return {"error": "目标地图不可读或地图键不唯一。"}
	var path := Maps.path_for(manifest, resolved.key)
	var result := Maps.read_path(path, manifest)
	if not result.ok or (stable_code and result.data.meta.code != key):
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
	return {"subject": {"map": map, "manifest": app._manifest_write_payload(manifest), "viewportId": preset,
		"camera": {"center": [center.x, center.y], "zoom": zoom}, "stagedContent": []},
		"default_size": default_size, "current": current}

static func reference_available(app, map_key: String) -> bool:
	return GamePreview.supports(app.manifest, CAPABILITY) and (app.map_loaded or map_key != "")

static func open_reference(app, decl: Dictionary, resolve: Callable, commit: Callable, window: Window) -> void:
	var mode := FieldWidgets.pick_mode(decl)
	var source := decl.duplicate()
	match mode:
		"entity":
			source["source"] = "entity_inst:" + ",".join(PackedStringArray(FieldWidgets.canvas_pick_types(decl)))
		"port":
			source["source"] = "port:" + str(decl.get("of", ""))
		"edge":
			source["source"] = "edge:"
	var choose := func(value: Variant) -> Dictionary:
		for row in resolve.call(source):
			var candidate = FieldWidgets.decode_pick(mode, str(row.v))
			if candidate != null and candidate == value:
				return {"text": "目标：" + str(row.t), "apply": func(): return await commit.call(candidate)}
		return {"text": "该画面目标不在字段的候选范围内。"}
	var key := str(decl.get("_mapKey", ""))
	var local: bool = key == "" or (app.map_loaded and key in [app.canvas.cur_map_code(), app.canvas.cur_map_name])
	var parent := {"parent": window} if window is PopupPanel else {}
	if local:
		_open(app, mode, choose, parent)
	else:
		var session = app._map_file_ctrl.sess
		var generation: int = session.generation
		var valid := func() -> bool: return not session.stale(generation)
		var options := {"title": "实景选引用 · " + key, "button": "渲染目标地图",
			"hint": "使用引用字段指定地图的已保存版本。确认后只写入当前字段。",
			"prefix": "MapGamePreview", "default_label": "当前窗口大小", "pick_mode": mode, "pick": choose, "camera": true}
		FrameDialog.open(app, CAPABILITY, options.merged(parent),
			_saved_snapshot.bind(app, app.manifest, key, false, Callable()), valid)

static func _open(app, mode: String, choose: Callable, extra := {}) -> void:
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
		return {"subject": subject, "default_size": canvas.get_viewport_rect().size,
			"current": func(): return session.revision == revision and context_matches(app, subject)}
	FrameDialog.open(app, CAPABILITY, {"title": "关卡游戏画面预览", "button": "渲染关卡",
		"hint": "用游戏渲染当前关卡和画布取景。未保存的地图与暂存内容会随请求传入。",
		"prefix": "MapGamePreview", "default_label": "当前画布大小", "pick_mode": mode, "pick": choose,
		"camera": true, "initial": "中心与缩放留空时使用当前画布相机。"}.merged(extra), capture, valid)

static func map_context(app) -> Dictionary:
	var canvas: EditorCanvas = app.canvas
	var map := canvas.extract()
	if map.is_empty():
		return {}
	return {"map": map, "stagedContent": _staged_content(app), "camera": _camera(canvas)}

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
