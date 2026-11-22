extends RefCounted
## MapDialogs：地图尺寸 / 导出弹窗（从 map_file.gd 拆出，宿主 = app）。
## 弹窗体零交叉依赖：只读清单常量 + 经 app 访问画布/状态栏/确认框。

const MapExport := preload("res://src/map/map_export.gd")
const UiKitScript := preload("res://src/ui/ui_kit.gd")
const K := preload("res://src/core/constants.gd")
const MapStore := preload("res://src/map/map_store.gd")
const MapResize := preload("res://src/ui/map_resize.gd")

var app   # app 宿主

func _init(a) -> void:
	app = a

# —— 地图尺寸编辑：扩展或裁剪 meta.w/h（缩小裁掉边界外数据，可撤销） ——
func open_size_dialog() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var meta: Dictionary = app.canvas.map_data.get("meta", {})
	var base: Dictionary = app.canvas.extract()
	if base.is_empty():   # 重建窗口哨兵：此刻读不到可裁剪的数据，别让预览数字是假的
		app._set_status(" 地图重建中，请稍后再试")
		return
	var shell: Dictionary = app._popup_body("地图尺寸",
		"以格为单位。缩小会裁掉边界外的瓦片 / 碰撞 / 摆放物，确认框里先列数量；应用是一次可撤销操作。")
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
	# E3：裁剪前先列数量（当前总量 + 目标尺寸会裁掉多少），别让人盲着按应用
	var counts_lbl := UiKitScript.hint_label("", 460)
	body.add_child(counts_lbl)
	var refresh_counts := func():
		var cur := _counts(base)
		var crop := _crop_counts(base, int(w_edit.value), int(h_edit.value))
		var cut: int = int(crop.tiles) + int(crop.collision) + int(crop.objects)
		var head := "当前 %d×%d：瓦片 %d · 碰撞 %d · 摆放物 %d" % [
			int(meta.get("w", K.DEFAULT_MAP_W)), int(meta.get("h", K.DEFAULT_MAP_H)),
			int(cur.tiles), int(cur.collision), int(cur.objects)]
		if cut > 0:
			counts_lbl.text = head + "\n缩到 %d×%d 将裁掉：瓦片 %d · 碰撞 %d · 摆放物 %d（可撤销）" % [
				int(w_edit.value), int(h_edit.value), int(crop.tiles), int(crop.collision), int(crop.objects)]
		else:
			counts_lbl.text = head + "\n目标尺寸不会裁掉数据"
	w_edit.value_changed.connect(func(_v: float): refresh_counts.call())
	h_edit.value_changed.connect(func(_v: float): refresh_counts.call())
	refresh_counts.call()
	# 逐图投影（B1）：空图才允许在普通设置里改；带内容的地图必须先做显式转换
	# （转换另作操作：先展示目标并保存副本），否则已摆内容的空间口径会被静默改写。
	var proj_sel := OptionButton.new()
	var proj_keys: Array = ["orthogonal", "isometric", "hexagonal"]
	var proj_labels: Array = ["正交", "等距", "六边形"]
	var cur_proj: String = app.canvas.grid.projection
	for i in proj_keys.size():
		proj_sel.add_item(str(proj_labels[i]))
		proj_sel.set_item_metadata(i, str(proj_keys[i]))
		if str(proj_keys[i]) == cur_proj:
			proj_sel.select(i)
	var has_content: bool = app.canvas.has_content()
	proj_sel.disabled = has_content
	if has_content:
		proj_sel.tooltip_text = "地图已有内容：投影切换需要显式转换（先保存副本），普通设置不允许直接改"
	body.add_child(UiKitScript.field_row("格投影", proj_sel, UiKitScript.LABEL_W_LONG))
	if has_content:
		body.add_child(UiKitScript.hint_label(
			"已有内容的投影已冻结。要换投影请复制这张图，在副本上转换并核对游戏加载器。", 460))
	var btn_row := UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	# apply 回调改走方法：lambda 里不能 await，而 load_data 是协程——
	# 不 await 就 _mark()，置脏会被 load_data 收尾覆盖（撤销恢复路径的脏标记）
	btn_row.add_child(UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	btn_row.add_child(UiKitScript.button("应用", func(): apply_map_size(int(w_edit.value), int(h_edit.value), pop,
		str(proj_sel.get_item_metadata(proj_sel.selected))), "primary"))
	body.add_child(btn_row)
	app._open_popup(pop)

## 现有条目计数 / 裁剪范围 / 就地裁剪：纯逻辑在 map_resize.gd（同一判据，可单测）。
func _counts(d: Dictionary) -> Dictionary:
	return MapResize.counts(d)

func _crop_counts(d: Dictionary, nw: int, nh: int) -> Dictionary:
	return MapResize.crop_counts(d, nw, nh)

func _outside(x: int, y: int, nw: int, nh: int) -> bool:
	return MapResize.outside(x, y, nw, nh)

func _outside_float(x: float, y: float, nw: int, nh: int) -> bool:
	return MapResize.outside_float(x, y, nw, nh)

func _crop_data(d: Dictionary, nw: int, nh: int) -> void:
	MapResize.crop_data(d, nw, nh)

func apply_map_size(nw: int, nh: int, pop: PopupPanel, proj := "") -> void:
	var d: Dictionary = app.canvas.extract()
	if d.is_empty():   # 重建窗口哨兵：空快照过 load_data = 清空整图
		app._set_status(" 地图重建中，请稍后再试")
		return
	# 缩小先确认裁剪范围（E3：裁掉多少瓦片/碰撞/摆放物，应用前可见）
	var crop := _crop_counts(d, nw, nh)
	var cut: int = int(crop.tiles) + int(crop.collision) + int(crop.objects)
	if cut > 0:
		var msg := "缩到 %d×%d 会裁掉边界外的数据：\n瓦片 %d · 碰撞 %d · 摆放物 %d\n\n应用后可用 Ctrl+Z 撤销（连同原尺寸恢复）。" % [
			nw, nh, int(crop.tiles), int(crop.collision), int(crop.objects)]
		if not await app._confirm_action("裁剪地图边界", msg, "裁剪"):
			pop.hide()
			app._set_status("已取消调整尺寸")
			return
	# 一笔可撤销快照（D17）：先在改尺寸前入栈，撤销即恢复原尺寸与边缘数据
	app.canvas.push_undo()
	_crop_data(d, nw, nh)
	d["meta"]["w"] = nw
	d["meta"]["h"] = nh
	# 逐图投影（B1）：空图可直接选；带内容的地图投影已冻结（弹窗里也禁用），
	# 这里再加一道守卫——数据路径不允许绕过内容检查。
	# 显式写入（含 orthogonal）：删键会让解析回落到项目缺省投影，
	# 项目里有 isometric/hexagonal 资产时「正交」就丢了（V4 P1）。
	if proj != "" and not app.canvas.has_content():
		d["meta"]["gridProjection"] = proj
	await app.canvas.load_data(d, app.cur_map_name, true)
	app.canvas._mark()
	pop.hide()
	if cut > 0:
		app._set_status("尺寸已改为 %d×%d，裁掉瓦片 %d / 碰撞 %d / 摆放物 %d（Ctrl+Z 可撤销）" % [
			nw, nh, int(crop.tiles), int(crop.collision), int(crop.objects)])
	else:
		app._set_status("尺寸已改为 %d×%d（记得保存）" % [nw, nh])


# —— 导出：预览图 PNG + 统计文本 ——
## A5：单图 / 批量导出。两者都先过 v7 校验（坏图不产出一半的文件），
## 生成图像前按 output_geometry 算像素总数，超 16_777_216 时提示可用缩放倍率。
func open_export_dialog() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var shell: Dictionary = app._popup_body("导出地图",
		"写到游戏项目的 editor/exports 目录。超预算会先提示可用的缩放倍率。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var px := SpinBox.new()
	px.min_value = 1
	px.max_value = MapExport.MAX_PX_PER_TILE
	px.step = 1
	px.value = 4
	px.suffix = " px/格"
	body.add_child(UiKitScript.field_row("预览精度", px, UiKitScript.LABEL_W_LONG))
	var geo_lbl := UiKitScript.hint_label("", 460)
	body.add_child(geo_lbl)
	var refresh := func():
		var data: Dictionary = app.canvas.extract()
		if data.is_empty():
			geo_lbl.text = "地图重建中，请稍后再试"
			return
		var b: Dictionary = MapExport.budget(data, app.manifest, int(px.value))
		var sz: Vector2i = b.size
		if bool(b.get("ok", false)):
			geo_lbl.text = "输出 %d×%d 像素（%d px/格）" % [sz.x, sz.y, int(px.value)]
		else:
			geo_lbl.text = "⚠ " + str(b.get("error", "超出预算"))
	px.value_changed.connect(func(_v: float): refresh.call())
	refresh.call()
	var row := UiKitScript.hbox(8)
	body.add_child(row)
	var png_cb := func():
		var data: Dictionary = app.canvas.extract()
		if data.is_empty():   # 重建窗口哨兵：空图导出的是白板 PNG
			app._set_status(" 地图重建中，请稍后再试")
			return
		var werr := _write_check(data)
		if werr != "":
			app._set_status("导出取消：" + werr)
			return
		var b: Dictionary = MapExport.budget(data, app.manifest, int(px.value))
		if not bool(b.get("ok", false)):
			app._set_status("导出取消：" + str(b.get("error", "")))
			return
		var img := MapExport.render_preview(data, int(px.value), app.manifest)
		if img.is_empty():
			app._set_status("导出失败：预览图为空（请检查地图尺寸）")
			return
		var dir := _export_dir()
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
		var werr := _write_check(data)
		if werr != "":
			app._set_status("导出取消：" + werr)
			return
		var txt := MapExport.stats_text(app.cur_map_name, data, app.manifest, int(px.value))
		var path2 := _export_dir().path_join(app.cur_map_name + ".txt")
		if MapStore.write_text(path2, txt):
			app._set_status("已导出 " + path2)
		else:
			app._set_status("导出失败: " + path2)
		pop.hide()
	row.add_child(UiKitScript.button("导出统计文本", txt_cb, "ghost"))
	body.add_child(UiKitScript.divider())
	# 批量导出：项目代次 + 输出目录 + 进度；每次让帧后检查取消/窗口有效性。
	var batch_lbl := UiKitScript.hint_label("批量导出逐图报告；取消时已写文件保留。", 460)
	body.add_child(batch_lbl)
	var batch_btn := UiKitScript.button("导出全部地图（预览图 + 统计）", Callable(), "ghost")
	batch_btn.pressed.connect(func(): _run_batch_export(batch_lbl, batch_btn, int(px.value)))
	body.add_child(batch_btn)
	var close_row := UiKitScript.hbox(6)
	close_row.add_child(UiKitScript.spacer())
	close_row.add_child(UiKitScript.button("关闭", func(): pop.hide(), "ghost"))
	body.add_child(close_row)
	app._open_popup(pop)

## 导出目标目录（游戏项目根 / editor/exports）。
func _export_dir() -> String:
	return str(app.manifest.get("_dir", "")).path_join("editor/exports")

## 写盘前校验：序列化结果必须过 v7 校验（坏图不落盘）。
func _write_check(data: Dictionary) -> String:
	var issues: Array = preload("res://src/map/map_data_validation.gd").validate(data, app.manifest)
	for issue in issues:
		if str((issue as Dictionary).get("severity", "")) == "error":
			return "%s: %s" % [str((issue as Dictionary).get("path", "")),
				str((issue as Dictionary).get("message", ""))]
	return ""

## 批量作业互斥：同一时刻只跑一个（弹窗重复打开也只会有一个在写盘）。
var _batch_running := false

## 批量导出（A5）：捕获项目代次与输出目录，每次让帧后检查取消与窗口有效性；
## 只运行一个作业，项目切换自动取消，已写文件保留。逐图报告 PNG 与统计各自结果。
func _run_batch_export(label: Label, btn: Button, px_per_tile: int) -> void:
	if _batch_running:
		app._set_status("批量导出已在进行中")
		return
	_batch_running = true
	var cancel := {"on": false}
	var cancel_cb := func(): cancel.on = true
	# 运行期间按钮改作取消入口：先摘下原回调，结束再原地接回（否则按取消会同时再进一次作业）
	var original: Array = []
	if is_instance_valid(btn):
		for c in btn.pressed.get_connections():
			var ocb = (c as Dictionary).get("callable", null)
			if ocb is Callable and (ocb as Callable).is_valid():
				original.append(ocb)
				btn.pressed.disconnect(ocb)
		btn.text = "取消批量导出"
		btn.pressed.connect(cancel_cb)
	var proj_dir := str(app.manifest.get("_dir", ""))
	# 项目身份以 app.cur_project_dir 为准（清单 _dir 可能被同目录另一项目覆盖）
	var proj_identity := str(app.cur_project_dir)
	var names: Array = MapStore.list_maps(app.manifest)
	var dir := _export_dir()
	DirAccess.make_dir_recursive_absolute(dir)
	var bpx := maxi(1, mini(px_per_tile, 4))
	var ok_n := 0
	var fail: Array = []
	var skipped: Array = []
	var lines: Array[String] = []
	var cancelled := false
	for i in names.size():
		if cancel.on:
			cancelled = true
			break
		# 项目切换（页面已重建）或窗口已释放：立即中止
		if app == null or not is_instance_valid(app) or not is_instance_valid(label):
			cancelled = true
			break
		if str(app.manifest.get("_dir", "")) != proj_dir or str(app.cur_project_dir) != proj_identity:
			cancelled = true
			break
		var nm := str(names[i])
		label.text = "导出 %d/%d：%s…（项目代次 %d）" % [i + 1, names.size(), nm,
			int(MapStore.project_rev)]
		app._set_status(label.text)
		await app.get_tree().process_frame
		# await 之后一切外部状态都可能变：取消、窗口、项目身份逐项复验再落盘
		if cancel.on:
			cancelled = true
			break
		if app == null or not is_instance_valid(app) or not is_instance_valid(label):
			cancelled = true
			break
		if app.manifest != null and (str(app.manifest.get("_dir", "")) != proj_dir \
				or str(app.cur_project_dir) != proj_identity):
			cancelled = true
			break
		var res: Dictionary = MapStore.read_path(MapStore.path_for(app.manifest, nm), app.manifest)
		if not bool(res.get("ok", false)):
			fail.append(nm + "（未通过 v7 校验）")
			lines.append("%s: 跳过（未通过 v7 校验）" % nm)
			continue
		var d: Dictionary = res.get("data", {})
		var b: Dictionary = MapExport.budget(d, app.manifest, bpx)
		if not bool(b.get("ok", false)):
			skipped.append(nm + "（超预算）")
			lines.append("%s: 跳过（%s）" % [nm, str(b.get("error", ""))])
			continue
		var img := MapExport.render_preview(d, bpx, app.manifest)
		var png_ok := false
		if not img.is_empty():
			png_ok = img.save_png(dir.path_join(nm + ".png")) == OK
		var txt_ok := MapStore.write_text(dir.path_join(nm + ".txt"),
			MapExport.stats_text(nm, d, app.manifest, bpx))
		if png_ok and txt_ok:
			ok_n += 1
			lines.append("%s: PNG + 统计 已写" % nm)
		else:
			var why: Array[String] = []
			if not png_ok:
				why.append("PNG")
			if not txt_ok:
				why.append("统计")
			fail.append(nm + "（" + "/".join(why) + "写失败）")
			lines.append("%s: %s 写失败" % [nm, "/".join(why)])
	if is_instance_valid(btn):
		if (btn.pressed as Signal).is_connected(cancel_cb):
			btn.pressed.disconnect(cancel_cb)
		for ocb in original:
			btn.pressed.connect(ocb)
		btn.text = "导出全部地图（预览图 + 统计）"
	_batch_running = false
	var msg := ("批量导出已取消：" if cancelled else "批量导出完成：") + "%d 张成功" % ok_n
	if not skipped.is_empty():
		msg += "；超预算跳过 %d 张" % skipped.size()
	if not fail.is_empty():
		msg += "；失败 %d 张" % fail.size()
	app._set_status(msg)
	if is_instance_valid(label):
		label.text = msg + "（逐图报告见 editor/exports/_export_report.txt）"
	# 逐图报告落一份文本，便于核对
	MapStore.write_text(dir.path_join("_export_report.txt"), "\n".join(lines) + "\n\n" + msg)
