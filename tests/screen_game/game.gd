extends Control
## Signal Room owns its UI, styling, state transitions and loading. No editor scripts are imported.

var manifest: Dictionary
var manifest_bytes: PackedByteArray
var map_bytes: PackedByteArray
var draft_digest := ""
var draft_locale := ""
var draft_view := ""
var draft_profile := ""
var draft_extent := Vector2.ZERO
var report := {}
var visited: Array[String] = []
var screens: Array[String] = []
var opened_buttons: Array[String] = []
var latch_inputs: Array[int] = []
var outlets: Array[String] = []
var screen_frames: Array[Dictionary] = []
var cancel_target := {}
var entered_board := {}
var runtime_course := {}
var verify := false

func _ready() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var split := arg.split("=", true, 1)
		args[split[0]] = split[1] if split.size() == 2 else ""
	if args.has("--editor-preview"):
		await _preview(args["--editor-preview"])
		return
	var manifest_path := "res://editor/editor_manifest.json"
	manifest_bytes = FileAccess.get_file_as_bytes(manifest_path)
	manifest = JSON.parse_string(manifest_bytes.get_string_from_utf8())
	verify = args.has("--verify")
	if args.has("--editor-playtest"):
		report = _decode(args["--editor-playtest"])
	if args.get("--map", "") != "":
		map_bytes = FileAccess.get_file_as_bytes(args["--map"])
		await _play_relay(JSON.parse_string(map_bytes.get_string_from_utf8()))
		return
	var entry: Dictionary = _decode(args["--editor-entry"]) if args.has("--editor-entry") else (
		manifest.get("startup", {}).get("target", {"function": "signal", "content": "project-default"}))
	if entry.has("viewDraft") and not _load_view_draft(entry):
		_finish("Cannot load this screen draft.")
		return
	_follow_target(entry)

func _follow_target(target: Dictionary, content_board := "") -> void:
	if target.has("view"):
		_show_view(target.view)
	elif target.has("map"):
		_show_map_target(target)
	else:
		_show_content(target, content_board)

func _show_map_target(destination: Dictionary) -> void:
	var code: String = destination.map
	for filename in DirAccess.get_files_at("res://maps"):
		if not filename.ends_with(".json"):
			continue
		var map = JSON.parse_string(FileAccess.get_file_as_string("res://maps/" + filename))
		if not map is Dictionary or map.get("meta", {}).get("code") != code:
			continue
		cancel_target = {}
		_clear_screen()
		var pawns := _draw_relay(self, map, _relay_camera(size))
		entered_board = {"board": code, "placed": pawns.keys()}
		if destination.has("port"):
			if not pawns.has(destination.inst):
				_finish("The arrival instance is missing.")
				return
			entered_board.merge({"arrivalInstance": destination.inst, "arrivalPort": destination.port})
		for row in map.objects:
			var target: Dictionary = row.get("props", {}).get("local_signal", {})
			if not target.is_empty():
				var signal_data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
					"res://content/%s/%s.json" % [target.function, target.content]))
				entered_board["localActor"] = signal_data.fields.ACTR
				break
		var exit_target: Dictionary = map.meta.get("flowOutputs", {}).get("completed", {})
		if exit_target.is_empty():
			for row in map.objects:
				exit_target = row.get("props", {}).get("exit_target", {})
				if not exit_target.is_empty():
					break
		if not exit_target.is_empty():
			var round_target: Dictionary = map.meta.get("contentSlots", {}).get("round", {})
			var required := 1
			if not round_target.is_empty():
				var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
					"res://content/%s/%s.json" % [round_target.function, round_target.content]))
				required = int(config.fields.INPT)
				entered_board["roundRules"] = round_target.content
				var role: Dictionary = config.fields.get("ROLE", {})
				if not role.is_empty():
					var role_config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
						"res://content/%s/%s.json" % [role.function, role.content]))
					var host_code: String = role_config.fields.HOST
					if not pawns.has(host_code):
						_finish("The round host is missing from this board.")
						return
					entered_board["roundHost"] = host_code
			entered_board["roundInputs"] = 0
			var leave := Button.new()
			leave.text = "Finish course (0/%d)" % required
			leave.position = Vector2(16, 16)
			add_child(leave)
			leave.pressed.connect(func():
				entered_board.roundInputs += 1
				leave.text = "Finish course (%d/%d)" % [entered_board.roundInputs, required]
				if entered_board.roundInputs == required:
					_follow_target.call_deferred(exit_target))
			if verify:
				await _verify_button(leave)
			return
		if verify:
			_finish("", "Board entered")
		return
	_finish("Missing target map: " + code)

func _decode(encoded: String) -> Dictionary:
	return JSON.parse_string(Marshalls.base64_to_utf8(encoded))

func _load_view_draft(entry: Dictionary) -> bool:
	var bytes := FileAccess.get_file_as_bytes(entry.viewDraft)
	var snapshot = JSON.parse_string(bytes.get_string_from_utf8())
	if not snapshot is Dictionary or snapshot.get("version") != 1 or snapshot.get("token") != report.get("token") \
			or not snapshot.get("view") is Dictionary or snapshot.view.get("view_id") != entry.view:
		return false
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	draft_digest = hash.finish().hex_encode()
	draft_locale = snapshot.get("locale", "")
	draft_view = entry.view
	draft_profile = snapshot.get("viewportId", "")
	draft_extent = Vector2(snapshot.viewport[0], snapshot.viewport[1])
	get_window().size = Vector2i(draft_extent)
	var views: Array = manifest.get("views", [])
	var index := views.find_custom(func(row): return row.view_id == entry.view)
	if index < 0:
		views.append(snapshot.view)
	else:
		views[index] = snapshot.view
	manifest["views"] = views
	return true

func _show_content(target: Dictionary, content_board: String) -> void:
	cancel_target = {}
	var kind: String = target.function
	var cid: String = target.content
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://content/%s/%s.json" % [kind, cid]))
	if not data is Dictionary or data.get("function") != manifest.functions[kind].code:
		_finish("Missing signal content: " + cid)
		return
	visited.append(cid)
	_clear_screen()
	var fields: Dictionary = data.get("fields", {})
	if kind == "sequence":
		var handoff: Dictionary = data.steps[0].fields
		_follow_target.call_deferred(handoff.ROUT, str(handoff.BRD1))
		return
	if kind == "course_rules":
		var placements: Array = fields.get("PLAC", []).map(func(row):
			return {"asset": row.ASST, "column": row.COLM})
		var map := _course_map({"projection": fields.PROJ, "placements": placements},
			{"version": 1, "name": "Runtime Course", "code": "RUNTIME"})
		_draw_relay(self, map, _relay_camera(size))
		runtime_course["runtimeCourse"] = map.objects.map(func(row): return int(row.x))
		var next_button := Button.new()
		next_button.text = "Finish procedural course"
		next_button.position = Vector2(16, 16)
		add_child(next_button)
		next_button.pressed.connect(func(): _follow_target.call_deferred(fields.CNXT))
		if verify:
			await _verify_button(next_button)
		return
	var next: Dictionary = fields.get("NEXT", {})
	if not next.is_empty():
		_follow_target.call_deferred(next)
		return
	var view_id: String = fields.get("PANE", "")
	if view_id.is_empty():
		if fields.has("ACTR"):
			var found := false
			for filename in DirAccess.get_files_at("res://maps"):
				var map = JSON.parse_string(FileAccess.get_file_as_string("res://maps/" + filename))
				if map is Dictionary and map.meta.code == content_board:
					found = map.objects.any(func(row): return row.code == fields.ACTR)
					break
			if not found:
				_finish("Ending actor is not on the supplied board.")
				return
			runtime_course.merge({"endingActor": fields.ACTR, "endingBoard": content_board})
		var label := Label.new()
		label.text = str(fields.get("TEXT", ""))
		add_child(label)
		if verify:
			_finish("", label.text)
		return
	_show_view(view_id, cid == "project-watch")

func _clear_screen() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

func _show_view(view_id: String, test_cancel := false) -> void:
	for view in manifest.get("views", []):
		if view.view_id != view_id:
			continue
		cancel_target = {}
		_clear_screen()
		screens.append(view_id)
		var extent := draft_extent if view_id == draft_view else size
		var profile := draft_profile if view_id == draft_view else _viewport_profile(extent)
		var buttons := _draw_screen(self, view.layout, extent, draft_locale, profile)
		screen_frames.append({"id": profile, "size": [extent.x, extent.y]})
		if verify:
			if buttons.is_empty() or screens.size() > 8:
				_finish("The authored route did not reach a conclusion.")
				return
			var button: Button = buttons[0]
			await get_tree().process_frame
			var click := InputEventAction.new()
			if test_cancel and not cancel_target.is_empty():
				click.action = &"ui_cancel"
				click.pressed = true
				Input.parse_input_event(click)
				return
			await _verify_button(button)
		return
	_finish("Missing signal screen: " + view_id)

func _verify_button(button: Button) -> void:
	var click := InputEventAction.new()
	click.action = &"ui_accept"
	button.grab_focus()
	for i in 4:
		if not is_instance_valid(button) or not button.is_inside_tree():
			break
		for pressed in [true, false]:
			click.pressed = pressed
			Input.parse_input_event(click)
			await get_tree().process_frame

func _unhandled_input(event: InputEvent) -> void:
	if not cancel_target.is_empty() and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		outlets.append("cancelled")
		_follow_target.call_deferred(cancel_target)

func _viewport_profile(extent: Vector2) -> String:
	var wide := extent.x >= extent.y
	for profile in manifest.viewports:
		if (profile.w >= profile.h) == wide:
			return profile.id
	return ""

func _draw_screen(parent: Node, layout: Dictionary, extent: Vector2, locale: String, profile: String) -> Array[Button]:
	var background := ColorRect.new()
	background.color = Color("#10232b")
	background.size = extent
	parent.add_child(background)
	var buttons: Array[Button] = []
	var geometry := _screen_rectangles(layout.elements, extent, profile)
	for row in layout.elements:
		if not geometry.has(row.id):
			continue
		var bounds: Rect2 = geometry[row.id]
		if not bounds.has_area():
			continue
		var caption := str(row.get("textLocales", {}).get(locale, row.get("text", "")))
		var item: Control
		match row.kind:
			"button", "module":
				var button := Button.new()
				button.text = caption
				var latch: bool = row.get("module") == "signal-latch"
				var route: Dictionary = row.get("outputs", {})
				var remaining := [int(row.get("props", {}).get("presses", 3)) if latch else 1]
				var authored_count: int = remaining[0]
				var style := StyleBoxFlat.new()
				style.bg_color = Color("#cc711e") if row.get("style") == "signal/relay" else Color("#286968")
				button.add_theme_stylebox_override("normal", style)
				var target: Dictionary = route.get("accepted", row.get("target", {}))
				if latch and parent == self:
					cancel_target = route.get("cancelled", {})
				if not target.is_empty():
					button.pressed.connect(func():
						remaining[0] -= 1
						if remaining[0] != 0:
							return
						if latch:
							latch_inputs.append(authored_count)
							outlets.append("accepted")
						opened_buttons.append(button.text)
						_follow_target.call_deferred(target))
					buttons.append(button)
				item = button
			"text":
				var label := Label.new()
				label.text = caption
				item = label
			_:
				var panel := ColorRect.new()
				panel.color = Color("#286968")
				item = panel
		item.position = bounds.position
		item.size = bounds.size
		parent.add_child(item)
	return buttons

func _screen_rectangles(elements: Array, extent: Vector2, profile: String) -> Dictionary:
	var by_parent := {}
	for row in elements:
		var parent_id: String = row.get("parent", "")
		if not by_parent.has(parent_id):
			by_parent[parent_id] = []
		by_parent[parent_id].append(row)
	var bounds := {"": Rect2(Vector2.ZERO, extent)}
	var pending := [""]
	while not pending.is_empty():
		var parent_id: String = pending.pop_back()
		var container: Rect2 = bounds[parent_id]
		for row in by_parent.get(parent_id, []):
			var variant: Dictionary = row.get("variants", {}).get(profile, {})
			if variant.get("hidden", row.get("hidden", false)):
				continue
			var a: Array = variant.get("anchors", row.anchors)
			var o: Array = variant.get("offsets", row.get("offsets", [0, 0, 0, 0]))
			var top_left := Vector2(a[0], a[1]) * container.size + Vector2(o[0], o[1])
			var bottom_right := Vector2(a[2], a[3]) * container.size + Vector2(o[2], o[3])
			bounds[row.id] = Rect2(container.position + top_left, bottom_right - top_left)
			pending.append(row.id)
	return bounds

func _preview(path: String) -> void:
	var request: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	if request.get("capability") == "generateMap":
		_generate_course(path.get_base_dir(), request)
		get_tree().quit()
		return
	var extent := Vector2i(request.viewport.w, request.viewport.h)
	var surface := SubViewport.new()
	surface.size = extent
	surface.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(surface)
	var dir := path.get_base_dir()
	if request.capability == "mapFrame":
		var map: Dictionary = request.subject.map
		var camera := _relay_camera(Vector2(extent))
		var pawns := _draw_relay(surface, map, camera)
		_write_json(dir.path_join("picks.json"), {"version": 1, "token": request.token,
			"regions": _relay_regions(map, pawns, Vector2(extent), camera)})
	else:
		_draw_screen(surface, request.subject.layout, Vector2(extent), request.locale, request.viewport.get("id", ""))
	await RenderingServer.frame_post_draw
	var ok := surface.get_texture().get_image().save_png(dir.path_join("frame.png")) == OK
	_write_json(dir.path_join("result.json"), {"version": 1, "token": request.token,
		"status": "ready" if ok else "error"})
	get_tree().quit(0 if ok else 1)

func _generate_course(dir: String, request: Dictionary) -> void:
	var subject: Dictionary = request.subject
	_write_json(dir.path_join("map.json"), _course_map(subject.parameters, subject.target))
	_write_json(dir.path_join("result.json"), {"version": 1, "token": request.token, "status": "ready"})

func _course_map(parameters: Dictionary, target: Dictionary) -> Dictionary:
	var objects := []
	for row in parameters.placements:
		objects.append({"asset": row.asset, "code": "R%03d" % objects.size(),
			"layer": "base", "x": row.column, "y": 2})
	return {"version": target.version,
		"meta": {"code": target.code, "name": target.name, "w": 12, "h": 8,
			"gridProjection": parameters.projection,
			"layers": [{"id": "base", "name": "Course", "visible": true}]},
		"spawn": [1, 2], "tiles": {}, "collision": [], "objects": objects}

func _relay_camera(extent: Vector2) -> Transform2D:
	return Transform2D(Vector2(3, 0), Vector2(0, 3), Vector2(extent.x * 0.5, extent.y / 9.0))

func _iso(cell: Vector2) -> Vector2:
	return Vector2(cell.x - cell.y, cell.x + cell.y) * 8.0

func _relay_layer(layer: Dictionary) -> Transform2D:
	var offset: Array = layer.get("offset", [0, 0])
	return Transform2D(0.0, Vector2.ONE * float(layer.get("scale", 1)), 0.0, Vector2(offset[0], offset[1]))

func _relay_regions(map: Dictionary, pawns: Dictionary, extent: Vector2, camera: Transform2D) -> Array:
	var layer: Dictionary = map.meta.layers[0]
	var inverse := (_relay_view(camera, layer)).affine_inverse()
	var regions := []
	var image_bounds := Rect2(Vector2.ZERO, extent)
	for row in map.objects:
		var pawn: Polygon2D = pawns[row.code]
		var outline := Array(pawn.polygon).map(func(p: Vector2): return pawn.position + p)
		if not outline.all(func(p: Vector2): return image_bounds.has_point(p)):
			continue
		var targets := {"entity": row.code}
		if row.asset == "relay":
			targets["port"] = {"map": map.meta.code, "inst": row.code, "port": "receive"}
		for points in [[0, 1, 2], [0, 2, 3]]:
			var screen: Array = points.map(func(i: int): return [outline[i].x, outline[i].y])
			regions.append({"screen": screen, "targets": targets})
	for triangle in [[Vector2.ZERO, Vector2(extent.x, 0), extent],
			[Vector2.ZERO, extent, Vector2(0, extent.y)]]:
		var screen: Array = triangle.map(func(p: Vector2): return [p.x, p.y])
		var local: Array = triangle.map(func(p: Vector2):
			var q := inverse * p
			return [q.x, q.y])
		regions.append({"screen": screen, "placement": {"layer": layer.id, "local": local}})
	return regions

func _relay_view(camera: Transform2D, layer: Dictionary) -> Transform2D:
	return camera * _relay_layer(layer)

func _draw_relay(parent: Node, map: Dictionary, camera: Transform2D) -> Dictionary:
	var xform := _relay_view(camera, map.meta.layers[0])
	for y in int(map.meta.h):
		for x in int(map.meta.w):
			var diamond := Polygon2D.new()
			var cell := Vector2(x, y)
			var points := PackedVector2Array()
			for corner in [Vector2.ZERO, Vector2.RIGHT, Vector2.ONE, Vector2.DOWN]:
				points.append(xform * _iso(cell + corner))
			diamond.polygon = points
			diamond.color = Color("#19434e") if (x + y) % 2 == 0 else Color("#245464")
			parent.add_child(diamond)
	var pawns := {}
	for row: Dictionary in map.objects:
		var pawn := Polygon2D.new()
		pawn.polygon = PackedVector2Array([Vector2(-7, 0), Vector2(0, -9), Vector2(7, 0), Vector2(0, 6)])
		pawn.color = Color("#ffbe54") if row.asset == "relay" else Color("#67e8bb")
		pawn.position = xform * _iso(Vector2(row.x, row.y) + Vector2(0.5, 0.5))
		parent.add_child(pawn)
		pawns[row.code] = pawn
	return pawns

func _play_relay(map: Dictionary) -> void:
	var relay: Dictionary = map.objects.filter(func(row): return row.asset == "relay")[0]
	var exit: Dictionary = map.objects.filter(func(row): return row.asset == "relay-exit")[0]
	var layer: Dictionary = map.meta.layers[0]
	var camera := _relay_camera(size)
	var pawns := _draw_relay(self, map, camera)
	var pawn: Node2D = pawns[relay.code]
	var gate: Node2D = pawns[exit.code]
	var points := []
	for pair in relay.props.route:
		var world := _relay_layer(layer) * Vector2(pair[0], pair[1])
		await create_tween().tween_property(pawn, "position", camera * world, 0.12).finished
		var reached := camera.affine_inverse() * pawn.position
		points.append([reached.x, reached.y])
	if not pawn.position.is_equal_approx(gate.position):
		_finish("The relay did not reach the placed exit.")
		return
	_finish("", "Relay reached", {"route": points, "exit": exit.code})

func _finish(error: String, text := "", extra := {}) -> void:
	if not report.is_empty():
		var digest := HashingContext.new()
		digest.start(HashingContext.HASH_SHA256)
		digest.update(manifest_bytes)
		var path: String = report.path
		var result := {"version": 1, "token": report.token, "status": "ready" if error.is_empty() else "error",
			"message": error, "mapDigest": _map_digest(), "manifestDigest": digest.finish().hex_encode(),
			"result": {"visited": visited, "screens": screens, "buttons": opened_buttons,
				"latchInputs": latch_inputs, "outlets": outlets, "text": text, "screenFrames": screen_frames}
				.merged(entered_board).merged(runtime_course).merged(extra)}
		if draft_digest != "":
			result["viewDigest"] = draft_digest
		_write_json(path + ".tmp", result)
		DirAccess.rename_absolute(path + ".tmp", path)
	if verify or not error.is_empty():
		get_tree().quit(0 if error.is_empty() else 1)

func _map_digest() -> String:
	if map_bytes.is_empty():
		return ""
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(map_bytes)
	return digest.finish().hex_encode()

func _write_json(path: String, value: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(value))
	file.close()
