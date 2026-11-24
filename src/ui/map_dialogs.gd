extends RefCounted
## MapDialogs：地图尺寸弹窗（从 map_file.gd 拆出，宿主 = app）。

const UiKitScript := preload("res://src/ui/ui_kit.gd")
const K := preload("res://src/core/constants.gd")
const MapResize := preload("res://src/ui/map_resize.gd")
const DocumentSession := preload("res://src/project/document_session.gd")

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
	var controller = app._map_file_ctrl
	var sess: DocumentSession = controller.sess
	var gen := sess.generation
	var revision := sess.revision
	var live_map: Dictionary = app.canvas.map_data
	var triangular: bool = app.canvas.grid.is_tri()
	var guard := func() -> bool:
		return app.map_loaded and app._map_file_ctrl == controller \
			and not sess.stale(gen) and sess.revision == revision \
			and is_same(app.canvas.map_data, live_map)
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
		var cur := MapResize.counts(base)
		var crop := MapResize.crop_counts(base, int(w_edit.value), int(h_edit.value), triangular)
		var cut: int = int(crop.tiles) + int(crop.collision) + int(crop.objects)
		var head := "当前 %d×%d：瓦片 %d · 碰撞 %d · 摆放物 %d" % [
			int(meta.get("w", K.DEFAULT_MAP_W)), int(meta.get("h", K.DEFAULT_MAP_H)),
			int(cur.tiles), int(cur.collision), int(cur.objects)]
		if cut > 0:
			counts_lbl.text = head + "\n缩到 %d×%d 将裁掉：瓦片 %d · 碰撞 %d · 摆放物 %d（可撤销）" % [
				int(w_edit.value), int(h_edit.value), int(crop.tiles), int(crop.collision), int(crop.objects)]
		else:
			counts_lbl.text = head + "\n目标尺寸不会裁掉数据"
		var spawn := MapResize.spawn_change(base, int(w_edit.value), int(h_edit.value), triangular)
		if not spawn.is_empty():
			counts_lbl.text += "\n出生点将从 %s 移到 %s（最近界内格）" % [spawn.from, spawn.to]
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
	btn_row.add_child(UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	btn_row.add_child(UiKitScript.button("应用", func():
		await apply_map_size(int(w_edit.value), int(h_edit.value), pop,
			str(proj_sel.get_item_metadata(proj_sel.selected)), triangular, guard), "primary"))
	body.add_child(btn_row)
	app._open_popup(pop)

func apply_map_size(nw: int, nh: int, pop: PopupPanel, proj: String, triangular: bool,
		guard: Callable) -> void:
	if not guard.call():
		pop.hide()
		app._set_status("地图已变更，请重新打开尺寸设置")
		return
	var d: Dictionary = app.canvas.extract()
	if d.is_empty():   # 重建窗口哨兵：空快照过 load_data = 清空整图
		app._set_status(" 地图重建中，请稍后再试")
		return
	# 缩小先确认裁剪范围（E3：裁掉多少瓦片/碰撞/摆放物，应用前可见）
	var plan := MapResize.plan(d, nw, nh, triangular)
	var crop: Dictionary = plan.crop
	var cut: int = int(crop.tiles) + int(crop.collision) + int(crop.objects)
	if cut > 0 or not plan.spawn.is_empty():
		var msg := "目标尺寸 %d×%d。将裁掉：瓦片 %d · 碰撞 %d · 摆放物 %d。" % [
			nw, nh, int(crop.tiles), int(crop.collision), int(crop.objects)]
		if not plan.spawn.is_empty():
			msg += "\n出生点：%s → %s（最近界内格）。" % [plan.spawn.from, plan.spawn.to]
		msg += "\n\n应用后可用 Ctrl+Z 恢复地图。"
		pop.hide()
		var accepted: bool = await app._confirm_action("调整地图边界", msg, "应用尺寸")
		if not accepted:
			app._set_status("已取消调整尺寸")
			return
	else:
		pop.hide()
	if not guard.call():
		app._set_status("确认期间地图已变更，请重新打开尺寸设置")
		return
	# 一笔可撤销快照：恢复原尺寸与边缘数据。
	app.canvas.push_undo()
	d = plan.map
	# 逐图投影（B1）：空图可直接选；带内容的地图投影已冻结（弹窗里也禁用），
	# 这里再加一道守卫——数据路径不允许绕过内容检查。
	# 显式写入（含 orthogonal）：删键会让解析回落到项目缺省投影，
	# 项目里有 isometric/hexagonal 资产时「正交」就丢了（V4 P1）。
	if proj != "" and not app.canvas.has_content():
		d["meta"]["gridProjection"] = proj
	var controller_before_load = app._map_file_ctrl
	await app.canvas.load_data(d, app.cur_map_name, true, true)
	if app._map_file_ctrl != controller_before_load or not is_same(app.canvas.map_data, d):
		return
	if cut > 0:
		app._set_status("尺寸已改为 %d×%d，裁掉瓦片 %d / 碰撞 %d / 摆放物 %d（Ctrl+Z 可撤销）" % [
			nw, nh, int(crop.tiles), int(crop.collision), int(crop.objects)])
	else:
		app._set_status("尺寸已改为 %d×%d（记得保存）" % [nw, nh])
