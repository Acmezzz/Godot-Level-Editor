extends RefCounted
## Captures the current map work copy for the game-owned renderer.

const GamePreview := preload("res://src/project/game_preview.gd")
const FrameDialog := preload("res://src/ui/game_frame_dialog.gd")
const FieldWidgets := preload("res://src/ui/field_widgets.gd")
const Assets := preload("res://src/assets/asset_decl.gd")
const Geometry := preload("res://src/map/object_geometry.gd")
const CAPABILITY := "mapFrame"

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

static func open_reference(app, decl: Dictionary, resolve: Callable, commit: Callable) -> void:
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
	_open(app, mode, choose)

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
		var camera := canvas.cam_pos
		var zoom := canvas.zoom
		subject["manifest"] = app._manifest_write_payload(app.manifest)
		subject["viewportId"] = preset
		var revision: int = session.revision
		return {"subject": subject, "default_size": canvas.get_viewport_rect().size,
			"summary": " · 中心 (%.1f, %.1f) · 缩放 ×%.2f" % [camera.x, camera.y, zoom],
			"current": func(): return session.revision == revision}
	FrameDialog.open(app, CAPABILITY, {"title": "关卡游戏画面预览", "button": "渲染关卡",
		"hint": "用游戏渲染当前关卡和画布取景。未保存的地图与暂存内容会随请求传入。",
		"prefix": "MapGamePreview", "default_label": "当前画布大小", "pick_mode": mode, "pick": choose,
		"initial": "可切换画幅，取景中心和缩放仍使用画布当前相机。"}.merged(extra), capture, valid)

static func map_context(app) -> Dictionary:
	var canvas: EditorCanvas = app.canvas
	var map := canvas.extract()
	if map.is_empty():
		return {}
	var stage: Array = []
	if app.project_shell != null and app.project_shell.content_editor != null:
		for row in app.project_shell.content_editor.staged_rows_current_doc():
			stage.append({"function": row.fn_id, "content": row.cid, "data": row.data})
	var center := canvas.cam_pos
	return {"map": map, "stagedContent": stage, "camera": {"center": [center.x, center.y], "zoom": canvas.zoom}}
