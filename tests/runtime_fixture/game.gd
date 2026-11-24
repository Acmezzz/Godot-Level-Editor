extends Node2D

const ChunkDelta := preload("res://generated_chunk_delta.gd")
const Grid := preload("res://src/canvas/grid_space.gd")
const ViewData := preload("res://map_view_data.gd")
const Geometry := preload("res://object_geometry.gd")
## Example game code. It reads saved contracts and shares the standalone format helpers.

var _request: Dictionary
var _manifest_text := ""
var _map_text := ""
var _entry: Dictionary
var _entry_digest := ""
var _cells := {}
var _board_edges: Array = []
var _traversed_edge := ""
var _departed_space := ""
var _departed_point := Vector2.ZERO
var _board_code := ""
var _current := ""
var _caption := ""
var _ending := ""
var _miss_ending := ""
var _flow_goal := {}
var _cue_seconds := 0.0
var _rhythm_player: AudioStreamPlayer
var _attempt_started := 0
var _attempts: Array = []
var _awaiting_input := false
var _manifest: Dictionary
var _dialogue_position := Vector2.ZERO
var _next_step := 0
var _headless := false
var _rule_grid: Grid
var _rule_tiles := {}
var _rule_blocked := {}
var _rule_player := Vector2i.ZERO
var _rule_goal := Vector2i.ZERO
var _rule_origin := Vector2(96, 38)
const CHUNK_SIZE := Vector2(192, 128)

func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var at := a.find("=")
		args[a.substr(0, at) if at >= 0 else a] = a.substr(at + 1) if at >= 0 else true
	if args.has("--editor-preview"):
		await _render_preview(str(args["--editor-preview"]))
		return
	var encoded := str(args.get("--editor-playtest", ""))
	_request = _parse(Marshalls.base64_to_utf8(encoded)) if encoded != "" else {}
	_headless = args.has("--verify")
	_manifest_text = FileAccess.get_file_as_string("res://editor/editor_manifest.json")
	var manifest := _parse(_manifest_text)
	_manifest = manifest
	var map_path := str(args.get("--map", ""))
	if manifest.is_empty():
		_fail("Cannot load manifest")
		return
	if map_path != "":
		_map_text = FileAccess.get_file_as_string(map_path)
		var map := _parse(_map_text)
		if map.get("meta", {}).get("name") == "frame_pick":
			var lanes := []
			for i in map.meta.layers.size():
				for row in map.objects:
					if row.asset == "door" and row.layer == map.meta.layers[i].id:
						var offset: Array = map.meta.layers[i].get("offset", [0, 0])
						var anchor := (Vector2(row.x, row.y) + Vector2(0.5, 0.5)) * 16.0
						anchor = Vector2(offset[0], offset[1]) + anchor * float(map.meta.layers[i].get("scale", 1.0))
						lanes.append({"lane": i, "point": [anchor.x, anchor.y], "door": row.code,
							"transform": row.get("transform", {})})
			var contours: Array = map.objects.filter(func(row): return row.asset == "free-ramp")
			var copies := []
			for row in map.objects:
				if row.asset == "switch" and row.code != "PICK":
					var cid: String = row.functions[0].content
					var content := _parse(FileAccess.get_file_as_string("res://content/reaction/%s.json" % cid))
					copies.append({"code": row.code, "layer": row.layer, "target": row.props.target,
						"message": content.get("fields", {}).get("RMES", "")})
			var start := Vector2i(int(map.spawn[0]), int(map.spawn[1]))
			var player := Node2D.new()
			var grid: Grid = Grid.resolve(map.meta, manifest).grid
			player.position = grid.cell_center_px(start)
			add_child(player)
			var route := _current if _load_board(map, "entry") and _advance_board() else ""
			var arrival := Vector2.ZERO if route.is_empty() else Vector2(_cells[route].polygon[0])
			_report("ready", "", {"picks": lanes, "opened": _activate_switch(map, manifest), "contours": contours,
				"openedBackup": _activate_switch(map, manifest, "backup"),
				"playerStart": [player.position.x, player.position.y], "switchCopies": copies, "authoredRoute": route,
				"authoredEdge": _traversed_edge, "arrivalMap": _board_code, "arrivalVertex": [arrival.x, arrival.y]})
		elif map.get("meta", {}).get("name") == "rule_hex" and not map.meta.get("cellGraph", {}).is_empty():
			var route := _check_floor_route(map)
			if route.is_empty():
				_fail("Authored floor route is missing or blocked")
				return
			_report("ready", "", route)
		elif not map.get("meta", {}).get("cellGraph", {}).is_empty():
			if not _load_board(map):
				_fail("Board has no valid cells or contains a missing neighbor")
				return
			if _headless and not _advance_board():
				_fail("Demo verification needs a directed neighbor from the starting cell")
				return
			var opened := _activate_switch(map, manifest)
			if _headless and opened == "":
				_fail("Board switch has no valid door port")
				return
			var reactions := _run_reactions(map, manifest)
			if reactions.is_empty():
				_fail("Switch could not run its declared reactions")
				return
			var result := {"cell": _current, "edge": _traversed_edge, "opened": opened, "reactions": reactions,
				"fromSpace": _departed_space, "toSpace": _cells[_current].space,
				"fromPoint": [_departed_point.x, _departed_point.y]}
			if _headless:
				if not _advance_board():
					_fail("Demo verification needs a second step across maps")
					return
				result.merge({"destinationMap": _board_code, "destinationCell": _current, "exitEdge": _traversed_edge})
			_report("ready", "", result)
		elif str(map.get("meta", {}).get("gridProjection", "orthogonal")) != "orthogonal" \
				or map.get("meta", {}).has("gridBasis") or map.get("meta", {}).get("gridTopology", "") == "triangles":
			var outcome := _load_rule_grid(map, manifest)
			if outcome.is_empty():
				_fail("Grid route does not reach a door from spawn")
				return
			_report("ready", "", outcome)
		else:
			var outcome := _traverse_platform(map)
			if outcome.is_empty():
				_fail("Platform route does not reach a gate from spawn")
				return
			if _headless and map.get("objects", []).any(func(row): return row.get("asset") == "free-ramp"):
				var collision_checks := await _check_free_ramp_motion(map, manifest)
				if collision_checks.values().has(false) or collision_checks.is_empty():
					_fail("Saved contour physics disagrees with the expected motion: " + str(collision_checks))
					return
				outcome["freeRampMotion"] = collision_checks
				var ramp: Dictionary = map.objects.filter(func(row): return row.asset == "free-ramp").front()
				var vertex := _ramp_transform(map, manifest, ramp) * Vector2(ramp.props.points[1][0], ramp.props.points[1][1])
				outcome["freeRampVertex"] = [vertex.x, vertex.y]
				if manifest.has("worldLayout"):
					var samples: Array = []
					for point in [Vector2(-32, 32), Vector2(32, 32), Vector2(160, 32)]:
						var loaded := _load_world_chunk(point)
						var traversed := _traverse_platform(loaded) if not loaded.is_empty() else {}
						samples.append({"map": loaded.get("meta", {}).get("code", ""), "gate": traversed.get("gate", "")})
					outcome["worldSamples"] = samples
			if _headless and manifest.get("worldLayout", {}).get("chunks", {}).values().any(
					func(row): return row.has("generatedKey")):
				var streamed := await _traverse_generated_world()
				if not streamed.get("reached", false):
					_fail("Could not move through streamed chunks: " + str(streamed))
					return
				outcome["generatedChunks"] = streamed.samples
				outcome["streaming"] = streamed.lifecycle
				if manifest.worldLayout.chunks.values().any(func(row): return row.get("generatedMode") in [ChunkDelta.GRID, ChunkDelta.CONTENT]):
					outcome["seedPatches"] = _sample_grid_delta()
			_report("ready", "", outcome)
	else:
		var content_dir := str(manifest.get("contentDir", "content"))
		if args.has("--editor-entry"):
			var entry := _parse(Marshalls.base64_to_utf8(str(args["--editor-entry"])))
			if entry.get("version") != 1 or entry.get("function") not in ["frame_sequence", "second_sequence"]:
				_fail("Unknown selected project entry")
				return
			var schedule := _read_schedule(entry.function, content_dir, entry.content)
			if schedule.is_empty():
				_fail("Selected project entry has no schedule")
				return
			_report("ready", "", {"entry": entry, "schedule": schedule})
			_caption = str(entry.content)
			queue_redraw()
			if _headless:
				get_tree().quit()
			return
		var entry_text := FileAccess.get_file_as_string("res://".path_join(content_dir).path_join(
			"campaign/project-acceptance.json"))
		_entry = _parse(entry_text)
		_entry_digest = entry_text.sha256_text()
		if not _load_campaign(manifest):
			_fail("Campaign, screen position, or first step is invalid")
			return
		_report("ready", "", {})
		_start_attempt()
		return
	queue_redraw()
	if _headless:
		get_tree().quit()

func _render_preview(path: String) -> void:
	var request := _parse(FileAccess.get_file_as_string(path))
	var dims: Dictionary = request.get("viewport", {})
	var size := Vector2i(int(dims.get("w", 0)), int(dims.get("h", 0)))
	var capability := str(request.get("capability", ""))
	if request.get("version") == 1 and capability == "generateMap":
		_generate_map(path.get_base_dir(), request)
		get_tree().quit()
		return
	if request.get("version") != 1 or capability not in ["screenLayout", "mapFrame", "timelineFrame", "worldFrame"] \
			or size.x <= 0 or size.y <= 0 or size.x > 4096 or size.y > 4096:
		get_tree().quit(1)
		return
	var surface := SubViewport.new()
	surface.size = size
	surface.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(surface)
	var subject: Dictionary = request.get("subject", {})
	var accepted := true
	if capability == "screenLayout":
		_compose_screen_frame(surface, subject, size, str(request.get("locale", "")))
	elif capability == "mapFrame":
		if subject.get("map", {}).get("meta", {}).get("name") == "frame_pick":
			_compose_pick_frame(surface, size, path.get_base_dir(), request)
		elif subject.get("map", {}).get("meta", {}).get("name") == "frame_pick_destination":
			_compose_destination_frame(surface, size, path.get_base_dir(), request)
		else:
			_compose_map_frame(surface, subject, size)
	elif capability == "worldFrame":
		_compose_world_frame(surface, subject, size)
	else:
		accepted = _compose_timeline_frame(surface, subject, size)
	var message := "The game could not sample this timeline."
	if accepted:
		await RenderingServer.frame_post_draw
		var image := surface.get_texture().get_image()
		message = "" if image != null and not image.is_empty() and image.save_png(
			path.get_base_dir().path_join("frame.png")) == OK else "The engine could not capture a frame."
	var report := FileAccess.open(path.get_base_dir().path_join("result.json"), FileAccess.WRITE)
	if report != null:
		report.store_string(JSON.stringify({"version": 1, "token": request.token,
			"status": "ready" if message.is_empty() else "error", "message": message}))
		report.close()
	get_tree().quit()

func _generate_map(directory: String, request: Dictionary) -> void:
	var subject: Dictionary = request.subject
	var target: Dictionary = subject.target
	var first := int(subject.parameters.get("start", 2))
	var valid: bool = subject.generator == "slope_room" and first >= 2 and first <= 5
	var message := "Unknown generator or invalid start" if not valid else ""
	if valid:
		var map := _slope_room(target, first)
		match int(subject.parameters.get("variant", 0)):
			1: map.collision.append({"x": first, "y": 0})
			2:
				map.collision.append_array([{"x": first + 2, "y": 3, "shape": "l45"},
					{"x": 0, "y": 0, "shape": "r45"}, {"x": first, "y": 0}])
				map.objects.append(_trim_row())
		var output := FileAccess.open(directory.path_join("map.json"), FileAccess.WRITE)
		if output == null:
			message = "Cannot write generated map"
		else:
			output.store_string(JSON.stringify(map))
			output.close()
	var report := FileAccess.open(directory.path_join("result.json"), FileAccess.WRITE)
	if report != null:
		report.store_string(JSON.stringify({"version": 1, "token": request.token,
			"status": "ready" if message == "" else "error", "message": message}))
		report.close()

func _slope_room(target: Dictionary, first: int) -> Dictionary:
	return {"version": target.version,
		"meta": {"code": target.code, "name": target.name, "w": 12, "h": 8, "gridProjection": "orthogonal",
			"layers": [{"id": "base", "name": "Generated terrain", "visible": true}]},
		"spawn": [first, 2], "tiles": {},
		"collision": [{"x": first, "y": 4}, {"x": first + 1, "y": 4, "shape": "r45"}],
		"objects": [{"asset": "door", "code": "GATE", "layer": "base", "x": first + 2, "y": 2}]}

func _compose_screen_frame(surface: SubViewport, subject: Dictionary, size: Vector2i, locale: String) -> void:
	var background := ColorRect.new()
	background.color = Color("#18203a")
	background.size = Vector2(size)
	surface.add_child(background)
	var layout: Dictionary = subject.get("layout", {})
	for row in layout.get("elements", []):
		var a: Array = row.anchors
		var o: Array = row.get("offsets", [0, 0, 0, 0])
		var lo := Vector2(a[0], a[1]) * Vector2(size) + Vector2(o[0], o[1])
		var hi := Vector2(a[2], a[3]) * Vector2(size) + Vector2(o[2], o[3])
		var caption := _layout_text(row, locale)
		var control: Control
		if row.kind == "button":
			var button := Button.new()
			button.text = caption
			button.add_theme_font_size_override("font_size", int(row.get("fontSize", 24)))
			if row.get("style") == "fixture/primary":
				var style := StyleBoxFlat.new()
				style.bg_color = Color("#c53874")
				button.add_theme_stylebox_override("normal", style)
			control = button
		else:
			var label := Label.new()
			label.text = caption
			control = label
		control.position = lo
		control.size = hi - lo
		surface.add_child(control)

func _compose_pick_frame(surface: SubViewport, size: Vector2i, dir: String, request: Dictionary) -> void:
	var map: Dictionary = request.subject.map
	_frame_rect(surface, Rect2(Vector2.ZERO, Vector2(size) * Vector2(0.5, 1)), Color("#34476c"))
	surface.own_world_3d = true
	var camera := Camera3D.new()
	camera.fov = 90.0
	surface.add_child(camera)
	camera.make_current()
	var aspect := float(size.x) / float(size.y)
	var foreground := PackedVector3Array([Vector3(0.44 * aspect, 0.64, -1) * 0.5,
		Vector3(0.62 * aspect, 0.64, -1) * 0.5, Vector3(0.44 * aspect, 0.5, -1) * 0.5])
	_frame_triangle_3d(surface, foreground, Color("#f0483d"))
	var regions := [{"label": "Foreground", "screen": _project_triangle(camera, foreground), "occludes": true}]
	for i in 2:
		var start := Vector2(size) * Vector2(0.05 + 0.5 * i, 0.15)
		var right := start + Vector2(size.x * 0.4, 0.0)
		var down := start + Vector2(0.0, size.y * 0.4)
		var layer: String = map.meta.layers[i].id
		var local := Vector2(16 + i * 32, 16 + i * 16)
		var root := Vector2(16 + i * 64, 16 + i * 32)
		var region := {"label": "View " + str(i + 1),
			"screen": [[start.x, start.y], [right.x, right.y], [down.x, down.y]],
			"placement": {"layer": layer, "local": [[local.x, local.y], [local.x + 32, local.y], [local.x, local.y + 32]]},
			"collision": {"local": [[root.x, root.y], [root.x + 32, root.y], [root.x, root.y + 32]]}}
		if i == 0:
			var triangle := Polygon2D.new()
			triangle.polygon = PackedVector2Array([start, right, down])
			triangle.color = Color("#f29b41")
			surface.add_child(triangle)
		else:
			var mesh := PackedVector3Array([Vector3(0.1 * aspect, 0.7, -1.0),
				Vector3(1.8 * aspect, 1.4, -2.0), Vector3(0.1 * aspect, -0.1, -1.0)])
			_frame_triangle_3d(surface, mesh, Color("#46c4ae"))
			region.screen = _project_triangle(camera, mesh)
			var weights := []
			for vertex in mesh:
				weights.append(-1.0 / vertex.z)
			region.placement.reciprocalW = weights
			region.collision.reciprocalW = weights
		var graph: Dictionary = map.meta.get("cellGraph", {})
		for cell: Dictionary in graph.get("cells", []):
			var space: Dictionary = graph.get("spaces", {}).get(cell.get("space", ""), {})
			if (i == 0 and not space.get("layer", "").is_empty()) or (i == 1 and space.get("layer", "") != layer):
				continue
			var basis := Transform2D(_vector(space.get("axisX", [1, 0])), _vector(space.get("axisY", [0, 1])),
				_vector(space.get("origin", [0, 0])))
			var screen := PackedVector2Array(region.screen.map(func(v): return Vector2(v[0], v[1])))
			var projected := PackedVector2Array()
			for point in cell.polygon:
				var uv := (basis * _vector(point) - (root if i == 0 else local)) / 32.0
				var w := Vector3(1.0 - uv.x - uv.y, uv.x * (2.0 if i == 1 else 1.0), uv.y)
				projected.append((screen[0] * w.x + screen[1] * w.y + screen[2] * w.z) / (w.x + w.y + w.z))
			for j in projected.size():
				var p := projected[j]
				regions.append({"screen": [[p.x - 7, p.y - 7], [p.x + 10, p.y - 7], [p.x - 7, p.y + 10]],
					"targets": {"cellVertex": {"cell": cell.id, "index": j}}})
			var indices := Geometry2D.triangulate_polygon(projected)
			for j in range(0, indices.size(), 3):
				var tri := []
				for k in 3:
					var p: Vector2 = projected[indices[j + k]]
					tri.append([p.x, p.y])
				regions.append({"screen": tri, "targets": {"cell": cell.id}})
		for row in map.objects:
			if i == 0 and row.get("code") == "PICK":
				var center := Vector2(size) * Vector2(0.11, 0.34)
				regions.append({"screen": [[center.x - 7, center.y - 7], [center.x + 10, center.y - 7], [center.x - 7, center.y + 10]],
					"targets": {"entity": row.code}})
			if row.get("asset") == "door" and row.get("layer") == layer:
				region["targets"] = {"entity": row.code, "port": {"map": map.meta.code, "inst": row.code, "port": "open"}}
				break
		for row in map.objects:
			if row.get("asset") != "free-ramp" or row.get("layer") != layer:
				continue
			var props: Dictionary = row.get("props", {})
			var rings := [props.get("points", [])]
			rings.append_array(props.get("holes", []))
			for part in props.get("parts", []):
				rings.append(part.points)
				rings.append_array(part.get("holes", []))
			var anchor := (Vector2(row.x, row.y) + Vector2(0.5, 0.5)) * 16.0
			var screen := PackedVector2Array(region.screen.map(func(v): return Vector2(v[0], v[1])))
			for ring in rings.size():
				for k in rings[ring].size():
					var p: Array = rings[ring][k]
					var uv := (anchor + Vector2(p[0], p[1]) - local) / 32.0
					var bary := Vector3(1.0 - uv.x - uv.y, uv.x * (2.0 if i == 1 else 1.0), uv.y)
					var center := (screen[0] * bary.x + screen[1] * bary.y + screen[2] * bary.z) / (bary.x + bary.y + bary.z)
					regions.append({"screen": [[center.x - 7, center.y - 7], [center.x + 10, center.y - 7], [center.x - 7, center.y + 10]],
						"targets": {"vertex": {"inst": row.code, "ring": ring, "index": k}}})
		regions.append(region)
	_write_frame_picks(dir, request.token, regions)

func _compose_destination_frame(surface: SubViewport, size: Vector2i, dir: String, request: Dictionary) -> void:
	var world := _frame_world(surface, request.subject, size)
	var map: Dictionary = request.subject.map
	_draw_map_doors(world, map, request.subject.manifest)
	var cell: Dictionary = map.meta.cellGraph.cells[0]
	var polygon := Polygon2D.new()
	polygon.polygon = PackedVector2Array(cell.polygon.map(func(point): return _vector(point)))
	polygon.color = Color("#46c4ae")
	world.add_child(polygon)
	var screen := func(point: Vector2) -> Array:
		var pixel := world.to_global(point)
		return [pixel.x, pixel.y]
	var door: Dictionary = map.objects[0]
	var center := (Vector2(door.x, door.y) + Vector2(0.5, 0.5)) * 16.0
	var lo := center - Vector2(6, 8)
	var hi := center + Vector2(6, 8)
	var port := {"port": {"map": map.meta.code, "inst": door.code, "port": "open"}}
	_write_frame_picks(dir, request.token, [
		{"screen": Array(polygon.polygon).map(screen), "targets": {"cell": cell.id}},
		{"screen": [screen.call(lo), screen.call(Vector2(hi.x, lo.y)), screen.call(hi)], "targets": port},
		{"screen": [screen.call(lo), screen.call(hi), screen.call(Vector2(lo.x, hi.y))], "targets": port}
	])

func _write_frame_picks(dir: String, token: String, regions: Array) -> void:
	var picks := FileAccess.open(dir.path_join("picks.json"), FileAccess.WRITE)
	picks.store_string(JSON.stringify({"version": 1, "token": token, "regions": regions}))
	picks.close()

func _frame_triangle_3d(surface: SubViewport, vertices: PackedVector3Array, color: Color) -> void:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = color
	var builder := SurfaceTool.new()
	builder.begin(Mesh.PRIMITIVE_TRIANGLES)
	builder.set_material(material)
	for point in vertices:
		builder.add_vertex(point)
	var model := MeshInstance3D.new()
	model.mesh = builder.commit()
	surface.add_child(model)

func _project_triangle(camera: Camera3D, vertices: PackedVector3Array) -> Array:
	var points := []
	for vertex in vertices:
		var p := camera.unproject_position(vertex)
		points.append([p.x, p.y])
	return points

func _compose_map_frame(surface: SubViewport, subject: Dictionary, size: Vector2i) -> void:
	var world := _frame_world(surface, subject, size)
	_draw_map_doors(world, subject.get("map", {}), subject.get("manifest", {}))
	if _has_preview_overlay(subject.get("stagedContent", [])):
		_frame_rect(surface, Rect2(0, 0, 12, 12), Color("#46c4ae"))

func _frame_world(surface: SubViewport, subject: Dictionary, size: Vector2i) -> Node2D:
	var camera: Dictionary = subject.get("camera", {})
	var center: Array = camera.get("center", [0, 0])
	var zoom := float(camera.get("zoom", 1))
	var world := Node2D.new()
	world.position = Vector2(size) * 0.5 - Vector2(center[0], center[1]) * zoom
	world.scale = Vector2.ONE * zoom
	surface.add_child(world)
	return world

func _draw_map_doors(parent: Node, map: Dictionary, manifest: Dictionary) -> void:
	for row in map.get("objects", []):
		for asset in manifest.get("assets", []):
			if asset.get("id") == row.get("asset") and asset.get("code") == "DOOR":
				var center := (Vector2(row.x, row.y) + Vector2(0.5, 0.5)) * 16.0
				_frame_rect(parent, Rect2(center - Vector2(6, 8), Vector2(12, 16)), Color("#f29b41"))

func _has_preview_overlay(staged: Array) -> bool:
	for row in staged:
		if row.get("function") == "ending" and row.get("content") == "preview-only" \
				and row.get("data", {}).get("fields", {}).get("MESG") == "Preview overlay":
			return true
	return false

func _frame_rect(parent: Node, rect: Rect2, color: Color) -> void:
	var control := ColorRect.new()
	control.position = rect.position
	control.size = rect.size
	control.color = color
	parent.add_child(control)

func _compose_world_frame(surface: SubViewport, subject: Dictionary, size: Vector2i) -> void:
	_frame_rect(surface, Rect2(Vector2.ZERO, Vector2(size)), Color("#18203a"))
	var world := _frame_world(surface, subject, size)
	var manifest: Dictionary = subject.get("manifest", {})
	var camera: Dictionary = subject.camera
	var viewport_size := Vector2(size) / float(camera.zoom)
	var visible_world := Rect2(Vector2(camera.center[0], camera.center[1]) - viewport_size * 0.5, viewport_size)
	var chunks: Dictionary = manifest.get("worldLayout", {}).get("chunks", {})
	for code in chunks:
		var row: Dictionary = chunks[code]
		var origin := Vector2(row.origin[0], row.origin[1])
		var bounds := Rect2(origin, Vector2(row.size[0], row.size[1]))
		if not bounds.intersects(visible_world):
			continue
		var override: Dictionary = subject.get("overrides", {}).get(code, {})
		var map: Dictionary = override.map if override.has("map") else _map_with_code(code)
		if map.is_empty():
			continue
		_frame_rect(world, bounds, Color("#34476c"))
		var chunk := Node2D.new()
		chunk.position = origin
		world.add_child(chunk)
		_draw_map_doors(chunk, map, manifest)
		if _has_preview_overlay(override.get("stagedContent", [])):
			_frame_rect(chunk, Rect2(2, 2, 10, 10), Color("#46c4ae"))

func _compose_timeline_frame(surface: SubViewport, subject: Dictionary, size: Vector2i) -> bool:
	var time: Dictionary = subject.get("time", {})
	var data: Dictionary = subject.get("data", {})
	var decl: Dictionary = subject.get("manifest", {}).get("functions", {}).get(subject.get("function"), {})
	var unit := str(decl.get("timebase", "seconds"))
	if decl.is_empty() or data.get("function") != decl.code or time.get("unit") != unit:
		return false
	if unit in ["frames", "seconds"]:
		var rate := _sequence_rate(data, decl)
		var raw := float(time.value)
		var seconds = raw / rate if rate > 0.0 else null
		if seconds == null:
			if time.seconds != null:
				return false
		elif time.seconds == null or not is_equal_approx(seconds, float(time.seconds)):
			return false
		var active := false
		for interval in _step_ranges(data.get("steps", []), 1.0):
			if (raw >= interval[0] and raw < interval[1]) or raw == interval[0]:
				active = true
				break
		if subject.has("instance"):
			return _compose_bound_timeline(surface, subject, size, active)
		var x := roundf(seconds * 100.0) if seconds != null else raw
		_frame_rect(surface, Rect2(x, size.y * 0.5, 16, 16),
			Color("#d75283") if active else Color("#479bb1"))
		return true
	if subject.get("function") != "campaign" or unit != "beats":
		return false
	var beat := float(time.get("value", 0.0))
	var seconds := float(data.get("fields", {}).get("OFST", 0.0))
	var last := 0.0
	var bpm := 120.0
	var cue_reached := false
	for row in data.get("steps", []):
		var at := float(row.get("at", 0.0))
		if at > beat:
			continue
		if row.get("step") == "TMPO":
			seconds += (at - last) * 60.0 / bpm
			last = at
			bpm = float(row.fields.BPM1)
		elif row.get("step") == "NEXT":
			cue_reached = true
	seconds += (beat - last) * 60.0 / bpm
	if not is_equal_approx(seconds, float(time.get("seconds", -1.0))):
		return false
	_frame_rect(surface, Rect2(roundf(seconds * 100.0), size.y * 0.5, 16, 16),
		(Color("#d75283") if cue_reached else Color("#479bb1"))
		if data.get("fields", {}).get("CAPT") == "Staged frame" else Color.WHITE)
	return true

func _compose_bound_timeline(surface: SubViewport, subject: Dictionary, size: Vector2i, active: bool) -> bool:
	for row in subject.map.objects:
		if row.get("code") != subject.instance:
			continue
		var bindings: Array = row.get("functions", [])
		var index := int(subject.bindingIndex)
		if index < 0 or index >= bindings.size():
			return false
		var binding: Dictionary = bindings[index]
		if binding.get("bindingId", "") != subject.bindingId or binding.get("content", "") != subject.content \
				or binding.get("fn") != subject.data.get("function"):
			return false
		# The switch's leave reaction renders differently from its mounted touch reaction.
		if binding.get("trigger") != "LEAV" or subject.data.get("fields", {}).get("RMES") != "exited":
			return false
		var world := _frame_world(surface, subject, size)
		var point := (Vector2(row.x, row.y) + Vector2(0.5, 0.5)) * 16.0
		_frame_rect(world, Rect2(point - Vector2(4, 4), Vector2(8, 8)),
			Color("#d75283") if active else Color("#479bb1"))
		for other in subject.stagedContent:
			if other.function == subject.function and other.content != subject.content \
					and other.data.get("fields", {}).get("RMES") == "entered" \
					and bindings.any(func(item): return item.get("content") == other.content and item.get("trigger") == "TUCH"):
				_frame_rect(surface, Rect2(0, 0, 12, 12), Color("#46c4ae"))
		return true
	return false

func _reference_target(point: Vector2) -> String:
	for view in _manifest.get("views", []):
		if view.get("view_id") != "title":
			continue
		for hotspot in view.get("hotspots", []):
			var r: Array = hotspot.rect
			var target: Dictionary = hotspot.get("target", {})
			if Rect2(r[0], r[1], r[2], r[3]).has_point(point) and target.get("function") == "ending":
				return str(target.get("content", ""))
	return ""

func _screen_target(viewport: Vector2) -> String:
	var point := Vector2(viewport.x * 0.5, viewport.y - 300.0)
	for view in _manifest.get("views", []):
		if view.get("view_id") != "title":
			continue
		var elements: Array = view.get("layout", {}).get("elements", [])
		for i in range(elements.size() - 1, -1, -1):
			var row: Dictionary = elements[i]
			if row.kind != "button":
				continue
			var a: Array = row.anchors
			var o: Array = row.get("offsets", [0, 0, 0, 0])
			var lo := Vector2(a[0], a[1]) * viewport + Vector2(o[0], o[1])
			var hi := Vector2(a[2], a[3]) * viewport + Vector2(o[2], o[3])
			if Rect2(lo, hi - lo).has_point(point):
				return str(row.get("target", {}).get("content", ""))
	return ""

func _screen_focus(direction: String) -> Dictionary:
	for view in _manifest.get("views", []):
		if view.get("view_id") != "title":
			continue
		var layout: Dictionary = view.get("layout", {})
		var buttons := {}
		for row in layout.get("elements", []):
			if row.kind == "button" and row.get("focusable", true):
				buttons[row.id] = row
		var start := str(layout.get("focusStart", ""))
		if not buttons.has(start):
			return {}
		var next := str(buttons[start].get("focus", {}).get(direction, ""))
		if not buttons.has(next):
			return {}
		var target: Dictionary = buttons[next].get("target", {})
		var content := str(target.get("content", ""))
		if target.get("function") != "ending" or not content.is_valid_filename():
			return {}
		var folder := "res://".path_join(str(_manifest.get("contentDir", "content")))
		var data := _parse(FileAccess.get_file_as_string(folder.path_join("ending").path_join(content + ".json")))
		if data.get("function") != _manifest.get("functions", {}).get("ending", {}).get("code"):
			return {}
		return {"start": start, "next": next, "content": content,
			"localized": _layout_text(buttons[next], "fr_CA"), "fallback": _layout_text(buttons[next], "de")}
	return {}

func _screen_artwork() -> Dictionary:
	for view in _manifest.get("views", []):
		if view.get("view_id") != "title":
			continue
		for row in view.get("layout", {}).get("elements", []):
			var id := str(row.get("imageAsset", ""))
			if id == "":
				continue
			for asset in _manifest.get("assets", []):
				if asset.get("id") != id or asset.get("kind") != "scene" or asset.get("shape") != "image":
					continue
				var image := Image.load_from_file("res://" + str(asset.get("texture", "")))
				if image != null and not image.is_empty():
					return {"fit": row.get("imageFit", "contain"), "size": [image.get_width(), image.get_height()],
						"pixel": image.get_pixel(0, 0).to_html(false)}
	return {}

func _layout_text(element: Dictionary, locale: String) -> String:
	var tag := locale.to_lower().replace("_", "-")
	var variants: Dictionary = element.get("textLocales", {})
	while tag != "":
		if variants.has(tag):
			return str(variants[tag])
		var dash := tag.rfind("-")
		tag = tag.left(dash) if dash >= 0 else ""
	return str(element.get("text", ""))

func _parse(s: String) -> Dictionary:
	var parser := JSON.new()
	if parser.parse(s) == OK and parser.data is Dictionary:
		return parser.data
	return {}

func _load_board(map: Dictionary, start := "") -> bool:
	var graph: Dictionary = map.get("meta", {}).get("cellGraph", {})
	var cells: Array = graph.get("cells", [])
	var spaces: Dictionary = graph.get("spaces", {})
	var layers := {}
	for decl in map.get("meta", {}).get("layers", []):
		var scale: float = decl.get("scale", 1.0)
		layers[decl.id] = Transform2D(0.0, Vector2.ONE * scale, 0.0, _vector(decl.get("offset", [0, 0])))
	var new_cells := {}
	var last := ""
	for cell in cells:
		var id := str(cell.id)
		var space := str(cell.get("space", ""))
		if space != "" and not spaces.has(space):
			return false
		var frame: Dictionary = spaces.get(space, {})
		var xf := Transform2D(_vector(frame.get("axisX", [1, 0])), _vector(frame.get("axisY", [0, 1])),
			_vector(frame.get("origin", [0, 0])))
		var layer: Transform2D = layers.get(frame.get("layer", ""), Transform2D.IDENTITY)
		xf = layer * xf
		var poly := PackedVector2Array()
		for p in cell.polygon:
			poly.append(xf * _vector(p))
		if poly.size() < 3:
			return false
		new_cells[id] = {"polygon": poly, "neighbors": cell.get("neighbors", []), "space": space}
		last = id
	for cell in new_cells.values():
		for neighbor in cell.neighbors:
			if not new_cells.has(neighbor):
				return false
	var edges: Array = graph.get("edges", [])
	for edge in edges:
		if not new_cells.has(edge.from) or (edge.get("toMap", "") == "" and not new_cells.has(edge.to)):
			return false
	var current := start if start != "" else last
	if not new_cells.has(current):
		return false
	_cells = new_cells
	_board_edges = edges
	_current = current
	_board_code = str(map.meta.get("code", ""))
	return true

func _vector(pair: Array) -> Vector2:
	return Vector2(float(pair[0]), float(pair[1]))

func _check_floor_route(map: Dictionary) -> Dictionary:
	var ids := ["ground:2,2", "ground:1,3", "ground:1,4", "upper:1,4", "upper:2,4", "upper:3,4"]
	if not _load_board(map, ids[0]) or not _cells.has(ids.back()):
		return {}
	var stairs := ""
	if _headless:
		for i in range(1, ids.size()):
			var from: String = ids[i - 1]
			var to: String = ids[i]
			if i == 3:
				if not _advance_board() or _current != to or _cells[to].neighbors.has(from):
					return {}
				stairs = _traversed_edge
			else:
				if not _cells[from].neighbors.has(to):
					return {}
				_current = to
	var point: Vector2 = _cells[ids.back()].polygon[0]
	var graph: Dictionary = map.meta.cellGraph
	var layer_id: String = graph.spaces.upper.layer
	var root_grid: Grid = Grid.resolve(map.meta, _manifest).grid
	for layer in map.meta.layers:
		if layer.id != layer_id:
			continue
		var tile_grid: Grid = Grid.resolve_tile_layer(layer, _manifest, root_grid).grid
		var cell := Vector2i(3, 4)
		var painted: bool = map.tiles[layer_id].any(func(row): return int(row[0]) == cell.x and int(row[1]) == cell.y)
		var tile_point := _vector(layer.offset) + float(layer.scale) * tile_grid.cell_polygon(cell)[0]
		if not painted or not tile_point.is_equal_approx(point):
			return {}
		return {"stairs": stairs, "goal": _current, "vertices": _cells[ids.back()].polygon.size(),
			"upperPoint": [point.x, point.y], "tileTopology": tile_grid.topology}
	return {}

func _activate_switch(map: Dictionary, manifest: Dictionary, field := "target") -> String:
	var target: Dictionary = {}
	for obj in map.get("objects", []):
		if obj.asset == "switch":
			target = obj.get("props", {}).get(field, {})
			break
	if target.get("port") != "open":
		return ""
	var target_map := map if target.get("map") == map.meta.code else _map_with_code(str(target.get("map", "")))
	for obj in target_map.get("objects", []):
		if obj.get("code") == target.get("inst") and obj.asset == "door":
			for asset in manifest.get("assets", []):
				if asset.id == obj.asset and asset.get("ports", []).any(func(p): return p.id == target.port):
					return obj.code
	return ""

func _run_reactions(map: Dictionary, manifest: Dictionary) -> Dictionary:
	var wanted := str(manifest.get("functions", {}).get("reaction", {}).get("code", ""))
	if wanted == "":
		return {}
	var output := {}
	for obj in map.get("objects", []):
		if obj.asset != "switch":
			continue
		for row in obj.get("functions", []):
			if row.get("fn") != wanted or not row.get("enabled", true):
				continue
			var cid := str(row.get("content", ""))
			var trigger := str(row.get("trigger", ""))
			if cid == "" or not cid.is_valid_filename() or trigger == "":
				return {}
			var root := "res://".path_join(str(manifest.get("contentDir", "content")))
			var record := _parse(FileAccess.get_file_as_string(root.path_join("reaction").path_join(cid + ".json")))
			if record.get("function") != wanted:
				return {}
			if not output.has(trigger):
				output[trigger] = []
			output[trigger].append(str(record.get("fields", {}).get("RMES", "")))
	return output

func _advance_board() -> bool:
	_departed_space = _cells[_current].space
	_departed_point = _cells[_current].polygon[0]
	for edge in _board_edges:
		if edge.from == _current and edge.type == "stairs" and int(edge.props.get("cost", 0)) <= 4:
			var code := str(edge.get("toMap", ""))
			if code == "":
				_current = edge.to
			elif not _load_board(_map_with_code(code), str(edge.to)):
				return false
			_traversed_edge = edge.id
			return true
	var exits: Array = _cells[_current].neighbors
	if exits.is_empty():
		return false
	_current = str(exits[0])
	return true

func _map_with_code(code: String) -> Dictionary:
	var target := {}
	for file in DirAccess.get_files_at("res://maps"):
		if not file.ends_with(".json"):
			continue
		var candidate := _parse(FileAccess.get_file_as_string("res://maps".path_join(file)))
		if candidate.get("meta", {}).get("code") == code:
			if not target.is_empty():
				return {}
			target = candidate
	return target

func _load_world_chunk(point: Vector2) -> Dictionary:
	var chunks: Dictionary = _manifest.get("worldLayout", {}).get("chunks", {})
	for code in chunks:
		var row: Dictionary = chunks[code]
		if row.has("generatedKey"):
			continue
		var footprint := Rect2(Vector2(row.origin[0], row.origin[1]), Vector2(row.size[0], row.size[1]))
		if footprint.has_point(point):
			return _map_with_code(code)
	return {}

func _generated_slots(manifest: Dictionary) -> Dictionary:
	var slots := {}
	var chunks: Dictionary = manifest.get("worldLayout", {}).get("chunks", {})
	for code in chunks:
		var key: String = chunks[code].get("generatedKey", "")
		if key != "":
			slots[key] = {"code": code, "mode": chunks[code].get("generatedMode", "")}
	return slots

func _trim_row() -> Dictionary:
	return {"asset": "door", "code": "TRIM", "layer": "base", "x": 1, "y": 0}

func _generated_chunk(cell: Vector2i, slots: Dictionary, seed := 0) -> Dictionary:
	var key := "slope/%d/%d" % [cell.x, cell.y]
	var binding: Dictionary = slots.get(key, {})
	var saved := _map_with_code(binding.code) if not binding.is_empty() else {}
	var mode := str(binding.get("mode", ""))
	if not saved.is_empty() and mode == "":
		return {"key": key, "map": saved, "authored": true}
	var first := 2 + posmod(cell.x, 4)
	var map := _slope_room({"version": 7, "code": key, "name": key}, first)
	map.collision.append({"x": first + 2, "y": 3, "shape": "l45"})
	if mode == ChunkDelta.CONTENT:
		map.objects[0].props = {"seedColor": seed}
		map.objects.append(_trim_row())
		if seed != 0:
			map.objects.append({"asset": "door", "code": "S%d" % seed, "layer": "base", "x": seed, "y": 0})
	else:
		map.objects[0].code = "SEED"
	if seed != 0:
		map.collision.append_array([{"x": seed, "y": 0}, {"x": 3, "y": 0}])
	var applied := false
	if not saved.is_empty() and mode in [ChunkDelta.GRID, ChunkDelta.CONTENT]:
		var patched := ChunkDelta.apply(map, ChunkDelta.compile(saved, mode))
		applied = patched.error == ""
		if applied:
			map = patched.map
	return {"key": key, "map": map, "authored": applied}

func _sample_grid_delta() -> Array:
	var samples: Array = []
	var slots := _generated_slots(_manifest)
	for seed in [7, 8]:
		var chunk := _generated_chunk(Vector2i(2, 0), slots, seed)
		var rows: Array = chunk.map.collision
		var objects: Array = chunk.map.objects
		var gate: Array = objects.filter(func(row): return row.code == "GATE")
		var props: Dictionary = gate[0].get("props", {}) if not gate.is_empty() else {}
		samples.append({"seed": seed, "applied": chunk.authored, "gate": _traverse_platform(chunk.map).get("gate", ""),
			"gateLabel": props.get("label", ""), "gateSeed": props.get("seedColor", -1),
			"removedObject": not objects.any(func(row): return row.code == "TRIM"),
			"seedObject": objects.any(func(row): return row.code == "S%d" % seed),
			"addedObject": objects.any(func(row): return row.get("props", {}).get("label") == "extra"),
			"seedCell": rows.any(func(row): return row.x == seed and row.y == 0),
			"deleted": not rows.any(func(row): return row.x == 3 and row.y == 0),
			"solidLanding": rows.any(func(row): return row.x == 5 and row.y == 3 and not row.has("shape")),
			"tilePatched": chunk.map.tiles.get("base", []).any(func(row): return row[0] == 1 and row[1] == 1)})
	return samples

func _mount_chunk(world: Node2D, cell: Vector2i, data: Dictionary) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.position = Vector2(cell) * CHUNK_SIZE
	body.set_meta("chunk", data)
	for row in data.map.get("collision", []):
		var shape := ConvexPolygonShape2D.new()
		match row.get("shape", ""):
			"r45": shape.points = PackedVector2Array([Vector2(0, 16), Vector2(16, 0), Vector2(16, 16)])
			"l45": shape.points = PackedVector2Array([Vector2.ZERO, Vector2(16, 16), Vector2(0, 16)])
			_: shape.points = PackedVector2Array([Vector2.ZERO, Vector2(16, 0), Vector2(16, 16), Vector2(0, 16)])
		var collider := CollisionShape2D.new()
		collider.shape = shape
		collider.position = Vector2(row.x, row.y) * 16
		body.add_child(collider)
	_draw_map_doors(body, data.map, _manifest)
	world.add_child(body)
	return body

func _stream_neighbors(world: Node2D, active: Dictionary, cell: Vector2i, slots: Dictionary) -> void:
	var needed := [cell + Vector2i.LEFT, cell, cell + Vector2i.RIGHT]
	for existing in active.keys():
		if not needed.has(existing):
			var expired: StaticBody2D = active[existing]
			active.erase(existing)
			world.remove_child(expired)
			expired.queue_free()
	for next in needed:
		if not active.has(next):
			active[next] = _mount_chunk(world, next, _generated_chunk(next, slots))

func _traverse_generated_world() -> Dictionary:
	var slots := _generated_slots(_manifest)
	var world := Node2D.new()
	add_child(world)
	var runner := CharacterBody2D.new()
	runner.position = Vector2(383, 32)
	var circle := CircleShape2D.new()
	circle.radius = 3
	var shape := CollisionShape2D.new()
	shape.shape = circle
	runner.add_child(shape)
	add_child(runner)
	var active := {}
	var samples: Array = []
	var lifecycle: Array = []
	var current := Vector2i(-999, -999)
	var reached := true
	while true:
		var cell := Vector2i((runner.position / CHUNK_SIZE).floor())
		if cell != current:
			var preloaded: StaticBody2D = active.get(cell)
			var old: Array = active.values()
			_stream_neighbors(world, active, cell, slots)
			await get_tree().physics_frame
			await get_tree().physics_frame
			var body: StaticBody2D = active[cell]
			var data: Dictionary = body.get_meta("chunk")
			var route := _traverse_platform(data.map)
			var mounted: Array = []
			for resident in world.get_children():
				mounted.append(resident.get_meta("chunk").key)
			var removed := old.filter(func(node): return not is_instance_valid(node)).size()
			var probe := PhysicsPointQueryParameters2D.new()
			probe.position = Vector2(393, 13)
			var has_override_shape := not world.get_world_2d().direct_space_state.intersect_point(probe, 1).is_empty()
			lifecycle.append({"resident": mounted, "reused": preloaded != null and preloaded == body,
				"unloaded": removed, "overrideShape": has_override_shape})
			samples.append({"key": data.key, "authored": data.authored, "map": data.map.meta.code,
				"gate": route.get("gate", ""), "collisions": body.get_children().filter(func(node): return node is CollisionShape2D).size()})
			current = cell
		if runner.position.x >= 768.0:
			break
		await get_tree().physics_frame
		var next_boundary := (current.x + 1) * CHUNK_SIZE.x
		if runner.move_and_collide(Vector2(minf(8.0, next_boundary - runner.position.x), 0)) != null:
			reached = false
			break
	runner.queue_free()
	world.queue_free()
	return {"reached": reached, "samples": samples, "lifecycle": lifecycle}

## Minimal side-view kinematics: land from spawn, walk one cell at a time,
## and treat the right-high cell as a ramp whose right surface is one tile higher.
func _traverse_platform(map: Dictionary) -> Dictionary:
	var solids := {}
	for row in map.get("collision", []):
		if row.get("type", "solid") == "solid":
			solids[Vector2i(int(row.x), int(row.y))] = str(row.get("shape", ""))
	var spawn: Array = map.get("spawn", [])
	if spawn.size() != 2:
		return {}
	var feet := Vector2i(int(spawn[0]), int(spawn[1]))
	var floor_limit := int(map.get("meta", {}).get("h", 0))
	while feet.y < floor_limit and not solids.has(feet + Vector2i.DOWN):
		feet.y += 1
	if feet.y >= floor_limit:
		return {}
	var rise := 0
	for _x in int(map.get("meta", {}).get("w", 0)):
		for object in map.get("objects", []):
			if object.get("asset") == "door" and Vector2i(int(object.x), int(object.y)) == feet:
				return {"rise": rise, "gate": str(object.code), "freeRamp": _has_free_ramp(map)}
		var step := feet + Vector2i.RIGHT
		var support := step + Vector2i.DOWN
		if solids.get(support, "") == "r45":
			step.y -= 1
			rise += 1
		elif not solids.has(support):
			break
		if solids.has(step):
			break
		feet = step
	return {}

func _load_campaign(manifest: Dictionary) -> bool:
	if _entry.get("function") != manifest.get("functions", {}).get("campaign", {}).get("code"):
		return false
	var fields: Dictionary = _entry.get("fields", {})
	var screen: Dictionary = fields.get("VPOS", {})
	var point: Array = screen.get("point", [])
	if point.size() != 2:
		return false
	for vp in manifest.get("viewports", []):
		if vp.id == screen.get("viewport"):
			_dialogue_position = Vector2(float(point[0]) * float(vp.w), float(point[1]) * float(vp.h))
			_caption = str(fields.get("CAPT", ""))
			return _prepare_campaign(manifest.get("steps", {}).get("advance", {}).get("code", ""))
	return false

func _has_free_ramp(map: Dictionary) -> bool:
	for row in map.get("objects", []):
		if row.get("asset") != "free-ramp":
			continue
		var anchor := (Vector2(row.x, row.y) + Vector2(0.5, 0.5)) * 16.0
		var shape := PackedVector2Array()
		for p in row.get("props", {}).get("points", []):
			shape.append(anchor + Vector2(p[0], p[1]))
		if shape.size() == 4:
			var holes: Array = row.get("props", {}).get("holes", [])
			if holes.size() != 1:
				return false
			var hole := PackedVector2Array()
			for p in holes[0]:
				hole.append(anchor + Vector2(p[0], p[1]))
			var parts: Array = row.props.get("parts", [])
			if parts.size() != 1 or parts[0].get("holes", []).size() != 1:
				return false
			var extra := PackedVector2Array()
			var extra_hole := PackedVector2Array()
			for p in parts[0].points:
				extra.append(anchor + Vector2(p[0], p[1]))
			for p in parts[0].holes[0]:
				extra_hole.append(anchor + Vector2(p[0], p[1]))
			return Geometry2D.is_point_in_polygon(Vector2(70, 62), shape) \
				and Geometry2D.is_point_in_polygon(Vector2(102, 51), extra) \
				and not Geometry2D.is_point_in_polygon(Vector2(84, 60), extra) \
				and Geometry2D.is_point_in_polygon(Vector2(112, 58), extra_hole) \
				and not Geometry2D.is_point_in_polygon(Vector2(37, 50), shape) \
				and Geometry2D.is_point_in_polygon(Vector2(61, 64), hole) \
				and not Geometry2D.is_point_in_polygon(Vector2(70, 62), hole) \
				and hole[0].distance_to(Vector2(57, 60)) <= 0.01 \
				and shape[0].distance_to(Vector2(32.5, 68)) <= 0.01
	return false

func _ramp_transform(map: Dictionary, manifest: Dictionary, row: Dictionary) -> Transform2D:
	var decl: Dictionary = manifest.assets.filter(func(asset): return asset.id == row.asset).front()
	var grid = ViewData.effective_grid(map, manifest)
	return ViewData.layer_transform(map, row.layer) * ViewData.object_transform_in_layer(grid, decl, row)

func _check_free_ramp_motion(map: Dictionary, manifest: Dictionary) -> Dictionary:
	var terrain := StaticBody2D.new()
	var sweep := Transform2D.IDENTITY
	for row in map.get("objects", []):
		if row.get("asset") != "free-ramp":
			continue
		var transform := _ramp_transform(map, manifest, row)
		sweep = transform * Transform2D(0.0, Vector2(-32.5, -68.0))
		var props: Dictionary = row.props
		var parts: Array = [props]
		parts.append_array(props.get("parts", []))
		for part in parts:
			var rings: Array = [part.points]
			rings.append_array(part.get("holes", []))
			var local_rings: Array[PackedVector2Array] = []
			for ring in rings:
				local_rings.append(PackedVector2Array(ring.map(func(p): return Vector2(p[0], p[1]))))
			for piece in Geometry.fill_strips(local_rings):
				var shape := ConvexPolygonShape2D.new()
				shape.points = transform * piece
				var child := CollisionShape2D.new()
				child.shape = shape
				terrain.add_child(child)
	if terrain.get_child_count() == 0:
		terrain.free()
		return {}
	add_child(terrain)
	var probe := CharacterBody2D.new()
	probe.collision_layer = 0
	var circle := CircleShape2D.new()
	circle.radius = 0.5
	var collider := CollisionShape2D.new()
	collider.shape = circle
	probe.add_child(collider)
	add_child(probe)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var results := {
		"primaryStops": _check_sweep(probe, terrain, sweep * Vector2(84, 62), sweep * Vector2(70, 62), true),
		"extraStops": _check_sweep(probe, terrain, sweep * Vector2(90, 51), sweep * Vector2(102, 51), true),
		"primaryHoleClears": _check_sweep(probe, terrain, sweep * Vector2(60, 63), sweep * Vector2(63, 66), false),
		"extraHoleClears": _check_sweep(probe, terrain, sweep * Vector2(110, 56), sweep * Vector2(114, 61), false),
		"gapClears": _check_sweep(probe, terrain, sweep * Vector2(84, 45), sweep * Vector2(84, 74), false),
	}
	probe.queue_free()
	terrain.queue_free()
	return results

func _check_sweep(probe: CharacterBody2D, terrain: StaticBody2D, start: Vector2, end: Vector2, blocked: bool) -> bool:
	probe.position = start
	var motion := end - start
	var hit := probe.move_and_collide(motion)
	if blocked:
		var travel := (probe.position - start).dot(motion.normalized())
		return hit != null and hit.get_collider() == terrain and travel > 0.5 and travel < motion.length() - 0.5
	return hit == null and probe.position.distance_to(end) < 0.01

func _read_schedule(fn_id: String, content_dir: String, id := "project-timing") -> Array:
	var decl: Dictionary = _manifest.functions[fn_id]
	var content := _parse(FileAccess.get_file_as_string("res://".path_join(content_dir).path_join(fn_id)
		.path_join(id + ".json")))
	if content.get("function") != decl.code:
		return []
	var rate := _sequence_rate(content, decl)
	return _step_ranges(content.steps, rate) if rate > 0.0 else []

func _sequence_rate(content: Dictionary, decl: Dictionary) -> float:
	if decl.get("timebase", "seconds") == "frames":
		for field in decl.fields:
			if field.id == decl.get("timePreview", {}).get("fpsField"):
				return float(content.fields.get(field.code, 0.0))
		return 0.0
	return 1.0

func _step_ranges(steps: Array, rate: float) -> Array:
	var cursors := {}
	var schedule := []
	for step in steps:
		var track := int(step.get("track", 0))
		var cursor := float(cursors.get(track, 0.0))
		var at := float(step.get("at", cursor))
		var end := at + float(step.get("duration", 0.0))
		schedule.append([at / rate, end / rate])
		if step.get("blocking", true):
			cursors[track] = maxf(cursor, end)
	return schedule

func _prepare_campaign(code: String) -> bool:
	var sequence: Array = _entry.get("steps", [])
	if sequence.size() < 2 or code == "" or sequence.back().get("step") != code:
		return false
	var chart_fields: Dictionary = _entry.get("fields", {})
	var audio := str(chart_fields.get("MUSC", ""))
	var audio_path := ""
	for row in _manifest.get("audio", {}).values():
		if row.get("code") == audio:
			audio_path = str(row.get("path", ""))
	var stream := AudioStreamWAV.load_from_file("res://".path_join(audio_path)) if audio_path != "" else null
	if stream == null:
		return false
	var cue: Dictionary = sequence.back()
	var cue_beat := float(cue.get("at", 0.0))
	var tempo_code := str(_manifest.get("steps", {}).get("tempo", {}).get("code", ""))
	var bpm := 0.0
	var last_beat := 0.0
	_cue_seconds = float(chart_fields.get("OFST", 0.0))
	for i in sequence.size() - 1:
		var row: Dictionary = sequence[i]
		var at := float(row.get("at", 0.0))
		var next_bpm := float(row.get("fields", {}).get("BPM1", 0.0))
		if row.get("step") != tempo_code or next_bpm <= 0.0 or at > cue_beat:
			return false
		if i == 0 and at != 0.0 or i > 0 and at <= last_beat:
			return false
		if i > 0:
			_cue_seconds += (at - last_beat) * 60.0 / bpm
		bpm = next_bpm
		last_beat = at
	_cue_seconds += (cue_beat - last_beat) * 60.0 / bpm
	_rhythm_player = AudioStreamPlayer.new()
	_rhythm_player.stream = stream
	add_child(_rhythm_player)
	return true

func _start_attempt() -> void:
	_rhythm_player.play()
	_attempt_started = Time.get_ticks_usec()
	_awaiting_input = true
	queue_redraw()

func _attempt_time() -> float:
	return (Time.get_ticks_usec() - _attempt_started) / 1000000.0

func _process(_dt: float) -> void:
	if not _awaiting_input:
		return
	queue_redraw()
	# Verification generates keys through the same running input handler as the interactive game.
	if _headless and _attempt_time() >= _cue_seconds + (0.3 if _attempts.is_empty() else 0.0):
		var key := InputEventKey.new()
		key.keycode = KEY_SPACE
		key.pressed = true
		Input.parse_input_event(key)
		key = key.duplicate()
		key.pressed = false
		Input.parse_input_event(key)

func _judge_attempt() -> void:
	var elapsed := _attempt_time()
	var result := _resolve_branch(_entry.steps.back(), elapsed, 2)
	if result.is_empty():
		return
	_next_step += 1
	_attempts.append({"inputSec": elapsed, "retry": result.retry})
	if result.retry == _entry.id:
		_miss_ending = result.message
		_publish_attempt("输入未命中，按作者配置重试。")
		_start_attempt()
		return
	_ending = result.message
	_awaiting_input = false
	_publish_attempt("进入结局：" + _ending)
	if _headless:
		get_tree().quit()

func _publish_attempt(message: String) -> void:
	var content_dir := str(_manifest.get("contentDir", "content"))
	_report("ready", "", {"caption": _caption, "step": _next_step, "ending": _ending, "missEnding": _miss_ending,
		"cueSec": _cue_seconds, "attempts": _attempts, "flowGoal": _flow_goal, "schedules": {
			"frame_sequence": _read_schedule("frame_sequence", content_dir),
			"second_sequence": _read_schedule("second_sequence", content_dir)},
		"pointPx": [_dialogue_position.x, _dialogue_position.y], "hotspot": _reference_target(Vector2(0.5, 0.5)),
		"screenTargets": [_screen_target(Vector2(720, 1280)), _screen_target(Vector2(900, 900))],
		"screenFocus": _screen_focus("right"), "screenArtwork": _screen_artwork()}, [{
			"message": message, "function": "campaign", "content": _entry.id, "contentDigest": _entry_digest,
			"step": _entry.steps.size() - 1, "stepCode": _entry.steps.back().step}])

## The game defines group evaluation, predicate code and how a chosen target is loaded.
func _resolve_branch(cue: Dictionary, input_seconds: float, lane: int) -> Dictionary:
	var destination := ""
	var map_code := ""
	for route in cue.get("fields", {}).get("BRCH", []):
		var require_all: bool = route.get("MODE", "all") == "all"
		var matches := require_all
		for row in route.get("PRED", []):
			var fields: Dictionary = row.get("fields", {})
			var pass_condition := false
			match row.get("condition", ""):
				"hit_window":
					pass_condition = absf(input_seconds - _cue_seconds) <= float(fields.get("WIND", 0)) / 1000.0
				"on_lane":
					pass_condition = lane == int(fields.get("LANE", 0))
				_:
					return {}
			if row.get("negate", false):
				pass_condition = not pass_condition
			matches = (matches and pass_condition) if require_all else (matches or pass_condition)
		if matches:
			destination = str(route.get("DEST", ""))
			map_code = str(route.get("DMAP", ""))
			break
	return _resolve_ending(destination, _map_with_code(map_code) if map_code != "" else {})

## The branch chooses a map. Its continuation keeps that map and resolves its own local instance.
func _resolve_ending(destination: String, current_map: Dictionary) -> Dictionary:
	var content_dir := str(_manifest.get("contentDir", "content"))
	var seen := {}
	while destination.is_valid_filename() and not seen.has(destination):
		seen[destination] = true
		var ending := _parse(FileAccess.get_file_as_string("res://".path_join(content_dir)
			.path_join("ending").path_join(destination + ".json")))
		if ending.is_empty() or ending.get("function") != _manifest.get("functions", {}).get("ending", {}).get("code"):
			return {}
		var fields: Dictionary = ending.get("fields", {})
		var instance := str(fields.get("GOAL", ""))
		if instance != "":
			if not current_map.get("objects", []).any(func(obj): return obj.get("code") == instance):
				return {}
			_flow_goal = {"map": current_map.meta.code, "inst": instance}
		destination = str(fields.get("HOP1", ""))
		if destination == "":
			return {"message": str(fields.get("MESG", "")), "retry": str(fields.get("AGAN", ""))}
	return {}

func _load_rule_grid(map: Dictionary, manifest: Dictionary) -> Dictionary:
	var resolved := Grid.resolve(map.meta, manifest)
	if not resolved.issues.is_empty():
		return {}
	_rule_grid = resolved.grid
	for layer in map.tiles.values():
		for row in layer:
			_rule_tiles[Vector2i(int(row[0]), int(row[1]))] = true
	for row in map.get("collision", []):
		_rule_blocked[Vector2i(int(row.x), int(row.y))] = true
	var start := Vector2i(int(map.spawn[0]), int(map.spawn[1]))
	var gate := ""
	for row in map.objects:
		if row.asset == "door":
			# The fixture's door has the default center anchor and belongs to an untransformed layer.
			var anchor := _rule_grid.object_anchor_px(Vector2(float(row.x), float(row.y)), Vector2(0.5, 0.5))
			_rule_goal = _rule_grid.pick_cell(anchor)
			gate = str(row.code)
			break
	if gate == "" or not _rule_tiles.has(start) or _rule_blocked.has(start) \
			or not _rule_tiles.has(_rule_goal) or _rule_blocked.has(_rule_goal):
		return {}
	# Find a legal route, then execute it through the same picker and move rule as a mouse click.
	var frontier: Array[Vector2i] = [start]
	var previous := {start: start}
	var cursor := 0
	while cursor < frontier.size() and not previous.has(_rule_goal):
		var from := frontier[cursor]
		cursor += 1
		for cell: Vector2i in _rule_grid.neighbors_any(from):
			if not previous.has(cell) and _rule_can_move(from, cell):
				previous[cell] = from
				frontier.append(cell)
	if not previous.has(_rule_goal):
		return {}
	var path: Array[Vector2i] = [_rule_goal]
	while path.back() != start:
		path.append(previous[path.back()])
	path.reverse()
	_rule_player = start
	var rejected_neighbor := false
	for cell: Vector2i in _rule_grid.neighbors_any(start):
		if _rule_tiles.has(cell) and _rule_blocked.has(cell):
			rejected_neighbor = not _rule_pick_move(_rule_grid.cell_center_px(cell))
	if _headless:
		for i in range(1, path.size()):
			if not _rule_pick_move(_rule_grid.cell_center_px(path[i])):
				return {}
	var center := _rule_grid.cell_center_px(start)
	return {"gate": gate, "path": path.map(func(c): return [c.x, c.y]),
		"center": [center.x, center.y], "vertices": _rule_grid.cell_polygon(start).size(),
		"neighbors": _rule_grid.neighbors_any(start).size(), "rejectedNeighbor": rejected_neighbor,
		"reached": _rule_player == _rule_goal}

func _rule_can_move(from: Vector2i, target: Vector2i) -> bool:
	return _rule_tiles.has(target) and not _rule_blocked.has(target) and _rule_grid.neighbors_any(from).has(target)

func _rule_pick_move(point: Vector2) -> bool:
	var cell := _rule_grid.pick_cell(point)
	if not _rule_can_move(_rule_player, cell):
		return false
	_rule_player = cell
	return true

func _unhandled_input(event: InputEvent) -> void:
	if _rule_grid != null and event is InputEventMouseButton \
			and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _rule_pick_move(get_local_mouse_position() - _rule_origin):
			queue_redraw()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_accept") or event.is_echo():
		return
	if _rule_grid != null:
		return
	if _current != "":
		_advance_board()
	elif _awaiting_input:
		_judge_attempt()
	queue_redraw()

func _draw() -> void:
	var font := ThemeDB.fallback_font
	if _rule_grid != null:
		draw_set_transform(_rule_origin)
		for cell: Vector2i in _rule_tiles:
			var color := Color.DARK_RED if _rule_blocked.has(cell) else Color.SLATE_GRAY
			if cell == _rule_goal:
				color = Color.GOLD
			var polygon := _rule_grid.cell_polygon(cell)
			draw_colored_polygon(polygon, color)
			polygon.append(polygon[0])
			draw_polyline(polygon, Color.BLACK, 1.0)
		draw_circle(_rule_grid.cell_center_px(_rule_player), 3.0, Color.AQUAMARINE)
		draw_set_transform(Vector2.ZERO)
		draw_string(font, Vector2(12, 26), "Reached door" if _rule_player == _rule_goal else "Click a neighboring cell")
	elif _current != "":
		draw_set_transform(Vector2(32, 60), 0.0, Vector2(6, 6))
		for id in _cells:
			draw_colored_polygon(_cells[id].polygon, Color.AQUAMARINE if id == _current else Color.SLATE_GRAY)
		draw_set_transform(Vector2.ZERO)
		draw_string(font, Vector2(32, 36), "Cell: " + _current + "  |  Space: follow directed link")
	else:
		draw_string(font, Vector2(32, 36) + _dialogue_position * 0.25, _caption)
		var hint := _ending
		if _awaiting_input:
			hint = "%s  Space at cue · %+.2fs" % [_miss_ending, _attempt_time() - _cue_seconds]
		draw_string(font, Vector2(32, 86), hint)

func _fail(message: String) -> void:
	printerr(message)
	_report("error", message, {})
	if _headless:
		get_tree().quit(1)

func _report(status: String, message: String, result: Dictionary, observations := []) -> void:
	if _request.is_empty():
		return
	var path := str(_request.get("path", ""))
	if path == "":
		return
	var report := {"version": 1, "token": _request.get("token", ""), "status": status,
		"mapDigest": _map_text.sha256_text() if _map_text != "" else "",
		"manifestDigest": _manifest_text.sha256_text(), "message": message, "result": result}
	if not observations.is_empty():
		report.observations = observations
	var tmp := path + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(report))
	file.close()
	DirAccess.rename_absolute(tmp, path)
