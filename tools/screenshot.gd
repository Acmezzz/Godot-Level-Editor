extends SceneTree
## 截图辅助：启动编辑器 → 切到指定界面 → 等待渲染 → 保存 PNG。
## 用法：godot --path <编辑器工程> --script res://tools/screenshot.gd -- <mode> <out.png>
## 仅开发期临时使用，不属于测试套件。

const DEFAULT_PROJECT := "D:/Game/BIRD/bird"

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var mode := "map"
	var out := "user://shot.png"
	var map_name := "TEST"
	if args.size() >= 1:
		mode = args[0]
	if args.size() >= 2:
		out = args[1]
	if args.size() >= 3:
		map_name = args[2]

	# 固定窗口尺寸，保证每次截图构图一致；SHOT_W/SHOT_H 可覆盖（窄屏回归用）
	var sw := int(OS.get_environment("SHOT_W"))
	var shh := int(OS.get_environment("SHOT_H"))
	DisplayServer.window_set_size(Vector2i(sw if sw > 0 else 1680, shh if shh > 0 else 946))
	await process_frame
	var app_script = load("res://src/app.gd")
	var app = app_script.new()
	root.add_child(app)
	# 真实入口是 editor.tscn（根节点已铺满窗口），手动 new 出来要自己补齐锚点
	app.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var project := OS.get_environment("BIRD_PROJECT")
	if project == "":
		project = DEFAULT_PROJECT
	app.manifest = EditorManifest.load_from(project)
	app._build_theme()
	app._build_editor_ui()
	await process_frame
	await process_frame

	if mode != "empty":
		app._open_map_by_name(map_name)
		await process_frame
		await process_frame

	match mode:
		"asset":
			app._set_mode("asset", "crawler")
		"asset_quick":
			app._set_mode("asset")
		"project":
			# R1 项目页壳（默认落在资产视图）
			app._set_mode("asset")
		"project_content":
			app._set_mode("content")
		"project_manifest":
			app._set_mode("manifest")
		"project_measure":
			# R1 实证：外壳三视图切换 + Esc 回画布 + 状态栏常驻
			app._set_mode("asset")
			await process_frame
			var sh = app.project_shell
			print("MEASURE shell_visible=%s map_visible=%s views=%d size=%s" % [
				str(sh.visible), str(app._map_view.visible), sh.get_child_count(), str(sh.size)])
			for v in ["asset", "content", "manifest"]:
				sh.show_view(v)
				await process_frame
				print("MEASURE view=%s visible_tabs=%s holder_child=%d" % [
					v, str(sh._tabs[v].button_pressed), sh._holder.get_child_count()])
			# Esc → 回画布
			var ev := InputEventKey.new()
			ev.keycode = KEY_ESCAPE
			ev.pressed = true
			Input.parse_input_event(ev)
			for i in 3:
				await process_frame
			print("MEASURE after_esc shell_visible=%s map_visible=%s" % [
				str(app.project_shell.visible), str(app._map_view.visible)])
			app._set_mode("manifest")
		"topbar":
			pass
		"props":
			var first = null
			for e in app.canvas.entities.get_children():
				if e.has_meta("scene"):
					first = e
					break
			if first != null:
				app.canvas.selected_entity = first
				app.canvas.selected_multi = [first]
				app._on_entity_selected(first)
		"size":
			app._open_size_dialog()
		"align":
			app.canvas.selected_multi = [1, 2]
			app._open_align_menu()
		"collide":
			app._open_collision_gen()
		"export":
			app._open_export_dialog()
		"play":
			app.play_cfg = {"abilities": ["dash"], "hp": 3}
			app._open_play_cfg()
		"levels":
			app._set_mode("manifest")
		"world":
			app._set_mode("manifest")
		"validate":
			app._run_validate(true)
			app.side_panel.select_tab(2)
		"entities":
			app.side_panel.select_tab(1)
		"ent_hover":
			# 实体清单悬停 → 画布上被悬停的实体应出现青色高亮框
			app.side_panel.select_tab(1)
			await process_frame
			var lst = app.side_panel.ent_list
			if lst.item_count > 0:
				app.side_panel.entity_hover_requested.emit(str(lst.get_item_metadata(0)))
		"layers":
			# 可见/锁定按钮的两种状态各拍一张对照（未启用 vs 已启用）
			app.canvas.set_layer_locked(app.canvas.active_layer, true)
			app._sync_layer_buttons()
		"multi":
			# 框选多个实体：应画出外接框 + 「拖动可整体移动」提示
			var pick := []
			for e in app.canvas.entities.get_children():
				if e.has_meta("scene"):
					pick.append(e)
			if pick.size() > 1:
				app._apply_state("select", app.canvas._ent_layer_index())
				# 取靠近地图中心的一簇，保证外接框和文字都在可视区内
				var meta: Dictionary = app.canvas.map_data.get("meta", {})
				var mid := Vector2(float(meta.get("w", 40)) * 8.0, float(meta.get("h", 22)) * 8.0)
				pick.sort_custom(func(a, b):
					return a.position.distance_to(mid) < b.position.distance_to(mid))
				app.canvas.selected_multi = pick.slice(0, 3)
				app.canvas.selected_entity = null
				# 把镜头挪到这一簇上，否则框可能落在可视区外拍不到
				app.canvas.cam_pos = app.canvas._multi_bounds(app.canvas._valid_multi()).get_center()
				app.canvas.zoom = 3.0
				app.canvas._update_cam()
				app.canvas.queue_redraw()
		"coll_layer":
			# 切到碰撞层：碰撞可视化应作为普通图层显示
			var ci := -1
			var L: Array = app.manifest.get("layers", [])
			for k in L.size():
				if str(L[k].get("type", "tiles")) == "grid":
					ci = k
			app._on_layer(ci)
		"picker":
			# 跨图选点：完整地图 + 缩放 + 当前目标居中
			var first_exit = null
			for e in app.canvas.entities.get_children():
				if str(e.get_meta("scene", "")) == "exit":
					first_exit = e
					break
			if first_exit != null:
				var pr: Dictionary = first_exit.get_meta("props", {})
				app.canvas.selected_entity = first_exit
				app.selected_spr = first_exit
				app._open_map_point_picker("level1", "target_map", "target_point", pr)
		"ents_page":
			app._set_palette_page("entities")
		"props_multi":
			var pick2 := []
			for e in app.canvas.entities.get_children():
				if e.has_meta("scene"):
					pick2.append(e)
			if pick2.size() > 1:
				app._apply_state("select", app.canvas._ent_layer_index())
				app.canvas.selected_multi = pick2.slice(0, 2)
				app.canvas.selected_entity = pick2[0]
				app._on_entity_selected(pick2[0])
		"dock":
			app._set_content_dock(true)
		"dock_wide":
			# R4 抽屉「放大」态：写作时展开占半屏
			app._set_content_dock(true)
			await process_frame
			app.content_dock.toggle_wide()
			print("MEASURE dock_width=%d wide=%s" % [int(app.content_dock.custom_minimum_size.x), str(app.content_dock._wide)])
			for i in 4:
				await process_frame
			var mp = app.content_dock.get_parent()
			print("MEASURE main size=%s pos=%s" % [str(mp.size), str(mp.global_position)])
			for ch in mp.get_children():
				print("MEASURE child %s x=%d w=%d min=%d vis=%s" % [ch.get_class(), int(ch.global_position.x), int(ch.size.x), int(ch.get_combined_minimum_size().x), str(ch.visible)])
			print("MEASURE side x=%d w=%d win=%d" % [int(app.side_panel.global_position.x), int(app.side_panel.size.x), int(app.size.x)])
		"help":
			# R4 快捷键速查（? 键）
			app._open_shortcut_help()
		"multi_dim":
			# P1 多选置灰：字段区应整体压暗并出现提示行
			var pickx := []
			for e in app.canvas.entities.get_children():
				if e.has_meta("scene"):
					pickx.append(e)
			if pickx.size() > 1:
				app._apply_state("select", app.canvas._ent_layer_index())
				app.canvas.selected_multi = pickx.slice(0, 3)
				app.canvas.selected_entity = pickx[0]
				app._on_entity_selected(pickx[0])
		"dock_commit":
			# P0-2 实证：校验徽章只追加不清旧——连调 _validate 三次数行数
			app._set_content_dock(true)
			await process_frame
			var dk = app.content_dock
			dk._data = {"id": "probe"}
			var b0: int = dk.body.get_child_count()
			dk._validate()
			dk._validate()
			dk._validate()
			var b1: int = dk.body.get_child_count()
			print("MEASURE dock_badges before=%d after=%d growth=%d" % [b0, b1, b1 - b0])
		"bgdlg":
			app._open_bg_dialog()
		"manifest":
			app._set_mode("manifest")
		"manifest_over":
			app._set_mode("manifest")
			var mp = app.manifest_panel
			for i in 40:
				mp._add_item()
			await process_frame
			print("MEASURE manifest_min_h=%d win_h=%d" % [int(mp.get_combined_minimum_size().y), int(root.size.y)])
		"content":
			app._set_mode("content")
		"content_event":
			app._set_mode("content")
			await process_frame
			app.content_panel.show_kind("events")
		"content_shop":
			app._set_mode("content")
			await process_frame
			app.content_panel.show_kind("shops")
		"content_def":
			app._set_mode("content")
			await process_frame
			app.content_panel.show_kind("defs")
		"rename_size":
			# P0-4 实证：先开尺寸弹窗（走两段式定尺寸），关掉，再开改名弹窗量尺寸
			app._open_size_dialog()
			for i in 6:
				await process_frame
			var spop: PopupPanel = null
			for c in app.get_children():
				if c is PopupPanel:
					spop = c
			if spop != null:
				print("MEASURE size_popup=%dx%d" % [int(spop.size.x), int(spop.size.y)])
				spop.hide()
			for i in 4:
				await process_frame
			app.side_panel._ask_rename("probe_map")
			for i in 6:
				await process_frame
			var rpop: PopupPanel = null
			for c in app.side_panel.get_children():
				if c is PopupPanel:
					rpop = c
			if rpop != null:
				print("MEASURE rename_popup=%dx%d content_min=%s" % [int(rpop.size.x), int(rpop.size.y), str(rpop.get_contents_minimum_size().ceil())])
		"tab_nav":
			# P0-5 实证：焦点在按钮上时注入 Tab，看快捷键通道是否吞掉导航
			if app._cut_btn != null and not app._cut_btn.disabled:
				app._cut_btn.grab_focus()
				await process_frame
				print("MEASURE focus_before=%s ents=%d" % [str(app._cut_btn.has_focus()), app.canvas.entities.get_child_count()])
				var ev := InputEventKey.new()
				ev.physical_keycode = KEY_TAB
				ev.keycode = KEY_TAB
				ev.pressed = true
				Input.parse_input_event(ev)
				for i in 4:
					await process_frame
				print("MEASURE sel_after=%s focus_moved=%s" % [
					str(app.canvas.selected_entity != null), str(not app._cut_btn.has_focus())])
		"measure":
			# P0-1 实证：_bg_btn 从未加入布局 → 无父节点
			print("MEASURE bg_btn_parent_null=%s" % str(app._layout_ctrl._bg_btn == null or app._layout_ctrl._bg_btn.get_parent() == null))
		_:
			pass

	# 等几帧让布局与绘制稳定
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png(out)
	print("SHOT_SAVED ", out, " mode=", mode)
	quit(0)
