extends RefCounted
## 地图尺寸设置与裁剪。
## 改尺寸的弹窗预览与真正的裁剪必须用同一判据，否则「预览说裁 3 个、实际裁 5 个」。
## 兼容 v7 的三种条目形态：瓦片六元组、碰撞对象与退役数组、摆放物对象。

const GridSpaceScript := preload("res://src/canvas/grid_space.gd")
const UiKitScript := preload("res://src/ui/ui_kit.gd")
const K := preload("res://src/core/constants.gd")

## 现有条目计数：{tiles, collision, objects}
static func counts(d: Dictionary) -> Dictionary:
	var tiles := 0
	for lid in (d.get("tiles", {}) as Dictionary):
		var cells = (d.get("tiles", {}) as Dictionary)[lid]
		if cells is Array:
			tiles += (cells as Array).size()
	return {"tiles": tiles, "collision": (d.get("collision", []) as Array).size(),
		"objects": (d.get("objects", []) as Array).size()}

static func _layer_columns(d: Dictionary, width: int) -> Dictionary:
	var columns := {}
	for layer in d.get("meta", {}).get("layers", []):
		if layer is Dictionary and layer.get("tileGrid") is Dictionary:
			columns[str(layer.get("id", ""))] = GridSpaceScript.cell_columns(width,
				layer.tileGrid.get("gridTopology", "") == "triangles")
	return columns

static func spawn_change(d: Dictionary, nw: int, nh: int, triangular: bool) -> Dictionary:
	var spawn: Array = d.get("spawn", [2, 2])
	var old := Vector2i(int(spawn[0]), int(spawn[1]))
	var next := old.clamp(Vector2i.ZERO, Vector2i(GridSpaceScript.cell_columns(nw, triangular) - 1, nh - 1))
	return {} if old == next else {"from": old, "to": next}

static func plan(d: Dictionary, nw: int, nh: int, triangular: bool) -> Dictionary:
	var result := d.duplicate(true)
	var count := _crop(result, nw, nh, triangular, true)
	var spawn := spawn_change(d, nw, nh, triangular)
	if not spawn.is_empty():
		result["spawn"] = [spawn.to.x, spawn.to.y]
	result.meta["w"] = nw
	result.meta["h"] = nh
	return {"map": result, "crop": count, "spawn": spawn}

static func _keeps_extent(d: Dictionary, nw: int, nh: int) -> bool:
	var meta: Dictionary = d.get("meta", {})
	return meta.has("w") and meta.has("h") and nw >= int(meta.w) and nh >= int(meta.h)

static func crop_counts(d: Dictionary, nw: int, nh: int, triangular := false) -> Dictionary:
	return _crop(d, nw, nh, triangular, false)

## 扩大时保留界外数据；瓦片和碰撞用拓扑列，摆放物用连续坐标。
static func _crop(d: Dictionary, nw: int, nh: int, triangular: bool, apply: bool) -> Dictionary:
	var out := {"tiles": 0, "collision": 0, "objects": 0}
	if _keeps_extent(d, nw, nh):
		return out
	var columns := GridSpaceScript.cell_columns(nw, triangular)
	var layers := _layer_columns(d, nw)
	var tiles: Dictionary = d.get("tiles", {})
	for lid in tiles:
		if tiles[lid] is Array:
			out.tiles += _crop_rows(tiles[lid], Vector2i(layers.get(lid, columns), nh), "tiles", apply)
	for kind in ["collision", "objects"]:
		if d.get(kind) is Array:
			out[kind] = _crop_rows(d[kind], Vector2i(columns if kind == "collision" else nw, nh), kind, apply)
	return out

## 残缺条目不算界外；真正裁剪时才剔除。
static func _crop_rows(rows: Array, size: Vector2i, kind: String, apply: bool) -> int:
	var kept := []
	var removed := 0
	for row in rows:
		var x: float
		var y: float
		if row is Array and kind != "objects" and row.size() >= 2:
			x = float(int(row[0]))
			y = float(int(row[1]))
		elif row is Dictionary and kind != "tiles":
			x = float(row.get("x", 0)) if kind == "objects" else float(int(row.get("x", 0)))
			y = float(row.get("y", 0)) if kind == "objects" else float(int(row.get("y", 0)))
		else:
			continue
		if x < 0 or y < 0 or x >= size.x or y >= size.y:
			removed += 1
		elif apply:
			kept.append(row)
	if apply:
		rows.assign(kept)
	return removed

static func open(app) -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var meta: Dictionary = app.canvas.map_data.get("meta", {})
	var base: Dictionary = app.canvas.extract()
	if base.is_empty():   # 重建窗口哨兵：此刻读不到可裁剪的数据，别让预览数字是假的
		app._set_status(" 地图重建中，请稍后再试")
		return
	var current: Callable = app._map_file_ctrl.document_guard()
	var live_map: Dictionary = app.canvas.map_data
	var triangular: bool = app.canvas.grid.is_tri()
	var guard := func() -> bool:
		return app.map_loaded and current.call() and is_same(app.canvas.map_data, live_map)
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
		var cur := counts(base)
		var crop := crop_counts(base, int(w_edit.value), int(h_edit.value), triangular)
		var cut: int = int(crop.tiles) + int(crop.collision) + int(crop.objects)
		var head := "当前 %d×%d：瓦片 %d · 碰撞 %d · 摆放物 %d" % [
			int(meta.get("w", K.DEFAULT_MAP_W)), int(meta.get("h", K.DEFAULT_MAP_H)),
			int(cur.tiles), int(cur.collision), int(cur.objects)]
		if cut > 0:
			counts_lbl.text = head + "\n缩到 %d×%d 将裁掉：瓦片 %d · 碰撞 %d · 摆放物 %d（可撤销）" % [
				int(w_edit.value), int(h_edit.value), int(crop.tiles), int(crop.collision), int(crop.objects)]
		else:
			counts_lbl.text = head + "\n目标尺寸不会裁掉数据"
		var spawn := spawn_change(base, int(w_edit.value), int(h_edit.value), triangular)
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
		await _apply_map_size(app, int(w_edit.value), int(h_edit.value), pop,
			str(proj_sel.get_item_metadata(proj_sel.selected)), triangular, guard), "primary"))
	body.add_child(btn_row)
	app._open_popup(pop)

static func _apply_map_size(app, nw: int, nh: int, pop: PopupPanel, proj: String, triangular: bool,
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
	var resize_plan := plan(d, nw, nh, triangular)
	var crop: Dictionary = resize_plan.crop
	var cut: int = int(crop.tiles) + int(crop.collision) + int(crop.objects)
	if cut > 0 or not resize_plan.spawn.is_empty():
		var msg := "目标尺寸 %d×%d。将裁掉：瓦片 %d · 碰撞 %d · 摆放物 %d。" % [
			nw, nh, int(crop.tiles), int(crop.collision), int(crop.objects)]
		if not resize_plan.spawn.is_empty():
			msg += "\n出生点：%s → %s（最近界内格）。" % [resize_plan.spawn.from, resize_plan.spawn.to]
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
	d = resize_plan.map
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
