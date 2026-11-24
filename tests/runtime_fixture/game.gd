extends Node2D

const ChunkDelta := preload("res://generated_chunk_delta.gd")
const Grid := preload("res://grid_space.gd")
## Example game code. It reads saved contracts and shares the standalone format helpers.

var _request: Dictionary
var _manifest_text := ""
var _map_text := ""
var _entry: Dictionary
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
		if map.get("meta", {}).get("name") == "rule_hex" and not map.meta.get("cellGraph", {}).is_empty():
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
				var collision_checks := await _check_free_ramp_motion(map)
				if collision_checks.values().has(false) or collision_checks.is_empty():
					_fail("Saved contour physics disagrees with the expected motion: " + str(collision_checks))
					return
				outcome["freeRampMotion"] = collision_checks
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
		_entry = _parse(FileAccess.get_file_as_string("res://".path_join(content_dir).path_join(
			"campaign/project-acceptance.json")))
		if not _load_campaign(manifest):
			_fail("Campaign, screen position, or first step is invalid")
			return
		_report("ready", "", {"caption": _caption, "step": _next_step, "ending": _ending, "missEnding": _miss_ending, "cueSec": _cue_seconds,
			"flowGoal": _flow_goal,
			"pointPx": [_dialogue_position.x, _dialogue_position.y], "hotspot": _reference_target(Vector2(0.5, 0.5)),
			"screenTargets": [_screen_target(Vector2(720, 1280)), _screen_target(Vector2(900, 900))],
			"screenFocus": _screen_focus("right"), "screenArtwork": _screen_artwork()})
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
	if capability == "screenLayout":
		_compose_screen_frame(surface, subject, size, str(request.get("locale", "")))
	elif capability == "mapFrame":
		_compose_map_frame(surface, subject, size)
	elif capability == "worldFrame":
		_compose_world_frame(surface, subject, size)
	else:
		_compose_timeline_frame(surface, subject, size)
	await RenderingServer.frame_post_draw
	var image := surface.get_texture().get_image()
	var status := "ready"
	if image == null or image.is_empty() or image.save_png(path.get_base_dir().path_join("frame.png")) != OK:
		status = "error"
	var report := FileAccess.open(path.get_base_dir().path_join("result.json"), FileAccess.WRITE)
	if report != null:
		report.store_string(JSON.stringify({"version": 1, "token": request.token, "status": status,
			"message": "" if status == "ready" else "The engine could not capture a frame."}))
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

func _compose_timeline_frame(surface: SubViewport, subject: Dictionary, size: Vector2i) -> void:
	var time: Dictionary = subject.get("time", {})
	var data: Dictionary = subject.get("data", {})
	if subject.get("function") != "campaign" or subject.get("content") != "project-acceptance" \
			or time.get("unit") != "beats" or data.get("fields", {}).get("CAPT") != "Staged frame":
		return
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
		return
	var cue := ColorRect.new()
	cue.color = Color("#d75283") if cue_reached else Color("#479bb1")
	cue.size = Vector2(16, 16)
	cue.position = Vector2(roundf(seconds * 100.0), size.y * 0.5)
	surface.add_child(cue)

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

func _activate_switch(map: Dictionary, manifest: Dictionary) -> String:
	var target: Dictionary = {}
	for obj in map.get("objects", []):
		if obj.asset == "switch":
			target = obj.get("props", {}).get("target", {})
			break
	if target.get("map") != map.meta.code or target.get("port") != "open":
		return ""
	for obj in map.get("objects", []):
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
			return _advance_campaign(manifest.get("steps", {}).get("advance", {}).get("code", ""))
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

func _check_free_ramp_motion(map: Dictionary) -> Dictionary:
	var terrain := StaticBody2D.new()
	for row in map.get("objects", []):
		if row.get("asset") != "free-ramp":
			continue
		var anchor := (Vector2(row.x, row.y) + Vector2(0.5, 0.5)) * 16.0
		var props: Dictionary = row.props
		var parts: Array = [props]
		parts.append_array(props.get("parts", []))
		for part in parts:
			var rings: Array = [part.points]
			rings.append_array(part.get("holes", []))
			_add_solid_pieces(terrain, anchor, rings)
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
		"primaryStops": _check_sweep(probe, terrain, Vector2(84, 62), Vector2(70, 62), true),
		"extraStops": _check_sweep(probe, terrain, Vector2(90, 51), Vector2(102, 51), true),
		"primaryHoleClears": _check_sweep(probe, terrain, Vector2(60, 63), Vector2(63, 66), false),
		"extraHoleClears": _check_sweep(probe, terrain, Vector2(110, 56), Vector2(114, 61), false),
		"gapClears": _check_sweep(probe, terrain, Vector2(84, 45), Vector2(84, 74), false),
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

## Sweep horizontal bands between vertices. Crossing pairs bound convex solid
## pieces; the empty intervals between them include any holes in this part.
func _add_solid_pieces(terrain: StaticBody2D, anchor: Vector2, rings: Array) -> void:
	var heights := {}
	var edges: Array[Vector4] = []
	for ring in rings:
		for i in ring.size():
			var a := Vector2(ring[i][0], ring[i][1])
			var next: Array = ring[(i + 1) % ring.size()]
			var b := Vector2(next[0], next[1])
			heights[a.y] = true
			if a.y < b.y:
				edges.append(Vector4(a.x, a.y, b.x, b.y))
			elif b.y < a.y:
				edges.append(Vector4(b.x, b.y, a.x, a.y))
	var ys := heights.keys()
	ys.sort()
	for i in range(ys.size() - 1):
		var low: float = ys[i]
		var high: float = ys[i + 1]
		var crossings: Array[Vector2] = []
		for edge in edges:
			if edge.y <= low and edge.w >= high:
				var slope := (edge.z - edge.x) / (edge.w - edge.y)
				crossings.append(Vector2(edge.x + (low - edge.y) * slope, edge.x + (high - edge.y) * slope))
		crossings.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x + a.y < b.x + b.y)
		for j in range(0, crossings.size() - 1, 2):
			var left := crossings[j]
			var right := crossings[j + 1]
			var points := PackedVector2Array([anchor + Vector2(left.x, low)])
			if not is_equal_approx(left.x, right.x):
				points.append(anchor + Vector2(right.x, low))
			points.append(anchor + Vector2(right.y, high))
			if not is_equal_approx(left.y, right.y):
				points.append(anchor + Vector2(left.y, high))
			if points.size() < 3:
				continue
			var shape := ConvexPolygonShape2D.new()
			shape.points = points
			var child := CollisionShape2D.new()
			child.shape = shape
			terrain.add_child(child)

func _advance_campaign(code: String) -> bool:
	var sequence: Array = _entry.get("steps", [])
	if _next_step > 0 or sequence.size() < 2 or code == "" or sequence.back().get("step") != code:
		return false
	var chart_fields: Dictionary = _entry.get("fields", {})
	var audio := str(chart_fields.get("MUSC", ""))
	var audio_path := ""
	for row in _manifest.get("audio", {}).values():
		if row.get("code") == audio:
			audio_path = str(row.get("path", ""))
	if audio_path == "" or AudioStreamWAV.load_from_file("res://".path_join(audio_path)) == null:
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
	_ending = _resolve_branch(cue, _cue_seconds, 2)
	_miss_ending = _resolve_branch(cue, _cue_seconds + 0.3, 2)
	if _ending == "" or _miss_ending == "" or _resolve_branch(cue, _cue_seconds, 1) != "":
		return false
	_next_step += 1
	return true

## The game defines group evaluation, predicate code and how a chosen target is loaded.
func _resolve_branch(cue: Dictionary, input_seconds: float, lane: int) -> String:
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
					return ""
			if row.get("negate", false):
				pass_condition = not pass_condition
			matches = (matches and pass_condition) if require_all else (matches or pass_condition)
		if matches:
			destination = str(route.get("DEST", ""))
			map_code = str(route.get("DMAP", ""))
			break
	return _resolve_ending(destination, _map_with_code(map_code) if map_code != "" else {})

## The branch chooses a map. Its continuation keeps that map and resolves its own local instance.
func _resolve_ending(destination: String, current_map: Dictionary) -> String:
	var content_dir := str(_manifest.get("contentDir", "content"))
	var seen := {}
	while destination.is_valid_filename() and not seen.has(destination):
		seen[destination] = true
		var ending := _parse(FileAccess.get_file_as_string("res://".path_join(content_dir)
			.path_join("ending").path_join(destination + ".json")))
		if ending.is_empty() or ending.get("function") != _manifest.get("functions", {}).get("ending", {}).get("code"):
			return ""
		var fields: Dictionary = ending.get("fields", {})
		var instance := str(fields.get("GOAL", ""))
		if instance != "":
			if not current_map.get("objects", []).any(func(obj): return obj.get("code") == instance):
				return ""
			_flow_goal = {"map": current_map.meta.code, "inst": instance}
		destination = str(fields.get("HOP1", ""))
		if destination == "":
			return str(fields.get("MESG", ""))
	return ""

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
	if not event.is_action_pressed("ui_accept"):
		return
	if _rule_grid != null:
		return
	if _current != "":
		_advance_board()
	else:
		_advance_campaign("NEXT")
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
		draw_string(font, Vector2(32, 86), "Step " + str(_next_step) + " · " + _ending)

func _fail(message: String) -> void:
	printerr(message)
	_report("error", message, {})
	if _headless:
		get_tree().quit(1)

func _report(status: String, message: String, result: Dictionary) -> void:
	if _request.is_empty():
		return
	var path := str(_request.get("path", ""))
	if path == "":
		return
	var report := {"version": 1, "token": _request.get("token", ""), "status": status,
		"mapDigest": _map_text.sha256_text() if _map_text != "" else "",
		"manifestDigest": _manifest_text.sha256_text(), "message": message, "result": result}
	var tmp := path + ".tmp"
	var file := FileAccess.open(tmp, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(report))
	file.close()
	DirAccess.rename_absolute(tmp, path)
