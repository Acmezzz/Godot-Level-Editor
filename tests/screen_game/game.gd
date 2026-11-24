extends Control
## Signal Room owns its UI, styling, state transitions and loading. No editor scripts are imported.

var manifest: Dictionary
var manifest_bytes: PackedByteArray
var map_bytes: PackedByteArray
var report := {}
var visited: Array[String] = []
var screens: Array[String] = []
var opened_buttons: Array[String] = []
var latch_inputs: Array[int] = []
var outlets: Array[String] = []
var cancel_target := {}
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
	var entry := _decode(args["--editor-entry"]) if args.has("--editor-entry") else {"function": "signal", "content": "project-default"}
	if entry.has("view"):
		_show_view(entry.view)
	else:
		_show_content(entry)

func _decode(encoded: String) -> Dictionary:
	return JSON.parse_string(Marshalls.base64_to_utf8(encoded))

func _show_content(target: Dictionary) -> void:
	cancel_target = {}
	var kind: String = target.function
	var cid: String = target.content
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://content/%s/%s.json" % [kind, cid]))
	if not data is Dictionary or data.get("function") != manifest.functions[kind].code:
		_finish("Missing signal content: " + cid)
		return
	visited.append(cid)
	for child in get_children():
		remove_child(child)
		child.queue_free()
	var fields: Dictionary = data.get("fields", {})
	var view_id: String = fields.get("PANE", "")
	if view_id.is_empty():
		var label := Label.new()
		label.text = str(fields.get("TEXT", ""))
		add_child(label)
		if verify:
			_finish("", label.text)
		return
	_show_view(view_id, cid == "project-watch")

func _show_view(view_id: String, test_cancel := false) -> void:
	for view in manifest.get("views", []):
		if view.view_id != view_id:
			continue
		screens.append(view_id)
		var buttons := _draw_screen(self, view.layout, size, "")
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
			click.action = &"ui_accept"
			button.grab_focus()
			for i in 4:
				if not is_instance_valid(button) or not button.is_inside_tree():
					break
				for pressed in [true, false]:
					click.pressed = pressed
					Input.parse_input_event(click)
					await get_tree().process_frame
		return
	_finish("Missing signal screen: " + view_id)

func _unhandled_input(event: InputEvent) -> void:
	if not cancel_target.is_empty() and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		outlets.append("cancelled")
		_show_content.call_deferred(cancel_target)

func _draw_screen(parent: Node, layout: Dictionary, extent: Vector2, locale: String) -> Array[Button]:
	var background := ColorRect.new()
	background.color = Color("#10232b")
	background.size = extent
	parent.add_child(background)
	var buttons: Array[Button] = []
	for row in layout.elements:
		var anchors: Array = row.anchors
		var offsets: Array = row.get("offsets", [0, 0, 0, 0])
		var start := Vector2(anchors[0], anchors[1]) * extent + Vector2(offsets[0], offsets[1])
		var finish := Vector2(anchors[2], anchors[3]) * extent + Vector2(offsets[2], offsets[3])
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
						_show_content.call_deferred(target))
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
		item.position = start
		item.size = finish - start
		parent.add_child(item)
	return buttons

func _preview(path: String) -> void:
	var request: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
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
		_draw_screen(surface, request.subject.layout, Vector2(extent), request.locale)
	await RenderingServer.frame_post_draw
	var ok := surface.get_texture().get_image().save_png(dir.path_join("frame.png")) == OK
	_write_json(dir.path_join("result.json"), {"version": 1, "token": request.token,
		"status": "ready" if ok else "error"})
	get_tree().quit(0 if ok else 1)

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
				"latchInputs": latch_inputs, "outlets": outlets, "text": text}.merged(extra)}
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
