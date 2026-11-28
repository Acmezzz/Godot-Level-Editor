extends RefCounted
## Images come either from an editor viewport or from a declared game renderer.

const Runner := preload("res://src/project/game_preview.gd")
const MapView := preload("res://src/map/map_view_data.gd")
const MapPreview := preload("res://src/ui/map_game_preview.gd")
const Assets := preload("res://src/assets/asset_decl.gd")
const Audio := preload("res://src/content/audio_decl.gd")
const AudioPreview := preload("res://src/ui/timeline_audio_preview.gd")
const Clock := preload("res://src/content/timeline_clock.gd")
const Layout := preload("res://src/project/screen_layout.gd")
const Recovery := preload("res://src/map/recovery.gd")

var drafts: RefCounted
var app

func _init(store: RefCounted) -> void:
	drafts = store
	app = store.app

func capture(args: Dictionary, batch: Dictionary) -> Dictionary:
	if DisplayServer.get_name() == "headless":
		return {"error": "截图需要以图形模式运行编辑器。"}
	var target: String = args.get("target", "window")
	if target == "draft_map":
		if not args.has("draft"):
			return {"error": "草稿画布需要 draft。"}
		var frame := await draft_frame(args, batch)
		if frame.has("error"):
			return frame
		return _capture_result(frame.image, args, {"target": "draft_map", "map": args.get("map", "")})
	if args.has("draft"):
		return {"error": "草稿截图请使用 target: draft_map，草稿屏幕或演出请使用 render_preview。"}
	if args.has("panel") or args.has("map"):
		var problem := await _navigate(args)
		if problem != "":
			return {"error": problem}
	var tree: SceneTree = app.get_tree()
	await tree.process_frame
	if args.get("delayMs", 0) > 0:
		await tree.create_timer(clampf(args.delayMs / 1000.0, 0.0, 30.0)).timeout
	var root := tree.root
	var windows: Array[Window] = []
	var items: Array = []
	_collect(root, root, windows, items)
	if target == "tree":
		return {"windows": windows.map(func(w): return {"path": str(w.get_path()), "title": w.title}),
			"controls": items}
	var viewport: Viewport = root
	var area := Rect2()
	var subject: String = target
	match target:
		"popup":
			if windows.size() < 2:
				return {"error": "当前没有可见的弹窗。"}
			viewport = windows.back()
			if args.has("window"):
				var chosen := root.get_node_or_null(args.window) as Window
				if chosen == null or chosen not in windows or chosen == root:
					return {"error": "该弹窗不可见；先用 target: tree 查找路径。"}
				viewport = chosen
			subject = str(viewport.get_path())
		"canvas":
			if not app.map_loaded or not app.canvas.is_visible_in_tree():
				return {"error": "当前没有可见的地图画布。"}
			viewport = app.canvas.get_viewport()
		"control":
			var control := root.get_node_or_null(str(args.get("control", ""))) as Control
			if control == null or not control.is_visible_in_tree() or not control.get_window().visible:
				return {"error": "找不到可见的控件；先用 target: tree 查看路径。"}
			viewport = control.get_viewport()
			var transform := control.get_global_transform_with_canvas()
			area = transform * Rect2(Vector2.ZERO, control.size)
			var ancestor := control.get_parent()
			while ancestor is Control:
				if ancestor.clip_contents:
					area = area.intersection(ancestor.get_global_transform_with_canvas() * Rect2(Vector2.ZERO, ancestor.size))
				ancestor = ancestor.get_parent()
			if not area.has_area():
				return {"error": "控件当前已被裁掉，请先滚动到可见位置。"}
			subject = str(control.get_path())
	await RenderingServer.frame_post_draw
	if not is_instance_valid(viewport):
		return {"error": "截图前窗口已关闭。"}
	var image := viewport.get_texture().get_image()
	if image == null or image.is_empty():
		return {"error": "当前视口没有可用的画面。"}
	if area.has_area():
		var scale := Vector2(image.get_size()) / viewport.get_visible_rect().size
		image = _crop(image, Rect2i(area.position * scale, area.size * scale))
		if image == null:
			return {"error": "控件在当前画面之外。"}
	return _capture_result(image, args, {"target": subject})

static func _capture_result(image: Image, args: Dictionary, info: Dictionary) -> Dictionary:
	if args.has("rect"):
		var rect: Array = args.rect
		if rect.size() != 4 or not rect.all(_number):
			return {"error": "rect 必须是 [x,y,w,h]。"}
		image = _crop(image, Rect2i(int(rect[0]), int(rect[1]), int(rect[2]), int(rect[3])))
		if image == null:
			return {"error": "截图范围与画面没有交集。"}
	return _image_result(image, info)

func _collect(node: Node, root: Window, windows: Array[Window], items: Array) -> void:
	if node is Window:
		if node != root and not node.visible:
			return
		windows.append(node)
	if node is Control:
		if not node.is_visible_in_tree():
			return
		var rect: Rect2 = node.get_global_rect()
		items.append({"path": str(node.get_path()), "class": node.get_class(),
			"text": str(node.get("text")).left(200) if node is Label or node is BaseButton or node is LineEdit or node is RichTextLabel else "",
			"rect": [rect.position.x, rect.position.y, rect.size.x, rect.size.y],
			"window": str(node.get_window().get_path())})
	for child in node.get_children():
		_collect(child, root, windows, items)

func _navigate(args: Dictionary) -> String:
	if app.manifest.is_empty() or app.manifest.has("_error"):
		return "请先打开游戏工程。"
	if args.has("map") and (not app.map_loaded or app.canvas.cur_map_code() != args.map):
		if app.map_loaded and (app.canvas.modified_flag or app.canvas.doc_busy \
				or app.project_shell.content_editor.has_staged_for_current_doc()):
			return "当前地图有未保存的编辑，请先处理。"
		await app._map_file_ctrl.open_map_by_code(args.map)
		if not app.map_loaded or app.canvas.cur_map_code() != args.map:
			return "无法打开地图：" + args.map
	match args.get("panel", "map" if args.has("map") else ""):
		"map":
			app._set_mode("map")
			if args.has("instance") and (not app.map_loaded or not app.canvas.focus_entity_code(args.instance)):
				return "找不到该实例。"
			if args.has("camera") and app.map_loaded:
				_set_camera(app.canvas, args.camera)
		"assets", "content":
			app._set_mode("asset" if args.panel == "assets" else "content", str(args.get("instance", "")))
		"groups": preload("res://src/ui/event_layers_dialog.gd").open(app)
		"screens": preload("res://src/ui/reference_view_library.gd").open(app, args.get("view", ""))
		"world": preload("res://src/ui/world_layout_editor.gd").open(app)
		"viewports": preload("res://src/ui/viewport_library.gd").open(app)
		"startup": preload("res://src/ui/startup_dialog.gd").open(app)
		"flow":
			var flow := preload("res://src/ui/map_flow_dialog.gd")
			if not flow.available(app):
				return "当前地图没有可编辑的内容槽位或流程出口。"
			flow.open(app)
		"library": app.project_shell.content_editor.open_project_library()
		"playtest": app._playtest_ctrl.open_configuration()
		"timeline":
			app._set_mode("content", str(args.get("instance", "")))
			if args.get("function", "") == "" or args.get("content", "") == "":
				return "演出截图需要 function 和 content。"
			if not app.project_shell.content_editor.open_content_timeline(
					args.function, args.content, args.get("map", ""), args.get("time")):
				return "无法定位此演出内容。"
		"": pass
		_: return "未知编辑器面板：" + str(args.panel)
	return ""

func draft_frame(args: Dictionary, batch: Dictionary) -> Dictionary:
	var code: String = args.get("map", "")
	var row: Dictionary = drafts.map_of(batch, code)
	if row.is_empty():
		return {"error": "草稿地图不存在：" + code}
	var candidate: Dictionary = drafts.candidate(batch)
	var size := _size(args, candidate)
	if not Runner.valid_size(size):
		return {"error": "画幅大小无效。"}
	var viewport := SubViewport.new()
	viewport.world_2d = World2D.new()
	viewport.size = size
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var canvas := EditorCanvas.new()
	canvas.manifest = candidate
	canvas.app_host = app
	canvas.ent_sizes = app._entity_sizes()
	canvas.set_thumbs(app._entity_thumbs())
	viewport.add_child(canvas)
	app.get_tree().root.add_child(viewport)
	await canvas.load_data(row.data, row.name)
	if not canvas.is_map_ready():
		viewport.queue_free()
		return {"error": "无法建立草稿地图的画布。"}
	var drawings: Array[Dictionary] = []
	drawings.assign(drafts.event_drawings(batch, canvas.manifest, code))
	canvas.show_drawing_context(drawings)
	var bounds := MapView.scene_bounds(row.data, canvas.manifest)
	var center := bounds.get_center()
	var zoom := minf(size.x / maxf(bounds.size.x, 1.0), size.y / maxf(bounds.size.y, 1.0)) * 0.9
	canvas.cam_pos = center
	canvas.zoom = zoom
	_set_camera(canvas, args.get("camera", {}))
	if args.has("instance") and not canvas.focus_entity_code(args.instance):
		viewport.queue_free()
		return {"error": "找不到该实例。"}
	await app.get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	viewport.queue_free()
	return {"image": image} if image != null and not image.is_empty() else {"error": "无法获取草稿画面。"}

static func _set_camera(canvas: EditorCanvas, camera: Dictionary) -> void:
	if camera.has("center") and _pair(camera.center):
		canvas.cam_pos = Vector2(camera.center[0], camera.center[1])
	if _number(camera.get("zoom")) and camera.zoom > 0:
		canvas.zoom = camera.zoom
	canvas._update_cam()

func render(args: Dictionary, batch: Dictionary) -> Dictionary:
	var m: Dictionary = drafts.candidate(batch)
	var capability: String = args.capability
	var size := _size(args, m)
	if not Runner.valid_size(size):
		return {"error": "画幅大小无效。"}
	if not Runner.supports(m, capability):
		return {"error": "游戏工程未声明此预览能力：" + capability}
	var profile: String = args.get("profile", "")
	var snapshot: Dictionary = app._manifest_write_payload(m)
	var code: String = args.get("map", "")
	var body := {"manifest": snapshot, "viewportId": profile}
	var clock := Clock.new("seconds", {})
	if capability in ["mapFrame", "timelineFrame", "playtestFrame"] and code != "":
		var row: Dictionary = drafts.map_of(batch, code)
		if row.is_empty():
			return {"error": "地图不存在：" + code}
		var bounds := MapView.scene_bounds(row.data, m)
		var center := bounds.get_center()
		var zoom := minf(size.x / maxf(bounds.size.x, 1.0), size.y / maxf(bounds.size.y, 1.0)) * 0.9
		body.merge({"map": row.data, "eventDrawings": drafts.event_drawings(batch, m, code),
			"stagedContent": _staged(batch),
			"camera": args.get("camera", {"center": [center.x, center.y], "zoom": zoom})})
	match capability:
		"mapFrame":
			if code == "":
				return {"error": "mapFrame 需要 map。"}
		"screenLayout":
			var row := _view(m, args.get("view", ""))
			if not row.get("layout") is Dictionary:
				return {"error": "此屏幕没有布局声明。"}
			body = row
		"timelineFrame":
			var fn: String = args.get("function", "")
			var cid: String = args.get("content", "")
			var row: Dictionary = drafts.content_of(batch, fn, cid)
			if row.is_empty():
				return {"error": "演出内容不存在。"}
			var clock_decl := Clock.from_decl(m, fn, row.data)
			clock = Clock.new(clock_decl.timebase, clock_decl.cfg)
			body.merge({"function": fn, "content": cid, "data": row.data})
			if args.has("instance"):
				if not body.has("map"):
					return {"error": "实例演出需指定 map。"}
				var objects: Array = body.map.get("objects", []).filter(func(obj): return obj.get("code") == args.instance)
				if objects.is_empty():
					return {"error": "未找到该实例。"}
				var bindings: Array = objects[0].get("functions", [])
				var index := bindings.find_custom(func(row_): return row_.get("bindingId") == args.get("binding", ""))
				if index < 0:
					return {"error": "实例演出需指定有效的 binding。"}
				body.merge({"instance": args.instance, "bindingId": args.binding, "bindingIndex": index})
		"worldFrame":
			body["camera"] = args.get("camera", {"center": [0, 0], "zoom": 1.0})
			var overrides := {}
			for id in batch.maps:
				var row: Dictionary = batch.maps[id]
				overrides[id] = {"map": row.data, "stagedContent": _staged(batch)} if not row.get("deleted", false) else {"deleted": true}
			body["overrides"] = overrides
		"playtestFrame":
			body.merge({"view": args.get("view", ""), "stagedContent": _staged(batch)})
	var times: Array = args.get("times", [0.0])
	if times.is_empty() or times.size() > 12 or not times.all(func(n): return _number(n) and n >= 0):
		return {"error": "times 必须包含 1–12 个非负取样位置。"}
	var unit: String = args.get("unit", clock.timebase)
	if unit not in [clock.timebase, "seconds"]:
		return {"error": "取样单位请使用秒或该时间轴的原生单位：" + clock.timebase}
	var frames := []
	var attachments := []
	var keep := func() -> bool: return app.manifest.get("_dir") == m._dir
	for moment in times:
		var subject := body.duplicate(true)
		if capability in ["timelineFrame", "playtestFrame"]:
			var sec: float = moment if unit == "seconds" else clock.seconds_at(moment)
			subject["time"] = {"value": clock.value_at(sec) if clock.is_ready() and unit != clock.timebase else moment,
				"unit": clock.timebase if clock.is_ready() else unit, "seconds": null}
			if is_finite(sec):
				subject.time.seconds = sec
		var result := await Runner.render(app.get_tree(), m, capability, subject, size, args.get("locale", ""), keep, profile)
		if result.error != "":
			return {"error": result.error, "frames": frames, "_media": attachments}
		attachments.append(_image(result.image))
		frames.append({"sample": moment, "width": size.x, "height": size.y,
			"picks": _pick_regions(result.get("picks", [])), "pickError": result.get("pick_error", "")})
	return {"frames": frames, "unit": unit, "_media": attachments}

func asset(args: Dictionary) -> Dictionary:
	var m: Dictionary = app.manifest
	if args.has("audio"):
		return _audio(args, m)
	var id: String = args.get("asset", "")
	var row := Assets.by_id(m, id)
	if row.is_empty():
		return {"error": "资产不存在：" + id}
	var attachments := []
	var frames: Array = args.get("frames", [0])
	var paths = row.get("frames", [])
	if paths is Array and not paths.is_empty():
		if frames.is_empty() or frames.size() > 24 or not frames.all(func(i): return _number(i) and i == floorf(i) and i >= 0 and i < paths.size()):
			return {"error": "frames 需要 1–24 个有效动画帧下标。"}
		for i in frames:
			var image := _asset_file(m, str(paths[int(i)]))
			if image == null:
				return {"error": "动画帧无法读取：" + str(i)}
			attachments.append(_image(image))
	else:
		var tile: bool = row.get("shape") == "tile"
		var path := str(row.get("atlas_abs", "")) if tile else str(row.get("thumb", row.get("texture", "")))
		var image := _asset_file(m, path)
		if image != null and tile and args.has("cell"):
			var cell: Array = args.cell
			if not _pair(cell) or not cell.all(func(i): return i == floorf(i) and i >= 0):
				return {"error": "cell 必须是非负整数坐标 [x,y]。"}
			var extent := Assets.cell_size(m, id)
			var rect := Rect2i(Vector2i(int(cell[0]), int(cell[1])) * extent, extent)
			if not Rect2i(Vector2i.ZERO, image.get_size()).encloses(rect):
				return {"error": "图集格超出图片边界。"}
			image = image.get_region(rect)
		if image != null:
			attachments.append(_image(image))
		elif path != "":
			return {"error": "图片无法读取。", "asset": row}
		elif row.get("kind") == "entity" and row.has("visual") and DisplayServer.get_name() != "headless":
			var shape := await _shape_image(m, id, row)
			if shape != null:
				attachments.append(_image(shape))
	return {"asset": row, "frames": frames if paths is Array and not paths.is_empty() else [], "_media": attachments}

func _shape_image(m: Dictionary, id: String, row: Dictionary) -> Image:
	var viewport := SubViewport.new()
	viewport.world_2d = World2D.new()
	viewport.size = Vector2i(256, 256)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var size := EditorManifest.entity_editor_size(m, row)
	var entity := EntityNode.create(m, id, Vector2(size), 16)
	viewport.add_child(entity)
	app.get_tree().root.add_child(viewport)
	var bounds := entity.aabb()
	if not bounds.has_area():
		bounds = Rect2(Vector2.ZERO, Vector2(16, 16))
	var ratio := 212.0 / maxf(bounds.size.x, bounds.size.y)
	entity.scale = Vector2.ONE * ratio
	entity.position = Vector2(128, 128) - bounds.get_center() * ratio
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	viewport.queue_free()
	return image

func _audio(args: Dictionary, m: Dictionary) -> Dictionary:
	var row := Audio.by_code(m, args.audio)
	if row.is_empty():
		row = Audio.audio(m).get(args.audio, {})
	if row.is_empty():
		return {"error": "音频未声明：" + args.audio}
	var rel := Audio.preview_relative_path(str(row.get("previewPath", row.path)))
	var path := str(m._dir).path_join(rel)
	if rel == "" or not FileAccess.file_exists(path):
		return {"error": "没有可试听的项目内音频文件。", "audio": row}
	var stream: AudioStream
	var mime := ""
	match rel.get_extension().to_lower():
		"wav":
			stream = AudioStreamWAV.load_from_file(path)
			mime = "audio/wav"
		"ogg":
			stream = AudioStreamOggVorbis.load_from_file(path)
			mime = "audio/ogg"
		"mp3":
			stream = AudioStreamMP3.load_from_file(path)
			mime = "audio/mpeg"
	if stream == null:
		return {"error": "无法解码音频。"}
	var response := {"audio": row, "duration": stream.get_length(), "waveform": []}
	var pcm := stream as AudioStreamWAV
	var sample_bytes := 0
	if pcm != null:
		match pcm.format:
			AudioStreamWAV.FORMAT_8_BITS: sample_bytes = 1
			AudioStreamWAV.FORMAT_16_BITS: sample_bytes = 2
		response.waveform = Array(AudioPreview._pcm_envelope(pcm)).map(func(range_): return [range_.x, range_.y])
	var bytes := PackedByteArray()
	if args.has("start") or args.has("duration"):
		if sample_bytes == 0:
			return response.merged({"error": "片段裁切需要未压缩的 PCM WAV；移除 start 和 duration 可试听原文件。"})
		var start := clampf(args.get("start", 0.0), 0.0, pcm.get_length())
		var end := minf(pcm.get_length(), start + clampf(args.get("duration", 10.0), 0.0, 60.0))
		if end <= start:
			return response.merged({"error": "指定的时间范围没有音频。"})
		bytes = _wav_clip(pcm, sample_bytes, start, end)
		response["clip"] = {"start": start, "end": end}
	else:
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null and f.get_length() <= 16 * 1024 * 1024:
			bytes = f.get_buffer(f.get_length())
		else:
			response["mediaNote"] = "原文件超过 16 MiB；PCM WAV 可以指定片段。"
	if not bytes.is_empty():
		response["_media"] = [{"type": "audio", "mimeType": mime, "data": Marshalls.raw_to_base64(bytes)}]
	return response

func playtest(args: Dictionary, batch: Dictionary) -> Dictionary:
	var ctrl = app._playtest_ctrl
	var pid: int = ctrl._play_pid
	var running := pid > 0 and Playtest.is_alive(pid)
	var request: Dictionary = ctrl._play_report_request
	match args.action:
		"status":
			var report := Playtest.read_report(request)
			return {"running": running, "pid": pid if running else 0, "report": report}
		"stop":
			if running and OS.kill(pid) != OK:
				return {"error": "无法停止该试玩进程。"}
			return {"stopped": running}
		"capture":
			if not running:
				return {"error": "没有正在运行的试玩。"}
			return await _live_frame(args, request)
	var target: Dictionary = args.get("target", {})
	var ok := false
	if args.has("draft") and args.get("entry", "project") != "screen":
		return {"error": "现有试玩协议支持未发布的屏幕快照。其他草稿需先发布，或使用 render_preview 渲染。"}
	match args.get("entry", "project"):
		"project":
			if app.manifest.get("playtest", {}).get("projectEntry", false) and ctrl._published_manifest_current():
				ok = ctrl._start_playtest("", "", PackedStringArray(), "项目入口")
		"map":
			if not target.get("map") is String:
				return {"error": "地图入口需要 map。"}
			ok = ctrl.play_map_entry(target)
		"content":
			if not target.get("function") is String or not target.get("content") is String:
				return {"error": "内容入口需要 function 和 content。"}
			ok = ctrl.play_content_entry(target, str(target.get("contentMap", "")))
		"screen":
			var id := str(target.get("view", ""))
			var row := _view(drafts.candidate(batch), id)
			if row.is_empty():
				return {"error": "未找到该屏幕。"}
			var snapshot := {}
			if args.has("draft"):
				var size := _size(args, drafts.candidate(batch))
				if not Runner.valid_size(size):
					return {"error": "画幅大小无效。"}
				snapshot = {"view": row, "viewport": [size.x, size.y],
					"viewportId": args.get("profile", ""), "locale": args.get("locale", "")}
			ok = ctrl.play_view(id, snapshot)
	return {"running": true, "pid": ctrl._play_pid} if ok else {"error": "无法从此入口试玩；检查游戏声明、入口和当前运行状态。"}

func _live_frame(args: Dictionary, report: Dictionary) -> Dictionary:
	if report.is_empty() or not app.manifest.get("playtest", {}).get("captureFrames", false):
		return {"error": "游戏未声明 playtest.captureFrames；render_preview 可提供离线取样。"}
	var size := _size(args, app.manifest)
	if not Runner.valid_size(size):
		return {"error": "画幅大小无效。"}
	var nonce := Crypto.new().generate_random_bytes(12).hex_encode()
	var stem: String = str(report.path).get_basename() + ".frame"
	var capture_file := stem + ".request.json"
	var result_file: String = stem + "." + nonce + ".png"
	if not Recovery.write_json(capture_file, {"version": 1, "token": report.token, "id": nonce,
			"width": size.x, "height": size.y, "result": result_file}):
		return {"error": "无法写入实时截图请求。"}
	var deadline := Time.get_ticks_msec() + 5000
	while not FileAccess.file_exists(result_file) and Time.get_ticks_msec() < deadline \
			and app._playtest_ctrl._play_pid > 0 and Playtest.is_alive(app._playtest_ctrl._play_pid):
		await app.get_tree().create_timer(0.05).timeout
	DirAccess.remove_absolute(capture_file)
	var bytes := Runner._read_bounded(result_file, Runner.MAX_PNG)
	if FileAccess.file_exists(result_file):
		DirAccess.remove_absolute(result_file)
	var image := Image.new()
	if bytes.is_empty() or not Runner._matches_png_size(bytes, size) or image.load_png_from_buffer(bytes) != OK:
		return {"error": "试玩没有及时返回有效的实时 PNG。"}
	return _image_result(image, {"target": "live_game"})

static func _staged(batch: Dictionary) -> Array:
	return batch.contents.values().filter(func(row): return not row.get("deleted", false)).map(
		func(row): return {"function": row.function, "content": row.content, "data": row.data})

static func _view(m: Dictionary, id: String) -> Dictionary:
	for row in m.get("views", []):
		if row.get("view_id") == id:
			return row.duplicate(true)
	return {}

static func _size(args: Dictionary, m: Dictionary) -> Vector2i:
	var preset: Vector2 = Layout.sizes(m).get(args.get("profile", ""), Vector2(1280, 720))
	return Vector2i(int(args.get("width", preset.x)), int(args.get("height", preset.y)))

static func _pair(raw: Variant) -> bool:
	return raw is Array and raw.size() == 2 and raw.all(_number)

static func _number(n: Variant) -> bool:
	return (n is float or n is int) and is_finite(float(n))

static func _crop(image: Image, rect: Rect2i) -> Image:
	var region := rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	return image.get_region(region) if region.has_area() else null

static func _image(image: Image) -> Dictionary:
	return {"type": "image", "mimeType": "image/png", "data": Marshalls.raw_to_base64(image.save_png_to_buffer())}

static func _image_result(image: Image, info: Dictionary) -> Dictionary:
	if image == null or image.is_empty():
		return {"error": "无法获取图像。"}
	return info.merged({"width": image.get_width(), "height": image.get_height(), "_media": [_image(image)]})

static func _asset_file(m: Dictionary, path: String) -> Image:
	if path == "":
		return null
	if path.is_absolute_path():
		return Image.load_from_file(path) if FileAccess.file_exists(path) else null
	var tex := EntityNode.texture_of(m, path)
	return tex.get_image() if tex != null else null

static func _pick_regions(rows: Array) -> Array:
	var out := []
	for row in rows:
		var region: Dictionary = {"screen": Array(row.screen).map(func(p): return [p.x, p.y]),
			"label": row.label, "targets": row.targets, "occludes": row.occludes}
		for key in ["placement", "collision"]:
			var mapping: Dictionary = row[key]
			if not mapping.is_empty():
				var weights: Vector3 = mapping.reciprocal
				region[key] = {"local": Array(mapping.local).map(func(p): return [p.x, p.y]),
					"reciprocalW": [weights.x, weights.y, weights.z]}
				if key == "placement":
					region[key]["layer"] = mapping.layer
		out.append(region)
	return out

static func _wav_clip(wav: AudioStreamWAV, sample_bytes: int, start: float, end: float) -> PackedByteArray:
	var channels := 2 if wav.stereo else 1
	var stride := sample_bytes * channels
	var first := floori(start * wav.mix_rate) * stride
	var last := floori(end * wav.mix_rate) * stride
	var bytes := wav.data.slice(first, last)
	if sample_bytes == 1:
		for i in bytes.size():
			bytes[i] = bytes[i] ^ 128
	var header := ("RIFF    WAVEfmt " + " ".repeat(20) + "data    ").to_ascii_buffer()
	header.encode_u32(4, bytes.size() + 36 + bytes.size() % 2)
	header.encode_u32(16, 16)
	header.encode_u16(20, 1)
	header.encode_u16(22, channels)
	header.encode_u32(24, wav.mix_rate)
	header.encode_u32(28, wav.mix_rate * stride)
	header.encode_u16(32, stride)
	header.encode_u16(34, sample_bytes * 8)
	header.encode_u32(40, bytes.size())
	header.append_array(bytes)
	if bytes.size() % 2:
		header.append(0)
	return header
