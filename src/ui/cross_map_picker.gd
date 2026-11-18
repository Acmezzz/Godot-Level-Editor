extends RefCounted
## 跨图落点/出口配对选点器：MapThumb 全图视图 + CrossMap 纯逻辑规划 + MapStore 落盘。
const Store := preload("res://src/map_store.gd")
const CrossMap := preload("res://src/cross_map.gd")
const ManifestScript := preload("res://src/manifest.gd")
const MapThumbScript := preload("res://src/ui/map_thumb.gd")
const UiKitScript := preload("res://src/ui/ui_kit.gd")
const UiThemeScript := preload("res://src/ui/ui_theme.gd")

var app   # 宿主引用

func _init(host) -> void:
	app = host

## 跨图选点器（审查 8.2 块 8：从 app.gd 拆出）——完整地图视图 + 缩放平移选点/配对
# 数据读写走 MapStore，配对规划走 CrossMap（都是纯逻辑，可 headless 测试）。
func clear_exit_pair(map_name: String, exit_id: String, peer_map: String, peer_id: String) -> void:
	if map_name == "" or exit_id == "":
		return
	var data := Store.read(app.manifest, map_name)
	if data.is_empty():
		return
	if Store.clear_exit_pair(data, exit_id, peer_map, peer_id, app.manifest):
		if not Store.write(app.manifest, map_name, data):
			app._set_status(" 无法写回 %s（解绑未生效）" % map_name)

func _stage_pair_clear(updates: Dictionary, map_name: String, exit_id: String,
		peer_map: String, peer_id: String) -> bool:
	if map_name == "" or exit_id == "":
		return true
	var data: Dictionary
	if updates.has(map_name):
		data = updates[map_name]
	else:
		var result := Store.read_path(Store.path_for(app.manifest, map_name), app.manifest)
		if not result.get("ok", false):
			return false
		data = result.data
	if Store.clear_exit_pair(data, exit_id, peer_map, peer_id, app.manifest):
		updates[map_name] = data
	return true
func open_map_point_picker(tmap: String, map_fid: String, point_fid: String, props: Dictionary) -> void:
	if tmap == str(app.canvas.cur_map_name):
		app._set_status(" 目标地图不能是当前地图（图内传送请用传送门）")
		return
	var data := Store.read(app.manifest, tmap)
	if data.is_empty():
		app._set_status(" 找不到或无法读取目标地图: " + tmap)
		return
	var own_map := str(app.canvas.cur_map_name)
	var own_id := str(app.selected_spr.get_meta("ent_id", "")) if app.selected_spr else ""
	var pop := PopupPanel.new()
	var vb := UiKitScript.vbox(10)
	pop.add_child(vb)
	# 标题行：地图名 + 当前目标（一眼看到现在连的是哪）
	var head := UiKitScript.hbox(8)
	head.add_child(UiKitScript.text_label("在 %s 上选择目标" % tmap,
		UiThemeScript.TEXT, UiThemeScript.FS_MD))
	head.add_child(UiKitScript.spacer())
	var cur_target := str(props.get(point_fid, "")) if point_fid != "" else ""
	var target_badge := UiKitScript.badge(
		("当前：" + cur_target) if cur_target != "" else "当前：未设置",
		UiThemeScript.ACCENT if cur_target != "" else UiThemeScript.TEXT_MUTE)
	head.add_child(target_badge)
	vb.add_child(head)
	vb.add_child(UiKitScript.hint_label(
		"滚轮缩放 · 中键/右键拖拽平移；点绿色落点复用，点出口配对，空白处新建落点。配对会写盘对端图（不走撤销），点选后会先确认", app.POPUP_BODY_W))
	# 完整地图视图（不再是固定缩略图），自带缩放与平移
	var viewport_size: Vector2 = app.get_viewport_rect().size
	var view_h := minf(viewport_size.y * 0.72, 760.0)
	var view_w := maxf(minf(viewport_size.x * 0.9, 1200.0), 560.0)
	var thumb := MapThumbScript.new()
	thumb.data = data
	thumb.custom_minimum_size = Vector2(view_w, view_h)
	thumb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	thumb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(thumb)
	# 底部状态行：悬停坐标/实体 + 操作按钮
	var foot := UiKitScript.hbox(8)
	var hover_lbl := UiKitScript.text_label("", UiThemeScript.TEXT_MUTE, UiThemeScript.FS_META)
	hover_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hover_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hover_lbl.clip_text = true
	foot.add_child(hover_lbl)
	# 「适应窗口」把视图拉回整图——缩放乱了随时能回来
	var fit_btn := UiKitScript.button("适应窗口", func(): thumb.fit_view(), "ghost")
	foot.add_child(fit_btn)
	# 有当前目标时给一个「跳到目标」
	if cur_target != "":
		foot.add_child(UiKitScript.button("跳到当前目标", func():
			for e in data.get("entities", []):
				if str(e.get("id", "")) == cur_target:
					thumb.zoom = clampf(thumb.zoom, 12.0, 32.0)
					thumb.focus_cell(Vector2i(int(e.get("x", 0)), int(e.get("y", 0))))
					return, "ghost"))
	var cancel_btn := UiKitScript.button("取消", func(): pop.hide(), "ghost")
	foot.add_child(cancel_btn)
	vb.add_child(foot)
	thumb.hover_info.connect(func(t: String): hover_lbl.text = t)
	thumb.on_pick = func(cell: Vector2i, picked_id: String, picked_scene: String):
		var current_scene := str(app.selected_spr.get_meta("scene", "")) if app.selected_spr else ""
		var plan := CrossMap.plan_pick(app.manifest, tmap, own_map, own_id, current_scene, picked_id, picked_scene, cell)
		if not plan.get("ok", false):
			app._set_status(" " + str(plan.get("error", "无法建立连接")))
			return
		# P0-5：这一步会即时写盘对端地图且不走撤销——先明确确认，不能一点就落盘
		var acted := str(plan.get("acted", ""))
		var chosen_id := str(plan.get("id", ""))
		var what := ""
		if acted == "new":
			what = "在 %s (%d,%d) 新建共用落点 %s" % [tmap, cell.x, cell.y, chosen_id]
		elif ManifestScript.has_role(app.manifest, picked_scene, "exit"):
			what = "与 %s 的出口 %s 建立双向连接" % [tmap, chosen_id]
		else:
			what = "复用 %s 的传送落点 %s" % [tmap, chosen_id]
		var unbind_n: int = (plan.get("unbind", []) as Array).size()
		var extra := "" if unbind_n == 0 else "\n同时会解除 %d 处旧配对。" % unbind_n
		var cd := ConfirmationDialog.new()
		cd.title = "确认跨图配对"
		cd.dialog_text = "%s。\n\n这会立即写入目标地图文件（不走撤销），当前地图仍需手动保存。%s" % [what, extra]
		cd.ok_button_text = "写入目标图"
		cd.cancel_button_text = "取消"
		app.add_child(cd)
		cd.confirmed.connect(func():
			cd.queue_free()
			_apply_plan(plan, tmap, own_map, own_id, current_scene, map_fid, point_fid, props, cell)
			pop.hide())
		cd.canceled.connect(func(): cd.queue_free())
		cd.popup_centered()
	app._open_popup(pop, Vector2i(int(view_w) + 48, int(view_h) + 150))
	# 弹窗刚开时 view 控件还没排版，size 是 0——此时算缩放/居中都会错。
	# 延到下一帧布局完成后，再适应窗口并把当前目标挪到视野中心。
	var focus_target := cur_target
	thumb.call_deferred("deferred_open", focus_target, data)

## 执行跨图配对提交（确认之后）：多图事务写盘 → 同步当前图内存 → 状态提示
func _apply_plan(plan: Dictionary, tmap: String, own_map: String, own_id: String,
		current_scene: String, map_fid: String, point_fid: String, props: Dictionary,
		cell: Vector2i) -> void:
	var chosen_id := str(plan.get("id", ""))
	var acted := str(plan.get("acted", ""))
	# 将目标图和所有被解绑的远端图合并，作为一次可回滚事务提交。
	var updates := {}
	for un in plan.get("unbind", []):
		if not _stage_pair_clear(updates, str(un[0]), str(un[1]), str(un[2]), str(un[3])):
			app._set_status(" 无法准备解绑地图: " + str(un[0]))
			return
	var old_map := str(props.get(map_fid, ""))
	var old_id := str(props.get(point_fid, "")) if point_fid != "" else ""
	if ManifestScript.has_role(app.manifest, current_scene, "exit") and old_id != "" and old_map != "" and old_map != own_map and old_map != tmap:
		if not _stage_pair_clear(updates, old_map, old_id, own_map, own_id):
			app._set_status(" 无法准备解绑地图: " + old_map)
			return
	var target_data: Dictionary = plan.get("data", {})
	if updates.has(tmap):
		target_data = updates[tmap]
	# 同一目标图内改连另一个出口时，先在目标快照里清除当前出口的旧对端。
	if ManifestScript.has_role(app.manifest, current_scene, "exit") and old_map == tmap and old_id != "" and old_id != chosen_id:
		Store.clear_exit_pair(target_data, old_id, own_map, own_id)
	updates[tmap] = target_data
	var write_result := Store.write_transaction(app.manifest, updates)
	if not write_result.get("ok", false):
		var detail := str(write_result.get("error", "写入失败"))
		if not write_result.get("rollback_ok", false):
			detail += "；回滚未能完整恢复，请检查地图文件"
		app._set_status(" 跨图提交失败: %s（%s）" % [str(write_result.get("failed_map", tmap)), detail])
		return
	# 文件事务成功后再改当前图内存，当前图仍由用户显式保存。
	for uid in plan.get("unbind_local", []):
		var lspr: Sprite2D = app._ent_by_id(str(uid))
		if lspr != null and is_instance_valid(lspr) and ManifestScript.has_role(app.manifest, str(lspr.get_meta("scene", "")), "exit"):
			var lp: Dictionary = lspr.get_meta("props", {})
			lp.erase("target_map")
			lp.erase("target_point")
			lspr.set_meta("props", lp)
			app.canvas._mark()
	if ManifestScript.has_role(app.manifest, current_scene, "exit") and old_id != "" and old_map != "" and old_map != own_map:
		props.erase("target_map")
		props.erase("target_point")
	props[map_fid] = tmap
	if point_fid != "":
		props[point_fid] = chosen_id
	if app.selected_spr and is_instance_valid(app.selected_spr):
		app.selected_spr.set_meta("props", props)
		app.canvas._mark()
	if acted == "new":
		app._set_status("已在 %s (%d,%d) 新建共用落点 %s（保存当前地图后生效）" % [tmap, cell.x, cell.y, chosen_id])
	elif ManifestScript.has_role(app.manifest, str(app.selected_spr.get_meta("scene", "")) if app.selected_spr else "", "exit"):
		app._set_status("已与 %s 建立双向连接（保存当前地图后生效）" % tmap)
	else:
		app._set_status("已复用 %s 的传送落点 %s（保存当前地图后生效）" % [tmap, chosen_id])
	app._rebuild_props_panel()
