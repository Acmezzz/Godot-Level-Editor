extends RefCounted
## MapDialogs：地图尺寸 / 导出弹窗（从 map_file.gd 拆出，宿主 = app）。
## 弹窗体零交叉依赖：只读清单常量 + 经 app 访问画布/状态栏/确认框。

const MapExport := preload("res://src/map/map_export.gd")
const UiKitScript := preload("res://src/ui/ui_kit.gd")
const K := preload("res://src/core/constants.gd")
const MapStore := preload("res://src/map/map_store.gd")

var app   # app 宿主

func _init(a) -> void:
	app = a

# —— 地图尺寸编辑：扩展或裁剪 meta.w/h（裁剪不删数据，只改边界） ——
func open_size_dialog() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var meta: Dictionary = app.canvas.map_data.get("meta", {})
	var shell: Dictionary = app._popup_body("地图尺寸", "以格为单位。裁剪只改边界，不删除已画内容。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var row := UiKitScript.hbox(12)
	body.add_child(row)
	var w_edit := SpinBox.new()
	w_edit.min_value = 8
	w_edit.max_value = 4000
	w_edit.step = 1
	w_edit.value = int(meta.get("w", K.DEFAULT_MAP_W))
	row.add_child(UiKitScript.field_row("宽", w_edit))
	var h_edit := SpinBox.new()
	h_edit.min_value = 8
	h_edit.max_value = 4000
	h_edit.step = 1
	h_edit.value = int(meta.get("h", K.DEFAULT_MAP_H))
	row.add_child(UiKitScript.field_row("高", h_edit))
	var btn_row := UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	# apply 回调改走方法：lambda 里不能 await，而 load_data 是协程——
	# 不 await 就 _mark()，置脏会被 load_data 收尾覆盖（撤销恢复路径的脏标记）
	btn_row.add_child(UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	btn_row.add_child(UiKitScript.button("应用", func(): apply_map_size(int(w_edit.value), int(h_edit.value), pop), "primary"))
	body.add_child(btn_row)
	app._open_popup(pop)

func apply_map_size(nw: int, nh: int, pop: PopupPanel) -> void:
	var d: Dictionary = app.canvas.extract()
	if d.is_empty():   # 重建窗口哨兵：空快照过 load_data = 清空整图
		app._set_status(" 地图重建中，请稍后再试")
		return
	d["meta"]["w"] = nw
	d["meta"]["h"] = nh
	await app.canvas.load_data(d, app.cur_map_name, true)
	app.canvas.undo_stack.clear()
	app.canvas.redo_stack.clear()
	app.canvas._mark()
	pop.hide()
	app._set_status("尺寸已改为 %d×%d（记得保存）" % [nw, nh])


# —— 导出：预览图 PNG + 统计文本 ——
func open_export_dialog() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var shell: Dictionary = app._popup_body("导出地图", "写到游戏项目的 editor/exports 目录。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var px := SpinBox.new()
	px.min_value = 1
	px.max_value = 16
	px.step = 1
	px.value = 4
	px.suffix = " px/格"
	body.add_child(UiKitScript.field_row("预览精度", px, UiKitScript.LABEL_W_LONG))
	var row := UiKitScript.hbox(8)
	body.add_child(row)
	var png_cb := func():
		var data: Dictionary = app.canvas.extract()
		if data.is_empty():   # 重建窗口哨兵：空图导出的是白板 PNG
			app._set_status(" 地图重建中，请稍后再试")
			return
		var img := MapExport.render_preview(data, int(px.value), app.manifest, int(app.manifest.get("tileSize", 16)))   # 多图集+tileSize
		var dir := str(app.manifest.get("_dir", "")).path_join("editor/exports")
		DirAccess.make_dir_recursive_absolute(dir)
		var path := dir.path_join(app.cur_map_name + ".png")
		var err := img.save_png(path)
		app._set_status(("已导出 " + path) if err == OK else ("导出失败（%d）: %s" % [err, path]))
		pop.hide()
	row.add_child(UiKitScript.button("导出预览 PNG", png_cb, "primary"))
	var txt_cb := func():
		var data: Dictionary = app.canvas.extract()
		if data.is_empty():   # 重建窗口哨兵：空图统计无意义
			app._set_status(" 地图瓦片重建中，请稍后再试")
			return
		var txt := MapExport.stats_text(app.cur_map_name, data)
		var dir2 := str(app.manifest.get("_dir", "")).path_join("editor/exports")
		DirAccess.make_dir_recursive_absolute(dir2)
		var path2 := dir2.path_join(app.cur_map_name + ".txt")
		# 导出写盘同样走原子写
		if app.MapStore.write_text(path2, txt):
			app._set_status("已导出 " + path2)
		else:
			app._set_status("导出失败: " + path2)
		pop.hide()
	row.add_child(UiKitScript.button("导出统计文本", txt_cb, "ghost"))
	body.add_child(UiKitScript.divider())
	# 批量导出：全部地图一次出齐（预览图 + 统计）；精度上限 4px/格，防止大图导出超大 PNG
	var batch_cb := func():
		var names: Array = app.MapStore.list_maps(app.manifest)
		var bad: Array = []
		var all = app.MapStore.read_all(app.manifest, bad)
		var dir := str(app.manifest.get("_dir", "")).path_join("editor/exports")
		DirAccess.make_dir_recursive_absolute(dir)
		var bpx := mini(int(px.value), 4)
		var ok_n := 0
		var fail: Array = []
		for i in names.size():
			var nm := str(names[i])
			app._set_status("导出 %d/%d：%s…" % [i + 1, names.size(), nm])
			await app.get_tree().process_frame   # E2：每图一帧，UI 不冻结
			var d: Dictionary = all.get(nm, {})
			if d.is_empty():
				fail.append(nm)
				continue
			var img := MapExport.render_preview(d, bpx, app.manifest, int(app.manifest.get("tileSize", 16)))
			var err := img.save_png(dir.path_join(nm + ".png"))
			if err == OK:
				ok_n += 1
			else:
				fail.append(nm)
			var txt := MapExport.stats_text(nm, d)
			app.MapStore.write_text(dir.path_join(nm + ".txt"), txt)
		var msg := "批量导出完成：%d 张成功" % ok_n
		if not fail.is_empty():
			msg += "；失败：" + ", ".join(fail)
		app._set_status(msg)
		pop.hide()
	body.add_child(UiKitScript.button("导出全部地图（预览图 + 统计）", batch_cb, "ghost"))
	var close_row := UiKitScript.hbox(6)
	close_row.add_child(UiKitScript.spacer())
	close_row.add_child(UiKitScript.button("关闭", func(): pop.hide(), "ghost"))
	body.add_child(close_row)
	app._open_popup(pop)
