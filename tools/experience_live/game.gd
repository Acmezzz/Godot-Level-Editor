extends Node2D

const Grid := preload("res://src/canvas/grid_space.gd")
const MANIFEST := "res://editor/editor_manifest.json"
const STATE := "res://editor/live-state.json"
const BG := Color("101b30")
const MINT := Color("57e4c5")
const GOLD := Color("f6c271")

var manifest: Dictionary
var maps := {}
var report := {}
var map := {}
var screen := ""
var buttons := {}
var player := Vector2i.ZERO
var cell := ""
var seen := {}
var energy := 0
var cargo := 0
var deliveries := 0
var blocked := 0
var moves := 0
var stack: Array[Dictionary] = []
var cue := {}
var cue_at := 0.0
var elapsed := 0.0
var fired := {}
var layer_display := {}
var subtitle := ""
var fade := 0.0
var notice := ""
var volume := 1.0
var sound := AudioStreamPlayer.new()
var last_frame := ""

func _ready() -> void:
	get_window().title = "BIRD authoring playtest"
	add_child(sound)
	manifest = _read(MANIFEST)
	for file_name in DirAccess.get_files_at("res://maps"):
		if file_name.ends_with(".json"):
			var data := _read("res://maps/" + file_name)
			maps[data.meta.code] = data
	var entry: Dictionary = {}
	var map_path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--editor-entry="):
			entry = JSON.parse_string(Marshalls.base64_to_utf8(arg.trim_prefix("--editor-entry=")))
		elif arg.begins_with("--editor-playtest="):
			report = JSON.parse_string(Marshalls.base64_to_utf8(arg.trim_prefix("--editor-playtest=")))
		elif arg.begins_with("--map="):
			map_path = arg.trim_prefix("--map=")
	if entry.is_empty():
		entry = {"map": _read(map_path).meta.code} if map_path != "" else manifest.startup.target
	_follow(entry)
	if not report.is_empty():
		var rcpt := report.merged({"status": "ready", "result": _state()})
		rcpt.manifestDigest = FileAccess.get_sha256(MANIFEST)
		rcpt.mapDigest = FileAccess.get_sha256(map_path) if map_path != "" else ""
		_write(report.path, rcpt)

func _read(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path))

func _write(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()
	DirAccess.rename_absolute(ProjectSettings.globalize_path(path + ".tmp"), ProjectSettings.globalize_path(path))

func _content(fn_id: String, id: String) -> Dictionary:
	return _read("res://content/%s/%s.json" % [fn_id, id])

func _call(target: Dictionary) -> void:
	var fn_id := str(target.function)
	var data := _content(fn_id, target.content)
	match fn_id:
		"route": _follow(data.fields.DST0)
		"option":
			volume = float(data.fields.VOL0)
			sound.volume_db = linear_to_db(volume)
		"rule": energy = int(data.fields.STA0)
		"cue":
			cue = data
			fired.clear()
			cue_at = elapsed

func _follow(target: Dictionary) -> void:
	if target.has("view"):
		screen = target.view
		map = {}
		for view in manifest.views:
			if view.view_id == screen:
				buttons.clear()
				for el in view.layout.elements:
					buttons[el.id] = el
				break
	elif target.has("map"):
		screen = ""
		map = maps[target.map]
		var s: Array = map.spawn
		player = Vector2i(s[0], s[1])
		cue.clear()
		layer_display.clear()
		seen.clear()
		cell = "start"
		fade = 0.0
		subtitle = ""
		notice = ""
		stack = [{"map": map, "order": 0}]
		for group in manifest.get("eventLayers", {}).values():
			if group.has("maps") and target.map not in group.maps:
				continue
			if group.has("drawingMap"):
				stack.append({"map": maps[group.drawingMap], "order": group.drawOrder})
			var enter: Dictionary = group.get("events", {}).get("ENT0", {})
			if not enter.is_empty():
				_call(enter)
		stack.sort_custom(func(a, b): return a.order < b.order)
		camera_at = _camera()
	_write(STATE, _state())

func _graph() -> Dictionary:
	return map.get("meta", {}).get("cellGraph", {})

func _state() -> Dictionary:
	return {"screen": screen, "map": map.get("meta", {}).get("code", ""), "stack": stack.map(func(s): return s.order),
		"projection": map.get("meta", {}).get("gridProjection", ""), "energy": energy, "cells": _graph().get("cells", []).size(),
		"x": player.x, "y": player.y, "moves": moves, "blocked": blocked, "notice": notice,
		"cell": cell, "cargo": cargo, "deliveries": deliveries, "volume": volume, "layerDisplay": layer_display,
		"fade": fade, "fired": fired.values(), "audioPlaying": sound.playing, "subtitle": subtitle,
		"cameraX": _camera().x, "hudAt": [18, 36] if _has_hud() else []}

func _has_hud() -> bool:
	return stack.any(func(s): return s.map.objects.any(func(o): return o.asset == "hud"))

func _unhandled_input(event: InputEvent) -> void:
	if screen == "" or not event is InputEventMouseButton or not event.pressed or event.button_index != MOUSE_BUTTON_LEFT:
		return
	var size := get_viewport_rect().size
	for el in buttons.values():
		if el.kind == "button" and _layout_rect(el, size).has_point(event.position):
			_call(el.target)
			_write(STATE, _state())
			break

func _unhandled_key_input(event: InputEvent) -> void:
	if event is not InputEventKey or not event.pressed or event.echo:
		return
	var key: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
	if screen != "":
		for el in buttons.values():
			if el.kind == "button" and el.text.left(1) == OS.get_keycode_string(key):
				_call(el.target)
				break
	elif not _graph().is_empty():
		if key in [KEY_1, KEY_2]:
			_take_edge(key - KEY_1)
	elif key in [KEY_A, KEY_D, KEY_W, KEY_S]:
		var direction: Vector2i = {KEY_A: Vector2i.LEFT, KEY_D: Vector2i.RIGHT, KEY_W: Vector2i.UP, KEY_S: Vector2i.DOWN}[key]
		var p := player + direction
		if map.collision.any(func(c): return c.x == p.x and c.y == p.y):
			blocked += 1
			notice = "BASE COLLISION"
		else:
			moves += 1
			player = p
			notice = ""
	elif key == KEY_E:
		for entity in map.objects:
			if Vector2i(entity.x, entity.y) != player:
				continue
			for row in entity.get("functions", []):
				if row.get("enabled", true) and row.get("trigger") == "USE0" and row.get("content", "") != "":
					for id in manifest.functions:
						if manifest.functions[id].code == row.fn:
							_call({"function": id, "content": row.content})
	_write(STATE, _state())

func _take_edge(i: int) -> void:
	var graph := _graph()
	var choices: Array = graph.edges.filter(func(link): return link.from == cell)
	if i >= choices.size():
		return
	var edge: Dictionary = choices[i]
	var cost := int(edge.props.cost)
	var hex := _grid(map).is_hex()
	if edge.props.gate == "needs_switch" and not seen.has("switch"):
		notice = "ROUTE LOCKED"
		return
	if (cargo if hex else energy) < cost:
		notice = "INSUFFICIENT CARGO" if hex else "NO ACTION POINTS"
		return
	cell = edge.to
	seen[cell] = true
	if hex:
		cargo -= cost
		for c in graph.cells:
			if c.id == cell:
				cargo += int(c.get("props", {}).get("cargo", 0))
		if cell == "port":
			deliveries += 1
	else:
		energy -= cost
	notice = "DELIVERY COMPLETE" if cell == "port" else "SIGNAL SOLVED" if cell == "exit" else ""

func _process(dt: float) -> void:
	elapsed += dt
	camera_at = camera_at.lerp(_camera(), 1.0 - exp(-8.0 * dt))
	if not cue.is_empty():
		var t := elapsed - cue_at
		var layers := {}
		subtitle = ""
		fade = 0.0
		var clocks := {}
		for i in cue.steps.size():
			var step: Dictionary = cue.steps[i]
			var track = step.get("track", 0)
			var time := float(step.get("at", clocks.get(track, 0.0)))
			var length := float(step.get("duration", 0.0))
			if step.get("blocking", true):
				clocks[track] = maxf(time + length, float(clocks.get(track, 0.0)))
			if t < time:
				continue
			var id := ""
			for candidate in manifest.steps:
				if manifest.steps[candidate].code == step.step:
					id = candidate
					break
			var first := not fired.has(i)
			fired[i] = id
			var local_t: float = t - time
			match id:
				"say":
					if local_t < length: subtitle = step.fields.MSG0
				"reveal": layers[step.fields.LYR0] = local_t < length
				"fade": fade = minf(local_t / length, 1.0)
				"sound":
					if first: _play_sound(step.fields.CLP0)
				"follow":
					if first:
						_call(step.fields.NXT0)
						break
		layer_display = layers
		_write(STATE, _state())
	queue_redraw()
	_capture()

func _play_sound(code: String) -> void:
	for clip in manifest.audio:
		if clip.code == code:
			sound.stream = AudioStreamWAV.load_from_file("res://" + clip.path)
			sound.play()
			break

func _capture() -> void:
	if report.is_empty():
		return
	var filename: String = str(report.path).get_basename() + ".frame.request.json"
	if not FileAccess.file_exists(filename):
		return
	var request := _read(filename)
	if request.token != report.token or request.id == last_frame:
		return
	last_frame = request.id
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.resize(int(request.width), int(request.height))
	if image.save_png(request.result + ".tmp") == OK:
		DirAccess.rename_absolute(request.result + ".tmp", request.result)

func _grid(data: Dictionary) -> GridSpace:
	return Grid.resolve(data.meta, manifest).grid

var camera_at := Vector2.ZERO

func _camera() -> Vector2:
	if not map.is_empty() and _graph().is_empty():
		return Vector2(player.x * 32.0, player.y * 32.0 - 128.0)
	return Vector2.ZERO

func _label(at: Vector2, value: String, size := 24, color := Color.WHITE) -> void:
	draw_string(ThemeDB.fallback_font, at, value, HORIZONTAL_ALIGNMENT_LEFT, -1.0, size, color)

func _layout_rect(el: Dictionary, size: Vector2) -> Rect2:
	var a: Array = el.anchors
	return Rect2(size * Vector2(a[0], a[1]), size * Vector2(a[2] - a[0], a[3] - a[1]))

func _draw() -> void:
	var size := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	if screen != "":
		for el in buttons.values():
			var r := _layout_rect(el, size)
			if el.kind == "button":
				draw_rect(r, Color("253e57"))
			_label(r.position + Vector2(12, r.size.y * 0.68), el.text, int(el.fontSize), MINT if el.kind == "text" else Color.WHITE)
		_label(Vector2(188, 390), "Volume %d%%" % int(volume * 100), 18, GOLD)
		return
	if map.is_empty():
		return
	var graph := _graph()
	var origin := Vector2(180, 139) if graph.is_empty() else Vector2(240, 114)
	for s in stack:
		_draw_map(s.map, origin, camera_at, int(s.order))
		if s.order == 0 and graph.is_empty():
			draw_circle(origin + _grid(map).cell_center_px(player) - camera_at, 12, GOLD)
	if not graph.is_empty():
		_draw_graph(graph, origin)
		_label(Vector2(24, 43), "HEX FREIGHT" if _grid(map).is_hex() else "ISOMETRIC SIGNAL ROUTE", 27, MINT)
		_label(Vector2(24, 75), "Cargo %d   Delivered %d" % [cargo, deliveries] if _grid(map).is_hex() else "Action points %d" % energy, 20)
		var destinations: Array = graph.edges.filter(func(edge): return edge.from == cell)
		for i in destinations.size():
			_label(Vector2(24, 379 + i * 24), "%d  /  %s  ·  cost %s" % [i + 1, destinations[i].to, destinations[i].props.cost], 18)
	else:
		_label(Vector2(20, size.y - 25), "A/D/W/S  Move    E  Interact", 18, MINT)
	if notice != "":
		_label(Vector2(20, size.y - 53), notice, 22, GOLD)
	if subtitle != "":
		draw_rect(Rect2(155, 331, 490, 56), Color(0.04, 0.08, 0.15, 0.94))
		_label(Vector2(175, 366), subtitle, 23)
	if fade > 0.0:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.27, 0.05, 0.42, fade))
		_label(Vector2(313, 239), "SIGNAL HANDOFF", 25, Color(1, 1, 1, fade))

func _draw_map(data: Dictionary, origin: Vector2, camera: Vector2, order: int) -> void:
	var grid := _grid(data)
	for layer in data.meta.layers:
		if not layer_display.get(layer.id, layer.get("visible", true)):
			continue
		var tile_grid: GridSpace = Grid.resolve_tile_layer(layer, manifest, grid).grid
		var shift := camera * float(layer.get("parallax", 1.0))
		for row in data.tiles.get(layer.id, []):
			var polygon := tile_grid.cell_polygon(Vector2i(row[0], row[1]))
			for i in polygon.size():
				polygon[i] += origin - shift
			var color := Color("244953") if row[2] == "floor" else Color("263550")
			if order < 0: color = Color("4d6989") if row[2] == "floor" else Color("413966")
			if layer.get("blend") == "add": color = MINT
			draw_colored_polygon(polygon, color)
			draw_polyline(PackedVector2Array(Array(polygon) + [polygon[0]]), color.lightened(0.18), 1.0, true)
		for o in data.objects:
			if o.layer != layer.id:
				continue
			if o.asset == "beacon":
				var p: Vector2 = origin + grid.cell_center_px(Vector2i(o.x, o.y)) - shift
				draw_arc(p, 18, 0, TAU, 24, MINT, 2, true)
			elif o.asset == "hud":
				draw_rect(Rect2(12, 12, 250, 36), Color("253e57"))
				_label(Vector2(18, 36), "CORRIDOR   ·   POWER %d" % energy, 19, MINT)

func _draw_graph(graph: Dictionary, origin: Vector2) -> void:
	var points := {}
	for c in graph.cells:
		var polygon := PackedVector2Array()
		var center := Vector2.ZERO
		for p in c.polygon:
			var v := origin + Vector2(p[0], p[1])
			polygon.append(v)
			center += v
		points[c.id] = center / polygon.size()
		draw_colored_polygon(polygon, GOLD if c.id == cell else MINT)
	for link in graph.edges:
		var from: Vector2 = points[link.from]
		var to: Vector2 = points[link.to]
		draw_line(from, to, Color("adcadf"), 2, true)
	for id in points:
		_label(points[id] + Vector2(-20, -16), id, 18, GOLD if id == cell else Color.WHITE)
