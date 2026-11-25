extends SceneTree
## 批量记录真实界面：godot --path <独立编辑器工作副本> --script res://tools/screenshot.gd -- <游戏工程> <输出目录> <地图名> [宽 高]
## 使用测试游戏工程副本；会像正常启动一样更新该编辑器工作副本的最近项目记录。

var app: Control
var out := ""
var shots: Array[Dictionary] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3:
		push_error("截图需要：游戏工程目录、输出目录、地图名")
		quit(1)
		return
	out = args[1]
	DirAccess.make_dir_recursive_absolute(out)
	root.gui_embed_subwindows = true
	root.size = Vector2i(int(args[3]), int(args[4])) if args.size() >= 5 else Vector2i(1440, 900)
	app = load("res://src/editor.tscn").instantiate()
	if app.get_script() == null:
		push_error("编辑器脚本未加载")
		quit(1)
		return
	root.add_child(app)
	var project := args[0]
	var manifest := EditorManifest.load_from(project)
	if manifest.has("_error"):
		push_error(str(manifest._error))
		quit(1)
		return
	app._clear_project_session()
	app.project_dirs = []
	app._picker_ctrl.show_picker()
	await _shot("01-picker-empty")
	app.project_dirs = [project]
	app.project_names = {project: manifest.get("projectName", "项目")}
	app._picker_ctrl.show_picker()
	await _shot("02-picker-recent")
	await _dialog("03-picker-folder", app._picker_ctrl._pick_project)
	app._enter_project(project, manifest)
	await _shot("04-map-empty")

	await app._map_file_ctrl.open_map_by_name(args[2])
	for i in 6:
		await process_frame
	if not app.map_loaded:
		push_error("地图未打开：" + args[2])
		quit(1)
		return
	await _shot("05-map")
	var nav = app._nav_bars[0]
	var layout = app._layout_ctrl
	var map_file = app._map_file_ctrl
	await _dialog("06-map-list", func(): nav._switch_btn.pressed.emit())
	await _dialog("07-map-settings", func(): app._map_btn.pressed.emit())
	await _dialog("08-layer-menu", layout._toggle_layer_menu)
	await _dialog("09-layer-manager", layout._open_layer_manager)
	await _dialog("10-map-new", map_file.on_new)
	await _dialog("11-map-open", map_file.on_open)
	await _dialog("12-map-rename", map_file.on_rename)
	await _dialog("13-map-copy", map_file.on_duplicate)
	await _dialog("14-map-grid-convert", map_file.on_convert_projection)
	await _dialog("15-map-resize", func(): layout._on_map_menu_id(5))
	await _dialog("16-shortcuts", app._open_shortcut_help)
	await _dialog("17-play-config", app._playtest_ctrl.open_configuration)
	await _dialog("18-cell-graph", func(): nav._on_map_selected(nav._MENU_CELL_GRAPH))
	await _dialog("19-world-layout", func(): nav._on_map_selected(nav._MENU_WORLD))
	await _dialog("20-event-drawings", func(): nav._on_map_selected(nav._MENU_EVENTS))
	await _dialog("21-map-generation", func(): layout._on_map_menu_id(15))
	await _dialog("22-map-runtime-preview", func(): layout._on_map_menu_id(14), true)
	await _dialog("23-spawn-preview", func(): layout._on_map_menu_id(22), true)
	await _dialog("24-map-content-flow", func(): layout._on_map_menu_id(24))
	await _dialog("26-move-region-settings", func(): layout._on_map_menu_id(19))
	app._toggle_world_region_mode()
	app.canvas._world_region_move.select_area(Vector2.ZERO, Vector2(112, 112))
	await _dialog("25-copy-region-settings", func(): layout._on_map_menu_id(18))
	app._toggle_world_region_mode()

	var instances: Array = app.canvas.ents_all()
	var focus := ""
	for item in instances:
		if item is EntityNode and item.asset != "":
			app._editor_state_ctrl.apply("select", app.canvas._layer_index_of(item.layer_id))
			app.canvas.selected_entity = item
			app.canvas.selected_multi = [item]
			app._on_entity_selected(item)
			app.canvas.queue_redraw()
			focus = item.code
			await _shot("27-map-selected-instance")
			break
	if focus == "":
		_skip("27-map-selected-instance", "地图没有可选实例")
	app._set_mode("asset")
	await _shot("28-assets")
	app.asset_panel._filter_edit.text = "no-match-123"
	app.asset_panel._filter_edit.text_changed.emit("no-match-123")
	await _shot("29-assets-no-results")
	app.asset_panel._filter_edit.text = ""
	app.asset_panel._filter_edit.text_changed.emit("")
	app._set_mode("content", focus)
	await _shot("30-content")
	var ce = app.project_shell.content_editor
	await _dialog("31-content-library", ce._library.open)
	await _dialog("32-project-flow", ce._library._open_flow)
	await _dialog("33-viewport-library", func(): preload("res://src/ui/viewport_library.gd").open(app))
	await _dialog("34-reference-views", func(): preload("res://src/ui/reference_view_library.gd").open(app))
	await _dialog("35-screen-layout", func(): preload("res://src/ui/reference_view_library.gd").open(app), false, "ViewLayoutMode")
	if manifest.has("startup"):
		await _dialog("36-startup", func(): layout._work_actions.startup.pressed.emit())
	else:
		_skip("36-startup", "该项目未声明启动入口")
	await _dialog("37-project-events", func(): preload("res://src/ui/event_layers_dialog.gd").open(app))

	var fn := ""
	var cid := ""
	var store := preload("res://src/content/content_store.gd")
	var decl := preload("res://src/content/function_decl.gd")
	for kind in store.declared_kinds(manifest):
		if not decl.fn_has_steps(manifest, kind):
			continue
		for id in store.list_ids(manifest, kind):
			var data := store.read(manifest, kind, id)
			if not data.get("steps", []).is_empty():
				fn = kind
				cid = id
				break
		if cid != "":
			break
	if cid != "":
		await _dialog("38-content-fields", func(): ce._library._open_item(fn, cid))
		if ce._steps.open_content(fn, cid):
			await _shot("39-steps-list", ce._steps._steps_pop)
			ce._steps._set_steps_view("timeline")
			await _shot("40-timeline", ce._steps._steps_pop)
			if preload("res://src/project/game_preview.gd").supports(manifest, "timelineFrame"):
				await _dialog("42-timeline-game-frame", ce._steps._open_game_frame, true, "", ce._steps._steps_pop)
			ce._steps._steps_set_dock_where("content")
			await _shot("41-timeline-docked")
		else:
			for name in ["39-steps-list", "40-timeline", "41-timeline-docked"]:
				_skip(name, "演出编辑器没有打开")
	else:
		for name in ["38-content-fields", "39-steps-list", "40-timeline", "41-timeline-docked"]:
			_skip(name, "项目没有包含步骤的内容")
	if is_instance_valid(ce._steps._steps_dock) and ce._steps._steps_dock.is_visible_in_tree():
		ce._steps._steps_close_dock()
	if app._in_project_view():
		app._set_mode("map")
	await _dialog("43-geometry-tools", layout._geometry_menu.show_popup)
	app._editor_state_ctrl.apply("", app.canvas.collision_index())
	await _shot("44-collision-palette")
	await _dialog("45-collision-generator", func(): preload("res://src/ui/collision_dialog.gd").open(app))
	app._editor_state_ctrl.apply("", 0)
	var layer: String = app.canvas.layer_id(0)
	await _dialog("46-layer-custom-grid", func(): layout._layer_ctrl._open_custom_grid(layer, {}))
	var declaration := preload("res://src/assets/asset_decl.gd")
	for asset in declaration.of_kind(manifest, "scene"):
		if asset.get("shape") == "image":
			app._set_mode("asset", asset.id)
			await _shot("48-image-asset-details")
			break
	app._set_mode("map")
	var tile_layers: Array = app.canvas.layers_decl().filter(func(row):
		return app.canvas.layer_has_tiles(app.canvas._layer_index_of(row.id)))
	if not tile_layers.is_empty():
		var row: Dictionary = tile_layers[0]
		await _dialog("47-layer-grid-migration",
			func(): layout._layer_ctrl._open_grid_conversion(row.id, row.get("tileGrid", {})))
		var tiles: Array = app.canvas.extract().get("tiles", {}).get(row.id, [])
		app.canvas._region_sel = Rect2i(Vector2i(int(tiles[0][0]), int(tiles[0][1])), Vector2i(1, 1))
		app.canvas._region_layer = row.id
		await _dialog("49-tile-replace", app._open_tile_replace)
	else:
		_skip("47-layer-grid-migration", "需要带瓦片的验收地图")
		_skip("49-tile-replace", "需要带瓦片的验收地图")
	var report := FileAccess.open(out.path_join("manifest.json"), FileAccess.WRITE)
	report.store_string(JSON.stringify({"width": root.size.x, "height": root.size.y, "shots": shots}, "  "))
	report.close()
	quit(0 if shots.any(func(row): return row.has("png")) else 1)

func _windows(node: Node) -> Array[Window]:
	var result: Array[Window] = []
	for child in node.get_children(true):
		if child is Window:
			if child.visible:
				result.append(child)
		result.append_array(_windows(child))
	return result

func _dialog(label: String, action: Callable, render := false, toggle := "", except: Window = null) -> void:
	action.call()
	for i in 5:
		await process_frame
	var windows := _windows(app).filter(func(item): return item != except)
	if windows.is_empty():
		_skip(label, app.status.text if is_instance_valid(app.status) else "未打开窗口")
		return
	var window: Window = windows.back()
	if toggle != "":
		var button := window.find_child(toggle, true, false) as BaseButton
		if button == null or button.disabled:
			_skip(label, "当前参照没有可编辑布局")
			window.hide()
			return
		button.button_pressed = true
	if render:
		var render_buttons := window.find_children("*Render", "Button", true, false)
		if not render_buttons.is_empty():
			var button := render_buttons[0] as Button
			button.pressed.emit()
			var deadline := Time.get_ticks_msec() + 7000
			while is_instance_valid(button) and button.disabled and Time.get_ticks_msec() < deadline:
				await create_timer(0.05).timeout
			var frames := window.find_children("*Frame", "TextureRect", true, false)
			if not frames.any(func(frame): return frame.texture != null):
				print("PREVIEW ", label, " no rendered texture")
	await _shot(label, window)
	if is_instance_valid(window):
		if window is FileDialog:
			window.canceled.emit()
		else:
			window.hide()
	for i in 3:
		await process_frame

func _shot(label: String, window: Window = null) -> void:
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	var path := label + ".png"
	var image := root.get_texture().get_image()
	var err := image.save_png(out.path_join(path))
	if err != OK:
		_skip(label, error_string(err))
		return
	var row: Dictionary = {"screen": label, "png": path}
	if is_instance_valid(window):
		row["dialog"] = [window.position.x, window.position.y, window.size.x, window.size.y]
	shots.append(row)
	print("SHOT ", label)

func _skip(label: String, reason: String) -> void:
	shots.append({"screen": label, "skip": reason.strip_edges()})
	print("SKIP ", label, ": ", reason)
