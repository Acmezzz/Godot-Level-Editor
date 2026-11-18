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
		"asset_dist":
			# 批次 D-2：实例分布行 = id + 各数值就地可改 + 定位
			app._set_mode("asset", "crawler")
			await process_frame
			await process_frame
			print("MEASURE dist_rows=%d" % (app.asset_panel._dist_rows.get_child_count() if app.asset_panel._dist_rows != null else -1))
		"map_menu":
			# 地图设置菜单：应看到新建/打开/保存/重命名/导出/尺寸/校验（无清单入口）
			var pm: PopupMenu = null
			for c in app.find_children("*", "PopupMenu", true, false):
				if c.item_count >= 6 and c.get_item_id(0) == 1:
					pm = c
					break
			if pm != null:
				var labels := []
				for i in pm.item_count:
					labels.append(pm.get_item_text(i))
				print("MEASURE map_menu=", labels)
		"asset_quick":
			app._set_mode("asset")
		"project":
			# R1 项目页壳（默认落在资产视图）
			app._set_mode("asset")
		"project_content":
			app._set_mode("content")
		"project_measure":
			# R1 实证：外壳三视图切换 + Esc 回画布 + 状态栏常驻
			app._set_mode("asset")
			await process_frame
			var sh = app.project_shell
			print("MEASURE shell_visible=%s map_visible=%s views=%d size=%s" % [
				str(sh.visible), str(app._map_view.visible), sh.get_child_count(), str(sh.size)])
			for v in ["asset", "content"]:
				sh.show_view(v)
				await process_frame
				print("MEASURE view=%s mode_btn=%s holder_child=%d" % [
					v, str(sh._nav_bar._mode_btns[v].button_pressed), sh._holder.get_child_count()])
			# Esc → 回画布
			var ev := InputEventKey.new()
			ev.keycode = KEY_ESCAPE
			ev.pressed = true
			Input.parse_input_event(ev)
			for i in 3:
				await process_frame
			print("MEASURE after_esc shell_visible=%s map_visible=%s" % [
				str(app.project_shell.visible), str(app._map_view.visible)])
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
		"collide":
			app._open_collision_gen()
		"export":
			app._open_export_dialog()
		"play":
			app.play_cfg = {"abilities": ["dash"], "hp": 3}
			app._open_play_cfg()
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
			# 切到碰撞层：碰撞可视化应作为普通图层显示，左栏不再有瓦片资产
			var ci := -1
			var L: Array = app.manifest.get("layers", [])
			for k in L.size():
				if str(L[k].get("type", "tiles")) == "grid":
					ci = k
			app._on_layer(ci)
			await process_frame
			await process_frame
			print("MEASURE coll_visible=%s tile_list=%s ents=%s" % [
				str(app.canvas.is_layer_visible(ci)),
				str(app.tile_list.visible), str(app.ent_list.visible)])
		"decor_layer":
			# 装饰层没有独立资产清单：左栏应为空状态，不显示地形瓦片
			app._on_layer(1)
			await process_frame
			await process_frame
			var tl: ItemList = app.tile_list
			print("MEASURE decor_items=%d" % tl.item_count)
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
			# v2：切到实体层 = 唯一的「换到实体资产」入口（页签按钮已删）
			app._on_layer(app.canvas._ent_layer_index())
		"layer_menu":
			# v2 §2.2：层下拉展开，应看到每一层一行 + 👁/🔒
			app._layout_ctrl._toggle_layer_menu()
			await process_frame
			await process_frame
			print("MEASURE layer_menu_rows=%d visible=%s" % [
				app._layout_ctrl._layer_menu_body.get_child_count(),
				str(app._layout_ctrl._layer_menu.visible)])
		"props_multi":
			var pick2 := []
			for e in app.canvas.entities.get_children():
				if e.has_meta("scene"):
					pick2.append(e)
			if pick2.size() > 1:
				app._apply_state("", app.canvas._ent_layer_index())
				app.canvas.selected_multi = pick2.slice(0, 2)
				app.canvas.selected_entity = pick2[0]
				app._on_entity_selected(pick2[0])
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
	# 等几帧让布局与绘制稳定
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png(out)
	print("SHOT_SAVED ", out, " mode=", mode)
	quit(0)
