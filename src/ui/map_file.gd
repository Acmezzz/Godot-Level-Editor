extends RefCounted
## 地图文件生命周期控制器。状态经宿主访问；写盘暂仍走 FileAccess（S-02 收敛在后续批次）。
const MapValidate := preload("res://src/map_validate.gd")
const MapExport := preload("res://src/map_export.gd")
const UiKitScript := preload("res://src/ui/ui_kit.gd")
const UiThemeScript := preload("res://src/ui/ui_theme.gd")

var app   # 宿主引用

func _init(host) -> void:
	app = host

const AUTOSAVE_INTERVAL_MS := 120000
var _last_autosave_msec := 0
var _opened_mtime := 0   # A4.3：打开地图时记录的磁盘 mtime（保存时对比检测外部改动）
var _last_alive_poll := 0   # PF-04：存活轮询节流
var _play_pid := 0
var _play_started_msec: int = 0

## 地图文件生命周期（审查 8.2 块 4：从 app.gd 拆出）——新建/打开/保存/改名迁移/自动保存/试玩/尺寸/导出
func confirm_discard(action: String) -> bool:
	if not app.map_loaded or not app.canvas.modified_flag:
		return true
	var dlg := ConfirmationDialog.new()
	dlg.title = "未保存的修改"
	dlg.dialog_text = "地图 %s 有未保存修改。\n继续%s将丢失这些修改。" % [app.cur_map_name, action]
	dlg.ok_button_text = "放弃修改并继续"
	dlg.cancel_button_text = "取消"
	# 中文正文需要足够宽度，否则 ConfirmationDialog 的 Label 会被压成一条看不见的窄条
	dlg.min_size = Vector2i(460, 0)
	app.add_child(dlg)
	var answer := [false]
	dlg.confirmed.connect(func(): answer[0] = true)
	dlg.popup_centered()
	# 等对话框真正关闭：确认 → true，取消/关闭 → false
	while dlg.visible:
		await app.get_tree().process_frame
	dlg.queue_free()
	return answer[0]

## 通用确认框：删除/不可撤销动作统一走这里（文本与确定钮文案可定制）
func confirm_action(title: String, text: String, ok_text := "确定", danger := false) -> bool:
	var dlg := ConfirmationDialog.new()
	dlg.title = title
	dlg.dialog_text = text
	dlg.ok_button_text = ok_text
	dlg.cancel_button_text = "取消"
	dlg.min_size = Vector2i(460, 0)
	app.add_child(dlg)
	var answer := [false]
	dlg.confirmed.connect(func(): answer[0] = true)
	dlg.popup_centered()
	while dlg.visible:
		await app.get_tree().process_frame
	dlg.queue_free()
	return answer[0]
func on_new() -> void:
	var n: String = app.map_name_edit.text.strip_edges()
	if n == "":
		app._set_status(" 先填地图名再点新建")
		return
	if not EditorManifest.is_valid_map_name(n):
		app._set_status(" 地图名不合法：不能含 / \\ : * ? \" < > | 或以 . 开头")
		return
	if FileAccess.file_exists(EditorManifest.map_path(app.manifest, n)):
		app._set_status(" 同名地图已存在：点【打开】编辑它，或换个名字新建")
		return
	if not await confirm_discard("新建"):
		return
	app.canvas.set_thumbs(app._entity_thumbs())
	app.canvas.load_data({
		"meta": {"name": n, "w": 120, "h": 56},
		"spawn": [2, 2],
		"terrain": [], "decor": [], "collision": [], "entities": [],
	}, n)
	app.cur_map_name = n
	app.cur_map_path = EditorManifest.map_path(app.manifest, n)
	app._sync_play_cfg_to_map()
	app._set_map_loaded(true)
	app.canvas.undo_stack.clear()
	app.canvas.redo_stack.clear()
	app._set_status(" 新建空地图 " + n + "（先保存再试玩）")
	app._refresh_side_panel()

func on_open() -> void:
	if not await confirm_discard("打开另一张地图"):
		return
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.current_dir = str(app.manifest.get("_maps_dir", ""))
	fd.add_filter("*.json")
	fd.file_selected.connect(load_map_file)
	app.add_child(fd)
	fd.popup_centered(Vector2i(700, 500))

func load_map_file(p: String) -> void:
	var result: Dictionary = app.MapStore.read_path(p, app.manifest)
	if not result.ok:
		app._set_status(" 打开失败: " + _format_issues(result.errors))
		return
	var data: Dictionary = result.data
	if not result.warnings.is_empty():
		app._set_status(" 地图已打开但有兼容警告: " + _format_issues(result.warnings))
	# A6：草稿归位——打开 .autosave.json 读草稿数据，但名字/路径/名字框归位正式名；
	# 之后 Ctrl+S 写回正式文件，草稿自然变旧、草稿列表条目消失（与侧栏 tooltip 承诺一致）
	var was_draft := str(p.get_file()).ends_with(".autosave.json")
	var base := p.get_file().get_basename()
	if was_draft:
		base = base.trim_suffix(".autosave")
		p = EditorManifest.map_path(app.manifest, base)
	_opened_mtime = FileAccess.get_modified_time(p)
	app.canvas.set_thumbs(app._entity_thumbs())
	app.canvas.load_data(data, base)
	app.cur_map_name = base
	app._sync_play_cfg_to_map()
	app.cur_map_path = p
	app.map_name_edit.text = base
	app._set_map_loaded(true)
	app.canvas.undo_stack.clear()
	app.canvas.redo_stack.clear()
	var terr: Array = data["terrain"]
	var ents: Array = data["entities"]
	app._set_status(" 已打开 %s%s（%d 瓦片 / %d 实体）" % [
		base, "（草稿归位，保存写回正式文件）" if was_draft else "", terr.size(), ents.size()])
	app._refresh_side_panel()

func _format_issues(issues: Array) -> String:
	var lines: Array[String] = []
	for issue in issues:
		lines.append("%s: %s" % [str(issue.get("path", "map")), str(issue.get("message", "invalid data"))])
	return "; ".join(lines)

## 保存当前地图；返回是否成功（试玩前依赖它决定是否继续）
func on_save() -> bool:
	if not app.map_loaded:
		app._set_status(" 无地图：先新建或打开一张地图")
		return false
	var n: String = app.map_name_edit.text.strip_edges()
	if n == "":
		app._set_status(" 先填地图名再保存")
		return false
	if not EditorManifest.is_valid_map_name(n):
		app._set_status(" 地图名不合法：不能含 / \\ : * ? \" < > | 或以 . 开头")
		return false
	var data: Dictionary = app.canvas.extract()
	data.meta.name = n
	var path := EditorManifest.map_path(app.manifest, n)
	if path == "":
		app._set_status(" 地图名不合法: " + n)
		return false
	var renamed: bool = app.cur_map_name != "" and app.cur_map_name != n
	var old_name: String = app.cur_map_name
	# 改名且目标已存在 → 不静默覆盖别人的地图
	if renamed and FileAccess.file_exists(path):
		app._set_status(" 已存在同名地图 %s，保存被拒绝（换个名字或先打开它）" % n)
		return false
	# A4.3：外部变更检测——打开后磁盘 mtime 变了 = 别处改过这份文件（本次保存会覆盖外部改动）
	var ext_changed := _opened_mtime > 0 and FileAccess.file_exists(path) \
		and FileAccess.get_modified_time(path) != _opened_mtime
	# P-02/S-02：写盘收敛到 MapStore 单入口（.tmp 原子替换，中途崩溃不留半截 JSON）
	if not app.MapStore.write(app.manifest, n, data):
		app._set_status(" 保存失败: " + path)
		return false
	_opened_mtime = FileAccess.get_modified_time(path)
	# 画布与 app 的地图名必须同步：跨图配对/撤销等都以 app.canvas.cur_map_name 为来源
	app.canvas.cur_map_name = n
	app.canvas.map_data["meta"] = data.meta
	app.cur_map_name = n
	app.cur_map_path = path
	app._sync_play_cfg_to_map()
	app.canvas.modified_flag = false
	_last_autosave_msec = Time.get_ticks_msec()
	var msg := " 已保存 %s（%d 瓦片 / %d 实体）" % [n, data.terrain.size(), data.entities.size()]
	if renamed:
		# 自动迁移其他地图里指向旧名的出口，避免死链
		var mig := MapValidate.migrate_map_rename(app.manifest, old_name, n)
		if mig.get("failed", []).is_empty():
			var cnt: int = (mig.get("changed", []) as Array).size()
			msg += "；已迁移 %d 处跨图引用" % cnt
		else:
			msg += "；迁移失败的地图: " + ", ".join(mig.get("failed", []))
	# T23：保存即校验——问题在你按 Ctrl+S 的那一秒出现，而不是三天后
	var v_issues = MapValidate.validate_map(app.manifest, n, data)
	var v_errs := 0
	for it in v_issues:
		if str(it.get("level", "")) == "error":
			v_errs += 1
	if v_errs > 0:
		msg += "；⚠ 本图 %d 个错误（校验页详情）" % v_errs
		# 有错误就把校验区推上来并填好列表：状态栏只报数，点得到才有用
		if app.side_panel != null:
			app.side_panel.set_issues(v_issues)
			app.side_panel.select_tab(2)
	elif v_issues.size() > 0:
		msg += "；本图 %d 个警告" % v_issues.size()
	if ext_changed:
		msg += "；注意：磁盘文件在打开后被外部修改过，本次保存覆盖了外部改动"
	app._set_status(msg)
	app._refresh_side_panel()
	return true

## 自动保存：有未保存修改且距上次保存超过间隔时写入 .autosave.json

func maybe_autosave() -> void:
	if not app.map_loaded or not app.canvas.modified_flag or app.cur_map_name == "":
		return
	if Time.get_ticks_msec() - _last_autosave_msec < AUTOSAVE_INTERVAL_MS:
		return
	var data: Dictionary = app.canvas.extract()
	data.meta.name = app.cur_map_name
	data["_autosave_of"] = app.cur_map_name
	var path := str(app.manifest.get("_maps_dir", "")).path_join(app.cur_map_name + ".autosave.json")
	# P-02/S-02：自动保存同样走原子写
	if not app.MapStore.write_json(path, data):
		return
	_last_autosave_msec = Time.get_ticks_msec()
	app._set_status(" 已自动保存草稿 → %s.autosave.json" % app.cur_map_name)

func on_play(spawn_tiles: Vector2i = Vector2i(-1, -1)) -> void:
	if not app.map_loaded:
		app._set_status(" 无地图：先新建或打开一张地图")
		return
	if app.map_name_edit.text.strip_edges() == "":
		app._set_status(" 试玩前先填地图名并保存")
		return
	if not on_save():
		app._set_status(" 试玩中止：地图未保存成功")
		return
	var res := Playtest.launch_tracked(app.manifest, app.cur_map_path, app._play_args(spawn_tiles))
	if not res.get("ok", false):
		app._set_status(" 试玩失败: " + str(res.get("error", "")))
		return
	_play_pid = int(res.get("pid", 0))
	_play_started_msec = Time.get_ticks_msec()
	app._set_status(" 试玩启动: " + app.cur_map_path.get_file() + "（游戏退出后此处会提示）")

## 试玩进程跟踪：退出后回报一次（Windows tasklist 轮询）

func poll_playtest() -> void:
	# PF-04：is_alive 是阻塞的 tasklist 调用，每帧轮询会卡主线程——1s 节流
	if Time.get_ticks_msec() - _last_alive_poll < 1000:
		return
	_last_alive_poll = Time.get_ticks_msec()
	if _play_pid <= 0:
		return
	# 刚启动的头几秒 tasklist 可能还查不到，先跳过
	if Time.get_ticks_msec() - _play_started_msec < 4000:
		return
	if Playtest.is_alive(_play_pid):
		return
	var secs := int((Time.get_ticks_msec() - _play_started_msec) / 1000.0)
	_play_pid = 0
	# A5.1：试玩日志尾随——游戏侧写 editor/playtest.log，退出后取最后几行（无文件 = 原消息）
	var tail := Playtest.log_tail(str(app.manifest.get("_dir", "")), 4)
	if tail != "":
		app._set_status(" 试玩退出（%d 秒）· 日志: %s" % [secs, tail.replace("
", " | ")])
	else:
		app._set_status(" 试玩进程已退出（运行 %d 秒）" % secs)

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
	w_edit.value = int(meta.get("w", 120))
	row.add_child(UiKitScript.field_row("宽", w_edit))
	var h_edit := SpinBox.new()
	h_edit.min_value = 8
	h_edit.max_value = 4000
	h_edit.step = 1
	h_edit.value = int(meta.get("h", 56))
	row.add_child(UiKitScript.field_row("高", h_edit))
	var btn_row := UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	# apply 回调改走方法：lambda 里不能 await，而 load_data 是协程——
	# 不 await 就 _mark()，置脏会被 load_data 收尾覆盖（BUG-01 第二入口）。
	btn_row.add_child(UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	btn_row.add_child(UiKitScript.button("应用", func(): apply_map_size(int(w_edit.value), int(h_edit.value), pop), "primary"))
	body.add_child(btn_row)
	app._open_popup(pop)

func apply_map_size(nw: int, nh: int, pop: PopupPanel) -> void:
	var d: Dictionary = app.canvas.extract()
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
		var img := MapExport.render_preview(app.canvas.extract(), int(px.value), app.canvas.atlas_imgs, int(app.manifest.get("tileSize", 16)))   # B6/批次 12：多图集+tileSize
		var dir := str(app.manifest.get("_dir", "")).path_join("editor/exports")
		DirAccess.make_dir_recursive_absolute(dir)
		var path := dir.path_join(app.cur_map_name + ".png")
		var err := img.save_png(path)
		app._set_status(("已导出 " + path) if err == OK else ("导出失败（%d）: %s" % [err, path]))
		pop.hide()
	row.add_child(UiKitScript.button("导出预览 PNG", png_cb, "primary"))
	var txt_cb := func():
		var txt := MapExport.stats_text(app.cur_map_name, app.canvas.extract())
		var dir2 := str(app.manifest.get("_dir", "")).path_join("editor/exports")
		DirAccess.make_dir_recursive_absolute(dir2)
		var path2 := dir2.path_join(app.cur_map_name + ".txt")
		# P-02：导出写盘同样走原子写
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
			var img := MapExport.render_preview(d, bpx, app.canvas.atlas_imgs, int(app.manifest.get("tileSize", 16)))
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
# —— 背景图组：只做「选择引用」。图组定义在清单 bgGroups 里手工维护（与瓦片件套同一工作流） ——
func open_bg_dialog() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var shell: Dictionary = app._popup_body("背景图组", "图组在清单 bgGroups 里手工定义（editor/editor_manifest.json）；这里只选择本图引用哪个组。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var groups: Dictionary = app.manifest.get("bgGroups", {})
	var ref_opt := OptionButton.new()
	var info := UiKitScript.text_label("", UiThemeScript.TEXT_MUTE, UiThemeScript.FS_SMALL)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.custom_minimum_size = Vector2(app.POPUP_BODY_W, 0)
	# 选中组 → 只读展示层构成
	var show_info = func(gname: String):
		if gname == "" or not groups.has(gname):
			info.text = "未配置背景：画布与游戏使用默认渐变。"
			return
		var lines: Array[String] = []
		for lay in (groups[gname] as Dictionary).get("layers", []):
			if not (lay is Dictionary):
				continue
			var sc: Array = lay.get("scale", [0.3, 0.1])
			var sx := str(sc[0]) if sc.size() > 0 else "?"
			var sy := str(sc[1]) if sc.size() > 1 else "?"
			lines.append("%s  · 系数 %s,%s · z %d · 平铺%s" % [
				str(lay.get("img", "?")), sx, sy, int(lay.get("z", -8)),
				"开" if bool(lay.get("mirror", true)) else "关"])
		info.text = "\n".join(lines) if not lines.is_empty() else "（该组没有图层）"
	# 本图引用下拉
	var ref_row := UiKitScript.hbox(8)
	ref_row.add_child(UiKitScript.text_label("本图引用", UiThemeScript.TEXT_DIM, UiThemeScript.FS_SMALL))
	ref_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ref_row.add_child(ref_opt)
	body.add_child(ref_row)
	ref_opt.add_item("（无背景）")
	ref_opt.set_item_metadata(0, "")
	var keys: Array = groups.keys()
	keys.sort()
	var sel := 0
	var cur := str(app.canvas.map_data.get("bgGroup", ""))
	var i := 1
	for k in keys:
		ref_opt.add_item(str(k))
		ref_opt.set_item_metadata(i, str(k))
		if str(k) == cur:
			sel = i
		i += 1
	ref_opt.select(sel)
	ref_opt.item_selected.connect(func(_i: int):
		var gname := str(ref_opt.get_item_metadata(ref_opt.selected))
		# E5（批次 12）：选回原值不置脏（无变化不产生撤销步/脏标记）
		if str(app.canvas.map_data.get("bgGroup", "")) == gname:
			show_info.call(gname)
			return
		app.canvas.map_data["bgGroup"] = gname
		app.canvas._mark()
		app.canvas._bg_ctrl.rebuild()
		show_info.call(gname)
		app._set_status("本图背景引用已改为: " + (gname if gname != "" else "（无）")))
	show_info.call(cur)
	body.add_child(UiKitScript.divider())
	body.add_child(info)
	var btn_row := UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_child(UiKitScript.button("关闭", func(): pop.hide(), "ghost"))
	body.add_child(btn_row)
	app._open_popup(pop)


## app._toggle_bg 委托：画布背景显隐切换 + 状态栏开关同步
func toggle_bg() -> void:
	if app.canvas == null:
		return
	app.canvas.bg_visible = not app.canvas.bg_visible
	app.canvas._bg_ctrl.set_visible(app.canvas.bg_visible)
	app._refresh_view_toggles()

func _open_play_cfg() -> void:
	if not app.map_loaded:
		app._set_status("无地图：先新建或打开一张地图")
		return
	var shell = app._popup_body("试玩配置 —— %s" % app.cur_map_name, "只存编辑器本地，不写进地图 JSON。")
	var pop: PopupPanel = shell.pop
	var body: VBoxContainer = shell.body
	var cb_dash := CheckBox.new()
	cb_dash.text = "初始拥有冲刺（羽毛）"
	cb_dash.button_pressed = "dash" in app.play_cfg.get("abilities", [])
	var cb_glide := CheckBox.new()
	cb_glide.text = "初始拥有滑翔（翅膀）"
	cb_glide.button_pressed = "glide" in app.play_cfg.get("abilities", [])
	var sp := SpinBox.new()
	sp.min_value = 0
	sp.max_value = 5
	sp.step = 1
	sp.value = int(app.play_cfg.get("hp", 0))
	sp.suffix = " 心"
	body.add_child(cb_dash)
	body.add_child(cb_glide)
	body.add_child(app.UiKitScript.field_row("初始血量", sp, UiKitScript.LABEL_W))
	body.add_child(app.UiKitScript.hint_label("0 = 用游戏默认（3 心）", app.POPUP_BODY_W))
	var btn_row = app.UiKitScript.hbox(8)
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_child(app.UiKitScript.button("取消", func(): pop.hide(), "ghost"))
	var apply_cfg := func():
		var ab: Array = []
		if cb_dash.button_pressed:
			ab.append("dash")
		if cb_glide.button_pressed:
			ab.append("glide")
		app.play_cfg = {"abilities": ab, "hp": int(sp.value)}
		app._prefs[app.cur_map_name] = app.play_cfg
		app._save_prefs()
		pop.hide()
		app._set_status("试玩配置已应用（仅影响试玩启动参数）")
	btn_row.add_child(app.UiKitScript.button("应用", apply_cfg, "primary"))
	body.add_child(btn_row)
	app._open_popup(pop)


func _play_args(spawn_tiles := Vector2i(-1, -1)) -> PackedStringArray:
	var out: PackedStringArray = []
	var ab: Array = app.play_cfg.get("abilities", [])
	if not ab.is_empty():
		out.append("--abilities=" + ",".join(ab))
	if int(app.play_cfg.get("hp", 0)) > 0:
		out.append("--hp=%d" % int(app.play_cfg.get("hp", 0)))
	if spawn_tiles.x >= 0 and spawn_tiles.y >= 0:
		out.append("--spawnx=%d" % spawn_tiles.x)
		out.append("--spawny=%d" % spawn_tiles.y)
	return out


func _sync_play_cfg_to_map() -> void:
	app.play_cfg = app._prefs.get(app.cur_map_name, {"abilities": [], "hp": 0})

## 实体缩略图：读图后统一裁掉透明留白。
## 预览图都是固定画布 + 居中小图形，不裁的话画布上和调色板里都只是个小点。
